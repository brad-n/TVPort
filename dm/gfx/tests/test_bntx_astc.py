"""bntx_astc.py: the prebuilt ASTC cache is keyed and encoded by the engine's own code, so what it holds is what the runtime looks up.

Synthetic textures only (no game files). macOS with clang is required: the tool builds the engine's texture code into a library. Covers the container walk (Yaz0, SARC, zstd, embedded BNTX),
the BNTX header fields, the pack (layout, shared payloads, incremental runs) and, through the runtime's own functions, that every plane of every prebuilt texture is found in the pack by the
runtime's plane walk, with the blocks the runtime's encoder makes.
"""
import ctypes
import importlib.util
import os
import random
import re
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

TOOLS = Path(__file__).resolve().parents[1] / 'tools'
DM = TOOLS.parents[1]
sys.path.insert(0, str(TOOLS))   # the tool's worker processes import it by name
spec = importlib.util.spec_from_file_location('bntx_astc', TOOLS / 'bntx_astc.py')
tool = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = tool
spec.loader.exec_module(tool)

NVN = {0x1a01: 0x42, 0x1a06: 0x46, 0x1b01: 0x43, 0x1c01: 0x44, 0x2001: 0x4d, 0x2006: 0x4e}
BYTES_PER_BLOCK = {0x42: 8, 0x46: 8, 0x43: 16, 0x44: 16, 0x4d: 16, 0x4e: 16}


def blocks(rng, nvn, w, h):
    """Random but valid-looking BC blocks for a w x h plane (BC7 mode 6; the others are noise, every bit pattern decodes)"""
    n = ((w + 3) // 4) * ((h + 3) // 4)
    bpb = BYTES_PER_BLOCK[nvn]
    out = bytearray(rng.randbytes(n * bpb))
    if nvn in (0x4d, 0x4e):
        for i in range(0, len(out), 16): out[i] = (out[i] & ~0x7f) | 0x40
    return bytes(out)


class Texture:
    """A texture to place in a BNTX: format, size, mips, layers, the packaged block height, and its linear planes by (level, layer)"""
    def __init__(self, fmt, w, h, mips=1, layers=1, dim=1, pkg=0, seed=0):
        self.fmt, self.w, self.h, self.mips, self.layers, self.dim, self.pkg = fmt, w, h, mips, layers, dim, pkg
        self.nvn = NVN.get(fmt, 0x42)
        rng = random.Random(seed or (fmt * 1000 + w * 7 + h))
        self.planes = {(l, y): blocks(rng, self.nvn, max(w >> l, 1), max(h >> l, 1)) for l in range(mips) for y in range(layers)} if fmt in NVN else {}
        self.target = {1: 1, 5: 4, 3: 8}.get(dim, 1)
        self.depth = layers if self.target in (4,) else (6 if self.target == 8 else 1)

    def storage(self, lib):
        size = lib.dm_texture_size(self.target, self.nvn, self.w, self.h, self.depth, self.mips, self.pkg + 1)
        buf = ctypes.create_string_buffer(size)
        for (l, y), plane in self.planes.items():
            pitch = ((max(self.w >> l, 1) + 3) // 4) * BYTES_PER_BLOCK[self.nvn]
            assert lib.dm_swizzle(self.target, self.nvn, self.w, self.h, self.depth, self.mips, self.pkg + 1, l, y, plane, pitch, buf) == 0
        return buf.raw


def bntx(lib, textures, prefix=b''):
    """A BNTX file with the fields tool.bntx_textures reads (and the usual places for the rest)"""
    n = len(textures)
    info_at = 0x50
    brti_at = info_at + 8 * n
    heads, offs_at = [], brti_at + 0x90 * n
    mip_tables = []
    cursor = offs_at + sum(8 * t.mips for t in textures)
    data_at = (cursor + 0x1ff) & ~0x1ff
    blocks_ = []
    data = bytearray()
    for t in textures:
        st = t.storage(lib) if t.fmt in NVN else bytes(256)
        start = data_at + 0x10 + len(data)
        blocks_.append((start, len(st)))
        offs = [start + lib.dm_level_offset(t.target, t.nvn, t.w, t.h, t.depth, t.mips, t.pkg + 1, i) for i in range(t.mips)] if t.fmt in NVN else [start] * t.mips
        mip_tables.append(offs)
        data += st + bytes(-len(st) % 0x200)
    out = bytearray(data_at + 0x10 + len(data))
    out[0:8] = b'BNTX\0\0\0\0'
    struct.pack_into('<IHBB', out, 8, 0x00040001, 0xfeff, 0x0c, 0x40)
    struct.pack_into('<I', out, 0x1c, len(out))
    out[0x20:0x24] = b'NX  '
    struct.pack_into('<IQQ', out, 0x24, n, info_at, data_at)
    mo = offs_at
    for i, t in enumerate(textures):
        struct.pack_into('<Q', out, info_at + 8 * i, brti_at + 0x90 * i)
        b = brti_at + 0x90 * i
        out[b:b + 4] = b'BRTI'
        struct.pack_into('<BBHHH9I', out, b + 0x10, 0, 1, 0, 0, t.mips, 1, t.fmt, 0x20, t.w, t.h, 1, t.layers, t.pkg, 0)
        struct.pack_into('<IIII', out, b + 0x50, blocks_[i][1], 512, 0, t.dim)
        struct.pack_into('<Q', out, b + 0x70, mo)
        for k, o in enumerate(mip_tables[i]): struct.pack_into('<Q', out, mo + 8 * k, o)
        mo += 8 * t.mips
    out[data_at:data_at + 4] = b'BRTD'
    out[data_at + 0x10:] = data
    return prefix + bytes(out)


def sarc(members):
    names = b''
    entries = b''
    data = b''
    for i, (name, d) in enumerate(members):
        data += bytes(-len(data) % 16)
        entries += struct.pack('<IIII', 0, 0x01000000 | len(names) // 4, len(data), len(data) + len(d))
        names += name.encode() + b'\0'; names += bytes(-len(names) % 4)
        data += d
    sfat = b'SFAT' + struct.pack('<HHI', 12, len(members), 0x65) + entries
    sfnt = b'SFNT' + struct.pack('<HH', 8, 0) + names
    doff = 0x14 + len(sfat) + len(sfnt)
    doff = (doff + 15) & ~15
    head = b'SARC' + struct.pack('<HHIIHH', 0x14, 0xfeff, doff + len(data), doff, 0x100, 0)
    return head + sfat + sfnt + bytes(doff - (0x14 + len(sfat) + len(sfnt))) + data


def yaz0_encode(data):
    """A Yaz0 stream with literals and back-references (greedy, small window): the decoder is checked against the format's definition"""
    out = bytearray(b'Yaz0' + struct.pack('>I', len(data)) + bytes(8))
    i = 0
    while i < len(data):
        group_at = len(out); out.append(0); bits = 0
        for k in range(8):
            if i >= len(data): break
            best, dist = 0, 0
            for d in range(1, min(i, 4096) + 1):
                n = 0
                while n < 255 + 0x12 and i + n < len(data) and data[i + n] == data[i + n - d]: n += 1
                if n > best: best, dist = n, d
            if best >= 3:
                if best <= 0x11: out += bytes([((best - 2) << 4) | ((dist - 1) >> 8), (dist - 1) & 255])
                else: out += bytes([(dist - 1) >> 8, (dist - 1) & 255, best - 0x12])
                i += best
            else:
                out[group_at] |= 0x80 >> k; out.append(data[i]); i += 1
    return bytes(out)


def zstd_compress(d):
    z = tool.zstd_module()
    if z is not None: return z.compress(d)
    return subprocess.run(['zstd', '-q', '-c'], input=d, capture_output=True, check=True).stdout


class NvnTexdesc(ctypes.Structure):   # nvn_texdesc, dm/gfx/nvn/nvn_tex.h
    _fields_ = [('target', ctypes.c_int), ('format', ctypes.c_int), ('flags', ctypes.c_int), ('samples', ctypes.c_int), ('width', ctypes.c_uint32), ('height', ctypes.c_uint32),
                ('depth', ctypes.c_uint32), ('levels', ctypes.c_uint32), ('stride', ctypes.c_uint32), ('pkg_block_h', ctypes.c_int)]


PLANE_FN = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_void_p, ctypes.c_uint, ctypes.c_uint, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_size_t)


class Config(ctypes.Structure):   # nvn_astc_bg_config
    _fields_ = [('cache', ctypes.c_char_p), ('readonly', ctypes.c_char_p), ('queue_cap', ctypes.c_size_t), ('cache_max', ctypes.c_uint64), ('min_free', ctypes.c_uint64), ('threads', ctypes.c_uint)]


@unittest.skipUnless(sys.platform == 'darwin', 'builds the engine\'s Objective-C texture code')
class PrebuildTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.root = Path(cls.tmp.name)
        cls.libpath = tool.build_library(str(cls.root / 'lib'))
        cls.lib = tool.lib_open(cls.libpath)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def textures(self):
        return [Texture(0x2001, 64, 40, mips=4, pkg=2), Texture(0x1a06, 37, 21, mips=3, pkg=0), Texture(0x1a01, 16, 16, mips=2, layers=3, dim=5, pkg=1),
                Texture(0x1c01, 128, 64, mips=5, pkg=3), Texture(0x1b01, 8, 8, mips=1), Texture(0x2006, 20, 36, mips=3, layers=6, dim=3, pkg=1)]

    def build_tree(self, name):
        lib = self.lib
        ts = self.textures()
        d = self.root / name
        (d / 'Model').mkdir(parents=True)
        (d / 'plain.bntx').write_bytes(bntx(lib, ts[:1]))
        # a BNTX inside a BFRES-like blob, inside a SARC, inside Yaz0
        blob = b'FRES    ' + bytes(0x40) + bntx(lib, [ts[1], ts[2]]) + bytes(100)
        inner = sarc([('a.bfres', blob), ('notes.txt', b'hello')])
        (d / 'Model' / 'kart.szs').write_bytes(yaz0_encode(sarc([('kart.bfres', blob), ('inner.sarc', inner)])))
        # zstd and nested SARC
        (d / 'tex.bntx.zs').write_bytes(zstd_compress(bntx(lib, ts[3:5])))
        (d / 'pack.pack.zs').write_bytes(zstd_compress(sarc([('t.bntx', bntx(lib, [ts[5]]))])))
        # not textures: an ASTC BNTX, BC4, garbage with a container name
        (d / 'astc.bntx').write_bytes(bntx(lib, [Texture(0x2d01, 32, 32, mips=1)]))
        (d / 'bad.szs').write_bytes(b'Yaz0' + struct.pack('>I', 1000) + bytes(8) + b'\x00\x01\x02')
        (d / 'cut.bntx').write_bytes(bntx(lib, ts[:1])[:300])
        (d / 'data.bin').write_bytes(bytes(1000))
        return d, ts

    def runtime_finds(self, ts, pack, cap=0, absent=None):
        """Every plane of every texture, as the RUNTIME enumerates and looks it up (nvn_astc_walk_planes + nvn_bc_astc_learn / fetch with the pack as the read-only cache).
        cap is DM_BC_MAX_DIM: the runtime skips nvn_bc_skip_levels(d, cap) levels (its bc_skip calls that function); the walk here starts there. Every plane of a skipped level is appended to `absent` when the pack lacks it"""
        L = self.lib
        L.nvn_bc_astc_bg_configure.argtypes = [ctypes.POINTER(Config)]
        L.nvn_bc_astc_learn.argtypes = [ctypes.c_uint32, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_uint, ctypes.c_void_p]
        L.nvn_bc_astc_fetch.argtypes = [ctypes.c_uint32, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_uint, ctypes.c_void_p, ctypes.c_size_t]
        L.nvn_bc_astc_encode.argtypes = [ctypes.c_uint32, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_uint, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_char_p, ctypes.c_char_p,
                                         ctypes.POINTER(ctypes.c_int)]
        L.nvn_bc_skip_levels.argtypes = [ctypes.POINTER(NvnTexdesc), ctypes.c_int]
        L.nvn_bc_skip_levels.restype = ctypes.c_uint
        L.nvn_astc_walk_planes.argtypes = [ctypes.POINTER(NvnTexdesc), ctypes.c_void_p, ctypes.c_uint, PLANE_FN, ctypes.c_void_p]
        L.nvn_bc_astc_bg_configure(ctypes.byref(Config(None, str(pack).encode(), 1 << 20, 1 << 30, 0, 1)))
        found = []
        for t in ts:
            if t.fmt not in NVN: continue
            formats = [t.nvn] + ([0x41] if t.fmt == 0x1a01 else [])
            for fmt in formats:
                d = NvnTexdesc(t.target, fmt, 0, 1, t.w, t.h, t.depth, t.mips, 0, t.pkg + 1)
                storage = ctypes.create_string_buffer(t.storage(L))
                seen = []
                skip = L.nvn_bc_skip_levels(ctypes.byref(d), cap)

                def cb(_, level, layer, w, h, bc, size):
                    plane = ctypes.string_at(bc, size)
                    seen.append((level, layer, plane == t.planes[(level, layer)]))   # deswizzle(swizzle(x)) == x: the runtime's walk sees the texture's planes
                    ok = L.nvn_bc_astc_learn(fmt, bc, size, w, h, 4, None) == 1
                    astc = ((w + 3) // 4) * 16 * ((h + 3) // 4)
                    got, want = ctypes.create_string_buffer(astc), ctypes.create_string_buffer(astc)
                    ok = ok and L.nvn_bc_astc_fetch(fmt, bc, size, w, h, 4, got, astc) == 1
                    hit = ctypes.c_int()
                    # the encoder given the texture's own linear plane (not the deswizzled copy): the blocks the pack holds are the ones this encoder makes
                    ok = ok and L.nvn_bc_astc_encode(fmt, t.planes[(level, layer)], size, w, h, 4, want, astc, None, None, ctypes.byref(hit)) == 0 and got.raw == want.raw
                    found.append(ok)
                    return 0
                fn = PLANE_FN(cb)
                self.assertEqual(L.nvn_astc_walk_planes(ctypes.byref(d), ctypes.cast(storage, ctypes.c_void_p), skip, fn, None), 0)
                self.assertTrue(all(s[2] for s in seen), (t.fmt, seen))
                self.assertEqual(len(seen), (t.mips - skip) * (t.layers if t.target != 8 else 6))
                if absent is not None:   # the levels the runtime leaves out: not in the pack
                    for level in range(skip):
                        for layer in range(t.layers if t.target != 8 else 6):
                            w, h = max(t.w >> level, 1), max(t.h >> level, 1)
                            plane = t.planes[(level, layer)]
                            absent.append(L.nvn_bc_astc_fetch(fmt, plane, len(plane), w, h, 4, ctypes.create_string_buffer(((w + 3) // 4) * 16 * ((h + 3) // 4)), ((w + 3) // 4) * 16 * ((h + 3) // 4)) != 1)
        return found

    def test_flags_match_the_host_makefile(self):
        mk = (DM / 'host/Makefile').read_text()
        line = next(l for l in mk.splitlines() if 'clang++' in l and 'ASTCENC_BLOCK_MAX_TEXELS' in l)
        for flag in tool.ASTC_FLAGS: self.assertIn(flag, line.split())

    def test_yaz0_decodes_the_formats_stream(self):
        rng = random.Random(5)
        for data in (b'', b'a', bytes(700), rng.randbytes(3000), (b'abcabcabd' * 200) + rng.randbytes(50)):
            self.assertEqual(tool.unyaz0(yaz0_encode(data), self.lib), data)
        with self.assertRaises(ValueError): tool.unyaz0(b'Yaz0' + struct.pack('>I', 1000) + bytes(8) + b'\x00\x01', self.lib)

    def test_prebuilt_entries_are_what_the_runtime_looks_up(self):
        d, ts = self.build_tree('tree')
        out = self.root / 'out'
        rep = tool.prebuild(str(d), str(out), 4, workers=2, log=lambda *_: None)
        self.assertEqual(rep['eligible_textures'], 8)   # two of the six sit in two archives
        self.assertEqual(rep['converted_textures'] + rep['repeated_textures'], 8)
        self.assertEqual(rep['layout_differs'], 0)
        self.assertEqual(rep['plane_errors'], 0)
        self.assertGreaterEqual(rep['container_errors'], 1)   # bad.szs was counted and did not stop the run (cut.bntx is no BNTX: its size field passes the end of the file)
        expect_planes = sum(t.mips * (6 if t.target == 8 else t.layers) for t in ts)
        self.assertEqual(rep['unique_planes'], expect_planes)
        pack = out / 'astc-ro.pack'
        info = tool.read_pack_header(str(pack))
        self.assertIsNotNone(info)
        self.assertEqual(rep['entries'], info['entries'])
        found = self.runtime_finds(ts, pack)
        self.assertEqual(len(found), expect_planes + sum(t.mips * t.layers for t in ts if t.fmt == 0x1a01))   # BC1 is looked up under both of its NVN formats
        self.assertTrue(all(found), 'a plane the runtime walks is missing from the pack or differs from the runtime encoder')

    def test_texture_cap_packs_only_the_levels_the_runtime_keeps(self):
        lib = self.lib
        ts = [Texture(0x1a01, 2048, 1024, mips=6, pkg=4), Texture(0x1c01, 1024, 1024, mips=4, layers=2, dim=5, pkg=3), Texture(0x1a06, 1024, 1024, mips=3, layers=6, dim=3, pkg=1),
              Texture(0x1c01, 1024, 512, mips=1, pkg=2), Texture(0x1a06, 600, 300, mips=2, pkg=1)]
        d = self.root / 'captree'
        d.mkdir()
        (d / 'a.bntx').write_bytes(bntx(lib, ts))
        out = self.root / 'capout'
        base = tool.prebuild(str(d), str(self.root / 'capfull'), 4, workers=2, log=lambda *_: None)
        rep = tool.prebuild(str(d), str(out), 4, workers=2, log=lambda *_: None, max_dim=512)
        self.assertEqual(rep['max_dim'], 512)
        # 2048x1024 x6 mips: levels 0-1 left out (1024 > 512); 1024 array x4: level 0 left out; cube and a single-level texture are never cut; 600x300 x2: level 0 (600 > 512) left out, the last level stays
        kept = (6 - 2) + (4 - 1) * 2 + 3 * 6 + 1 + 1
        self.assertEqual(rep['unique_planes'], kept)
        self.assertEqual(base['unique_planes'], 6 + 4 * 2 + 3 * 6 + 1 + 2)
        self.assertLess(rep['pack_bytes'], base['pack_bytes'])
        absent = []
        found = self.runtime_finds(ts, out / 'astc-ro.pack', cap=512, absent=absent)
        self.assertTrue(found and all(found), 'a plane the runtime asks for under the cap is missing from the pack')
        self.assertEqual(len(absent), 2 * 2 + 1 * 2 + 1)   # the BC1 texture is looked up under both its NVN formats
        self.assertTrue(all(absent), 'the pack holds a level the runtime skips under the cap')
        # a cap change is another pack; the same cap is the same pack
        self.assertTrue(tool.prebuild(str(d), str(out), 4, workers=2, log=lambda *_: None, max_dim=512)['up_to_date'])
        self.assertFalse(tool.prebuild(str(d), str(out), 4, workers=2, log=lambda *_: None, max_dim=256)['up_to_date'])

    def test_pack_is_sorted_and_shares_the_bc1_payloads(self):
        d, ts = self.build_tree('tree2')
        out = self.root / 'out2'
        tool.prebuild(str(d), str(out), 4, workers=2, log=lambda *_: None)
        data = (out / 'astc-ro.pack').read_bytes()
        count, ioff, size = struct.unpack_from('<QQQ', data, 16)
        self.assertEqual(size, len(data))
        self.assertEqual(ioff + 48 * count, len(data))
        keys = [data[ioff + 48 * i:ioff + 48 * i + 32] for i in range(count)]
        self.assertEqual(keys, sorted(set(keys)))
        offsets = [struct.unpack_from('<Q', data, ioff + 48 * i + 32)[0] for i in range(count)]
        self.assertLess(len(set(offsets)), count)   # the BC1 planes' second key points at the same payload
        self.assertTrue(all(o % 16 == 0 for o in offsets))

    def test_incremental(self):
        d, ts = self.build_tree('tree3')
        out = self.root / 'out3'
        first = tool.prebuild(str(d), str(out), 4, workers=2, log=lambda *_: None)
        self.assertFalse(first['up_to_date'])
        stamp = (out / 'astc-ro.pack').stat().st_mtime_ns
        again = tool.prebuild(str(d), str(out), 4, workers=2, log=lambda *_: None)
        self.assertTrue(again['up_to_date'])
        self.assertEqual((out / 'astc-ro.pack').stat().st_mtime_ns, stamp)
        os.utime(d / 'plain.bntx', (1, 1))   # an input changed: rebuilt, from the entries already encoded
        third = tool.prebuild(str(d), str(out), 4, workers=2, log=lambda *_: None)
        self.assertFalse(third['up_to_date'])
        self.assertEqual(third['encoded_now'], 0)
        six = tool.prebuild(str(d), str(out), 6, workers=2, log=lambda *_: None)   # another block size is another pack
        self.assertFalse(six['up_to_date'])
        self.assertNotEqual(six['unique_planes'], 0)

    def test_scan_only_writes_no_pack(self):
        d, ts = self.build_tree('tree4')
        rep = tool.prebuild(str(d), str(self.root / 'out4'), 4, workers=1, scan_only=True, log=lambda *_: None)
        self.assertEqual(rep['converted_textures'] + rep['repeated_textures'], 8)
        self.assertFalse((self.root / 'out4' / 'astc-ro.pack').exists())

    def test_build_folder_and_image_are_found(self):
        b = self.root / 'build' / 'extract' / 'v7'
        (b / 'ExeFS').mkdir(parents=True)
        (b / 'RomFS.img').write_bytes(b'DMROMFS1')
        (self.root / 'build' / 'extract' / 'v10').mkdir()
        (self.root / 'build' / 'extract' / 'v10' / 'RomFS.img').write_bytes(b'DMROMFS1')
        self.assertTrue(tool.find_romfs(str(self.root / 'build')).endswith('v10/RomFS.img'))


if __name__ == '__main__':
    unittest.main()
