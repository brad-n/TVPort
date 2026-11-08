"""tex_once.py and sparse_image.py (docs/texture_once.md sections 1, 2 and 4): the sparse image round trip, the Yaz0 encoder, the strip of every container kind and its self-check.

Synthetic game files only (no game data). The strip tests need macOS with clang (they build the engine's texture code, as test_bntx_astc.py does).
"""
import hashlib
import importlib.util
import json
import os
import random
import struct
import sys
import tempfile
import unittest
import zlib
from pathlib import Path

TESTS = Path(__file__).resolve().parent
TOOLS = Path(__file__).resolve().parents[1] / 'tools'
DM = TOOLS.parents[1]
sys.path.insert(0, str(TOOLS)); sys.path.insert(0, str(TESTS)); sys.path.insert(0, str(DM / 'tools'))


def load(name):
    spec = importlib.util.spec_from_file_location(name, TOOLS / (name + '.py'))
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


import test_bntx_astc as T   # the synthetic BNTX / SARC / Yaz0 / zstd builders (first: it registers the one bntx_astc module the worker processes unpickle)
S = load('sparse_image')
tool = load('tex_once')
B = tool.B
assert B is T.tool
import romfs_image


def fake_pack(path, entries=3):
    """A minimal valid NXASTCPK file (the sparse image embeds it unchanged)"""
    body = b''.join(bytes([i + 1]) * 64 for i in range(entries))
    ioff = 80 + len(body)
    idx = b''.join(hashlib.sha256(bytes([i])).digest() + struct.pack('<QQ', 80 + 64 * i, 64) for i in range(entries))
    size = ioff + len(idx)
    Path(path).write_bytes(b'NXASTCPK' + struct.pack('<IIQQQ', 1, 48, entries, ioff, size) + bytes(32) + bytes(8) + body + idx)


class SparseTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.root = Path(self.tmp.name)

    def tearDown(self): self.tmp.cleanup()

    def image(self, logical, pack=True):
        """Logical bytes with holes: data, a 100 KB zero run, data, a short zero run (stays), data, a 50 KB zero tail"""
        rng = random.Random(3)
        a, b, c = rng.randbytes(5000), rng.randbytes(777), rng.randbytes(9000)
        data = a + bytes(100_000) + b + bytes(3000) + c + bytes(50_000)
        w = S.SparseWriter(str(self.root / 'x.img'), len(data))
        w.put_scanned(0, data)
        info = w.finish(str(self.root / 'x.pack') if pack else None)
        return data, info

    def test_round_trip_with_holes_and_trailer(self):
        fake_pack(self.root / 'x.pack')
        data, info = self.image(0)
        self.assertLess(info['physical'], len(data) // 2)
        s = S.SparseImage(str(self.root / 'x.img'))
        self.assertEqual(s.logical_size, len(data))
        self.assertEqual(s.read(0, len(data)), data)
        for off, n in ((0, 1), (4999, 3), (5000, 100), (104_990, 5000), (len(data) - 10, 100), (len(data), 5), (60_000, 1)):
            self.assertEqual(s.read(off, n), data[off:off + n])
        self.assertEqual(len(s.read(len(data) - 3, 10)), 3)   # short at the end, like a file
        ext = s.extents()
        self.assertTrue(all(p % 16 == 0 for _, _, p in ext))
        self.assertTrue(all(ext[i][0] + ext[i][1] <= ext[i + 1][0] for i in range(len(ext) - 1)))
        self.assertEqual(len(ext), 2)                     # the 3,000-byte run stayed inside an extent; both long runs are holes
        self.assertEqual(s.hole_bytes(), 100_000 + 50_000)
        raw = (self.root / 'x.img').read_bytes()
        self.assertEqual(raw[:8], b'DMSPARS1')
        self.assertEqual(raw[-32:-24], b'DMSPEND1')
        self.assertEqual(struct.unpack_from('<Q', raw, len(raw) - 24)[0], len(raw))
        self.assertEqual(s.pack_offset % 16384, 0)
        self.assertEqual(raw[s.pack_offset:s.pack_offset + s.pack_size], (self.root / 'x.pack').read_bytes())
        self.assertEqual(s.read_pack(0, 8), b'NXASTCPK')
        s.close()

    def test_no_pack_and_all_zero_image(self):
        data, info = self.image(0, pack=False)
        with S.SparseImage(str(self.root / 'x.img')) as s: self.assertEqual((s.pack_offset, s.pack_size), (0, 0))
        w = S.SparseWriter(str(self.root / 'z.img'), 1 << 20)
        w.put_scanned(0, bytes(1 << 20)); w.finish()
        with S.SparseImage(str(self.root / 'z.img')) as s:
            self.assertEqual((s.count, s.read(100, 50)), (0, bytes(50)))
        self.assertLess((self.root / 'z.img').stat().st_size, 200)

    def test_truncated_and_damaged_files_are_rejected(self):
        fake_pack(self.root / 'x.pack')
        self.image(0)
        raw = (self.root / 'x.img').read_bytes()
        for cut in (len(raw) - 1, len(raw) - 32, len(raw) // 2, 64, 10, 0):
            (self.root / 'cut.img').write_bytes(raw[:cut])
            with self.assertRaises(S.SparseError, msg=cut): S.SparseImage(str(self.root / 'cut.img'))
        bad = bytearray(raw); bad[len(raw) - 24] ^= 1   # the trailer's size
        (self.root / 'bad.img').write_bytes(bytes(bad))
        with self.assertRaises(S.SparseError): S.SparseImage(str(self.root / 'bad.img'))
        bad = bytearray(raw); bad[0] = ord('X')
        (self.root / 'bad.img').write_bytes(bytes(bad))
        with self.assertRaises(S.SparseError): S.SparseImage(str(self.root / 'bad.img'))
        bad = bytearray(raw); bad[8:12] = struct.pack('<I', 2)   # version
        (self.root / 'bad.img').write_bytes(bytes(bad))
        with self.assertRaises(S.SparseError): S.SparseImage(str(self.root / 'bad.img'))

    def test_writer_rules(self):
        w = S.SparseWriter(str(self.root / 'w.img'), 100)
        w.put(10, b'abc')
        with self.assertRaises(S.SparseError): w.put(5, b'x')            # out of order
        with self.assertRaises(S.SparseError): w.put(99, b'xx')          # past the logical size
        w.abort()
        self.assertFalse((self.root / 'w.img.part').exists())
        self.assertFalse((self.root / 'w.img').exists())

    def test_zero_run_scan(self):
        z = bytes(S.MIN_HOLE)
        self.assertEqual(S.split_zero_runs(b''), [])
        self.assertEqual(S.split_zero_runs(bytes(10_000)), [])
        self.assertEqual(S.split_zero_runs(b'a' + bytes(S.MIN_HOLE - 1) + b'b'), [(0, S.MIN_HOLE + 1)])     # one byte short of a hole
        self.assertEqual(S.split_zero_runs(b'a' + z + b'b'), [(0, 1), (S.MIN_HOLE + 1, S.MIN_HOLE + 2)])    # exactly a hole
        self.assertEqual(S.split_zero_runs(z + b'abc' + z), [(S.MIN_HOLE, S.MIN_HOLE + 3)])

    def test_logical_file_reads_like_the_plain_file(self):
        fake_pack(self.root / 'x.pack')
        data, _ = self.image(0)
        with S.open_logical(str(self.root / 'x.img')) as f:
            self.assertEqual(f.read(10), data[:10])
            f.seek(104_000); self.assertEqual(f.read(2000), data[104_000:106_000])
            f.seek(-5, 2); self.assertEqual(f.read(), data[-5:])
        plain = self.root / 'p.img'; plain.write_bytes(b'hello')
        with S.open_logical(str(plain)) as f: self.assertEqual(f.read(), b'hello')


class RomfsViewTests(unittest.TestCase):
    """romfs.py, romfs_image.py (identity, index, format check) see a DMSPARS1 file as the DMROMFS1 image it holds"""
    def test_sparse_image_lists_reads_and_identifies_like_its_plain_image(self):
        import romfs
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            src = root / 'src'
            (src / 'a' / 'b').mkdir(parents=True)
            (src / 'a' / 'one.bin').write_bytes(os.urandom(3000) + bytes(40_000) + b'tail')
            (src / 'a' / 'b' / 'two.zs').write_bytes(bytes.fromhex('28b52ffd') + b'zzz')
            (src / 'big.bin').write_bytes(bytes(300_000))
            (src / 'x.txt').write_bytes(b'hello')
            plain = root / 'plain' / 'RomFS.img'; plain.parent.mkdir()
            romfs_image.pack(str(src), str(plain))
            fake_pack(root / 'p.pack')
            sparse = root / 'sparse' / 'romfs.img'; sparse.parent.mkdir()
            data = plain.read_bytes()
            w = S.SparseWriter(str(sparse), len(data)); w.put_scanned(0, data); w.finish(str(root / 'p.pack'))
            self.assertLess(sparse.stat().st_size, len(data))
            self.assertTrue(romfs.is_image(str(sparse)))
            self.assertEqual(romfs_image.identity(str(sparse), 't', '1', '2'), romfs_image.identity(str(plain), 't', '1', '2'))
            self.assertEqual(romfs_image.read_index(str(sparse)), romfs_image.read_index(str(plain)))
            self.assertEqual(romfs_image.format_mismatches(str(sparse)), romfs_image.format_mismatches(str(plain)))
            for name in ('a/one.bin', 'a/b/two.zs', 'big.bin', 'x.txt'):
                self.assertEqual(romfs.Path(str(sparse) + '/' + name).read_bytes(), romfs.Path(str(plain) + '/' + name).read_bytes(), name)
            self.assertEqual(sorted(romfs.os.listdir(str(sparse) + '/a')), sorted(romfs.os.listdir(str(plain) + '/a')))
            self.assertEqual(sorted(r for r, _, _ in romfs.walk(str(sparse))), sorted(r.replace('plain/RomFS.img', 'sparse/romfs.img') for r, _, _ in romfs.walk(str(plain))))
            self.assertEqual(romfs.stat(str(sparse) + '/big.bin').st_size, 300_000)
            # mmap of a file inside the image (archive scans)
            with romfs.open(str(sparse) + '/a/one.bin', 'rb') as f:
                with romfs.mmap.mmap(f.fileno(), 0, access=romfs.mmap.ACCESS_READ) as m:
                    full = (src / 'a' / 'one.bin').read_bytes()
                    self.assertEqual((len(m), m[3000:3010], m.find(b'tail'), m[10]), (len(full), full[3000:3010], len(full) - 4, full[10]))
            # the command line: --identity prints the same line
            import subprocess
            ids = [subprocess.run([sys.executable, '-I', str(DM / 'tools' / 'romfs_image.py'), '--identity', str(p), 't', '1', '2'], capture_output=True, text=True).stdout for p in (sparse, plain)]
            self.assertEqual(ids[0], ids[1]); self.assertIn('DMROMFSID1', ids[0])
            r = subprocess.run([sys.executable, '-I', str(DM / 'tools' / 'romfs.py'), str(sparse), 'x.txt'], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stderr)


class NativeYaz0Tests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.native = tool.native_open(tool.build_native(cls.tmp.name))

    @classmethod
    def tearDownClass(cls): cls.tmp.cleanup()

    def decode(self, stream):
        """The format's own definition (test_bntx_astc's decoder-by-definition), independent of the engine's C decoder"""
        n = int.from_bytes(stream[4:8], 'big'); out = bytearray(); i = 16
        while len(out) < n:
            h = stream[i]; i += 1
            for k in range(8):
                if len(out) >= n: break
                if h & (0x80 >> k): out.append(stream[i]); i += 1
                else:
                    b1, b2 = stream[i], stream[i + 1]; i += 2
                    ln = b1 >> 4
                    if ln: ln += 2
                    else: ln = stream[i] + 0x12; i += 1
                    d = ((b1 & 15) << 8 | b2) + 1
                    for _ in range(ln): out.append(out[-d])
        return bytes(out), i

    def test_streams_decode_to_the_input(self):
        rng = random.Random(8)
        cases = [b'', b'a', b'ab', b'abc' * 3, bytes(5000), rng.randbytes(3000), (b'abcabcabd' * 300) + rng.randbytes(50), bytes(100_000) + rng.randbytes(100) + bytes(70_000),
                 b''.join(rng.randbytes(40) + bytes(rng.randrange(0, 500)) for _ in range(200))]
        for data in cases:
            s = tool.yaz0_pack(self.native, data, len(data) + len(data) // 8 + 64)
            self.assertIsNotNone(s, len(data))
            self.assertEqual(s[:4], b'Yaz0'); self.assertEqual(int.from_bytes(s[4:8], 'big'), len(data))
            dec, used = self.decode(s)
            self.assertEqual(dec, data)
            self.assertEqual(used, len(s))
        self.assertLess(len(tool.yaz0_pack(self.native, bytes(1_000_000), 100_000)), 12000)   # zeros cost 3 bytes per 273

    def test_a_stream_that_does_not_fit_is_refused(self):
        data = random.Random(1).randbytes(5000)
        self.assertIsNone(tool.yaz0_pack(self.native, data, 4000))
        self.assertIsNotNone(tool.yaz0_pack(self.native, data, 6000))


class ZstdSlotTests(unittest.TestCase):
    def test_slot_is_filled_with_a_skippable_frame(self):
        z = B.zstd_module()
        data = random.Random(2).randbytes(3000) + bytes(40_000)
        comp = z.compress(data, level=3)
        for slot in (len(comp) + 8, len(comp) + 1000, len(comp)):
            r = tool.zstd_slot(data, slot)
            self.assertEqual(len(r), slot)
            self.assertEqual(z.decompress(r), data)
        self.assertIsNone(tool.zstd_slot(data, len(comp) - 100))
        r = tool.zstd_slot(data, len(comp) + 3)       # 3 bytes cannot hold a frame header: a stronger level may fit exactly, else None
        self.assertTrue(r is None or (len(r) == len(comp) + 3 and z.decompress(r) == data))
        f = tool.skippable_frame(20)
        self.assertEqual((len(f), f[:4], f[4:8], f[8:]), (20, bytes.fromhex('502a4d18'), struct.pack('<I', 12), bytes(12)))


def swizzled(lib, tex, pkg_block_h):
    """A texture's block-linear storage with the given packaged block height (0 = the automatic layout, as a NUTEXB has)"""
    import ctypes
    size = lib.dm_texture_size(tex.target, tex.nvn, tex.w, tex.h, tex.depth, tex.mips, pkg_block_h)
    buf = ctypes.create_string_buffer(size)
    for (l, y), plane in tex.planes.items():
        pitch = ((max(tex.w >> l, 1) + 3) // 4) * T.BYTES_PER_BLOCK[tex.nvn]
        assert lib.dm_swizzle(tex.target, tex.nvn, tex.w, tex.h, tex.depth, tex.mips, pkg_block_h, l, y, plane, pitch, buf) == 0
    return buf.raw


def nutexb(lib, tex, fmt_byte):
    image = swizzled(lib, tex, 0)
    footer = bytes(0x40) + struct.pack('<9I', tex.w, tex.h, 1, fmt_byte | 0x300, 4, tex.mips, 0x1000, 1, len(image)) + b' XET' + struct.pack('<I', 0x00020001)
    assert len(footer) == 0x6c
    return image + footer


def skippable(n): return tool.skippable_frame(n)


def smash_fs(entries, stored_placeholder=0):
    """The inflated file system table of a data.arc with `entries` = [(offset in file section / 4, stored size, size)], all nutexb, one directory at offset 0 of the file section"""
    n = len(entries)
    hdr = bytearray(0x58)
    tsize = 0x58 + 16 + 8 + n * 32 + n * 8 + 0x1c + n * 16 + n * 12 + n * 16 + n * 12 * 0
    struct.pack_into('<12I', hdr, 0, tsize, n, n, 0, 1, 0, n, n, n, 0, 0, 0)
    out = bytearray(hdr)
    out += bytes(16) + struct.pack('<2I', 0, 0)                    # stream header, hash group header
    ec, ew = zlib.crc32(b'nutexb'), 6
    for i in range(n): out += struct.pack('<IIII', 0x1000 + i, (i << 8) | 8, ec, ew) + bytes(16)       # paths: {crc, len | index << 8}, extension
    for i in range(n): out += struct.pack('<II', 0, i)                                                    # path-to-info: directory offset, file info
    out += struct.pack('<Q', 0) + bytes(0x14)                                                            # directory offset 0
    for i in range(n): out += struct.pack('<IIII', i, i, i, 0)                                           # file infos: path, path-to-info, info-to-data, flags
    for i in range(n): out += struct.pack('<III', 0, i, 0)                                               # info-to-data: directory offset, file data
    for off, csz, usz in entries: out += struct.pack('<IIII', off, csz, usz, 3 if csz != usz else 0)     # file data
    struct.pack_into('<I', out, 0, len(out))
    return bytes(out)


def smash_arc_file(payloads):
    """A data.arc holding the payloads (each (bytes, size inflated)), the table after them; -> (file bytes, [(offset, stored size, size)])"""
    zstd = B.zstd_module()
    file_off = 0x100
    body = bytearray(); ents = []
    for data, usz in payloads:
        body += bytes(-len(body) % 4)
        ents.append((len(body) // 4, len(data), usz)); body += data
    fs = smash_fs(ents)
    frame = zstd.compress(fs, level=1)          # a weak level: the rewrite (level 22) fits with room to spare
    table_off = file_off + len(body) + (-len(body) % 16)
    head = struct.pack('<Q', 0xABCDEF9876543210) + struct.pack('<6Q', 0, file_off, 0, table_off, table_off + 16 + len(frame), 0)
    return bytes(head) + bytes(file_off - len(head)) + bytes(body) + bytes(table_off - file_off - len(body)) + struct.pack('<4I', 0x10, len(fs), len(frame), len(fs)) + frame + bytes(16), ents


@unittest.skipUnless(sys.platform == 'darwin', 'builds the engine\'s Objective-C texture code')
class StripTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(); cls.root = Path(cls.tmp.name)
        cls.libdir = os.environ.get('TEX_ONCE_TEST_LIB')   # a folder holding libastc_prebuild-<tag>.dylib already (skips the compile)
        cls.libpath = B.build_library(cls.libdir or str(cls.root / 'lib'))
        cls.lib = B.lib_open(cls.libpath)

    @classmethod
    def tearDownClass(cls): cls.tmp.cleanup()

    def tree(self, name, arc=False):
        lib = self.lib
        ts = [T.Texture(0x2001, 64, 40, mips=4, pkg=2), T.Texture(0x1a06, 128, 64, mips=4, pkg=0), T.Texture(0x1a01, 64, 64, mips=3, layers=3, dim=5, pkg=1),
              T.Texture(0x1c01, 128, 64, mips=5, pkg=3), T.Texture(0x1b01, 64, 64, mips=2), T.Texture(0x2006, 64, 64, mips=3, layers=6, dim=3, pkg=1),
              T.Texture(0x1a01, 4, 4, mips=1, pkg=0)]          # the last: one 8-byte plane, under the 16-byte tag size
        d = self.root / name
        (d / 'Model').mkdir(parents=True)
        (d / 'plain.bntx').write_bytes(T.bntx(lib, [ts[0], ts[6]]))
        blob = b'FRES    ' + bytes(0x40) + T.bntx(lib, [ts[1], ts[2]]) + bytes(100)
        inner = T.sarc([('a.bfres', blob), ('notes.txt', b'hello')])
        raw_szs = T.sarc([('kart.bfres', blob), ('inner.sarc', inner)])
        yz = tool.yaz0_pack(tool.native_open(tool.build_native(str(self.root / 'nlib'))), raw_szs, 2 * len(raw_szs) + 64)   # the native encoder: the test helper's pure-Python one takes minutes on this size
        (d / 'Model' / 'kart.szs').write_bytes(yz + bytes(64))
        z = B.zstd_module()
        (d / 'tex.bntx.zs').write_bytes(z.compress(T.bntx(lib, ts[3:5]), level=19) + skippable(100))     # an input that already carries a padding frame
        (d / 'pack.pack.zs').write_bytes(z.compress(T.sarc([('t.bntx', T.bntx(lib, [ts[5]]))]), level=19))
        (d / 'astc.bntx').write_bytes(T.bntx(lib, [T.Texture(0x2d01, 32, 32, mips=1)]))
        (d / 'data.bin').write_bytes(bytes(1000) + os.urandom(100))
        self.ts = ts
        if arc:
            tex_a = T.Texture(0x1a01, 64, 64, mips=3, seed=5); tex_b = T.Texture(0x2001, 64, 64, mips=3, seed=6); tex_c = T.Texture(0x1c01, 32, 32, mips=2, seed=7)
            a, b = nutexb(lib, tex_a, 0x80), nutexb(lib, tex_b, 0xe0)
            c = z.compress(nutexb(lib, tex_c, 0xa0) + os.urandom(0), level=19)
            payloads = [(a, len(a)), (c, len(nutexb(lib, tex_c, 0xa0))), (b, len(b)), (b'not a texture' * 5, 65)]
            data, self.arc_entries = smash_arc_file(payloads)
            (d / 'data.arc').write_bytes(data)
        return d

    def make(self, name, arc=False, cap=0):
        d = self.tree(name, arc)
        work = self.root / (name + '_work'); work.mkdir()
        img = work / 'RomFS.img'
        romfs_image.pack(str(d), str(img))
        if self.libdir:
            (work / 'pack' / 'lib').mkdir(parents=True)
            for f in Path(self.libdir).glob('*.dylib'): (work / 'pack' / 'lib' / f.name).write_bytes(f.read_bytes())
        rep = B.prebuild(str(img), str(work / 'pack'), 4, workers=2, log=lambda *_: None, max_dim=cap)
        return d, img, work / 'pack' / 'astc-ro.pack', work / 'out'

    def run_tool(self, img, pack, out, cap=0, *extra):
        argv = [str(img), '--pack', str(pack), '--out', str(out), '--workers', '2', '--max-dim', str(cap)] + list(extra)
        old = sys.argv; sys.argv = ['tex_once.py'] + argv
        try:
            a = self.parse(argv)
            return tool.run(a)
        finally: sys.argv = old

    def parse(self, argv):
        import argparse
        ns = argparse.Namespace(input=argv[0], pack=None, out=None, max_dim=0, block=4, bc1_block=None, workers=2, arc_mode='table', force=False, json=False, no_pack_check=False)
        i = 1
        while i < len(argv):
            k = argv[i]
            if k == '--pack': ns.pack = argv[i + 1]; i += 2
            elif k == '--out': ns.out = argv[i + 1]; i += 2
            elif k == '--workers': ns.workers = int(argv[i + 1]); i += 2
            elif k == '--max-dim': ns.max_dim = int(argv[i + 1]); i += 2
            elif k == '--arc-mode': ns.arc_mode = argv[i + 1]; i += 2
            elif k == '--force': ns.force = True; i += 1
            elif k == '--bc1-block': ns.bc1_block = int(argv[i + 1]); i += 2
            elif k == '--no-pack-check': ns.no_pack_check = True; i += 1
            else: i += 1
        return ns

    def report(self, out): return json.loads((out / 'report.json').read_text())

    def test_every_container_kind_is_stripped_and_checked(self):
        d, img, pack, out = self.make('t1')
        self.assertEqual(self.run_tool(img, pack, out), 0)
        rep = self.report(out)
        self.assertTrue(rep['self_check']['passed'])
        self.assertEqual(rep['bytes']['logical'], img.stat().st_size)
        self.assertEqual(rep['bytes']['pack'], pack.stat().st_size)
        self.assertEqual(rep['bytes']['physical'], (out / 'romfs.img').stat().st_size)
        self.assertLess(rep['bytes']['physical'] - rep['bytes']['pack'], img.stat().st_size)
        c = rep['containers']
        self.assertGreaterEqual(c['yaz0'], 1); self.assertGreaterEqual(c['zstd'], 2); self.assertGreaterEqual(c['sarc'], 2)
        self.assertGreaterEqual(c['recompressed:yaz0'], 1); self.assertGreaterEqual(c['recompressed:zstd'], 2)
        self.assertEqual(rep['planes']['untouched_under_16_bytes'], 0)             # even the one-block 4x4 BC1 plane has a stored length of whole GOBs
        self.assertGreater(rep['planes']['tagged'], 20)
        self.assertEqual(rep['planes']['skipped'], {})
        # romfs.py reads the stripped image like a plain one: same listing, sizes, untouched files
        import romfs
        a, b = str(img), str(out / 'romfs.img')
        self.assertEqual(sorted(romfs.os.listdir(a)), sorted(romfs.os.listdir(b)))
        for name in ('astc.bntx', 'data.bin'):
            self.assertEqual(romfs.Path(a + '/' + name).read_bytes(), romfs.Path(b + '/' + name).read_bytes())
        for name in ('plain.bntx', 'tex.bntx.zs', 'pack.pack.zs', 'Model/kart.szs'):
            self.assertEqual(romfs.stat(a + '/' + name).st_size, romfs.stat(b + '/' + name).st_size)
            self.assertNotEqual(romfs.Path(a + '/' + name).read_bytes(), romfs.Path(b + '/' + name).read_bytes(), name)
        self.assertEqual(romfs_image.identity(str(img)), romfs_image.identity(b))

    def test_tags_equal_the_key_prefix_and_everything_else_is_zero_or_untouched(self):
        d, img, pack, out = self.make('t2')
        self.assertEqual(self.run_tool(img, pack, out), 0)
        import romfs
        orig = romfs.Path(str(img) + '/plain.bntx').read_bytes()
        new = romfs.Path(str(out / 'romfs.img') + '/plain.bntx').read_bytes()
        self.assertEqual(len(orig), len(new))
        L = self.lib
        idx = tool.PackIndex(str(pack))
        t0 = self.ts[0]
        tex = B.bntx_textures(orig, 0)[0]
        start = tex['start']
        cap = 40
        planes = (B.Plane * cap)()
        n = L.dm_texture_planes(1, t0.nvn, t0.w, t0.h, 1, t0.mips, t0.pkg + 1, B.addr(orig) + start, tex['size'], 4, 0, None, 0, planes, cap, 0)
        self.assertEqual(n, t0.mips)
        offs = [L.dm_level_offset(1, t0.nvn, t0.w, t0.h, 1, t0.mips, t0.pkg + 1, i) for i in range(t0.mips)]
        desc = tool.NvnTexdesc(1, t0.nvn, 0, 0, t0.w, t0.h, 1, t0.mips, 0, t0.pkg + 1)
        expect = bytearray(orig)
        for i in range(n):
            key = bytes.fromhex(planes[i].key.decode())
            self.assertIn(key, idx.keys)
            so, sl = tool.plane_storage(L, desc, planes[i].level, planes[i].layer)    # the runtime's stored length of the plane: exactly this range is overwritten
            lo = start + so; hi = lo + sl
            self.assertEqual(new[lo:lo + 8], key[:8])                      # the tag is the first 8 bytes of the pack key
            self.assertEqual(new[lo + 8:hi], bytes(hi - lo - 8))           # then zeros
            expect[lo:hi] = key[:8] + bytes(hi - lo - 8)
        t6 = B.bntx_textures(orig, 0)[1]
        other = slice(t6['start'], t6['start'] + t6['size'])               # the second texture is checked below
        expect[other] = bytes(t6['size']); got = bytearray(new); got[other] = bytes(t6['size'])
        self.assertEqual(bytes(expect), bytes(got))                        # every other byte is the original's
        # the one-block BC1 texture (second): its single plane has whole GOBs of storage, so it is tagged too
        self.assertEqual(new[t6['start'] + 8:t6['start'] + 512], bytes(504))


    def test_zeroed_range_is_the_runtime_plane_storage(self):
        """2D, array, cube and mipped textures: the bytes the strip rewrites are exactly each plane's [nvn_astc_plane_storage offset, + length)"""
        lib = self.lib
        cases = [T.Texture(0x1c01, 128, 64, mips=5, pkg=3), T.Texture(0x1a01, 64, 64, mips=3, layers=3, dim=5, pkg=1), T.Texture(0x2006, 64, 64, mips=3, layers=6, dim=3, pkg=1),
                 T.Texture(0x1a06, 128, 64, mips=4, pkg=0), T.Texture(0x2001, 37, 21, mips=3, pkg=2)]
        w = tool.Walker(self.libpath, tool.build_native(str(self.root / 'nlib')), 4, 0, None, {})
        for tex in cases:
            data = T.bntx(lib, [tex])
            t = B.bntx_textures(data, 0)[0]
            target, depth = B.target_of(t)
            desc = tool.NvnTexdesc(target, tex.nvn, 0, 0, tex.w, tex.h, depth, tex.mips, 0, tex.pkg + 1)
            walked = (B.Plane * 64)()
            n = lib.dm_texture_planes(target, tex.nvn, tex.w, tex.h, depth, tex.mips, tex.pkg + 1, B.addr(data) + t['start'], t['size'], 4, 0, None, 0, walked, 64, 0)
            self.assertGreater(n, 0)
            pack = tool.PackIndex.__new__(tool.PackIndex)
            pack.keys = {bytes.fromhex(walked[i].key.decode()): walked[i].astc_bytes for i in range(n)}
            pack.prefix = __import__('collections').Counter((k[:8], a) for k, a in pack.keys.items())
            w.pack = pack
            kind, mods, small = w.plan(data, t)
            self.assertEqual(kind, 'ok')
            want = []
            for i in range(n):
                off, ln = tool.plane_storage(lib, desc, walked[i].level, walked[i].layer)
                if hasattr(lib, 'nvn_astc_plane_storage'):   # the runtime's own function, once the library has it: the same range
                    import ctypes
                    o, l = ctypes.c_uint64(), ctypes.c_uint64()
                    lib.nvn_astc_plane_storage.argtypes = [ctypes.POINTER(tool.NvnTexdesc), ctypes.c_uint, ctypes.c_uint, ctypes.POINTER(ctypes.c_uint64), ctypes.POINTER(ctypes.c_uint64)]
                    self.assertEqual(lib.nvn_astc_plane_storage(ctypes.byref(desc), walked[i].level, walked[i].layer, ctypes.byref(o), ctypes.byref(l)), 0)
                    self.assertEqual((o.value, l.value), (off, ln))
                want.append((t['start'] + off, ln))
            self.assertEqual(sorted((m[0], m[1]) for m in mods), sorted(want), tex.fmt)
            self.assertEqual(small, 0)
            new = w.leaf(data, [t])
            exp = bytearray(data)
            for o, ln in want: exp[o:o + ln] = bytes(ln)
            for m in mods: exp[m[0]:m[0] + 8] = m[2]
            self.assertEqual(new, bytes(exp))

    def test_bc1_block_has_its_own_keys(self):
        """--bc1-block 6 with --block 4: BC1 planes are keyed and sized at 6x6, BC7 at 4x4; a pack made without it is the same as today's for the default"""
        import collections
        lib = self.lib
        bc1, bc7 = T.Texture(0x1a01, 64, 64, mips=3, pkg=1), T.Texture(0x2001, 64, 64, mips=3, pkg=2)
        d = self.root / 'bc1tree'; d.mkdir()
        (d / 'a.bntx').write_bytes(T.bntx(lib, [bc1])); (d / 'b.bntx').write_bytes(T.bntx(lib, [bc7]))
        work = self.root / 'bc1work'; work.mkdir()
        img = work / 'RomFS.img'; romfs_image.pack(str(d), str(img))
        cache = work / 'cache'; cache.mkdir()
        keys = {}
        for name, blk in (('a.bntx', 6), ('b.bntx', 4)):
            job = B.Job(self.libpath, blk, str(cache), True, {}, 0)
            job.blob((d / name).read_bytes(), name)
            for key, key2, w_, h_, astc, hit in job.planes:
                keys[key] = key
                if key2: keys[key2] = key
        pack = work / 'astc-ro.pack'
        B.write_pack(str(pack), str(cache), keys, bytes(32))
        out = work / 'out'
        self.assertEqual(self.run_tool(img, pack, out, 0, '--bc1-block', '6', '--no-pack-check'), 0)
        rep = self.report(out)
        self.assertEqual((rep['bc1_block'], rep['block'], rep['planes']['tagged'], rep['planes']['skipped']), (6, 4, 6, {}))
        # the same pack read at 4x4 for BC1: its BC1 planes are not in the pack
        out4 = work / 'out4'
        self.assertEqual(self.run_tool(img, pack, out4, 0, '--no-pack-check'), 0)
        rep4 = self.report(out4)
        self.assertEqual((rep4['planes']['tagged'], rep4['planes']['skipped'].get('not_in_pack')), (3, 3))
        self.assertNotEqual(rep['input_fingerprint'], rep4['input_fingerprint'])
        # a real pack's check: a bc1 block that the pack was not built for is refused
        self.assertEqual(self.run_tool(img, pack, work / 'out5', 0, '--bc1-block', '6'), 2)

    def test_texture_cap_zeroes_the_levels_the_runtime_never_loads(self):
        d, img, pack, out = self.make('t3', cap=64)
        self.assertEqual(self.run_tool(img, pack, out, 64), 0)
        rep = self.report(out)
        self.assertGreater(rep['planes']['zeroed_above_cap'], 0)
        self.assertTrue(rep['self_check']['passed'])

    def test_skip_when_inputs_are_unchanged_and_refuse_a_foreign_pack(self):
        d, img, pack, out = self.make('t4')
        self.assertEqual(self.run_tool(img, pack, out), 0)
        stamp = (out / 'romfs.img').stat().st_mtime_ns
        self.assertEqual(self.run_tool(img, pack, out), 0)
        self.assertEqual((out / 'romfs.img').stat().st_mtime_ns, stamp)          # nothing rewritten
        self.assertEqual(self.run_tool(img, pack, out, 0, '--force'), 0)
        self.assertNotEqual((out / 'romfs.img').stat().st_mtime_ns, stamp)
        # another cap: the pack was built for cap 0, so it is refused
        self.assertEqual(self.run_tool(img, pack, self.root / 'out_cap', 512), 2)
        self.assertFalse((self.root / 'out_cap' / 'romfs.img').exists())
        # another RomFS: refused
        other = self.root / 't4_work' / 'Other.img'
        other.write_bytes(img.read_bytes() + b'')
        self.assertEqual(self.run_tool(other, pack, self.root / 'out_other'), 2)

    def test_self_check_catches_a_damaged_strip(self):
        d, img, pack, out = self.make('t5')
        lib = self.lib
        w = tool.Walker(self.libpath, tool.build_native(str(self.root / 'nlib')), 4, 0, tool.PackIndex(str(pack)), {})
        o = T.bntx(lib, [self.ts[0]])
        n = w.strip(o, 'x.bntx')
        self.assertIsNotNone(n)
        w.c = __import__('collections').Counter()
        w.check(o, n, 'x.bntx')                                                       # the strip passes its own check
        bad = bytearray(n); bad[-5] ^= 0xff                                           # inside the last plane's span
        with self.assertRaises(tool.Mismatch): w.check(o, bytes(bad), 'x.bntx')
        bad = bytearray(n); bad[0x58] ^= 1                                            # the header
        with self.assertRaises(tool.Mismatch): w.check(o, bytes(bad), 'x.bntx')
        t = B.bntx_textures(o, 0)[0]
        bad = bytearray(n); bad[t['start']] ^= 1                                      # a tag
        with self.assertRaises(tool.Mismatch): w.check(o, bytes(bad), 'x.bntx')
        with self.assertRaises(tool.Mismatch): w.check(b'plain file', b'other file', 'f.bin')

    def test_unknown_or_unfitting_containers_are_left_alone_and_reported(self):
        d, img, pack, out = self.make('t6')
        w = tool.Walker(self.libpath, tool.build_native(str(self.root / 'nlib')), 4, 0, tool.PackIndex(str(pack)), {})
        o = T.bntx(self.lib, [self.ts[0]])
        z = B.zstd_module()
        # a zstd slot with no room: the stored stream is the best that fits, the stripped data does not -> kept as is
        tiny = z.compress(o, level=19)
        r = w.strip(tiny[:len(tiny) - 0], 'a.bntx.zs')
        self.assertIsNotNone(r); self.assertEqual(len(r), len(tiny))
        # a Yaz0 slot far too small for what it expands to once tagged
        noise = os.urandom(20000)
        ytiny = tool.yaz0_pack(w.N, noise, 25000)
        w.c.clear()
        self.assertIsNone(w.strip(ytiny[:len(ytiny)], 'n.szs'))                         # no texture: nothing to do
        self.assertEqual(w.c['other_files'], 1)

    def test_smash_data_arc_entries_and_table(self):
        import smash_arc
        d, img, pack, out = self.make('t7', arc=True)
        for mode in ('table', 'pad'):
            o = self.root / ('out_' + mode)
            self.assertEqual(self.run_tool(img, pack, o, 0, '--arc-mode', mode), 0, mode)
            rep = self.report(o)
            self.assertEqual(rep['arc_mode'], mode)
            self.assertTrue(rep['self_check']['passed'])
            import romfs
            ents0 = smash_arc.files(str(img) + '/data.arc')
            ents1 = smash_arc.files(str(o / 'romfs.img') + '/data.arc')
            self.assertEqual([e[1] for e in ents0], [e[1] for e in ents1])             # same offsets
            self.assertEqual([e[3] for e in ents0], [e[3] for e in ents1])             # same inflated sizes
            stored0, stored1 = [e[2] for e in ents0], [e[2] for e in ents1]
            if mode == 'table': self.assertLess(stored1[1], stored0[1])                # the compressed entry's stored size shrank
            else: self.assertEqual(stored0, stored1)
        # the entries are textures again after the strip
        self.assertGreaterEqual(self.report(self.root / 'out_table')['planes']['tagged'], 6)


    # -- hidden bisect switches (TEX_ONCE_DEBUG): what each mode claims
    def debug_run(self, mode, name):
        d, img, pack, out = self.make(name, arc=True)
        old = os.environ.get('TEX_ONCE_DEBUG')
        os.environ['TEX_ONCE_DEBUG'] = mode
        try: self.assertEqual(self.run_tool(img, pack, out, 0), 0)
        finally:
            if old is None: os.environ.pop('TEX_ONCE_DEBUG', None)
            else: os.environ['TEX_ONCE_DEBUG'] = old
        return d, img, out

    def test_debug_repack_only_changes_no_content(self):
        import romfs
        z = B.zstd_module()
        cmp = load('tex_once_arc_compare')
        d, img, out = self.debug_run('repack-only', 'd1')
        rep = self.report(out)
        self.assertTrue(rep['self_check']['passed'])
        self.assertEqual(rep['planes']['tagged'], 0); self.assertEqual(rep['planes']['zeroed_above_cap'], 0)
        self.assertEqual(rep['bytes']['pack'], 0)                                   # no pack embedded
        self.assertGreaterEqual(rep['containers']['recompressed:zstd'], 2)           # the containers were re-packed all the same
        a, b = str(img), str(out / 'romfs.img')
        for name in ('plain.bntx', 'astc.bntx', 'data.bin', 'Model/kart.szs'):       # not zstd: the bytes did not change
            self.assertEqual(romfs.Path(a + '/' + name).read_bytes(), romfs.Path(b + '/' + name).read_bytes(), name)
        for name in ('tex.bntx.zs', 'pack.pack.zs'):                                 # zstd: same content (the bytes may or may not be the original encoder's)
            ra, rb = romfs.Path(a + '/' + name).read_bytes(), romfs.Path(b + '/' + name).read_bytes()
            self.assertEqual(B.unzstd(ra, {}), B.unzstd(rb, {}), name)
        r = cmp.compare(a, b, 1)
        self.assertEqual(r['content_changed'], 0); self.assertEqual(r['undecodable'], 0); self.assertNotIn('offset_sets_differ', r)
        self.assertEqual(r['entries_compared'], 4)
        self.assertEqual(r['identical'] + r['same_content_different_bytes'], 4)
        self.assertGreaterEqual(r['same_content_different_bytes'], 1)               # the zstd entry was re-packed

    def test_debug_zero_only_touches_no_compressed_container(self):
        import romfs
        cmp = load('tex_once_arc_compare')
        d, img, out = self.debug_run('zero-only', 'd2')
        rep = self.report(out)
        self.assertTrue(rep['self_check']['passed'])
        self.assertGreater(rep['planes']['tagged'], 6)
        self.assertEqual(rep['arc_mode'], 'pad')
        self.assertEqual(rep['containers'].get('recompressed:zstd', 0), 0); self.assertEqual(rep['containers'].get('recompressed:yaz0', 0), 0)
        a, b = str(img), str(out / 'romfs.img')
        for name in ('tex.bntx.zs', 'pack.pack.zs', 'Model/kart.szs', 'data.bin', 'astc.bntx'):    # compressed: byte-identical
            self.assertEqual(romfs.Path(a + '/' + name).read_bytes(), romfs.Path(b + '/' + name).read_bytes(), name)
        self.assertNotEqual(romfs.Path(a + '/plain.bntx').read_bytes(), romfs.Path(b + '/plain.bntx').read_bytes())     # raw BNTX: tagged
        r = cmp.compare(a, b, 1)
        self.assertTrue(r['table_slot_bytes_identical']); self.assertTrue(r['table_inflated_identical'])
        self.assertEqual(r['content_changed'], 2)                                    # the two uncompressed texture entries (the zstd one and the junk one are untouched)
        self.assertEqual(r['identical'], 2)
        self.assertEqual(r['same_content_different_bytes'], 0)

    def test_debug_switch_rejects_unknown_mode(self):
        old = os.environ.get('TEX_ONCE_DEBUG'); os.environ['TEX_ONCE_DEBUG'] = 'bogus'
        try:
            with self.assertRaises(SystemExit): tool.debug_mode()
        finally:
            if old is None: os.environ.pop('TEX_ONCE_DEBUG', None)
            else: os.environ['TEX_ONCE_DEBUG'] = old


class ZstdHeaderLayout(unittest.TestCase):
    """A re-packed frame keeps the original frame's header layout (Smash decodes only frames without a content size / single segment, 2026-11-08)"""
    def test_new_frame_copies_original_header(self):
        z = tool.B.zstd_module(); P = z.CompressionParameter
        data = random.Random(7).randbytes(60000)
        orig = z.compress(data, options={P.compression_level: 3, P.content_size_flag: 0, P.window_log: 17})
        self.assertEqual(tool.zstd_header(orig)[0], 0)
        zeroed = data[:1000] + bytes(len(data) - 1000)
        new = tool.zstd_slot(zeroed, len(orig), like=orig)
        self.assertIsNotNone(new)
        self.assertEqual(tool.zstd_header(new)[0], tool.zstd_header(orig)[0])
        self.assertEqual(tool.zstd_header(new), tool.zstd_header(orig))   # same descriptor and the same window
        self.assertEqual(z.decompress(new), zeroed)
        stream = tool.zstd_stream(zeroed, len(orig), like=orig)
        self.assertEqual(tool.zstd_header(stream)[0], 0)

    def test_without_original_defaults_stay(self):
        z = tool.B.zstd_module()
        data = bytes(5000)
        self.assertNotEqual(tool.zstd_header(tool.zstd_stream(data, 4096))[0], 0)   # zstd's own default: a content size


class NoRleZstdTests(unittest.TestCase):
    """The re-packed frames use only what Smash's data.arc frames use: raw / compressed blocks, raw / Huffman / treeless literals, no skippable frame where the original has none"""
    @staticmethod
    def sparse_data():
        return random.Random(11).randbytes(3000) + bytes(200_000) + b'\x07' * 70_000 + random.Random(12).randbytes(500) + bytes(300_000)

    def test_stock_zstd_makes_rle_blocks_ours_does_not(self):
        z = B.zstd_module(); P = z.CompressionParameter
        data = self.sparse_data()
        stock = z.compress(data, options={P.compression_level: 3, P.content_size_flag: 0, P.window_log: 17})
        self.assertIn('rle', tool.Z.frame_features(stock)['blocks'])          # why the tool has its own encoder
        orig = z.compress(random.Random(3).randbytes(len(data)), options={P.compression_level: 3, P.content_size_flag: 0, P.window_log: 17})
        for level in (3, 10, 19):
            new = tool.zstd_compress(data, level, None, orig)
            f = tool.Z.frame_features(new)
            self.assertFalse(f['blocks'] - {'raw', 'compressed'}, f)
            self.assertFalse(f['literals'] - {'raw', 'huffman', 'treeless'}, f)
            self.assertEqual(z.decompress(new), data)
            self.assertEqual(tool.zstd_header(new), tool.zstd_header(orig))
            self.assertEqual(tool.Z.forbidden(new, orig), [])
        # a short run of one byte (stock zstd: an RLE literals section) and an all-zero block
        for data in (bytes(100), b'ab' * 40 + bytes(5000), bytes(1 << 20)):
            new = tool.zstd_compress(data, 3, None, orig)
            self.assertEqual(tool.Z.forbidden(new, orig), [])
            self.assertEqual(z.decompress(new), data)

    def test_one_shot_path_has_no_rle_either(self):
        z = B.zstd_module()
        data = self.sparse_data()
        new = tool.zstd_compress(data, 19)                  # no original: zstd's defaults, still no RLE
        self.assertEqual(tool.Z.forbidden(new), [])
        self.assertEqual(z.decompress(new), data)

    def test_feature_check_rejects_rle_block_and_literals(self):
        z = B.zstd_module(); P = z.CompressionParameter
        stock = z.compress(self.sparse_data(), options={P.compression_level: 3})
        self.assertTrue(any('block types' in b for b in tool.Z.forbidden(stock)))
        lit = tool.ZSTD_MAGIC + bytes([0x00, 0x58]) + struct.pack('<I', 1 | (2 << 1) | (3 << 3))[:3] + bytes([0x01 | (5 << 3), 0x41, 0x00])   # a compressed block whose literals are 5 x 'A'
        self.assertEqual(tool.Z.frame_features(lit)['literals'], {'rle'})
        self.assertTrue(any('literal types' in b for b in tool.Z.forbidden(lit)))
        rle_block = tool.ZSTD_MAGIC + bytes([0x00, 0x58]) + struct.pack('<I', 1 | (1 << 1) | (100 << 3))[:3] + b'\x00'
        self.assertEqual(tool.Z.frame_features(rle_block)['blocks'], {'rle'})
        self.assertTrue(tool.Z.forbidden(rle_block))
        skip = z.compress(b'x' * 100) + tool.skippable_frame(32)
        self.assertEqual(tool.Z.forbidden(skip, z.compress(b'x')), ['a skippable frame'])
        self.assertEqual(tool.Z.forbidden(skip, skip), [])

    def test_check_raises_mismatch_on_rle(self):
        z = B.zstd_module(); P = z.CompressionParameter
        w = tool.Walker.__new__(tool.Walker)
        w.dicts, w.c = {}, __import__('collections').Counter()
        data = self.sparse_data()
        orig = z.compress(random.Random(5).randbytes(len(data)), options={P.compression_level: 3, P.content_size_flag: 0, P.window_log: 17})
        w.kind = lambda o, name, hint: 'zstd'
        stock = z.compress(data, options={P.compression_level: 3, P.content_size_flag: 0, P.window_log: 17})
        self.assertIn('rle', tool.Z.frame_features(stock)['blocks'])
        with self.assertRaises(tool.Mismatch) as cm: w.check(orig, stock + bytes(len(orig) - len(stock)) if len(stock) < len(orig) else stock, 'x', top_csz=len(stock))
        self.assertIn('block types', str(cm.exception))


class TableSlotTests(unittest.TestCase):
    def test_table_is_one_frame_with_stored_size_of_that_frame(self):
        payloads = [(random.Random(i).randbytes(5000), 5000) for i in range(3)]
        raw, ents = smash_arc_file(payloads)
        with tempfile.TemporaryDirectory() as tmp:
            f = Path(tmp) / 'data.arc'; f.write_bytes(raw)
            arc = tool.Arc.__new__(tool.Arc)
            import smash_arc
            arc.sa = smash_arc; arc.T = smash_arc.table(str(f)); arc.fd = smash_arc.fd_by_offset(arc.T)
            arc.table_off = arc.T['fs_off']; arc.table_size = 16 + arc.T['stored']
            self.assertIsNotNone(tool.zstd_table_frame(bytes(arc.T['fs']), arc.T['stored'], None))
            orig = raw[arc.table_off:arc.table_off + arc.table_size]
            arc.old_csz = {arc.T['file_off'] + 4 * e[0]: e[1] for e in ents}
            at = arc.T['file_off'] + 4 * ents[0][0]
            slot, fs = arc.build_table(orig, {at: 123})
            self.assertEqual(len(slot), len(orig))
            stored = struct.unpack_from('<I', slot, 8)[0]
            frame = slot[16:16 + stored]
            self.assertEqual(tool.Z.frame_features(frame)['frames'], 1)
            self.assertEqual(tool.Z.frame_features(frame)['skippable'], 0)
            self.assertEqual(slot[16 + stored:], bytes(len(slot) - 16 - stored))
            self.assertEqual((slot[:8], slot[12:16]), (orig[:8], orig[12:16]))        # start, size and section size unchanged
            self.assertEqual(tool.Z.forbidden(frame), [])
            self.assertEqual(bytes(B.unzstd(frame, {})), fs)


if __name__ == '__main__':
    unittest.main()
