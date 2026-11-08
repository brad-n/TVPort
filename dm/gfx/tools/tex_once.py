#!/usr/bin/env python3
"""Store textures once (docs/texture_once.md): turn a RomFS image and the ASTC pack built from it into ONE sparse image that carries both.

Every plane the pack covers is overwritten in place in the game's files by a tag (the first 8 bytes of the plane's pack key) and zeros: sizes and offsets never change. Compressed
containers are recompressed into their own slot (Yaz0: zero tail; zstd: the rest of the slot is one zstd skippable frame of zeros; Smash's data.arc: the entry's stored size in the
archive's table is updated and the table is rewritten into its own slot the same way). The result is written as a DMSPARS1 file (sparse_image.py): zero runs are not stored, and the
pack is embedded unchanged. The runtime resolves a tagged plane straight to its pack entry; anything else behaves as before.

A plane's "length" for the tag rule is its stored length as the runtime computes it (nvn_astc_plane_storage: whole GOBs, ceil(row bytes / 64) wide x the block rows x block size) at its storage
offset; exactly [offset, offset + length) is overwritten (a plane under 16 bytes is never touched), so [8, length) reads as zeros.
The levels above the texture cap (the runtime never loads them) are zeroed whole and carry no tag.

Usage: tex_once.py <RomFS.img | build folder> --pack astc-ro.pack --out DIR [--max-dim N] [--block 4|6] [--bc1-block 4|5|6] [--workers N] [--json]
Output DIR: romfs.img (DMSPARS1, the pack embedded), report.json. Exit 0 only when the self-check passed (or the inputs are unchanged and nothing was rewritten).
The self-check re-reads the written file: every byte outside the covered planes equals the original, every tagged plane reads tag + zeros and its tag resolves in the pack (exactly one
entry of the plane's ASTC size), every container parses, the DMROMFS1 header and index are byte-identical and the embedded pack is the given pack.
"""
import argparse
import bisect
import collections
import concurrent.futures as cf
import ctypes
import hashlib
import json
import os
import re
import struct
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import bntx_astc as B
import sparse_image as S
import tex_once_zstd as Z

TOOL_VERSION = 1
TASK_BYTES = 64 << 20
ZSTD_MAGIC = b'\x28\xb5\x2f\xfd'
SKIPPABLE_FIRST = 0x184d2a50
YAZ0_CHAIN = 64
ZSTD_LEVELS = (3, 10, 19)
TABLE_LEVELS = (22,)      # Smash's data.arc table is stored at the strongest level: a weaker one does not fit its slot (level 19: 142 KB too big, level 22: 146 KB to spare)
MIN_PLANE = 16            # planes whose stored length (nvn_astc_plane_storage) is under this are never tagged (a tag is 8 bytes)
BC1_FORMATS = (0x1a01, 0x1a06)
NATIVE_SOURCE = os.path.join(HERE, 'tex_once_native.c')


def debug_mode():
    """Hidden bisect switch TEX_ONCE_DEBUG (Smash boot hang, 2026-11-08); empty = the normal tool.
    repack-only: every container the normal run touches is re-packed the same way, but its planes are left as they are (the decompressed contents equal the original; no pack is embedded).
    zero-only: planes are tagged + zeroed only in containers that need no re-compression (raw NUTEXB / BNTX / SARC, uncompressed data.arc entries); every zstd / Yaz0 container and the data.arc table stay byte-identical."""
    m = os.environ.get('TEX_ONCE_DEBUG', '')
    if m not in ('', 'repack-only', 'zero-only'): raise SystemExit(f'TEX_ONCE_DEBUG={m!r}: expected repack-only or zero-only')
    return m


class Mismatch(Exception):
    """The self-check found a difference the strip must not make"""


# ---- native library ------------------------------------------------------------------------------------------------------------------------------------------------------------------
def build_native(work):
    """libtex_once (the Yaz0 encoder), cached in work by its source's hash. -> path"""
    with open(NATIVE_SOURCE, 'rb') as f: tag = hashlib.sha256(f.read()).hexdigest()[:16]
    lib = os.path.join(work, f'libtex_once-{tag}.dylib')
    if os.path.exists(lib): return lib
    os.makedirs(work, exist_ok=True)
    part = lib + f'.{os.getpid()}.part'
    B.run(['clang', '-O2', '-dynamiclib' if sys.platform == 'darwin' else '-shared', '-fPIC', '-o', part, NATIVE_SOURCE])
    os.replace(part, lib)
    return lib


def native_open(path):
    N = ctypes.CDLL(path)
    N.dm_yaz0_pack.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int]
    N.dm_yaz0_pack.restype = ctypes.c_int64
    return N


def yaz0_pack(N, data, cap):
    """The Yaz0 stream of `data` if it fits in `cap` bytes, else None"""
    out = ctypes.create_string_buffer(cap)
    r = N.dm_yaz0_pack(B.addr(data), len(data), out, cap, YAZ0_CHAIN)
    return None if r < 0 else out.raw[:r]


def skippable_frame(n):
    """A zstd skippable frame of exactly n bytes (n >= 8) whose content is zeros"""
    return struct.pack('<II', SKIPPABLE_FIRST, n - 8) + bytes(n - 8)


def zstd_header(f):
    """The layout of a zstd frame's header: (frame header descriptor byte, window descriptor byte or None), or None for no frame"""
    return Z.frame_header(f)


def zstd_compress(data, level, zd=None, like=None):
    """One zstd frame of `data` from the encoder without RLE blocks / RLE literals (tex_once_zstd), with the header layout of `like`, the original frame it replaces.
    Smash's own zstd decoder takes only the layout the game shipped with (every frame in its data.arc, table included: descriptor 0 = no content size, a window descriptor,
    no checksum, no dictionary ID) and hung at boot on frames with RLE blocks, so the new frame copies the original's flags and its window and uses no RLE."""
    return Z.compress(data, level, zd.dict_content if zd else None, like)


def zstd_stream(data, slot, zd=None, like=None):
    """`data` as one zstd frame of at most `slot` bytes (tries stronger levels when the first does not fit), or None. like: the original frame, whose header layout the new one copies"""
    for level in ZSTD_LEVELS[:2 if len(data) > (32 << 20) else 3]:
        comp = zstd_compress(data, level, zd, like)
        if len(comp) <= slot: return comp
    return None


def zstd_slot(data, slot, zd=None, min_tail=0, levels=None, like=None):
    """`data` compressed into exactly `slot` bytes: the stream, then one skippable frame of zeros to the slot's end. None when it does not fit, or leaves a tail of 1..7 bytes (no room for the frame's header)"""
    for level in levels or ZSTD_LEVELS[:2 if len(data) > (32 << 20) else 3]:
        comp = zstd_compress(data, level, zd, like)
        tail = slot - len(comp)
        if tail == 0 and not min_tail: return comp
        if tail >= max(8, min_tail): return comp + skippable_frame(tail)
    return None


def zstd_table_frame(fs, stored, like):
    """The data.arc table `fs` as exactly one frame (no padding, no skippable frame) of at most `stored` bytes with the header layout of `like`, the original frame, or None"""
    for level in TABLE_LEVELS:
        comp = zstd_compress(fs, level, None, like)
        if len(comp) <= stored: return comp
    return None


class NvnTexdesc(ctypes.Structure):   # nvn_texdesc, dm/gfx/nvn/nvn_tex.h
    _fields_ = [('target', ctypes.c_int), ('format', ctypes.c_int), ('flags', ctypes.c_int), ('samples', ctypes.c_int), ('width', ctypes.c_uint32), ('height', ctypes.c_uint32),
                ('depth', ctypes.c_uint32), ('levels', ctypes.c_uint32), ('stride', ctypes.c_uint32), ('pkg_block_h', ctypes.c_int)]


def plane_storage(L, desc, level, layer):
    """(offset in the texture's storage, length) of a plane's stored bytes: the runtime's own nvn_astc_plane_storage (dm/gfx/tex/nvn_astc_planes.c) when the library has it; until it is merged,
    the same computation from the engine's geometry functions (whole GOBs: ceil(row bytes / 64) x ceil(rows / block height) blocks). None for a texture that cannot be deswizzled"""
    off, ln = ctypes.c_uint64(), ctypes.c_uint64()
    if hasattr(L, 'nvn_astc_plane_storage'):
        f = L.nvn_astc_plane_storage
        f.argtypes = [ctypes.POINTER(NvnTexdesc), ctypes.c_uint, ctypes.c_uint, ctypes.POINTER(ctypes.c_uint64), ctypes.POINTER(ctypes.c_uint64)]
        f.restype = ctypes.c_int
        return (off.value, ln.value) if f(ctypes.byref(desc), level, layer, ctypes.byref(off), ctypes.byref(ln)) == 0 else None
    g, gobs = L.nvn_deswizzle_geom, L.nvn_tex_level_gobs
    u32, u64, up = ctypes.c_uint32, ctypes.c_uint64, ctypes.c_uint
    g.argtypes = [ctypes.POINTER(NvnTexdesc), up, up, ctypes.POINTER(u32), ctypes.POINTER(u32), ctypes.POINTER(u32), ctypes.POINTER(u64), ctypes.POINTER(up), ctypes.POINTER(up), ctypes.POINTER(u32)]
    g.restype = ctypes.c_int
    gobs.argtypes = [ctypes.POINTER(NvnTexdesc), up]; gobs.restype = u32
    rb, rows, slices, base, th, td, bpb = u32(), u32(), u32(), u64(), up(), up(), u32()
    if g(ctypes.byref(desc), level, layer, *(ctypes.byref(x) for x in (rb, rows, slices, base, th, td, bpb))): return None
    lb = max(gobs(ctypes.byref(desc), level) * 64, rb.value)
    gobs_x = (lb + 63) >> 6
    blocks_y = (rows.value + 8 * (1 << th.value) - 1) >> (3 + th.value)
    return base.value, gobs_x * blocks_y * 512 * (1 << th.value) * (1 << td.value)


# ---- the pack ------------------------------------------------------------------------------------------------------------------------------------------------------------------------
class PackIndex:
    """The pack's sorted index: raw 32-byte key -> ASTC payload bytes, and how many entries share (8-byte key prefix, payload bytes): the runtime resolves a tag only when that is exactly one"""
    def __init__(self, path):
        with open(path, 'rb') as f:
            count, ioff, fsize = S.pack_header(f.read(S.PACK_HEAD))
            f.seek(ioff); raw = f.read(48 * count)
        if len(raw) != 48 * count: raise ValueError('pack index cut off')
        self.keys, self.prefix = {}, collections.Counter()
        for i in range(count):
            k = raw[48 * i:48 * i + 32]
            astc = struct.unpack_from('<Q', raw, 48 * i + 40)[0] - 40
            self.keys[k] = astc; self.prefix[(k[:8], astc)] += 1

    def resolves(self, tag, astc):
        return self.prefix.get((tag, astc), 0) == 1


def sarc_ranges(d):
    """(name, start, end) of each member of a SARC, in d"""
    hl, bom, size, doff = struct.unpack_from('<HHII', d, 4)
    n = struct.unpack_from('<H', d, hl + 6)[0]
    names = hl + 12 + 16 * n + 8
    if not names <= doff <= len(d): raise ValueError('damaged SARC')
    for i in range(n):
        h, attr, s, e = struct.unpack_from('<IIII', d, hl + 12 + 16 * i)
        if not s <= e <= len(d) - doff: raise ValueError('SARC member outside the archive')
        if attr >> 24:
            o = names + (attr & 0xffffff) * 4; z = d.find(b'\0', o)
            nm = d[o:z if z >= 0 else len(d)].decode('utf-8', 'replace')
        else: nm = f'#{i}'
        yield nm, doff + s, doff + e


# ---- the walker: strip and check share the container dispatch and the texture plan -----------------------------------------------------------------------------------------------
class Walker:
    def __init__(self, lib, native, block, max_dim, pack, dicts, bc1_block=None):
        self.L, self.N = B.lib_open(lib), native_open(native)
        self.block, self.max_dim, self.pack, self.dicts = block, max_dim, pack, dicts
        self.bc1_block = bc1_block or block
        self.c = collections.Counter(); self.errors = []; self.new_csz = None
        self.mf = []; self.meta = {}; self.item = ''   # --manifest: one record per tagged plane the strip keeps (meta: the planes of the texture being planned, by offset)
        self.zdicts = {}
        self.debug = debug_mode()

    # -- textures
    def plan(self, d, t):
        """What to do with one texture of d: None (not a format the pack covers), ('skip', reason, planes) or ('ok', mods, small) with mods = [(offset in d, length, tag or None, ASTC bytes)]:
        tag + zeros over [plane storage offset, + its stored length) for a plane the pack holds, zeros alone over a whole level above the cap; `small` counts the planes under MIN_PLANE bytes left as they are"""
        L = self.L
        if 'bad' in t: return None
        eligible = B.BC_ELIGIBLE.get(t['fmt'])
        if not eligible: return None
        tg = B.target_of(t)
        if tg is None or t['samples'] > 1 or t['dimension'] == 2: return ('skip', 'ineligible_shape', 0)
        target, depth = tg
        if t['w'] == 0 or t['h'] == 0 or (not t['offs'] and not t.get('auto')) or t['w'] > 16384 or t['h'] > 16384: return ('skip', 'unparsed', 0)
        nvn, alt = eligible
        pkg = 0 if t.get('auto') else (t['layout'] & 0xff) + 1
        start, size, mips = t['start'], t['size'], t['mips']
        if start + size > t['end']: return ('skip', 'short', 0)
        total = L.dm_texture_size(target, nvn, t['w'], t['h'], depth, mips, pkg)
        offs = [L.dm_level_offset(target, nvn, t['w'], t['h'], depth, mips, pkg, i) for i in range(mips)]
        if t['offs']:
            if [o - t['offs'][0] for o in t['offs']] != offs: return ('skip', 'layout_differs', 0)
        elif total != size: return ('skip', 'layout_differs', 0)
        if not total or total > size: return ('skip', 'layout_failed', 0)
        layers = depth if target in (4, 8, 9) else 1
        ls = total // layers
        cap = mips * (depth + 1) + 8
        out = (B.Plane * cap)()
        blk = self.bc1_block if t['fmt'] in BC1_FORMATS else self.block        # BC1 has its own ASTC block (DM_NVN_BC1_ASTC), every other format the general one
        n = L.dm_texture_planes(target, nvn, t['w'], t['h'], depth, mips, pkg, B.addr(d) + start, size, blk, alt, None, 0, out, cap, self.max_dim)
        if n < 0: return ('skip', 'layout_failed', 0)
        skip = L.dm_skip_levels(target, nvn, t['w'], t['h'], depth, mips, self.max_dim)
        desc = NvnTexdesc(target, nvn, 0, 0, t['w'], t['h'], depth, mips, 0, pkg)
        mods, small = [], 0
        self.meta = {}
        for i in range(n):
            p = out[i]
            key = bytes.fromhex(p.key.decode())
            if self.pack.keys.get(key) != p.astc_bytes: return ('skip', 'not_in_pack', n)
            tag = key[:8]
            if not any(tag) or not self.pack.resolves(tag, p.astc_bytes): return ('skip', 'tag_ambiguous', n)
            st = plane_storage(L, desc, p.level, p.layer)
            if st is None: return ('skip', 'layout_failed', n)
            if st[1] < MIN_PLANE: small += 1; continue
            if st[0] + st[1] > size: return ('skip', 'short', n)
            mods.append((start + st[0], st[1], tag, p.astc_bytes))
            self.meta[start + st[0]] = (nvn, t['w'], t['h'], p.level, p.layer, p.astc_bytes, st[1], blk, key.hex())
        for level in range(skip):
            lo = offs[level]; hi = offs[level + 1] if level + 1 < mips else ls
            for layer in range(layers): mods.append((start + layer * ls + lo, hi - lo, None, 0))
        return ('ok', mods, small)

    def leaf(self, d, texs):
        """Strip the textures of d (a BNTX file, a BFRES with BNTX inside, a NUTEXB). -> the new bytes, or None when nothing changes"""
        c = self.c
        buf = None
        taken, exact = [], {}
        for t in texs:
            c['textures'] += 1
            p = self.plan(d, t)
            if p is None: continue
            if p[0] == 'skip':
                c['textures_skipped:' + p[1]] += 1; c['planes_skipped:' + p[1]] += p[2]; continue
            mods, small = p[1], p[2]
            c['planes_small_untouched'] += small
            if not mods: continue
            fresh = []
            conflict = False
            for off, span, tag, astc in mods:
                if exact.get(off) == (span, tag): continue
                i = bisect.bisect_left(taken, (off, 0))
                if (i and taken[i - 1][1] > off) or (i < len(taken) and taken[i][0] < off + span) or off in exact: conflict = True; break
                fresh.append((off, span, tag))
            if conflict:
                c['textures_skipped:overlap'] += 1; c['planes_skipped:overlap'] += len(mods); continue
            if buf is None: buf = bytearray(d)
            if self.debug == 'repack-only': continue     # the container counts as touched (it is re-packed by the caller) but its planes stay
            for off, span, tag, astc in mods:
                if tag is None: buf[off:off + span] = bytes(span)
                else: buf[off:off + 8] = tag; buf[off + 8:off + span] = bytes(span - 8)
                c['planes_zeroed_cap' if tag is None else 'planes_tagged'] += 1
                if tag is not None: self.mf.append((tag.hex(),) + self.meta[off] + (self.item,))
            for off, span, tag in fresh:
                bisect.insort(taken, (off, off + span)); exact[off] = (span, tag)
            c['textures_changed'] += 1
        return bytes(buf) if buf is not None else None

    def check_leaf(self, o, n, texs):
        """The strip's result n of the leaf o: every covered plane is untouched, or tag + zeros (tag resolving in the pack), or zeros (a level above the cap); nothing else differs"""
        v = self.c
        exp = bytearray(o)
        for t in texs:
            p = self.plan(o, t)
            if p is None or p[0] == 'skip': continue
            kinds = []
            for off, span, tag, astc in p[1]:
                want = bytes(span) if tag is None else tag + bytes(span - 8)
                seg = n[off:off + span]
                if seg == want: kinds.append('zero' if tag is None else 'tag')
                elif seg == o[off:off + span]: kinds.append('same')
                else: raise Mismatch(f'plane at {off:#x} (+{span}) is neither untouched, nor tag + zeros, nor zeros')
                if tag is not None and not self.pack.resolves(tag, astc): raise Mismatch(f'tag {tag.hex()} does not resolve in the pack')
                exp[off:off + span] = want
            if 'same' in kinds and len(set(kinds)) > 1: raise Mismatch('a texture is only partly rewritten')
            if kinds and 'same' not in kinds:
                v['textures_changed'] += 1
                v['planes_tagged'] += kinds.count('tag'); v['planes_zeroed_cap'] += kinds.count('zero')
        if bytes(exp) != n: raise Mismatch('bytes changed outside the covered planes')

    # -- containers
    def kind(self, d, name, hint):
        m = d[:4]
        if m == ZSTD_MAGIC or (len(m) == 4 and struct.unpack('<I', m)[0] in B.SKIPPABLE): return 'zstd'
        if m == b'Yaz0': return 'yaz0'
        if m == b'SARC': return 'sarc'
        if name.endswith('.nutexb'): return 'nutexb'
        if m in (b'BNTX', b'FRES', b'EFFN') or hint.endswith(('.bfres', '.bntx', '.bkres')) or name.endswith(('.bfres', '.bntx', '.bkres')): return 'bntx'
        return 'other'

    def bntx_textures(self, d):
        texs = []
        for mt in re.finditer(b'BNTX\0\0\0\0', d):
            if B.bntx_ok(d, mt.start()): texs += B.bntx_textures(d, mt.start())
        return texs

    def zdict(self, d):
        z = B.zstd_module()
        did = B.zstd_dict_id(d)
        if did and did in self.dicts:
            if did not in self.zdicts: self.zdicts[did] = z.ZstdDict(self.dicts[did])
            return self.zdicts[did]
        return None

    def fit_zstd(self, data, orig, top):
        """`data` compressed into the slot of `orig`: the stream and one skippable frame of zeros to the slot's end (a data.arc entry whose size the table records: the stream and a zero tail).
        None when it does not fit (or leaves a tail under 8 bytes, too short for the frame's header)"""
        if top == 'arc':
            comp = zstd_stream(data, len(orig), self.zdict(orig), like=orig)
            if comp is None: return None
            self.new_csz = len(comp)
            return comp + bytes(len(orig) - len(comp))
        return zstd_slot(data, len(orig), self.zdict(orig), like=orig)

    def sub(self, d, name, depth, hint, top=None):
        """strip() with its own counters: -> (new bytes or None, the counters it made); an error leaves the container as it is"""
        saved, saved_mf = self.c, self.mf; self.c = collections.Counter(); self.mf = []
        try: r = self._strip(d, name, depth, hint, top)
        except Exception as e:   # a container the walk cannot read stays untouched, counted, never fatal
            self.c = collections.Counter(); self.mf = []; self.c['container_errors'] += 1; self.errors.append(f'{name}: {type(e).__name__}: {e}'); r = None
        delta = self.c; delta.mf = self.mf; self.c, self.mf = saved, saved_mf
        return r, delta

    def strip(self, d, name, depth=0, hint='', top=None):
        r, delta = self.sub(d, name, depth, hint, top)
        self.take(delta)
        return r

    def take(self, delta):
        """A container's counters (and manifest records) are kept"""
        self.c.update(delta); self.mf += delta.mf

    def reject(self, delta, reason):
        """The container keeps its original bytes: what its textures would have changed is counted as skipped for `reason`"""
        for k, v in delta.items():
            if k in ('planes_tagged', 'planes_zeroed_cap'): self.c['planes_skipped:' + reason] += v
            elif k == 'textures_changed': self.c['textures_skipped:' + reason] += v
            elif k.startswith(('recompressed:',)): continue
            else: self.c[k] += v

    def _strip(self, d, name, depth, hint, top):
        c = self.c
        if depth > B.MAX_DEPTH: c['too_deep'] += 1; return None
        kind = self.kind(d, name, hint)
        if self.debug == 'zero-only' and kind in ('zstd', 'yaz0'): c['debug_compressed_left'] += 1; return None
        if kind == 'zstd':
            c['zstd'] += 1
            dec = B.unzstd(d, self.dicts)
            r, delta = self.sub(dec, name, depth + 1, hint)
            if r is None: self.take(delta); return None
            new = self.fit_zstd(r, d, top)
            if new is None: self.reject(delta, 'zstd_no_fit'); c['recompress_failed:zstd'] += 1; return None
            self.take(delta); c['recompressed:zstd'] += 1
            return new
        if kind == 'yaz0':
            c['yaz0'] += 1
            dec = B.unyaz0(d, self.L)
            r, delta = self.sub(dec, name, depth + 1, hint)
            if r is None: self.take(delta); return None
            comp = yaz0_pack(self.N, r, len(d))
            if comp is None: self.reject(delta, 'yaz0_no_fit'); c['recompress_failed:yaz0'] += 1; return None
            self.take(delta); c['recompressed:yaz0'] += 1
            return d[:16] + comp[16:] + bytes(len(d) - len(comp))
        if kind == 'sarc':
            c['sarc'] += 1
            buf = None
            for nm, s, e in sarc_ranges(d):
                r = self.strip(d[s:e], name + '/' + nm, depth + 1, nm)
                if r is not None:
                    if buf is None: buf = bytearray(d)
                    buf[s:e] = r
            return bytes(buf) if buf is not None else None
        if kind == 'nutexb':
            c['nutexb'] += 1
            t = B.nutexb_texture(d)
            return self.leaf(d, [t]) if t else None
        if kind == 'bntx':
            texs = self.bntx_textures(d)
            c['bntx'] += 1
            return self.leaf(d, texs)
        c['other_files'] += 1
        return None

    def process_item(self, d, name, arc=False):
        """One file of the image (or one entry of data.arc): -> (new bytes of the same length or None, the entry's new stored size when it changed and the archive's table records it)"""
        self.new_csz = None; self.item = name
        r = self.strip(d, name, 0, '', 'arc' if arc else None)
        return r, self.new_csz

    # -- the self-check
    def check(self, o, n, name, depth=0, hint='', top_csz=None):
        """n is the strip's result for o (the same slot): it must be what strip() makes of it. Raises Mismatch"""
        if top_csz is None and len(o) != len(n): raise Mismatch(f'{name}: the slot changed size')
        if top_csz is None and o == n: return
        kind = self.kind(o, name, hint)
        if kind == 'zstd':
            nn = n
            if top_csz is not None:
                if n[top_csz:].count(0) != len(n) - top_csz: raise Mismatch(f'{name}: bytes after the new stream are not zero')
                nn = n[:top_csz]
            if nn[:4] != ZSTD_MAGIC and not (len(nn) >= 4 and struct.unpack('<I', nn[:4])[0] in B.SKIPPABLE): raise Mismatch(f'{name}: no zstd frame')
            if o != n:
                try: bad = Z.forbidden(nn, o, skippable_ok=top_csz is None)   # a data.arc entry never gets a skippable frame (zero tail); other zstd files are padded with one to fill their slot
                except (ValueError, IndexError) as e: raise Mismatch(f'{name}: the new zstd data is not a readable frame run ({e})')
                if bad: raise Mismatch(f'{name}: the new zstd frame uses {bad}, which the original does not; the game decodes only the original archive\'s features')
            ho, hn = zstd_header(o), zstd_header(nn)
            if ho is not None and hn is not None and o != n and ho != hn:
                raise Mismatch(f'{name}: zstd frame header changed ({ho} -> {hn}); the game decodes only the original layout')
            do, dn = B.unzstd(o, self.dicts), B.unzstd(nn, self.dicts)
            if len(do) != len(dn): raise Mismatch(f'{name}: the inflated size changed')
            self.check(do, dn, name, depth + 1, hint)
            self.c['containers_checked:zstd'] += 1
            return
        if kind == 'yaz0':
            if n[:4] != b'Yaz0' or n[4:16] != o[4:16]: raise Mismatch(f'{name}: Yaz0 header changed')
            do, dn = B.unyaz0(o, self.L), B.unyaz0(n, self.L)
            self.check(do, dn, name, depth + 1, hint)
            self.c['containers_checked:yaz0'] += 1
            return
        if kind == 'sarc':
            exp = bytearray(o)
            for nm, s, e in sarc_ranges(o):
                self.check(o[s:e], n[s:e], name + '/' + nm, depth + 1, nm)
                exp[s:e] = n[s:e]
            if bytes(exp) != n: raise Mismatch(f'{name}: SARC bytes outside its members changed')
            return
        if kind == 'nutexb':
            t = B.nutexb_texture(o)
            if not t: raise Mismatch(f'{name}: NUTEXB changed but does not parse')
            return self.check_leaf(o, n, [t])
        if kind == 'bntx': return self.check_leaf(o, n, self.bntx_textures(o))
        raise Mismatch(f'{name}: bytes changed in a file that holds no covered textures')


# ---- tasks ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------
_W = {}


def worker_init(cfg):
    if cfg.get('zstd_work'): Z.configure(cfg['zstd_work'])
    pack = PackIndex(cfg['pack'])
    _W.update(cfg=cfg, w=Walker(cfg['lib'], cfg['native'], cfg['block'], cfg['max_dim'], pack, cfg['dicts'], cfg.get('bc1_block')), fd=os.open(cfg['romfs'], os.O_RDONLY))
    if cfg.get('sparse'): _W['sparse'] = S.SparseImage(cfg['sparse'])


def pread_full(fd, n, off):
    out = bytearray()
    while len(out) < n:
        got = os.pread(fd, min(n - len(out), 1 << 30), off + len(out))
        if not got: raise OSError('image cut off')
        out += got
    return out


def strip_task(task):
    w, fd = _W['w'], _W['fd']
    lo, hi, items = task['lo'], task['hi'], task['items']
    w.c = collections.Counter(); w.errors = []; w.mf = []
    buf = pread_full(fd, hi - lo, lo)
    mods = []
    for name, off, size, arc in items:
        d = bytes(buf[off - lo:off - lo + size])
        r, csz = w.process_item(d, name, arc)
        if r is not None:
            buf[off - lo:off - lo + size] = r
            mods.append((off, size, csz))
    ext = [] if _W['cfg'].get('manifest') else [(lo + a, bytes(buf[a:b])) for a, b in S.split_zero_runs(buf)]
    return dict(lo=lo, ext=ext, mods=mods, c=dict(w.c), errors=w.errors[:20], n_errors=len(w.errors), mf=w.mf)


def check_task(task):
    w, fd, sp = _W['w'], _W['fd'], _W['sparse']
    lo, hi, items = task['lo'], task['hi'], task['items']
    w.c = collections.Counter()
    o = pread_full(fd, hi - lo, lo)
    n = sp.read(lo, hi - lo)
    exp = bytearray(o)
    for name, off, size, csz in items:
        a, b = off - lo, off - lo + size
        try: w.check(bytes(o[a:b]), n[a:b], name, top_csz=csz)
        except Mismatch as e: return dict(error=str(e), lo=lo)
        except Exception as e: return dict(error=f'{name}: {type(e).__name__}: {e}', lo=lo)
        exp[a:b] = n[a:b]
    if bytes(exp) != n:
        i = next(i for i in range(len(n)) if exp[i] != n[i])
        return dict(error=f'bytes differ from the original outside the covered planes, first at {lo + i:#x}', lo=lo)
    return dict(c=dict(w.c), lo=lo)


# ---- planning ------------------------------------------------------------------------------------------------------------------------------------------------------------------------
def candidate(fd, name, off, size):
    """Whether an item may hold covered textures (the same filter bntx_astc's workers use)"""
    if size < 4 and not name.endswith(B.HINTS): return False
    head = os.pread(fd, 4, off)
    return head in B.KNOWN_MAGIC or (len(head) == 4 and head[1:4] == b'*M\x18' and 0x50 <= head[0] <= 0x5f) or name.endswith(B.HINTS)


def partition(total, marks, target=TASK_BYTES):
    """Tasks that tile [0, total): {'lo', 'hi', 'items', 'kind'} in order. marks: sorted [(off, size, payload, kind)] ('item' or 'table'); an item stays whole in one task, a table is its own task"""
    tasks = []
    state = dict(cur=None, pos=0)

    def close():
        cur = state['cur']
        if cur is not None and state['pos'] > cur['lo']: tasks.append(dict(lo=cur['lo'], hi=state['pos'], items=cur['items'], kind='items' if cur['items'] else 'raw'))
        state['cur'] = None

    def raw(lo, hi):
        while lo < hi:
            step = min(hi, lo + target)
            tasks.append(dict(lo=lo, hi=step, items=[], kind='raw')); lo = step

    for off, size, payload, kind in marks:
        if off < state['pos']: continue                  # overlapping items: the later one stays as bytes
        if off - state['pos'] > target:
            close(); raw(state['pos'], off); state['pos'] = off
        if kind == 'table' or size >= target:
            if state['cur'] is None and state['pos'] < off: state['cur'] = dict(lo=state['pos'], items=[])
            state['pos'] = off; close()
            tasks.append(dict(lo=off, hi=off + size, items=[payload] if kind != 'table' else [], kind=kind, payload=payload if kind == 'table' else None))
            state['pos'] = off + size
            continue
        if state['cur'] is None: state['cur'] = dict(lo=state['pos'], items=[])
        state['cur']['items'].append(payload)
        state['pos'] = off + size
        if state['pos'] - state['cur']['lo'] >= target: close()
    close()
    raw(state['pos'], total)
    at = 0
    for t in tasks:
        if t['lo'] != at: raise AssertionError(f'partition gap at {at:#x}')
        at = t['hi']
    if at != total: raise AssertionError('partition does not reach the end')
    return tasks


# ---- data.arc ------------------------------------------------------------------------------------------------------------------------------------------------------------------------
class Arc:
    """Smash's data.arc inside the image: its entries are items of their own (their stored size lives in the archive's zstd-compressed table); with `table` on, a recompressed entry
    keeps its stream and a zero tail and the table is rewritten into its own slot, else the entry is padded with a skippable frame like any zstd file and the table stays"""
    def __init__(self, romfs, files, want_table):
        import smash_arc
        self.sa = smash_arc
        self.base, self.size = next((o, s) for n, o, s in files if n == '/data.arc')
        self.T = smash_arc.table(romfs + '/data.arc')
        if self.T is None: return
        self.fd = smash_arc.fd_by_offset(self.T)
        self.table_off = self.base + self.T['fs_off']
        self.table_size = 16 + self.T['stored']
        self.table = False
        if want_table:
            fs = bytes(self.T['fs'])
            fits = zstd_table_frame(fs, self.T['stored'], None) is not None
            self.table = fits and self.table_off + self.table_size <= self.base + self.size

    def usable(self, entries):
        """Table mode needs every entry before the table (the table is written once all their sizes are known)"""
        if self.table and any(off + size > self.table_off for _, off, size in entries): self.table = False

    def build_table(self, orig, updates):
        """The table's slot (header, stream, padding) with each updated entry's stored size; updates: {offset in the archive: new stored size}. -> (slot, the table's new bytes)"""
        T = self.T
        fs = bytearray(T['fs']); old = self.old_csz
        n = 0
        for at, new in updates.items():
            for fdi in self.fd.get(at, ()):
                p = T['FD'] + 16 * fdi + 4
                if struct.unpack_from('<I', fs, p)[0] == old[at]: struct.pack_into('<I', fs, p, new); n += 1
        frame = zstd_table_frame(bytes(fs), T['stored'], orig[16:16 + T['stored']])
        if frame is None: raise RuntimeError('the rewritten data.arc table does not fit its slot')
        ho = zstd_header(orig[16:])
        if zstd_header(frame) != ho: raise Mismatch(f'the rewritten data.arc table frame has header {zstd_header(frame)}, the original {ho}: the game decodes only the original layout')
        bad = Z.forbidden(frame, orig[16:16 + T['stored']])
        if bad: raise Mismatch(f'the rewritten data.arc table frame uses {bad}, which the original table does not')
        # like the original: the table is one frame, its header's stored size is the frame's length (not the slot's), zeros after it, the section size unchanged
        hdr = orig[:8] + struct.pack('<I', len(frame)) + orig[12:16]
        return hdr + frame + bytes(T['stored'] - len(frame)), bytes(fs)


# ---- run ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------
def log(msg): print('tex_once: ' + msg, file=sys.stderr, flush=True)


def tool_hash():
    h = hashlib.sha256()
    for f in ('tex_once.py', 'sparse_image.py', 'tex_once_native.c', 'tex_once_zstd.py', 'tex_once_zstd.patch' if False else 'tex_once_zstd_norle.patch', 'tex_once_zstd_build.sh'):
        with open(os.path.join(HERE, f), 'rb') as fh: h.update(fh.read())
    return h.digest()


def read_report(path):
    try:
        with open(path) as f: return json.load(f)
    except (OSError, ValueError): return {}


def find_astc_lib(pack, out):
    tag = B.sources_hash()[:16]
    cand = os.path.join(os.path.dirname(os.path.abspath(pack)), 'lib', f'libastc_prebuild-{tag}.dylib')
    return cand if os.path.exists(cand) else B.build_library(os.path.join(out, 'lib'))


def tidy(report):
    return {k: v for k, v in sorted(report.items())}


def split_counters(c):
    skipped_p = {k.split(':', 1)[1]: v for k, v in c.items() if k.startswith('planes_skipped:')}
    skipped_t = {k.split(':', 1)[1]: v for k, v in c.items() if k.startswith('textures_skipped:')}
    cont = {k: v for k, v in c.items() if k in ('zstd', 'yaz0', 'sarc', 'bntx', 'nutexb', 'other_files', 'container_errors', 'too_deep') or k.startswith(('recompressed:', 'recompress_failed:'))}
    return dict(
        planes=dict(tagged=c.get('planes_tagged', 0), zeroed_above_cap=c.get('planes_zeroed_cap', 0), untouched_under_16_bytes=c.get('planes_small_untouched', 0), skipped=skipped_p),
        textures=dict(seen=c.get('textures', 0), changed=c.get('textures_changed', 0), skipped=skipped_t), containers=cont)


def run(args):
    t0 = time.monotonic()
    dbg = debug_mode()
    if dbg: log(f'DEBUG MODE {dbg}: not a shippable image')
    romfs = B.find_romfs(args.input)
    if not os.path.isfile(romfs): log(f'[RED] {romfs} is a folder: tex_once needs a RomFS image'); return 2
    if S.is_sparse(romfs): log(f'[RED] {romfs} is already a DMSPARS1 image'); return 2
    block, max_dim = int(args.block), max(int(args.max_dim or 0), 0)
    bc1 = int(args.bc1_block or block)
    out = os.path.abspath(args.out); pack = os.path.abspath(args.pack)
    os.makedirs(out, exist_ok=True)
    have = B.read_pack_header(pack)
    if not have: log(f'[RED] {pack} is no complete ASTC pack'); return 2
    fp_args = {} if bc1 == block else {'bc1_block': bc1}      # a pack built without --bc1-block is the pack of today: same fingerprint
    expect = None
    if not args.no_pack_check:
        try: expect = B.fingerprint(romfs, block, max_dim, **fp_args)
        except TypeError: log('[RED] this bntx_astc.py has no --bc1-block'); return 2
    if expect is not None and have['fingerprint'] != expect:
        log(f'[RED] {pack} was not built from this RomFS, cap {max_dim}, block {block}x{block}' + (f', BC1 block {bc1}' if bc1 != block else '') + ': build it again with bntx_astc.py'); return 2
    import romfs as romfs_mod
    img = romfs_mod.Image(romfs)
    logical = os.path.getsize(romfs)
    fp = hashlib.sha256(b'tex_once %d\0' % TOOL_VERSION + tool_hash() + b'size %d\0max_dim %d\0block %d\0bc1 %d\0arc %s\0dbg %s\0' % (logical, max_dim, block, bc1, args.arc_mode.encode(), dbg.encode())
                        + hashlib.sha256(img.index).digest() + have['fingerprint'] + b'%d' % have['bytes']).hexdigest()
    target, rep_path = os.path.join(out, 'romfs.img'), os.path.join(out, 'report.json')
    old = read_report(rep_path)
    if old.get('input_fingerprint') == fp and old.get('self_check', {}).get('passed') and not args.force:
        try:
            if S.validate(target)['physical'] == old['bytes']['physical']:
                log('up to date: the inputs are unchanged, nothing rewritten')
                if args.json: print(json.dumps(old, indent=1))
                return 0
        except (OSError, S.SparseError): pass
    for f in (target, rep_path): 
        if os.path.exists(f): os.unlink(f)
    lib = find_astc_lib(pack, out)
    native = build_native(os.path.join(out, 'lib'))
    Z.configure(os.path.join(out, 'lib')); Z.build(os.path.join(out, 'lib'))
    files = B.image_files(romfs)
    dicts = B.zs_dicts(romfs, files, lib)
    arc = None
    if any(n == '/data.arc' for n, _, _ in files):
        arc = Arc(romfs, files, args.arc_mode == 'table' and dbg != 'zero-only')       # zero-only: the table is never rewritten
        if arc.T is None: arc = None
    arc_base = arc.base if arc else 0
    items = B.smash_arc_files(romfs, files)
    items = sorted((i for i in items if i[2] > 0), key=lambda i: i[1])
    if arc:
        entries = [i for i in items if i[0].startswith('/data.arc#')]
        arc.usable(entries)
        arc.old_csz = {off - arc_base: size for _, off, size in entries}
    log(f'{len(items)} files, {logical / 2**30:.1f} GiB; cap {max_dim or "none"}, ASTC {block}x{block}; arc table {"on" if arc and arc.table else "off"}; {args.workers} workers')
    fd = os.open(romfs, os.O_RDONLY)
    marks = []
    for name, off, size in items:
        if candidate(fd, name, off, size): marks.append((off, size, (name, off, size, bool(arc and arc.table and name.startswith('/data.arc#'))), 'item'))
    if arc and arc.table: marks.append((arc.table_off, arc.table_size, None, 'table'))
    marks.sort(key=lambda m: m[0])
    tasks = partition(logical, marks)
    cfg = dict(lib=lib, native=native, block=block, bc1_block=bc1, max_dim=max_dim, pack=pack, dicts=dicts, romfs=romfs, zstd_work=os.path.join(out, 'lib'))
    writer = S.SparseWriter(target, logical)
    totals = collections.Counter(); errors = []; n_errors = 0
    updates, mods_by_task, table_new = {}, {}, None
    t1 = time.monotonic(); last = t1
    try:
        with cf.ProcessPoolExecutor(args.workers, initializer=worker_init, initargs=(cfg,)) as ex:
            pending = collections.deque(); it = iter(enumerate(tasks))

            def fill():
                while len(pending) < args.workers * 3:
                    nxt = next(it, None)
                    if nxt is None: return
                    i, t = nxt
                    pending.append((i, t, None if t['kind'] == 'table' else ex.submit(strip_task, t)))
            fill(); done = 0
            while pending:
                i, t, fut = pending.popleft()
                if t['kind'] == 'table':
                    orig = bytes(pread_full(fd, t['hi'] - t['lo'], t['lo']))
                    slot, table_new = arc.build_table(orig, updates)
                    r = dict(ext=[(t['lo'] + a, slot[a:b]) for a, b in S.split_zero_runs(slot)], mods=[], c={'containers_table': 1}, errors=[], n_errors=0)
                    table_slot = slot
                else: r = fut.result()
                for off, data in r['ext']: writer.put(off, data)
                totals.update(r['c']); errors += r['errors']; n_errors += r['n_errors']
                mods_by_task[i] = r['mods']
                for off, size, csz in r['mods']:
                    if csz is not None: updates[off - arc_base] = csz
                done += 1
                if time.monotonic() - last > 15: last = time.monotonic(); log(f'strip {done}/{len(tasks)} tasks, {last - t1:.0f} s')
                fill()
    except BaseException:
        writer.abort(); raise
    embed = dbg != 'repack-only'
    stats = writer.finish(pack if embed else None)
    strip_seconds = time.monotonic() - t1
    log(f'written: {stats["physical"] / 2**30:.2f} GB ({stats["stored"] / 2**30:.2f} GB of RomFS + {stats["pack_size"] / 2**30:.2f} GB pack), {strip_seconds:.0f} s; checking')
    # ---- self-check
    t2 = time.monotonic()
    problems = []
    name_of = {m[0]: m[2] for m in marks if m[3] == 'item'}
    vtasks = []
    for i, t in enumerate(tasks):
        mods = mods_by_task.get(i, [])
        if t['kind'] == 'table': continue
        vitems = [(name_of[off][0], off, size, csz) for off, size, csz in mods]
        vtasks.append(dict(lo=t['lo'], hi=t['hi'], items=vitems))
    vcfg = dict(cfg, sparse=target)
    vtotals = collections.Counter()
    with cf.ProcessPoolExecutor(args.workers, initializer=worker_init, initargs=(vcfg,)) as ex:
        for r in ex.map(check_task, vtasks):
            if 'error' in r: problems.append(f'{r["lo"]:#x}: {r["error"]}')
            else: vtotals.update(r['c'])
    with S.SparseImage(target) as sp:
        if sp.logical_size != logical: problems.append('logical size differs from the RomFS image')
        if sp.read(0, 32) != os.pread(fd, 32, 0): problems.append('DMROMFS1 header differs')
        ioff = struct.unpack_from('<Q', os.pread(fd, 32, 0), 8)[0]
        if sp.read(ioff, len(img.index)) != img.index: problems.append('DMROMFS1 index differs')
        if not embed:
            if sp.pack_offset != 0: problems.append('repack-only: a pack is embedded')
        elif sp.pack_offset == 0 or sp.pack_size != have['bytes']: problems.append('embedded pack missing or of another size')
        else:
            h = hashlib.sha256()
            for o in range(0, sp.pack_size, 8 << 20): h.update(sp.read_pack(o, 8 << 20))
            if h.hexdigest() != stats['pack_sha256']: problems.append('embedded pack differs from the pack written')
            with open(pack, 'rb') as pf:
                if pf.read(S.PACK_HEAD) != sp.read_pack(0, S.PACK_HEAD): problems.append('embedded pack header differs from the given pack')
        if table_new is not None:
            T = arc.T
            slot = sp.read(arc.table_off, arc.table_size)
            oh = os.pread(fd, 16, arc.table_off)
            stored_new = struct.unpack_from('<I', slot, 8)[0]
            frame = slot[16:16 + stored_new]
            if slot[:8] != oh[:8] or slot[12:16] != oh[12:16]: problems.append('data.arc table header changed beyond its stored size')
            elif slot[16 + stored_new:].count(0) != len(slot) - 16 - stored_new: problems.append('data.arc table: bytes after its frame are not zero')
            elif bytes(B.unzstd(frame, {})) != table_new: problems.append('data.arc table does not inflate to the expected table')
            elif len(table_new) != len(T['fs']): problems.append('data.arc table size changed')
            else:
                try:
                    bad = Z.forbidden(frame, os.pread(fd, T['stored'], arc.table_off + 16))
                    if bad or Z.frame_features(frame)['frames'] != 1: problems.append(f'data.arc table frame: {bad or "not exactly one frame"}')
                    if zstd_header(frame) != zstd_header(os.pread(fd, 8, arc.table_off + 16)): problems.append('data.arc table frame header differs from the original')
                except ValueError as e: problems.append(f'data.arc table frame unreadable: {e}')
    writer_c = collections.Counter({k: totals[k] for k in ('planes_tagged', 'planes_zeroed_cap', 'textures_changed')})
    for k in writer_c:
        if writer_c[k] != vtotals.get(k, 0): problems.append(f'{k}: the strip counted {writer_c[k]}, the check found {vtotals.get(k, 0)}')
    if n_errors: log(f'{n_errors} containers could not be read and were left as they are, first: {errors[:3]}')
    passed = not problems
    rep = dict(tool_version=TOOL_VERSION, input_fingerprint=fp, input=romfs, pack=pack, block=block, bc1_block=bc1, max_dim=max_dim, arc_mode='table' if arc and arc.table else 'pad' if arc else 'none',
               bytes=dict(logical=logical, physical=stats['physical'], pack=stats['pack_size'], romfs_stored=stats['stored'], extents=stats['extents']),
               errors=dict(containers_unreadable=n_errors, samples=errors[:10]), **split_counters(totals),
               self_check=dict(passed=passed, problems=problems[:20], seconds=round(time.monotonic() - t2, 1)),
               seconds=dict(strip=round(strip_seconds, 1), total=round(time.monotonic() - t0, 1)))
    os.close(fd)
    if not passed:
        log(f'[RED] self-check failed ({len(problems)} problems): {problems[:3]}')
        os.unlink(target)
    with open(rep_path, 'w') as f: json.dump(tidy(rep), f, indent=1)
    if passed: log(f'self-check passed; {rep["planes"]["tagged"]} planes tagged, {rep["planes"]["zeroed_above_cap"]} zeroed above the cap; {time.monotonic() - t0:.0f} s')
    if args.json: print(json.dumps(rep, indent=1))
    return 0 if passed else 1


def run_manifest(args):
    """--manifest FILE: the strip's walk of the ORIGINAL RomFS image with nothing written except FILE: one tab-separated line per tagged plane the strip keeps (the planes that count in report.json
    planes.tagged): tag (8 bytes, hex), NVN format, width, height, level, layer, ASTC payload bytes, stored plane length, ASTC block, pack key (hex), file. tex_once_verify.sh feeds it to the engine's pack reader"""
    t0 = time.monotonic()
    romfs = B.find_romfs(args.input)
    if not os.path.isfile(romfs) or S.is_sparse(romfs): log(f'[RED] {romfs} is no plain RomFS image'); return 2
    block, max_dim = int(args.block), max(int(args.max_dim or 0), 0)
    bc1 = int(args.bc1_block or block)
    out = os.path.abspath(args.out); pack = os.path.abspath(args.pack)
    os.makedirs(out, exist_ok=True)
    if not B.read_pack_header(pack): log(f'[RED] {pack} is no complete ASTC pack'); return 2
    lib = find_astc_lib(pack, out)
    native = build_native(os.path.join(out, 'lib'))
    Z.configure(os.path.join(out, 'lib')); Z.build(os.path.join(out, 'lib'))
    files = B.image_files(romfs)
    dicts = B.zs_dicts(romfs, files, lib)
    arc = None
    if any(n == '/data.arc' for n, _, _ in files):
        arc = Arc(romfs, files, args.arc_mode == 'table')
        if arc.T is None: arc = None
    items = sorted((i for i in B.smash_arc_files(romfs, files) if i[2] > 0), key=lambda i: i[1])
    if arc: arc.usable([i for i in items if i[0].startswith('/data.arc#')])
    fd = os.open(romfs, os.O_RDONLY)
    marks = [(off, size, (name, off, size, bool(arc and arc.table and name.startswith('/data.arc#'))), 'item') for name, off, size in items if candidate(fd, name, off, size)]
    tasks = [t for t in partition(os.path.getsize(romfs), sorted(marks, key=lambda m: m[0])) if t['kind'] != 'table']
    cfg = dict(lib=lib, native=native, block=block, bc1_block=bc1, max_dim=max_dim, pack=pack, dicts=dicts, romfs=romfs, manifest=True, zstd_work=os.path.join(out, 'lib'))
    n = 0
    with cf.ProcessPoolExecutor(args.workers, initializer=worker_init, initargs=(cfg,)) as ex, open(args.manifest + '.part', 'w') as f:
        for i, r in enumerate(ex.map(strip_task, tasks)):
            for rec in r['mf']: f.write('\t'.join(str(x) for x in rec) + '\n')
            n += len(r['mf'])
            if i % 50 == 0: log(f'manifest {i}/{len(tasks)} tasks, {n} planes, {time.monotonic() - t0:.0f} s')
    os.replace(args.manifest + '.part', args.manifest)
    os.close(fd)
    log(f'manifest: {n} tagged planes, {time.monotonic() - t0:.0f} s')
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('input', help='RomFS.img, or a build folder (its newest extract/<version>/RomFS.img)')
    ap.add_argument('--pack', required=True, help='the ASTC pack bntx_astc.py built from this RomFS (same cap and block)')
    ap.add_argument('--out', required=True, help='output folder: romfs.img (DMSPARS1), report.json')
    ap.add_argument('--max-dim', type=int, default=0, help='the texture cap the pack was built with (0 = none)')
    ap.add_argument('--block', type=int, default=4, choices=(4, 6))
    ap.add_argument('--workers', type=int, default=0, help='processes (default: every core)')
    ap.add_argument('--bc1-block', type=int, default=None, choices=(4, 5, 6), help='ASTC block of BC1 textures when it differs from --block (default: --block); the pack must have been built with it')
    ap.add_argument('--no-pack-check', action='store_true', help=argparse.SUPPRESS)   # tests only: a pack made by hand
    ap.add_argument('--arc-mode', choices=('table', 'pad'), default='table', help="Smash's data.arc: update the table's stored sizes (default), or pad entries with skippable frames and leave the table")
    ap.add_argument('--force', action='store_true', help='rewrite even if the inputs are unchanged')
    ap.add_argument('--json', action='store_true', help='print the whole report')
    ap.add_argument('--manifest', metavar='FILE', help='write FILE (one line per tagged plane the strip keeps) from the ORIGINAL RomFS image and write nothing else; --out holds only the helper libraries')
    a = ap.parse_args()
    a.workers = a.workers or os.cpu_count() or 4
    sys.exit(run_manifest(a) if a.manifest else run(a))


if __name__ == '__main__':
    main()
