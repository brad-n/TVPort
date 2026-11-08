#!/usr/bin/env python3
"""DMSPARS1: a sparse wrapper for one DMROMFS1 image, with an optional embedded ASTC pack (docs/texture_once.md sections 1 and 7).

The DMROMFS1 image the file represents is the LOGICAL image; the file's own byte offsets are PHYSICAL. Zero runs of the logical image (4,096 bytes or more) are not stored.

    header (64 bytes) | data extents (16-byte aligned) | pack (16,384-byte aligned) | extent table (24 bytes each, 16-byte aligned) | trailer (32 bytes)

Version 2 (docs/texture_once.md 7a) keeps the layout and makes the extent entries 32 bytes {logical, length, physical, u32 stored length, u32 kind}: kind 0 = raw, kind 1 = one zstd frame of at most
256 KiB of logical data. The embedded pack of a v2 image is an NXASTCPK v2 file (56-byte index entries, each payload raw or one zstd frame: 7b); write_pack_v2 makes it from a v1 pack.
Writing is streaming: SparseWriter takes the logical image in increasing offset order (put / put_scanned), never holds more than the piece it is given, and writes the header last.
SparseImage reads and validates a file: a file whose trailer is missing or disagrees with the header (a cut-off copy) is rejected, like the engine's reader does.

Usage (a checker): sparse_image.py FILE            validates FILE and prints its sizes
"""
import array
import bisect
import hashlib
import io
import os
import re
import struct
import sys
import threading
import collections
import concurrent.futures as cf

MAGIC, END_MAGIC = b'DMSPARS1', b'DMSPEND1'
HEAD = struct.Struct('<8sIIQQQQQQ')      # magic, version, header size, logical size, extents, table offset, pack offset, pack size, reserved
TRAILER = struct.Struct('<8sQQQ')        # magic, total file size, table offset, 0
EXTENT = struct.Struct('<QQQ')           # logical offset, length, physical offset
EXTENT2 = struct.Struct('<QQQII')        # v2: + stored length, kind
HEAD_SIZE, TRAILER_SIZE, EXTENT_SIZE = HEAD.size, TRAILER.size, EXTENT.size
EXTENT2_SIZE = EXTENT2.size
RAW, ZSTD = 0, 1
BLOCK = 256 << 10        # the largest zstd extent (logical bytes)
RAW_MAX = 1 << 30        # a raw extent's stored length is a u32
KEEP_RATIO = 97          # a block is stored raw unless it shrinks below this percentage
ZCACHE_MB = 16
MIN_HOLE = 4096          # a zero run shorter than this stays inside an extent
PACK_ALIGN = 16384
PACK_MAGIC, PACK_HEAD = b'NXASTCPK', 80
COPY = 8 << 20

assert HEAD_SIZE == 64 and TRAILER_SIZE == 32 and EXTENT_SIZE == 24 and EXTENT2_SIZE == 32

_ZERO_RUN = re.compile(b'\x00{%d,}' % MIN_HOLE)


class SparseError(ValueError):
    """The file is no complete DMSPARS1 image"""


def split_zero_runs(data):
    """[(a, b)] the parts of `data` that must be stored: everything except zero runs of MIN_HOLE bytes or more (shorter runs stay inside a part)"""
    n = len(data)
    if not n: return []
    if data.count(0) == n: return []
    out, at = [], 0
    for m in _ZERO_RUN.finditer(data):
        if m.start() > at: out.append((at, m.start()))
        at = m.end()
    if at < n: out.append((at, n))
    return out


PACK_ENT = {1: 48, 2: 56}      # NXASTCPK version -> index entry size


def pack_header(buf):
    """(entry count, index offset, file size) of an NXASTCPK v1 or v2 header in `buf` (its first 80 bytes), or SparseError"""
    return pack_header_ex(buf)[:3]


def pack_header_ex(buf):
    """(entry count, index offset, file size, version) of an NXASTCPK header"""
    if len(buf) < PACK_HEAD or buf[:8] != PACK_MAGIC: raise SparseError('the pack is no NXASTCPK file')
    ver, ent, count, ioff, fsize = struct.unpack_from('<IIQQQ', buf, 8)
    if ver not in PACK_ENT or ent != PACK_ENT[ver]: raise SparseError('unsupported NXASTCPK version')
    return count, ioff, fsize, ver


# ---- zstd (the TV's decoder is the engine's, so any conforming frames do) ------------------------------------------------------------------------------------------------------------
_zmod = False


def _zstd():
    global _zmod
    if _zmod is False:
        try:
            from compression import zstd as _zmod
        except ImportError:
            try: from backports import zstd as _zmod
            except ImportError: _zmod = None
    return _zmod


def zcompress(data, level):
    """One zstd frame of `data` at `level`: Python's zstd module, else tex_once_zstd's libzstd"""
    z = _zstd()
    if z is not None: return z.compress(data, level=level)
    import tex_once_zstd as Z
    return Z.compress(data, level)


def zdecompress(frame):
    z = _zstd()
    if z is not None: return z.decompress(frame)
    import bntx_astc
    return bntx_astc.unzstd(bytes(frame), {})


def compress_parts(data, base, level, block=BLOCK):
    """The logical bytes `data` (at logical offset `base`) as extents, zero runs of MIN_HOLE or more left out: [[offset, length, kind, payload]]. Each stored part is cut into blocks of at most
    `block` bytes; a block that does not shrink below KEEP_RATIO percent stays raw, and neighbouring raw blocks join into one raw extent (up to RAW_MAX)"""
    out = []
    mv = memoryview(data)
    for a, b in split_zero_runs(data):
        for c in range(a, b, block):
            e = min(c + block, b); n = e - c
            z = zcompress(mv[c:e], level) if level is not None else None
            if z is not None and len(z) * 100 < n * KEEP_RATIO:
                out.append([base + c, n, ZSTD, z])
            elif out and out[-1][2] == RAW and out[-1][0] + out[-1][1] == base + c and out[-1][1] + n <= RAW_MAX:
                out[-1][3] = bytearray(out[-1][3]) if not isinstance(out[-1][3], bytearray) else out[-1][3]
                out[-1][3] += mv[c:e]; out[-1][1] += n
            else:
                out.append([base + c, n, RAW, mv[c:e]])
    for x in out:
        if x[2] == RAW and isinstance(x[3], memoryview): x[3] = bytes(x[3])      # must outlive `data`
    return out


class SparseWriter:
    """Streams a logical image into a DMSPARS1 file. put(offset, data) with increasing offsets; finish(pack_path) writes the pack, the table and the trailer and publishes the file.
    version=2: extents carry a stored length and a kind; put_parts takes the output of compress_parts (put stays raw)."""

    def __init__(self, path, logical_size, version=1):
        if version not in (1, 2): raise ValueError('version')
        self.version, self.k = version, 3 if version == 1 else 4
        self.path, self.part = path, path + '.part'
        self.logical_size = int(logical_size)
        self.f = open(self.part, 'wb')
        self.f.write(bytes(HEAD_SIZE))
        self.pos = HEAD_SIZE
        self.ext = array.array('Q')        # logical, length, physical (v2: + stored | kind << 32), flat
        self.next_logical = 0              # the logical offset the next put must be at or beyond
        self.open_end = -1                 # logical end of the open extent (a put exactly there continues it)
        self.open_raw = False
        self.stored = 0

    def _pad(self, to):
        if self.pos % to:
            pad = to - self.pos % to
            self.f.write(bytes(pad)); self.pos += pad

    def put(self, offset, data):
        """Store `data` as logical bytes [offset, offset + len). No zero scan: the caller gives the bytes to keep"""
        n = len(data)
        if not n: return
        if offset < self.next_logical or offset + n > self.logical_size: raise SparseError('extent out of order or past the logical size')
        if offset == self.open_end and (self.version == 1 or (self.open_raw and self.ext[-3] + n <= RAW_MAX)):
            self.ext[-self.k + 1] += n
            if self.version == 2: self.ext[-1] += n          # stored length (kind 0)
        else:
            self._pad(16)
            self.ext.extend((offset, n, self.pos) if self.version == 1 else (offset, n, self.pos, n))
        self.open_raw = True
        self.f.write(data)
        self.pos += n; self.stored += n
        self.next_logical = self.open_end = offset + n

    def put_zstd(self, offset, length, frame):
        """v2: logical bytes [offset, offset + length) stored as the zstd frame `frame` (its own extent)"""
        if self.version != 2 or not 0 < length <= BLOCK or not 0 < len(frame) < length: raise SparseError('bad zstd extent')
        if offset < self.next_logical or offset + length > self.logical_size: raise SparseError('extent out of order or past the logical size')
        self._pad(16)
        self.ext.extend((offset, length, self.pos, len(frame) | ZSTD << 32))
        self.f.write(frame); self.pos += len(frame); self.stored += len(frame)
        self.next_logical = self.open_end = offset + length
        self.open_raw = False

    def put_parts(self, parts):
        for off, n, kind, payload in parts:
            if kind == RAW: self.put(off, payload)
            else: self.put_zstd(off, n, payload)

    def put_scanned(self, offset, data):
        """Store logical bytes [offset, offset + len), leaving out their zero runs of MIN_HOLE bytes or more"""
        view = memoryview(data)
        for a, b in split_zero_runs(data): self.put(offset + a, view[a:b])

    def finish(self, pack=None):
        """Write the embedded pack (a path, or None), the extent table, the trailer and the header; publish the file. -> dict(physical, extents, pack_offset, pack_size, pack_sha256)"""
        pack_off = pack_size = 0; digest = ''
        if pack:
            with open(pack, 'rb') as src:
                head = src.read(PACK_HEAD)
                count, ioff, fsize, ver = pack_header_ex(head)
                size = os.fstat(src.fileno()).st_size
                if fsize != size or ioff + PACK_ENT[ver] * count != size: raise SparseError('the pack\'s header disagrees with its size')
                self._pad(PACK_ALIGN)
                pack_off, pack_size = self.pos, size
                h = hashlib.sha256(head); self.f.write(head); self.pos += len(head)
                while True:
                    chunk = src.read(COPY)
                    if not chunk: break
                    h.update(chunk); self.f.write(chunk); self.pos += len(chunk)
                digest = h.hexdigest()
        self._pad(16)
        table_off = self.pos
        self.f.write(self.ext.tobytes() if sys.byteorder == 'little' else b''.join(struct.pack('<Q', v) for v in self.ext))
        self.pos += len(self.ext) * 8
        n_ext = len(self.ext) // self.k
        total = self.pos + TRAILER_SIZE
        self.f.write(TRAILER.pack(END_MAGIC, total, table_off, 0))
        self.f.seek(0)
        self.f.write(HEAD.pack(MAGIC, self.version, HEAD_SIZE, self.logical_size, n_ext, table_off, pack_off, pack_size, 0))
        self.f.flush(); os.fsync(self.f.fileno()); self.f.close()
        os.replace(self.part, self.path)
        return dict(physical=total, extents=n_ext, stored=self.stored, pack_offset=pack_off, pack_size=pack_size, pack_sha256=digest)

    def abort(self):
        try: self.f.close()
        except OSError: pass
        try: os.unlink(self.part)
        except OSError: pass


class _BlockCache:
    """Decompressed blocks, least recently used out first; safe for concurrent readers (docs/texture_once.md 7a: DM_ROMFS_ZCACHE_MB, default 16 MiB)"""
    def __init__(self, cap):
        self.cap, self.size, self.lock, self.d = cap, 0, threading.Lock(), collections.OrderedDict()

    def get(self, key):
        with self.lock:
            v = self.d.get(key)
            if v is not None: self.d.move_to_end(key)
            return v

    def put(self, key, value):
        with self.lock:
            if key in self.d: return
            self.d[key] = value; self.size += len(value)
            while self.size > self.cap and len(self.d) > 1:
                _, old = self.d.popitem(last=False); self.size -= len(old)


class SparseImage:
    """A validated DMSPARS1 file (version 1 or 2). read(offset, n) gives logical bytes (holes read as zero, reads past the logical size are short, like a file); a damaged zstd block is a SparseError."""

    def __init__(self, path):
        self.path = path
        self.fd = os.open(path, os.O_RDONLY)
        try: self._open()
        except BaseException:
            os.close(self.fd); self.fd = -1
            raise

    def _open(self):
        fd = self.fd
        size = os.fstat(fd).st_size
        self.size = size
        if size < HEAD_SIZE + TRAILER_SIZE: raise SparseError('too short for a DMSPARS1 file')
        magic, total, toff, zero = TRAILER.unpack(os.pread(fd, TRAILER_SIZE, size - TRAILER_SIZE))
        if magic != END_MAGIC or total != size or zero != 0: raise SparseError('incomplete DMSPARS1 file (no valid trailer)')
        head = os.pread(fd, HEAD_SIZE, 0)
        magic, ver, hsize, lsize, n, tbl, poff, psize, reserved = HEAD.unpack(head)
        if magic != MAGIC or ver not in (1, 2) or hsize != HEAD_SIZE or reserved != 0: raise SparseError('not a DMSPARS1 header')
        if tbl != toff: raise SparseError('the header and the trailer disagree on the extent table')
        if tbl % 16 or tbl < HEAD_SIZE: raise SparseError('bad extent table offset')
        k = 3 if ver == 1 else 4
        self.version = ver
        if tbl + n * 8 * k > size - TRAILER_SIZE: raise SparseError('extent table passes the trailer')
        self.logical_size, self.count, self.table_offset = lsize, n, tbl
        raw = os.pread(fd, n * 8 * k, tbl)
        if len(raw) != n * 8 * k: raise SparseError('extent table cut off')
        flat = array.array('Q'); flat.frombytes(raw)
        if sys.byteorder != 'little': flat.byteswap()
        self.lo, self.len, self.phys = flat[0::k], flat[1::k], flat[2::k]
        if ver == 1:
            self.stored, self.kind = self.len, array.array('B', bytes(n))
        else:
            tail = flat[3::4]
            self.stored = array.array('Q', (v & 0xffffffff for v in tail)); self.kind = array.array('Q', (v >> 32 for v in tail))
        prev_end = 0
        for i in range(n):
            lo, ln, ph, st, kd = self.lo[i], self.len[i], self.phys[i], self.stored[i], self.kind[i]
            if ln == 0 or lo < prev_end or lo + ln > lsize: raise SparseError(f'bad extent {i}')
            if kd == RAW:
                if st != ln: raise SparseError(f'raw extent {i} stored length differs from its length')
            elif kd == ZSTD:
                if not 0 < st < ln or ln > BLOCK: raise SparseError(f'bad zstd extent {i}')
            else: raise SparseError(f'extent {i} has an unknown kind')
            if ph % 16 or ph < HEAD_SIZE or ph + st > tbl: raise SparseError(f'extent {i} outside the file\'s data area')
            prev_end = lo + ln
        self.pack_offset, self.pack_size = poff, psize
        self.pack_version = 0
        if poff or psize:
            if poff % PACK_ALIGN or poff < HEAD_SIZE or poff + psize > tbl or psize < PACK_HEAD: raise SparseError('bad pack placement')
            count, ioff, fsize, pver = pack_header_ex(os.pread(fd, PACK_HEAD, poff))
            if fsize != psize or ioff + PACK_ENT[pver] * count != psize: raise SparseError('the embedded pack\'s header disagrees with its size')
            self.pack_version = pver
        mb = int(os.environ.get('DM_ROMFS_ZCACHE_MB', ZCACHE_MB) or ZCACHE_MB)
        self.cache = _BlockCache(max(mb, 1) << 20)

    def close(self):
        if self.fd >= 0: os.close(self.fd); self.fd = -1

    def __enter__(self): return self
    def __exit__(self, *a): self.close()

    def extents(self):
        """[(logical offset, length, physical offset)]"""
        return list(zip(self.lo, self.len, self.phys))

    def extents_ex(self):
        """[(logical offset, length, physical offset, stored length, kind)]"""
        return list(zip(self.lo, self.len, self.phys, self.stored, self.kind))

    def block(self, i):
        """The logical bytes of extent i (a zstd extent is inflated once and cached)"""
        v = self.cache.get(i)
        if v is not None: return v
        frame = os.pread(self.fd, self.stored[i], self.phys[i])
        if len(frame) != self.stored[i]: raise SparseError('file cut off inside an extent')
        try: v = zdecompress(frame)
        except Exception as e: raise SparseError(f'[RED] damaged zstd block at logical {self.lo[i]:#x}: {e}') from None
        if len(v) != self.len[i]: raise SparseError(f'[RED] zstd block at logical {self.lo[i]:#x} inflates to {len(v)} bytes, not {self.len[i]}')
        self.cache.put(i, v)
        return v

    def read(self, offset, n):
        """Logical bytes [offset, offset + n): holes read as zero; short at the logical end"""
        if offset < 0 or n < 0: raise ValueError('negative read')
        n = max(0, min(n, self.logical_size - offset))
        out = bytearray(n)
        if not n: return bytes(out)
        end = offset + n
        i = max(bisect.bisect_right(self.lo, offset) - 1, 0)
        while i < self.count and self.lo[i] < end:
            a = max(self.lo[i], offset); b = min(self.lo[i] + self.len[i], end)
            if b > a:
                if self.kind[i] == RAW:
                    got = os.pread(self.fd, b - a, self.phys[i] + (a - self.lo[i]))
                    if len(got) != b - a: raise SparseError('file cut off inside an extent')
                else:
                    blk = self.block(i); got = blk[a - self.lo[i]:b - self.lo[i]]
                out[a - offset:b - offset] = got
            i += 1
        return bytes(out)

    def read_pack(self, offset, n):
        """Bytes of the embedded pack (offsets relative to the pack's start)"""
        if not self.pack_size: raise SparseError('no embedded pack')
        n = max(0, min(n, self.pack_size - offset))
        return os.pread(self.fd, n, self.pack_offset + offset)

    def iter_logical(self, start=0, end=None, chunk=COPY):
        """(offset, bytes) pieces of the logical image in order"""
        end = self.logical_size if end is None else min(end, self.logical_size)
        for o in range(start, end, chunk): yield o, self.read(o, min(chunk, end - o))

    def hole_bytes(self):
        return self.logical_size - sum(self.len)

    def inflate_all(self):
        """Inflates every zstd extent (not cached); -> (zstd extents, raw extents). SparseError on the first damaged one"""
        z = 0
        for i in range(self.count):
            if self.kind[i] != ZSTD: continue
            frame = os.pread(self.fd, self.stored[i], self.phys[i])
            try: v = zdecompress(frame)
            except Exception as e: raise SparseError(f'damaged zstd block at logical {self.lo[i]:#x}: {e}') from None
            if len(v) != self.len[i]: raise SparseError(f'zstd block at logical {self.lo[i]:#x} inflates to {len(v)} bytes, not {self.len[i]}')
            z += 1
        return z, self.count - z


# ---- the embedded pack: NXASTCPK v2 (docs/texture_once.md 7b) ---------------------------------------------------------------------------------------------------------------------
_P = {}


def _read_index(path, base=0, size=None):
    """(version, header bytes, [(key, offset, stored, size)]) of an NXASTCPK file (or the part of a file at base)"""
    fd = os.open(path, os.O_RDONLY)
    try:
        head = os.pread(fd, PACK_HEAD, base)
        count, ioff, fsize, ver = pack_header_ex(head)
        raw = os.pread(fd, PACK_ENT[ver] * count, base + ioff)
    finally: os.close(fd)
    if len(raw) != PACK_ENT[ver] * count: raise SparseError('pack index cut off')
    ent = []
    for i in range(count):
        e = raw[PACK_ENT[ver] * i:PACK_ENT[ver] * (i + 1)]
        if ver == 1:
            off, sz = struct.unpack_from('<QQ', e, 32); ent.append((e[:32], off, sz, sz))
        else:
            off, st, sz = struct.unpack_from('<QQQ', e, 32); ent.append((e[:32], off, st, sz))
    return ver, head, ent


def _pack_compress_task(job):
    path, level, items = job
    fd = _P.get(path)
    if fd is None: fd = _P[path] = os.open(path, os.O_RDONLY)
    out = []
    for off, size in items:
        d = os.pread(fd, size, off)
        if len(d) != size: raise SparseError('pack cut off')
        z = zcompress(d, level)
        out.append(d if len(z) >= size else z)
    return out


def write_pack_v2(src, dst, level, workers=4, batch_bytes=8 << 20, progress=None):
    """Re-writes the NXASTCPK v1 pack `src` as a v2 pack at `dst`: every distinct payload compressed on its own (kept raw when it does not shrink), shared payloads stay shared, the index keeps its
    (sorted) order, payloads and index 16-byte aligned. -> dict(entries, payloads, size, zstd, raw, logical, stored)"""
    ver, head, ent = _read_index(src)
    if ver != 1: raise SparseError('the source pack is no v1 pack')
    payloads = sorted({(o, sz) for _, o, _, sz in ent})
    for (o1, s1), (o2, _) in zip(payloads, payloads[1:]):
        if o1 + s1 > o2: raise SparseError('overlapping payloads in the pack')
    jobs, cur, acc = [], [], 0
    for p in payloads:
        cur.append(p); acc += p[1]
        if acc >= batch_bytes: jobs.append((src, level, cur)); cur, acc = [], 0
    if cur: jobs.append((src, level, cur))
    part = dst + '.part'
    where, st = {}, collections.Counter()
    with open(part, 'wb') as f, cf.ProcessPoolExecutor(max(1, workers)) as ex:
        f.write(bytes(PACK_HEAD)); pos = PACK_HEAD
        pi = 0
        for n, res in enumerate(ex.map(_pack_compress_task, jobs)):
            for data in res:
                off, size = payloads[pi]; pi += 1
                if pos % 16: f.write(bytes(16 - pos % 16)); pos += 16 - pos % 16
                f.write(data)
                where[(off, size)] = (pos, len(data), size)
                st['zstd' if len(data) < size else 'raw'] += 1; st['logical'] += size; st['stored'] += len(data)
                pos += len(data)
            if progress: progress(n + 1, len(jobs))
        if pos % 16: f.write(bytes(16 - pos % 16)); pos += 16 - pos % 16
        ioff = pos
        for key, off, _, size in ent:
            o, stl, sz = where[(off, size)]
            f.write(key + struct.pack('<QQQ', o, stl, sz))
        total = ioff + 56 * len(ent)
        f.seek(0)
        f.write(b'NXASTCPK' + struct.pack('<IIQQQ', 2, 56, len(ent), ioff, total) + head[40:80])
        f.flush(); os.fsync(f.fileno())
    os.replace(part, dst)
    return dict(entries=len(ent), payloads=len(payloads), size=total, **{k: st[k] for k in ('zstd', 'raw', 'logical', 'stored')})


def _pack_verify_task(job):
    img, base, src, items = job
    fi = _P.get(img) or _P.setdefault(img, os.open(img, os.O_RDONLY))
    fs = _P.get(src) or _P.setdefault(src, os.open(src, os.O_RDONLY))
    bad = []
    for (so, ssz), (no, nst, nsz) in items:
        want = os.pread(fs, ssz, so)
        got = os.pread(fi, nst, base + no)
        if len(got) != nst: bad.append(f'payload at {so:#x}: cut off'); continue
        if nst != nsz:
            try: got = zdecompress(got)
            except Exception as e: bad.append(f'payload at {so:#x}: damaged zstd frame ({e})'); continue
        if got != want: bad.append(f'payload at {so:#x} differs from the source pack')
    return bad


def verify_pack_v2(img, base, size, src, workers=4, batch_bytes=16 << 20):
    """Checks the v2 pack embedded in `img` at `base` against the v1 pack `src`: the same keys in the same order, every payload inflates to the source's bytes, the index is sorted and aligned.
    -> list of problems"""
    ver, head, new = _read_index(img, base)
    ver0, head0, old = _read_index(src)
    if ver != 2 or ver0 != 1: return ['pack versions are not v2 (embedded) and v1 (source)']
    if len(new) != len(old): return ['the embedded pack has another number of entries']
    problems = []
    if head[40:80] != head0[40:80]: problems.append('the embedded pack header differs from the source (fingerprint)')
    if [e[0] for e in new] != [e[0] for e in old]: return problems + ['the embedded pack index keys differ from the source']
    if any(new[i][0] >= new[i + 1][0] for i in range(len(new) - 1)): problems.append('the embedded pack index is not sorted')
    pairs = {}
    for o, n in zip(old, new):
        if n[3] != o[3]: problems.append('an entry\'s size differs'); break
        if n[2] > n[3] or n[1] % 16 or n[1] + n[2] > size: problems.append('an entry is misplaced'); break
        prev = pairs.setdefault((o[1], o[3]), (n[1], n[2], n[3]))
        if prev != (n[1], n[2], n[3]): problems.append('entries sharing a payload disagree'); break
    if problems: return problems
    items = sorted(pairs.items())
    jobs, cur, acc = [], [], 0
    for it in items:
        cur.append(it); acc += it[0][1]
        if acc >= batch_bytes: jobs.append((img, base, src, cur)); cur, acc = [], 0
    if cur: jobs.append((img, base, src, cur))
    with cf.ProcessPoolExecutor(max(1, workers)) as ex:
        for bad in ex.map(_pack_verify_task, jobs): problems += bad
    return problems[:20]


class LogicalFile(io.RawIOBase):
    """A read-only file over the LOGICAL image of a DMSPARS1 file (what a plain DMROMFS1 file would hold): read / readinto / seek / tell, and .size"""
    def __init__(self, sparse):
        self.sparse, self.pos, self.size = sparse, 0, sparse.logical_size

    def readable(self): return True
    def seekable(self): return True
    def tell(self): return self.pos

    def seek(self, offset, whence=0):
        pos = offset + (self.pos if whence == 1 else self.size if whence == 2 else 0)
        if whence not in (0, 1, 2) or pos < 0: raise ValueError('invalid seek')
        self.pos = pos
        return pos

    def readinto(self, buffer):
        data = self.sparse.read(self.pos, len(buffer))
        buffer[:len(data)] = data; self.pos += len(data)
        return len(data)

    def close(self):
        if not self.closed: self.sparse.close()
        super().close()


def is_sparse(path):
    try:
        with open(path, 'rb') as f: return f.read(8) == MAGIC
    except (OSError, TypeError): return False


def open_logical(path):
    """The file at `path` for reading as a DMROMFS1 image: a plain file as it is, a DMSPARS1 file as a LogicalFile (buffered)"""
    if is_sparse(path): return io.BufferedReader(LogicalFile(SparseImage(path)), COPY)
    return open(path, 'rb')


def validate(path):
    """Open the file (every structural check) -> dict of its sizes; raises SparseError for a file that is no complete DMSPARS1 image"""
    with SparseImage(path) as s:
        return dict(physical=s.size, logical=s.logical_size, extents=s.count, stored=sum(s.len), stored_physical=sum(s.stored), version=s.version, pack_offset=s.pack_offset, pack_size=s.pack_size)


if __name__ == '__main__':
    if len(sys.argv) != 2: sys.exit(__doc__)
    try: print(validate(sys.argv[1]))
    except SparseError as e: sys.exit(f'invalid: {e}')
