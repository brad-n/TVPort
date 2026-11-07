#!/usr/bin/env python3
"""DMSPARS1: a sparse wrapper for one DMROMFS1 image, with an optional embedded ASTC pack (docs/texture_once.md section 1).

The DMROMFS1 image the file represents is the LOGICAL image; the file's own byte offsets are PHYSICAL. Zero runs of the logical image (4,096 bytes or more) are not stored.

    header (64 bytes) | data extents (16-byte aligned) | pack (16,384-byte aligned) | extent table (24 bytes each, 16-byte aligned) | trailer (32 bytes)

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

MAGIC, END_MAGIC = b'DMSPARS1', b'DMSPEND1'
HEAD = struct.Struct('<8sIIQQQQQQ')      # magic, version, header size, logical size, extents, table offset, pack offset, pack size, reserved
TRAILER = struct.Struct('<8sQQQ')        # magic, total file size, table offset, 0
EXTENT = struct.Struct('<QQQ')           # logical offset, length, physical offset
HEAD_SIZE, TRAILER_SIZE, EXTENT_SIZE = HEAD.size, TRAILER.size, EXTENT.size
MIN_HOLE = 4096          # a zero run shorter than this stays inside an extent
PACK_ALIGN = 16384
PACK_MAGIC, PACK_HEAD = b'NXASTCPK', 80
COPY = 8 << 20

assert HEAD_SIZE == 64 and TRAILER_SIZE == 32 and EXTENT_SIZE == 24

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


def pack_header(buf):
    """(entry count, index offset, file size) of an NXASTCPK header in `buf` (its first 80 bytes), or SparseError"""
    if len(buf) < PACK_HEAD or buf[:8] != PACK_MAGIC: raise SparseError('the pack is no NXASTCPK file')
    ver, ent, count, ioff, fsize = struct.unpack_from('<IIQQQ', buf, 8)
    if ver != 1 or ent != 48: raise SparseError('unsupported NXASTCPK version')
    return count, ioff, fsize


class SparseWriter:
    """Streams a logical image into a DMSPARS1 file. put(offset, data) with increasing offsets; finish(pack_path) writes the pack, the table and the trailer and publishes the file."""

    def __init__(self, path, logical_size):
        self.path, self.part = path, path + '.part'
        self.logical_size = int(logical_size)
        self.f = open(self.part, 'wb')
        self.f.write(bytes(HEAD_SIZE))
        self.pos = HEAD_SIZE
        self.ext = array.array('Q')        # logical, length, physical, flat
        self.next_logical = 0              # the logical offset the next put must be at or beyond
        self.open_end = -1                 # logical end of the open extent (a put exactly there continues it)
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
        if offset == self.open_end:
            self.ext[-2] += n
        else:
            self._pad(16)
            self.ext.extend((offset, n, self.pos))
        self.f.write(data)
        self.pos += n; self.stored += n
        self.next_logical = self.open_end = offset + n

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
                count, ioff, fsize = pack_header(head)
                size = os.fstat(src.fileno()).st_size
                if fsize != size or ioff + 48 * count != size: raise SparseError('the pack\'s header disagrees with its size')
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
        total = self.pos + TRAILER_SIZE
        self.f.write(TRAILER.pack(END_MAGIC, total, table_off, 0))
        self.f.seek(0)
        self.f.write(HEAD.pack(MAGIC, 1, HEAD_SIZE, self.logical_size, len(self.ext) // 3, table_off, pack_off, pack_size, 0))
        self.f.flush(); os.fsync(self.f.fileno()); self.f.close()
        os.replace(self.part, self.path)
        return dict(physical=total, extents=len(self.ext) // 3, stored=self.stored, pack_offset=pack_off, pack_size=pack_size, pack_sha256=digest)

    def abort(self):
        try: self.f.close()
        except OSError: pass
        try: os.unlink(self.part)
        except OSError: pass


class SparseImage:
    """A validated DMSPARS1 file. read(offset, n) gives logical bytes (holes read as zero, reads past the logical size are short, like a file)."""

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
        if magic != MAGIC or ver != 1 or hsize != HEAD_SIZE or reserved != 0: raise SparseError('not a DMSPARS1 header')
        if tbl != toff: raise SparseError('the header and the trailer disagree on the extent table')
        if tbl % 16 or tbl < HEAD_SIZE: raise SparseError('bad extent table offset')
        if tbl + n * EXTENT_SIZE > size - TRAILER_SIZE: raise SparseError('extent table passes the trailer')
        self.logical_size, self.count, self.table_offset = lsize, n, tbl
        raw = os.pread(fd, n * EXTENT_SIZE, tbl)
        if len(raw) != n * EXTENT_SIZE: raise SparseError('extent table cut off')
        flat = array.array('Q'); flat.frombytes(raw)
        if sys.byteorder != 'little': flat.byteswap()
        self.lo, self.len, self.phys = flat[0::3], flat[1::3], flat[2::3]
        prev_end = 0
        for i in range(n):
            lo, ln, ph = self.lo[i], self.len[i], self.phys[i]
            if ln == 0 or lo < prev_end or lo + ln > lsize: raise SparseError(f'bad extent {i}')
            if ph % 16 or ph < HEAD_SIZE or ph + ln > tbl: raise SparseError(f'extent {i} outside the file\'s data area')
            prev_end = lo + ln
        self.pack_offset, self.pack_size = poff, psize
        if poff or psize:
            if poff % PACK_ALIGN or poff < HEAD_SIZE or poff + psize > tbl or psize < PACK_HEAD: raise SparseError('bad pack placement')
            count, ioff, fsize = pack_header(os.pread(fd, PACK_HEAD, poff))
            if fsize != psize or ioff + 48 * count != psize: raise SparseError('the embedded pack\'s header disagrees with its size')

    def close(self):
        if self.fd >= 0: os.close(self.fd); self.fd = -1

    def __enter__(self): return self
    def __exit__(self, *a): self.close()

    def extents(self):
        """[(logical offset, length, physical offset)]"""
        return list(zip(self.lo, self.len, self.phys))

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
                got = os.pread(self.fd, b - a, self.phys[i] + (a - self.lo[i]))
                if len(got) != b - a: raise SparseError('file cut off inside an extent')
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
        return dict(physical=s.size, logical=s.logical_size, extents=s.count, stored=sum(s.len), pack_offset=s.pack_offset, pack_size=s.pack_size)


if __name__ == '__main__':
    if len(sys.argv) != 2: sys.exit(__doc__)
    try: print(validate(sys.argv[1]))
    except SparseError as e: sys.exit(f'invalid: {e}')
