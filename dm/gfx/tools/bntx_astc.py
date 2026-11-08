#!/usr/bin/env python3
"""Prebuild the ASTC cache (DM_NVN_BC_ASTC) of a game on the Mac, so an Apple TV starts with every texture already stored as ASTC.

The runtime stores a BC1/2/3/7 texture as ASTC only when every plane of it is already in a cache (nvn_mtl.m astc_decision): it hashes each plane's deswizzled BC bytes (cache key =
SHA-256 of a version tag, the NVN format, the plane's size, the ASTC block and the BC bytes). This tool finds the game's textures offline, forms exactly those planes, encodes them and
packs the entries into ONE file, astc-ro.pack, which the runtime reads as its read-only cache (DM_NVN_ASTC_CACHE_RO, nvn_astc_cache.m).

Identity with the runtime is by construction: the plane walk, the deswizzle, the key and the encoder are the engine's own C code (nvn_astc_planes.c, nvn_deswizzle.c, nvn_tex.c,
nvn_astc_cache.m, nvn_astc.mm, the astc-encoder objects built with the host Makefile's flags), compiled into one small library (astc_prebuild.m) that this script loads with ctypes.
Nothing in Python hashes or encodes a texel. The Python side only finds textures and tells the library what the game would tell NVN: target, format, size, levels, packaged layout byte.

Texture sources (any RomFS image, `RomFS.img`, or an extracted folder): BNTX files and BNTX embedded in other files (BFRES), also inside zstd, Yaz0 and SARC containers, nested.
Super Smash Bros. Ultimate keeps its textures as NUTEXB in data.arc (dm/gfx/tools/smash_arc.py): its current files are read from the archive, NUTEXB ones as textures.

Usage: bntx_astc.py <RomFS.img | RomFS folder | build folder> --out DIR [--block 4|6] [--bc1-block 4|5|6] [--bc4-block 0|4|5|6] [--bc5-block 0|4|5|6] [--bc6h-block 0|4|5|6] [--max-dim N] [--workers N] [--scan-only] [--force]
Output DIR: cache/<key>.astc (the entries), astc-ro.pack (the pack, with the input fingerprint in its header), report.json.
"""
import argparse
import collections
import concurrent.futures as cf
import ctypes
import hashlib
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
DM = os.path.normpath(os.path.join(HERE, '..', '..'))
sys.path.insert(0, os.path.join(DM, 'tools'))

TOOL_VERSION = 1
# Engine sources the library is built from, and the flags the astc-encoder objects are built with (dm/host/Makefile builds them the same way; test_bntx_astc.py checks the flags match)
LIB_SOURCES = ['gfx/tools/astc_prebuild.m', 'gfx/tex/nvn_astc_cache.m', 'gfx/tex/nvn_astc.mm', 'gfx/tex/nvn_bcdec.c', 'gfx/tex/nvn_deswizzle.c', 'gfx/tex/nvn_astc_planes.c', 'gfx/nvn/nvn_tex.c']
LIB_HEADERS = ['gfx/tex/nvn_astc_cache.h', 'gfx/tex/nvn_astc.h', 'gfx/tex/nvn_bcdec.h', 'gfx/tex/nvn_deswizzle.h', 'gfx/tex/nvn_astc_planes.h', 'gfx/nvn/nvn_tex.h']
# The zstd decoder nvn_astc_cache.m links for NXASTCPK v2 entries (dm/host/Makefile builds dm/third_party/zstd with these flags)
ZSTD_FLAGS = ['-O2', '-g', '-DNDEBUG', '-DZSTD_DISABLE_ASM', '-DZSTD_MULTITHREAD=0']
ASTC_FLAGS = ['-O3', '-g', '-DNDEBUG', '-std=c++14', '-ffp-contract=off', '-DASTCENC_BLOCK_MAX_TEXELS=36']
SKIPPABLE = range(0x184d2a50, 0x184d2a60)

# BNTX format (type << 8 | data type) -> (NVN format, the second NVN format with the same blocks or 0). BC1 is RGB_DXT1 (0x41) or RGBA_DXT1 (0x42) in NVN: the blocks decode the same, the cache key
# differs by the format, so the pack answers to both (one payload, two index entries)
# BC4 / BC5 / BC6H are the UNSIGNED ones only (0x1d01, 0x1e01, 0x1f0a): the signed forms (0x1d02, 0x1e02, 0x1f05) hold negative texels ASTC cannot, the runtime keeps them decoded.
BC_ELIGIBLE = {0x1a01: (0x42, 0x41), 0x1a06: (0x46, 0x45), 0x1b01: (0x43, 0), 0x1b06: (0x47, 0), 0x1c01: (0x44, 0), 0x1c06: (0x48, 0), 0x2001: (0x4d, 0), 0x2006: (0x4e, 0),
               0x1d01: (0x49, 0), 0x1e01: (0x4b, 0), 0x1f0a: (0x50, 0)}
FORMAT_NAMES = {0x0201: 'R4G4', 0x0701: 'R5G6B5', 0x0b01: 'R8G8', 0x0901: 'R8', 0x0a01: 'R8G8', 0x0b06: 'R8G8_SRGB', 0x1201: 'R16', 0x1401: 'R16', 0x1901: 'RGBA16', 0x1a01: 'BC1', 0x1a06: 'BC1_SRGB', 0x1b01: 'BC2', 0x1b06: 'BC2_SRGB',
                0x1c01: 'BC3', 0x1c06: 'BC3_SRGB', 0x1d01: 'BC4U', 0x1d02: 'BC4S', 0x1e01: 'BC5U', 0x1e02: 'BC5S', 0x1f05: 'BC6HS', 0x1f0a: 'BC6HU', 0x2001: 'BC7', 0x2006: 'BC7_SRGB',
                0x0101: 'R4G4B4A4', 0x0201 + 1: 'R5G5B5A1', 0x0301: 'A1B5G5R5', 0x0501: 'R5G6B5', 0x0b06 + 1: 'R8G8B8A8', 0x0b01 + 5: 'R8G8B8A8_SRGB', 0x3b01: 'BGR5A1'}
# BNTX image dimension (offset 0x5c) -> NVN texture target: 2D 1, 3D 2, CUBEMAP 8, 1D_ARRAY 3, 2D_ARRAY 4, CUBEMAP_ARRAY 9 (a 2D texture of several layers is a 2D array)
DIM_TARGET = {1: 1, 5: 4, 3: 8, 8: 9}


# ---- library ----------------------------------------------------------------------------------------------------------------------------------------------------------------------
class Plane(ctypes.Structure):   # dm_plane in astc_prebuild.m
    _fields_ = [('key', ctypes.c_char * 65), ('hit', ctypes.c_uint8), ('error', ctypes.c_uint8), ('level', ctypes.c_uint32), ('layer', ctypes.c_uint32), ('width', ctypes.c_uint32),
                ('height', ctypes.c_uint32), ('bc_bytes', ctypes.c_uint32), ('astc_bytes', ctypes.c_uint32), ('key2', ctypes.c_char * 65)]


def sources_hash():
    h = hashlib.sha256(b'bntx_astc %d\0' % TOOL_VERSION)
    for rel in LIB_SOURCES + LIB_HEADERS:
        h.update(rel.encode() + b'\0')
        with open(os.path.join(DM, rel), 'rb') as f: h.update(f.read())
    for f in sorted(os.listdir(os.path.join(DM, 'third_party/astc-encoder'))):
        if f.endswith(('.cpp', '.h')):
            with open(os.path.join(DM, 'third_party/astc-encoder', f), 'rb') as fh: h.update(f.encode() + b'\0' + fh.read())
    zdir = os.path.join(DM, 'third_party/zstd')
    for root, _, files in sorted(os.walk(zdir)):
        for f in sorted(files):
            if f.endswith(('.c', '.h')):
                with open(os.path.join(root, f), 'rb') as fh: h.update(os.path.relpath(os.path.join(root, f), zdir).encode() + b'\0' + fh.read())
    h.update(' '.join(ASTC_FLAGS + ZSTD_FLAGS).encode())
    return h.hexdigest()


def run(cmd, **kw):
    r = subprocess.run(cmd, capture_output=True, text=True, **kw)
    if r.returncode: raise RuntimeError(f'{cmd[0]} failed ({r.returncode}): {r.stderr[-2000:]}')


def min_os():
    with open(os.path.join(DM, 'mac/min_os.mk')) as f: m = re.search(r'MACOS_MIN\s*:?=\s*([\d.]+)', f.read())
    return m.group(1) if m else '14.0'


def build_library(work):
    """The prebuild library, made from the engine's sources and cached in work/lib by the sources' hash. → its path"""
    tag = sources_hash()[:16]
    lib = os.path.join(work, f'libastc_prebuild-{tag}.dylib')
    if os.path.exists(lib): return lib
    os.makedirs(work, exist_ok=True)
    mac = '-mmacosx-version-min=' + min_os()
    astc_dir = os.path.join(DM, 'third_party/astc-encoder')
    objs = []
    cpp = sorted(f for f in os.listdir(astc_dir) if f.startswith('astcenc_') and f.endswith('.cpp'))
    with cf.ThreadPoolExecutor(os.cpu_count() or 4) as ex:
        futs = []
        for f in cpp:
            o = os.path.join(work, f'astc-{tag}-{f[:-4]}.o'); objs.append(o)
            if not os.path.exists(o): futs.append(ex.submit(run, ['clang++'] + ASTC_FLAGS + [mac, '-c', os.path.join(astc_dir, f), '-o', o]))
        zdir = os.path.join(DM, 'third_party/zstd')
        for root, _, files in sorted(os.walk(zdir)):
            for f in sorted(files):
                if not f.endswith('.c'): continue
                o = os.path.join(work, f'zstd-{tag}-{os.path.basename(root)}-{f[:-2]}.o'); objs.append(o)
                if not os.path.exists(o): futs.append(ex.submit(run, ['clang'] + ZSTD_FLAGS + [mac, '-I' + zdir, '-c', os.path.join(root, f), '-o', o]))
        for fu in futs: fu.result()
    part = lib + f'.{os.getpid()}.part'
    cmd = ['clang', '-O2', '-g', '-fobjc-arc', '-dynamiclib', mac, '-I' + os.path.join(DM, 'gfx/nvn/include'), '-o', part] + [os.path.join(DM, s) for s in LIB_SOURCES] + objs
    run(cmd + ['-lc++', '-framework', 'Foundation', '-framework', 'Metal'])
    os.replace(part, lib)
    return lib


_LIB = None


def lib_open(path):
    global _LIB
    if _LIB is not None and _LIB[0] == path: return _LIB[1]
    L = ctypes.CDLL(path)
    L.dm_texture_planes.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_int, ctypes.c_void_p, ctypes.c_uint64,
                                    ctypes.c_uint, ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.POINTER(Plane), ctypes.c_uint32, ctypes.c_int]
    L.dm_texture_planes.restype = ctypes.c_int
    L.dm_skip_levels.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_int]
    L.dm_skip_levels.restype = ctypes.c_uint
    L.dm_texture_size.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_int]
    L.dm_texture_size.restype = ctypes.c_uint64
    L.dm_level_offset.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_int, ctypes.c_uint]
    L.dm_level_offset.restype = ctypes.c_uint64
    L.dm_yaz0.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p, ctypes.c_size_t]
    L.dm_yaz0.restype = ctypes.c_int64
    L.dm_swizzle.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_int, ctypes.c_uint, ctypes.c_uint, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p]
    L.dm_swizzle.restype = ctypes.c_int
    _LIB = (path, L)
    return L


def addr(b):
    return ctypes.cast(ctypes.c_char_p(b), ctypes.c_void_p).value


# ---- containers ---------------------------------------------------------------------------------------------------------------------------------------------------------------------
def zstd_module():
    try:
        from compression import zstd
        return zstd
    except ImportError:
        try:
            from backports import zstd
            return zstd
        except ImportError:
            return None


def unzstd(d, dicts):
    z = zstd_module()
    if z is not None:
        did = zstd_dict_id(d)
        if did and did in dicts: return z.decompress(d, zstd_dict=z.ZstdDict(dicts[did]))
        return z.decompress(d)
    return subprocess.run(['zstd', '-d', '-c', '-q'], input=d, capture_output=True, check=True).stdout


def zstd_dict_id(d):
    fhd = d[4] if len(d) > 5 else 0
    n, o = (0, 1, 2, 4)[fhd & 3], 6 - (fhd >> 5 & 1)
    return int.from_bytes(d[o:o + n], 'little')


def unyaz0(d, L):
    n = int.from_bytes(d[4:8], 'big')
    if n > MAX_BLOB: raise ValueError('Yaz0 stream expands beyond the limit')
    out = ctypes.create_string_buffer(n)
    r = L.dm_yaz0(addr(d), len(d), out, n)
    if r != n: raise ValueError('damaged Yaz0 stream')
    return out.raw


def sarc_members(d):
    """(name, bytes) of each member of a SARC"""
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
        yield nm, d[doff + s:doff + e]


KNOWN_MAGIC = (b'\x28\xb5\x2f\xfd', b'Yaz0', b'SARC', b'BNTX', b'FRES', b'EFFN')
HINTS = ('.bfres', '.bntx', '.bkres', '.nutexb')
MAX_BLOB = 3 << 30   # no container expands past this
MAX_DEPTH = 8


# ---- BNTX ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------
def bntx_ok(d, p):
    """Whether a BNTX header starts at d[p]"""
    if d[p:p + 8] != b'BNTX\0\0\0\0' or len(d) - p < 0x60: return False
    bom, = struct.unpack_from('<H', d, p + 0xc)
    size, = struct.unpack_from('<I', d, p + 0x1c)
    count, = struct.unpack_from('<I', d, p + 0x24)
    return bom == 0xfeff and d[p + 0x20:p + 0x24] in (b'NX  ', b'Ounc') and 0x60 <= size <= len(d) - p and count < 100000


def bntx_textures(d, p):
    """The textures of the BNTX at d[p]: dicts with the fields NVN is given. A texture that does not parse is {'bad': why}"""
    size, = struct.unpack_from('<I', d, p + 0x1c)
    end = p + size
    count, info = struct.unpack_from('<IQ', d, p + 0x24)
    out = []
    for i in range(count):
        try:
            ptr, = struct.unpack_from('<Q', d, p + info + 8 * i)
            t = p + ptr
            if d[t:t + 4] != b'BRTI' or t + 0x90 > end: raise ValueError('no BRTI')
            flags, dim, tile, swz, mips, samples, fmt, access, w, h, depth, arr, layout0, layout1 = struct.unpack_from('<BBHHH9I', d, t + 0x10)
            image_size, align, chan, dimension = struct.unpack_from('<IIII', d, t + 0x50)
            mip_ptr, = struct.unpack_from('<Q', d, t + 0x70)
            offs = struct.unpack_from('<%dQ' % mips, d, p + mip_ptr) if 0 < mips <= 32 else ()
            out.append({'fmt': fmt, 'w': w, 'h': h, 'depth': depth, 'array': arr, 'mips': mips, 'tile': tile, 'samples': samples, 'dimension': dimension, 'layout': layout0, 'size': image_size,
                        'offs': offs, 'start': p + offs[0] if offs else 0, 'end': end})
        except (struct.error, ValueError) as e:
            out.append({'bad': str(e)})
    return out


def target_of(t):
    """NVN target and depth a texture is created with"""
    tgt = DIM_TARGET.get(t['dimension'])
    if tgt is None: return None
    if tgt == 1 and t['array'] > 1: tgt = 4
    depth = t['array'] if tgt in (4,) else (6 if tgt == 8 else (t['array'] if tgt == 9 else 1))
    return tgt, max(depth, 1)


# NUTEXB (Super Smash Bros. Ultimate): the image, then a footer of 0x6c bytes: name[64], width, height, depth, format byte + 3, 4, mips, 0x1000, layers, image size, ' XET', version 0x00020001.
# Its block height is the driver's own (no packaged layout): the engine's automatic layout gives the recorded image size for every BC texture checked.
NUTEXB_FORMATS = {0x80: 0x1a01, 0x85: 0x1a06, 0x90: 0x1b01, 0x95: 0x1b06, 0xa0: 0x1c01, 0xa5: 0x1c06, 0xb0: 0x1d01, 0xb5: 0x1d02, 0xc0: 0x1e01, 0xc5: 0x1e02, 0xd7: 0x1f0a, 0xe0: 0x2001, 0xe5: 0x2006}


def nutexb_texture(d):
    """The texture a NUTEXB holds, as bntx_textures describes one; None for bytes that are no NUTEXB"""
    if len(d) < 0x6c + 0x200 or d[-8:-4] != b' XET': return None
    w, h, dep, fm, _, mips, _, layers, size = struct.unpack_from('<9I', d, len(d) - 0x6c + 0x40)
    if size > len(d) - 0x6c or not 0 < mips <= 20 or not 0 < layers <= 2048: return {'bad': 'nutexb footer'}
    dim = 2 if dep > 1 else 3 if layers == 6 else 5 if layers > 1 else 1
    return {'fmt': NUTEXB_FORMATS.get(fm & 0xff, 0x10000 | fm & 0xff), 'w': w, 'h': h, 'depth': dep, 'array': layers, 'mips': mips, 'samples': 1, 'dimension': dim, 'layout': 0, 'size': size,
            'offs': (), 'start': 0, 'end': len(d), 'auto': True}


class Job:
    """One worker's state: counters and the planes it keyed"""
    def __init__(self, lib, block, cache, encode, dicts, max_dim=0, bc1_block=0, fmt_blocks=None):
        self.L, self.block, self.cache, self.encode, self.dicts, self.max_dim = lib_open(lib), block, cache, encode, dicts, max_dim
        self.bc1_block = bc1_block or block
        self.fmt_blocks = norm_fmt_blocks(*(fmt_blocks or ()))
        self.c = collections.Counter(); self.planes = []; self.formats = collections.Counter(); self.seen = set(); self.errors = []

    def texture(self, d, t, name):
        c = self.c
        c['textures'] += 1
        if 'bad' in t: c['unparsed'] += 1; return
        self.formats[FORMAT_NAMES.get(t['fmt'], '%#x' % t['fmt'])] += 1
        eligible = BC_ELIGIBLE.get(t['fmt'])
        if not eligible: return
        tg = target_of(t)
        if tg is None or t['samples'] > 1 or t['dimension'] == 2: c['ineligible_shape'] += 1; return
        target, depth = tg
        if t['w'] == 0 or t['h'] == 0 or (not t['offs'] and not t.get('auto')) or t['w'] > 16384 or t['h'] > 16384: c['unparsed'] += 1; return
        c['eligible'] += 1
        nvn, alt = eligible
        block = block_of(nvn, self.block, self.bc1_block, self.fmt_blocks)   # what the runtime's astc_block_for(format) answers
        if not block: c['format_off'] += 1; return   # --bc4-block 0 (and the like): the pack does not cover the format
        pkg = 0 if t.get('auto') or os.environ.get('BNTX_ASTC_AUTO_LAYOUT') else (t['layout'] & 0xff) + 1   # SetPackagedTextureLayout's byte 0 (a NUTEXB has none: the automatic block height); --auto-layout is a diagnostic
        start, size = t['start'], t['size']
        if start + size > t['end']: c['short'] += 1; return
        # the texture must lie in the BNTX as the engine lays it out: the first mip offsets
        if t['offs']:
            rel = [o - t['offs'][0] for o in t['offs']]
            want = [self.L.dm_level_offset(target, nvn, t['w'], t['h'], depth, t['mips'], pkg, i) for i in range(len(rel))]
            if rel != want: c['layout_differs'] += 1
        elif self.L.dm_texture_size(target, nvn, t['w'], t['h'], depth, t['mips'], pkg) != size:   # a NUTEXB records the size the driver gave the texture
            c['layout_differs'] += 1
        ident = hashlib.sha1(struct.pack('<7I', t['fmt'], t['w'], t['h'], depth, t['mips'], target, pkg) + d[start:start + size]).digest()
        if ident in self.seen: c['repeat'] += 1; return
        self.seen.add(ident)
        cap = t['mips'] * (depth + 1) + 8
        out = (Plane * cap)()
        n = self.L.dm_texture_planes(target, nvn, t['w'], t['h'], depth, t['mips'], pkg, addr(d) + start, size, block, alt, self.cache.encode() if self.cache else None, int(self.encode), out, cap, self.max_dim)
        if n < 0: c['layout_failed'] += 1; self.errors.append(f'{name}: layout failed ({n})'); return
        c['converted'] += 1; c['conv_' + FORMAT_NAMES.get(t['fmt'], '%#x' % t['fmt'])] += 1
        for i in range(n):
            p = out[i]
            if p.error: c['plane_errors'] += 1; self.errors.append(f'{name}: plane {p.level}/{p.layer} error'); continue
            self.planes.append((p.key.decode(), p.key2.decode() if alt else '', p.width, p.height, p.astc_bytes, p.hit, DECODED_BPP.get(nvn, 4)))

    def blob(self, d, name, depth=0, hint=''):
        c = self.c
        if depth > MAX_DEPTH: c['too_deep'] += 1; return
        m = d[:4]
        try:
            if m == b'\x28\xb5\x2f\xfd' or (len(m) == 4 and struct.unpack('<I', m)[0] in SKIPPABLE):
                c['zstd'] += 1
                return self.blob(unzstd(d, self.dicts), name, depth + 1, hint)
            if m == b'Yaz0':
                c['yaz0'] += 1
                return self.blob(unyaz0(d, self.L), name, depth + 1, hint)
            if m == b'SARC':
                c['sarc'] += 1
                for nm, member in sarc_members(d): self.blob(member, name + '/' + nm, depth + 1, nm)
                return
            if name.endswith('.nutexb'):
                c['nutexb'] += 1
                t = nutexb_texture(d)
                if t: self.texture(d, t, name)
                return
            if m in (b'BNTX', b'FRES', b'EFFN') or hint.endswith(('.bfres', '.bntx', '.bkres')) or name.endswith(('.bfres', '.bntx', '.bkres')):
                for mt in re.finditer(b'BNTX\0\0\0\0', d):
                    if bntx_ok(d, mt.start()):
                        c['bntx'] += 1
                        for t in bntx_textures(d, mt.start()): self.texture(d, t, name)
                return
            c['other_files'] += 1; c['other_bytes'] += len(d)
        except (ValueError, struct.error, subprocess.CalledProcessError, IndexError) as e:
            c['container_errors'] += 1; self.errors.append(f'{name}: {e}')
        except Exception as e:   # zstd errors and the like: the file is skipped and counted, never fatal
            c['container_errors'] += 1; self.errors.append(f'{name}: {type(e).__name__}: {e}')


# ---- inputs -------------------------------------------------------------------------------------------------------------------------------------------------------------------------
def find_romfs(path):
    """A RomFS image, a RomFS folder or a build folder -> the RomFS image or folder to read (the newest version's extract/<ver>/RomFS.img of a build folder)"""
    path = os.path.expanduser(path)
    if os.path.isfile(path): return path
    for cand in ('RomFS.img', 'RomFS'):
        if os.path.exists(os.path.join(path, cand)): return os.path.join(path, cand)
    ex = os.path.join(path, 'extract')
    if os.path.isdir(ex):
        vers = sorted((d for d in os.listdir(ex) if d.startswith('v') and d[1:].isdigit()), key=lambda d: int(d[1:]), reverse=True)
        for v in vers:
            r = find_romfs(os.path.join(ex, v))
            if r: return r
    if os.path.isdir(path) and not os.path.isdir(os.path.join(path, 'ExeFS')): return path
    raise SystemExit(f'no RomFS found under {path}')


def image_files(path):
    """[(name, offset, size)] of an image's files"""
    import romfs
    img = romfs.Image(path)
    names = [''] * img.count
    out = []
    for k in range(img.count):
        a, b, _, _, t, _ = img.entry(k)
        if t: out.append((names[k], a, b))
        else:
            for j in range(a, a + b): names[j] = names[k] + '/' + img.name(j).decode('utf-8', 'replace')
    return out


def smash_arc_files(romfs, files):
    """data.arc (Super Smash Bros. Ultimate) replaces itself with its current files: [(name, offset in the input, stored size)], the NUTEXB ones named so"""
    arc = next(((n, o, sz) for n, o, sz in files if n == '/data.arc'), None)
    if arc is None: return files
    sys.path.insert(0, HERE)
    import smash_arc
    path = romfs + '/data.arc' if os.path.isfile(romfs) else os.path.join(romfs, 'data.arc')
    ents = smash_arc.files(path)
    if ents is None: return files
    nutexb = smash_arc.hash40('nutexb')
    base = arc[1] if os.path.isfile(romfs) else 0
    out = [f for f in files if f[0] != '/data.arc']
    out += [('/data.arc#%x%s' % (e[0], '.nutexb' if e[4] == nutexb else ''), base + e[1], e[2]) for e in ents]
    return out


def folder_files(path):
    out = []
    for r, ds, fs in os.walk(path):
        ds.sort()
        for f in sorted(fs):
            p = os.path.join(r, f)
            out.append((p[len(path):], 0, os.path.getsize(p)))
    return out


BC1_NVN = (0x41, 0x42, 0x45, 0x46)   # NVN BC1 formats and their sRGB forms


# BC4 (0x49) / BC5 (0x4b) / unsigned BC6H (0x50) have blocks of their own (the runtime's DM_NVN_BC4_ASTC / DM_NVN_BC5_ASTC / DM_NVN_BC6H_ASTC): default 6, 4, 4; 0 leaves the format out of the pack.
# Bytes a texel takes in today's decoded storage (R8, RG8, RG11B10Float; RGBA8 for the rest): what the pack's planes replace
FMT_NVN = (0x49, 0x4b, 0x50)
FMT_DEFAULT_BLOCKS = (6, 4, 4)
DECODED_BPP = {0x49: 1, 0x4b: 2, 0x50: 4}


def norm_fmt_blocks(bc4=None, bc5=None, bc6h=None):
    """(BC4, BC5, BC6H) ASTC blocks; None is the runtime's default, 0 leaves the format out"""
    out = tuple(d if v is None else int(v) for v, d in zip((bc4, bc5, bc6h), FMT_DEFAULT_BLOCKS))
    if any(v not in (0, 4, 5, 6) for v in out): raise SystemExit('--bc4-block, --bc5-block and --bc6h-block must be 0, 4, 5 or 6')
    return out


def block_of(nvn, block, bc1_block, fmt_blocks=None):
    """The ASTC block a plane of this NVN format is keyed and encoded at (the runtime's astc_block_for); 0: the pack does not hold the format"""
    if nvn in FMT_NVN: return norm_fmt_blocks(*(fmt_blocks or ()))[FMT_NVN.index(nvn)]
    return (bc1_block or block) if nvn in BC1_NVN else block


def fingerprint(romfs, block, max_dim=0, bc1_block=0, fmt_blocks=None):
    h = hashlib.sha256(); h.update(sources_hash().encode()); h.update(b'block %d\0max_dim %d\0' % (block, max_dim))
    h.update(b'bc4 %d bc5 %d bc6h %d\0' % norm_fmt_blocks(*(fmt_blocks or ())))   # the blocks BC4 / BC5 / BC6H planes are keyed and encoded at
    h.update(b'bc1_block %d\0' % (bc1_block or block))   # BC1 planes are keyed and encoded at their own block   # the texture cap decides which levels the pack holds
    with open(os.path.abspath(__file__), 'rb') as f: h.update(f.read())   # the tool's own logic (what it finds and how it names it) is part of what the pack holds
    if os.path.isfile(romfs):
        st = os.stat(romfs); h.update(b'img %d %d\0' % (st.st_size, st.st_mtime_ns)); h.update(os.path.basename(romfs).encode())
        with open(romfs, 'rb') as f: h.update(f.read(32))
    else:
        for name, _, size in folder_files(romfs):
            st = os.stat(romfs + name); h.update(b'%s %d %d\0' % (name.encode(), size, st.st_mtime_ns))
    return h.digest()


_STATE = {}


def init_worker(lib, block, cache, encode, romfs, dicts, max_dim=0, bc1_block=0, fmt_blocks=None):
    _STATE.update(lib=lib, block=block, bc1_block=bc1_block, fmt_blocks=fmt_blocks, max_dim=max_dim, cache=cache, encode=encode, romfs=romfs, dicts=dicts, fd=os.open(romfs, os.O_RDONLY) if os.path.isfile(romfs) else None)


def work(batch):
    s = _STATE
    job = Job(s['lib'], s['block'], s['cache'], s['encode'], s['dicts'], s['max_dim'], s['bc1_block'], s['fmt_blocks'])
    for name, off, size in batch:
        if s['fd'] is not None: head = os.pread(s['fd'], 4, off)
        else:
            with open(s['romfs'] + name.split('#')[0], 'rb') as f: head = f.read(4)
        if head not in KNOWN_MAGIC and not (len(head) == 4 and head[1:4] == b'*M\x18' and 0x50 <= head[0] <= 0x5f) and not name.endswith(HINTS):   # unknown bytes are not read: a RomFS holds multi-GB data files
            job.c['other_files'] += 1; job.c['other_bytes'] += size
            continue
        if s['fd'] is not None: d = os.pread(s['fd'], size, off)
        else:
            with open(s['romfs'] + name.split('#')[0], 'rb') as f: f.seek(off); d = f.read(size)
        job.blob(d, name)
    return dict(c=dict(job.c), planes=job.planes, formats=dict(job.formats), errors=job.errors[:50], n_errors=len(job.errors))


def zs_dicts(romfs, files, lib):
    """Zstd dictionaries of Pack/ZsDic.pack.zs (Tears of the Kingdom), {} for a game without them"""
    for name, off, size in files:
        if name == '/Pack/ZsDic.pack.zs':
            d = open(romfs, 'rb') if os.path.isfile(romfs) else open(romfs + name, 'rb')
            with d as f:
                if os.path.isfile(romfs): f.seek(off)
                data = f.read(size)
            data = unzstd(data, {})
            return {struct.unpack_from('<I', m, 4)[0]: m for _, m in sarc_members(data) if m[:4] == bytes.fromhex('37a430ec')}
    return {}


# ---- pack ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------
PACK_HEAD, PACK_ENT = 80, 48


def write_pack(path, cache, keys, fp):
    """keys: {key hex: payload key hex} (an alias names the entry that holds its payload). Entries go in as the cache files hold them; a payload is stored once however many keys name it.
    Layout: nvn_astc_cache.m. → (entries, payloads, bytes)"""
    part = path + '.part'
    index, placed, off = [], {}, PACK_HEAD
    with open(part, 'wb') as f:
        f.write(b'\0' * PACK_HEAD)
        for key in sorted(keys):
            src = keys[key]
            if src not in placed:
                with open(os.path.join(cache, src + '.astc'), 'rb') as e: data = e.read()
                if data[:8] != b'NXASTC01' or len(data) <= 40 or hashlib.sha256(data[40:]).digest() != data[8:40]: raise RuntimeError(f'cache entry {src} is damaged')
                f.write(data); pad = -len(data) % 16; f.write(b'\0' * pad)
                placed[src] = (off, len(data)); off += len(data) + pad
            index.append((bytes.fromhex(key),) + placed[src])
        index.sort()
        ioff = off
        for k, o, s in index: f.write(k + struct.pack('<QQ', o, s))
        size = ioff + PACK_ENT * len(index)
        f.seek(0)
        f.write(b'NXASTCPK' + struct.pack('<IIQQQ', 1, PACK_ENT, len(index), ioff, size) + fp + b'\0' * 8)
    os.replace(part, path)
    return len(index), len(placed), size


def read_pack_header(path):
    try:
        with open(path, 'rb') as f:
            h = f.read(PACK_HEAD)
            size = os.fstat(f.fileno()).st_size
        if h[:8] != b'NXASTCPK' or len(h) < PACK_HEAD: return None
        ver, ent, count, ioff, fsize = struct.unpack_from('<IIQQQ', h, 8)
        if ver != 1 or ent != PACK_ENT or fsize != size or ioff + count * PACK_ENT != size: return None
        return dict(entries=count, bytes=size, fingerprint=h[40:72])
    except OSError:
        return None


# ---- main ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------
def batches(files, n):
    big = sorted(files, key=lambda f: -f[2])
    batch, acc = [], 0
    for f in big:
        batch.append(f); acc += f[2] + 64
        if acc >= n: yield batch; batch, acc = [], 0
    if batch: yield batch


def prebuild(inp, out, block=4, workers=None, scan_only=False, force=False, log=print, drop_cache=False, verbose=False, max_dim=0, bc1_block=0, fmt_blocks=None):
    t0 = time.monotonic()
    fmt_blocks = norm_fmt_blocks(*(fmt_blocks or ()))
    block = int(block); max_dim = max(int(max_dim or 0), 0); bc1_block = int(bc1_block or block)
    if block not in (4, 6): raise SystemExit('--block must be 4 or 6')
    if bc1_block not in (4, 5, 6): raise SystemExit('--bc1-block must be 4, 5 or 6')
    romfs = find_romfs(inp)
    os.makedirs(out, exist_ok=True)
    pack, cache = os.path.join(out, 'astc-ro.pack'), os.path.join(out, 'cache')
    fp = fingerprint(romfs, block, max_dim, bc1_block, fmt_blocks)
    have = read_pack_header(pack)
    if have and have['fingerprint'] == fp and not force and not scan_only:
        rep = {}
        if os.path.exists(os.path.join(out, 'report.json')):
            with open(os.path.join(out, 'report.json')) as f: rep = json.load(f)
        log(f'astc-ro.pack is up to date for these inputs ({have["entries"]} entries, {have["bytes"] / 2**30:.2f} GB)')
        if drop_cache: shutil.rmtree(cache, ignore_errors=True)
        return dict(rep, up_to_date=True, pack=pack, entries=have['entries'], pack_bytes=have['bytes'])
    lib = build_library(os.path.join(out, 'lib'))
    os.makedirs(cache, exist_ok=True)
    files = image_files(romfs) if os.path.isfile(romfs) else folder_files(romfs)
    files = smash_arc_files(romfs, files)
    dicts = zs_dicts(romfs, files, lib)
    log(f'astc: {romfs}: {len(files)} files, {sum(f[2] for f in files) / 2**30:.1f} GiB; ASTC {block}x{block}{f' (BC1 {bc1_block}x{bc1_block})' if bc1_block != block else ''}; BC4/BC5/BC6H blocks {'/'.join(str(b) for b in fmt_blocks)}; texture cap {max_dim or 'none'}; library {os.path.basename(lib)}')
    workers = workers or os.cpu_count() or 4
    total = collections.Counter(); formats = collections.Counter(); keys = {}; errors = []; plane_count = 0; hits = 0
    unique = {}
    scanned = 0; t1 = time.monotonic()
    chunks = list(batches(files, 64 << 20 if len(files) > workers * 8 else 1))
    with cf.ProcessPoolExecutor(workers, initializer=init_worker, initargs=(lib, block, cache, not scan_only, romfs, dicts, max_dim, bc1_block, fmt_blocks)) as ex:
        for r in ex.map(work, chunks):
            total.update(r['c']); formats.update(r['formats']); errors += r['errors']; total['n_errors'] += r['n_errors']
            for key, key2, w, h, astc, hit, bpp in r['planes']:
                plane_count += 1
                if key not in unique:
                    unique[key] = (w, h, astc, bpp); hits += hit
                    keys[key] = key
                if key2 and key2 not in keys: keys[key2] = key
            scanned += 1
            if scanned % 20 == 0: log(f'astc: {scanned}/{len(chunks)} batches, {len(unique)} unique planes, {time.monotonic() - t1:.0f} s')
    t_scan = time.monotonic() - t1
    rgba = sum(w * h * 4 for w, h, _, _ in unique.values())   # as RGBA8 (the pack's convention)
    decoded = sum(w * h * bpp for w, h, _, bpp in unique.values())   # in the storage the runtime uses without the pack (R8, RG8, RG11B10Float, RGBA8)
    digest = hashlib.sha256(b''.join(bytes.fromhex(k) for k in sorted(unique))).hexdigest()
    rep = dict(input=romfs, block=block, bc1_block=bc1_block, max_dim=max_dim, files=len(files), textures_found=total['textures'], bntx_files=total['bntx'], eligible_textures=total['eligible'], converted_textures=total['converted'],
               repeated_textures=total['repeat'], nutexb_files=total['nutexb'], layout_differs=total['layout_differs'], layout_failed=total['layout_failed'], unparsed=total['unparsed'], short=total['short'],
               ineligible_shape=total['ineligible_shape'], container_errors=total['container_errors'], plane_errors=total['plane_errors'], planes=plane_count, unique_planes=len(unique), keys_sha256=digest,
               decoded_rgba_bytes_covered=rgba, astc_bytes=sum(a for _, _, a, _ in unique.values()), decoded_bytes_covered=decoded, fmt_blocks=dict(zip(('bc4', 'bc5', 'bc6h'), fmt_blocks)),
               converted_by_format={k[5:]: v for k, v in sorted(total.items()) if k.startswith('conv_')}, formats=dict(formats.most_common()), encoded_now=len(unique) - hits, cached_before=hits,
               scan_seconds=round(t_scan, 1), error_samples=errors[:20])
    if scan_only:
        log('astc: ' + json.dumps({k: v for k, v in rep.items() if k not in ('formats', 'error_samples')}) if not verbose else json.dumps(rep, indent=1)); return rep
    if total['plane_errors']: raise SystemExit(f'{total["plane_errors"]} planes failed to encode: {errors[:5]}')
    t2 = time.monotonic()
    entries, payloads, size = write_pack(pack, cache, keys, fp)
    rep.update(pack=pack, entries=entries, payloads=payloads, pack_bytes=size, pack_seconds=round(time.monotonic() - t2, 1), total_seconds=round(time.monotonic() - t0, 1), up_to_date=False)
    with open(os.path.join(out, 'report.json'), 'w') as f: json.dump(rep, f, indent=1)
    if drop_cache: shutil.rmtree(cache, ignore_errors=True)   # the pack holds every entry; the folder is only needed to encode again without it
    log(f'astc-ro.pack: {entries} entries ({payloads} blocks of ASTC), {size / 2**30:.2f} GB; {rep["converted_textures"]} textures, {len(unique)} planes covering {rgba / 2**30:.1f} GB of decoded RGBA8; {rep["total_seconds"]:.0f} s')
    if verbose: log(json.dumps(rep, indent=1))
    return rep


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('input', help='RomFS.img, a RomFS folder, or a build folder (its newest extract/<version>/RomFS.img)')
    ap.add_argument('--out', required=True, help='output folder: cache/, astc-ro.pack, report.json')
    ap.add_argument('--block', type=int, default=4, choices=(4, 6), help='ASTC block size (the runtime reads the same DM_NVN_BC_ASTC)')
    ap.add_argument('--bc1-block', type=int, default=0, choices=(0, 4, 5, 6), help='ASTC block size of the BC1 textures (the runtime reads DM_NVN_BC1_ASTC); default: --block')
    for nm, dflt, rt in (('bc4', 6, 'DM_NVN_BC4_ASTC'), ('bc5', 4, 'DM_NVN_BC5_ASTC'), ('bc6h', 4, 'DM_NVN_BC6H_ASTC')):
        ap.add_argument('--%s-block' % nm, type=int, default=None, choices=(0, 4, 5, 6), help='ASTC block size of the %s textures (the runtime reads %s; default %d); 0 leaves the format out of the pack' % (nm.upper(), rt, dflt))
    ap.add_argument('--max-dim', type=int, default=0, help="the game's texture cap (DM_BC_MAX_DIM, 0 = none): only the mip levels the runtime keeps under it are packed")
    ap.add_argument('--workers', type=int, default=0, help='processes (default: every core)')
    ap.add_argument('--scan-only', action='store_true', help='find and key the planes; encode and write nothing')
    ap.add_argument('--force', action='store_true', help='rebuild even if the pack is up to date')
    ap.add_argument('--drop-cache', action='store_true', help='delete the cache/ folder once the pack is written (it holds the same entries again)')
    ap.add_argument('--json', action='store_true', help='print the whole report')
    ap.add_argument('--auto-layout', action='store_true', help='diagnostic with --scan-only: ignore the BNTX block height and count the textures whose mip offsets the engine\'s automatic layout does not reproduce')
    a = ap.parse_args()
    if a.auto_layout:
        if not a.scan_only: ap.error('--auto-layout is a diagnostic: use it with --scan-only')
        os.environ['BNTX_ASTC_AUTO_LAYOUT'] = '1'
    prebuild(a.input, a.out, a.block, a.workers or None, a.scan_only, a.force, drop_cache=a.drop_cache, verbose=a.json, max_dim=a.max_dim, bc1_block=a.bc1_block, fmt_blocks=(a.bc4_block, a.bc5_block, a.bc6h_block))


if __name__ == '__main__':
    main()
