"""Shader trimming (docs/reference/tv-size.md, "Cut 2 as built"): dm/gfx/tools/shader_trim.py packs the vertex and pixel shaders a game's lists do not name into zstd frames of their own
library files. Tested here: the used-list reader (S, C, R, M rows and key-only lists), which shaders are packed and which stay, every packed file coming back byte for byte, the index and its id,
the check finding a missing or damaged frame, and the image surviving shader_lib.subset (pack_ipa.py). With --fixture <dir>, writes the host test's library (t_shader_trim.m, make check_t_shader_trim):
real Mac libraries, some packed, one with a damaged frame. Needs Python 3.14 (compression.zstd); the fixture also needs the Metal toolchain."""
import hashlib, json, os, re, shutil, subprocess, sys, tempfile, unittest
from pathlib import Path

TESTS = Path(__file__).resolve().parent
DM = TESTS.parents[1]
sys.path.insert(0, str(DM / 'gfx/tools')); sys.path.insert(0, str(DM / 'tools'))
import romfs   # noqa: E402
import shader_lib   # noqa: E402
import shader_trim as T   # noqa: E402

CHAIN = re.search(r'DMSH_CHAIN\s+"([0-9a-f]+)"', (DM / 'gfx/nvn/dmsh_chain.h').read_text()).group(1)
K = {name: hashlib.sha256(name.encode()).hexdigest()[:16] for name in ('v_used', 'f_used', 'v_src', 'f_src', 'v_src2', 'f_src2', 'f_bad', 'c_unused', 'v_nolib', 'v_mesh', 'f_seen', 'v_task')}

VERTEX = '''#include <metal_stdlib>
using namespace metal;
struct main0_out { float4 gl_Position [[position]]; };
vertex main0_out main0(uint vid [[vertex_id]])
{
    main0_out out = {};
    out.gl_Position = float4(vid == 1 ? 3.0 : -1.0, vid == 2 ? 3.0 : -1.0, 0.5, 1.0);
    return out;
}
'''
FRAGMENT = '''#include <metal_stdlib>
using namespace metal;
struct main0_out { float4 m_0 [[color(0)]]; };
fragment main0_out main0()
{
    main0_out out = {};
    out.m_0 = float4(1.0, 0.0, 0.0, 1.0);
    return out;
}
'''
SIDE = FRAGMENT + '''
fragment main0_out main0_a() { main0_out out = {}; out.m_0 = float4(0.0, 1.0, 0.0, 1.0); return out; }
'''


def refl(stage, **more): return {'chain': CHAIN, 'route': 'B', 'bindings': [], 'vertex_inputs': [], 'entry': 'main0', 'stage': stage, **more}


def metallib(src, work):
    (work / 'k.metal').write_text(src)
    subprocess.run(['xcrun', '-sdk', 'macosx', 'metal', '-c', str(work / 'k.metal'), '-o', str(work / 'k.air')], check=True, capture_output=True)
    subprocess.run(['xcrun', '-sdk', 'macosx', 'metallib', str(work / 'k.air'), '-o', str(work / 'k.lib')], check=True, capture_output=True)
    return (work / 'k.lib').read_bytes()


def library(root, real=False):
    """A library b-<chain>.img, a shader map and the used lists under root. real: Mac libraries compiled from VERTEX / FRAGMENT / SIDE (else stand-in bytes). → dict of paths"""
    root = Path(root); root.mkdir(parents=True, exist_ok=True)
    work = root / 'w'; work.mkdir()
    if real: v, f, s = metallib(VERTEX, work), metallib(FRAGMENT, work), metallib(SIDE, work)
    else: v, f, s = (bytes([i]) * (3000 + 97 * i) + b'MTLB' * 50 for i in (1, 2, 3))
    stages = {'v_used': 'vertex', 'f_used': 'pixel', 'v_src': 'vertex', 'f_src': 'pixel', 'v_src2': 'vertex', 'f_src2': 'pixel', 'f_bad': 'pixel', 'c_unused': 'compute',
              'v_nolib': 'vertex', 'v_mesh': 'vertex', 'f_seen': 'pixel', 'v_task': 'vertex'}
    files = {'inputs.tsv': b'game\t0100152000022000\ninputs\tfeedface\n', '_bp_left_out_not': b'a marker'}
    for name, st in stages.items():
        k = K[name]
        if name == 'v_nolib': files[f'{k}_b.json'] = json.dumps(refl('vs')).encode(); continue   # a reflection without a library: stays as it is
        r = refl({'vertex': 'vs', 'pixel': 'ps', 'compute': 'cs'}[st])
        if name == 'v_src': r['pull'] = {'entry': 'main0', 'slot': 20}; files[f'{k}_bp.metallib'] = v
        if name == 'f_src': r['alpha'] = {'entries': ['main0_a']}; files[f'{k}_bx.metallib'] = s; files[f'{k}_bf.metallib'] = s
        files[f'{k}_b.json'] = json.dumps(r).encode()
        files[f'{k}_b.metallib'] = v if st == 'vertex' else f if st == 'pixel' else b'compute-library' * 30
    files[f'{K["v_mesh"]}_{K["v_src"]}_m3.metallib'] = v   # a pair library: never a shader's own file
    paths = {'lib': str(root / f'b-{CHAIN}.img'), 'map': str(root / 'shader_map.tsv'), 'used': str(root / 'pso_manifest.tsv'), 'seen': str(root / 'shader_seen.tsv')}
    shader_lib.write(files, paths['lib'])
    rows = ['# kind: evidence  fixture', 'package\tindex\tstage\tdm_ctl_sha16\tsource'] + [f'pkg\t{i}\t{st}\t{K[n]}\tfixture' for i, (n, st) in enumerate(stages.items())]
    Path(paths['map']).write_text('\n'.join(rows) + '\n')
    skey = (K['v_used'] + '_b').encode().ljust(24, b'\0') + (K['f_used'] + '_b').encode().ljust(24, b'\0') + b'\1' * 20
    mesh = (K['v_mesh'] + '_b').encode().ljust(24, b'\0') + b'\0' * 24 + b'\2' * 20
    Path(paths['used']).write_text(f'# a prewarm list\nS\t{K["v_used"]}_b\t0\nC\t{K["c_unused"]}_b\nR\t{skey.hex()}\nM\t{K["v_task"]}_b\t{mesh.hex()}\nX\t{K["v_src"]}\n')
    Path(paths['seen']).write_text(f'# the playtests\n{K["f_seen"]}\tpixel\n')
    shutil.rmtree(work)
    return paths


@unittest.skipUnless(T.zstd, 'needs Python 3.14 (compression.zstd)')
class Split(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(); cls.root = Path(cls.tmp.name)
        cls.fx = library(cls.root / 'fx')
        cls.out = cls.root / 'out'
        cls.report = T.split(cls.fx['lib'], cls.fx['map'], [cls.fx['used'], cls.fx['seen'], str(cls.root / 'missing.tsv')], str(cls.out), level=3, jobs=2, say=lambda *_: None)
        cls.img = str(cls.out / f'b-{CHAIN}.img')
        cls.names = {p.name for p in romfs.Path(cls.img).iterdir()}
        cls.src = {p.name: p.read_bytes() for p in romfs.Path(cls.fx['lib']).iterdir()}

    @classmethod
    def tearDownClass(cls): cls.tmp.cleanup()

    def test_used_lists(self):
        keys, rows = T.read_used([self.fx['used'], self.fx['seen']])
        self.assertEqual(keys, {K['v_used'], K['f_used'], K['c_unused'], K['v_task'], K['v_mesh'], K['f_seen']})   # S, C, both keys of R, the task and mesh keys of M, key-only lines; X rows name nothing
        self.assertEqual((rows['S'], rows['C'], rows['R'], rows['M'], rows['key']), (1, 1, 2, 2, 1))

    def test_what_is_packed(self):
        _, idx = T.read_index(self.img)
        self.assertEqual(set(idx), {K[n] for n in ('v_src', 'f_src', 'v_src2', 'f_src2', 'f_bad')})
        self.assertEqual(idx[K['v_src']], ('vertex', [K['v_src'] + s for s in ('_b.json', '_b.metallib', '_bp.metallib')]))
        self.assertEqual(idx[K['f_src']][1], [K['f_src'] + s for s in ('_b.json', '_b.metallib', '_bf.metallib', '_bx.metallib')])
        self.assertEqual(self.report['packed'], 5)

    def test_packed_files_are_gone_and_come_back_byte_for_byte(self):
        _, idx = T.read_index(self.img)
        for k, (_, files) in idx.items():
            self.assertIn(k + T.SUFFIX, self.names)
            for n in files: self.assertNotIn(n, self.names)
            self.assertEqual(T.extract(self.img, k), [(n, self.src[n]) for n in files])

    def test_what_stays_as_it_is(self):
        for n in self.src:
            m = T.FILE_OF.fullmatch(n)
            if m and m.group(1) in {K[x] for x in ('v_src', 'f_src', 'v_src2', 'f_src2', 'f_bad')}: continue
            self.assertEqual((romfs.Path(self.img) / n).read_bytes(), self.src[n], n)   # used shaders, compute, a reflection without a library, the pair library, the stamp and markers

    def test_index_and_dictionary(self):
        lines = (romfs.Path(self.img) / T.INDEX).read_text().splitlines()
        self.assertTrue(lines[0].startswith(T.INDEX_HEAD + '\t'))
        self.assertEqual(lines[0].split('\t')[1], self.report['id'])
        d = (romfs.Path(self.img) / T.DICT).read_bytes()   # five shaders are too few to train a dictionary on: their own bytes, as a raw content dictionary
        self.assertTrue(d and not d.startswith(T.DICT_MAGIC))

    def test_check_passes_and_finds_damage(self):
        self.assertEqual(T.check(self.img, say=lambda *_: None), [])
        files = {p.name: p.read_bytes() for p in romfs.Path(self.img).iterdir()}
        bad = dict(files); fr = bytearray(bad[K['f_src'] + T.SUFFIX]); fr[len(fr) // 2] ^= 0xff; bad[K['f_src'] + T.SUFFIX] = bytes(fr)
        del bad[K['v_src2'] + T.SUFFIX]
        broken = str(self.root / 'broken.img'); shader_lib.write(bad, broken)
        problems = T.check(broken, say=lambda *_: None)
        self.assertTrue(any(K['f_src'] in p for p in problems), problems)
        self.assertTrue(any(K['v_src2'] in p and 'no ' in p for p in problems), problems)

    def test_the_id_follows_the_content(self):
        again = T.split(self.fx['lib'], self.fx['map'], [self.fx['used'], self.fx['seen']], str(self.root / 'again'), level=3, jobs=1, say=lambda *_: None)
        self.assertEqual(again['id'], self.report['id'])
        fewer = T.split(self.fx['lib'], self.fx['map'], [self.fx['used'], self.fx['seen'], self.write_list('S\t' + K['f_src2'] + '_b\t1\n')], str(self.root / 'fewer'), level=3, jobs=1, say=lambda *_: None)
        self.assertNotEqual(fewer['id'], self.report['id']); self.assertEqual(fewer['packed'], 4)

    def write_list(self, text):
        p = self.root / f'list{len(text)}.tsv'; p.write_text(text); return str(p)

    def test_nothing_to_pack_leaves_the_library_as_it_was(self):
        every = self.write_list(''.join(f'S\t{k}_b\t0\n' for k in K.values()))
        rep = T.split(self.fx['lib'], self.fx['map'], [every], str(self.root / 'all'), level=3, jobs=1, say=lambda *_: None)
        self.assertEqual(rep['packed'], 0)
        img = romfs.Path(str(self.root / 'all' / f'b-{CHAIN}.img'))
        self.assertEqual({p.name: p.read_bytes() for p in img.iterdir()}, self.src)

    def test_the_trimmed_image_survives_shader_lib_subset(self):
        sub = self.root / 'sub.img'
        shader_lib.subset(str(self.out / f'b-{CHAIN}'), sub, ('_bp.metallib',))   # pack_ipa.py with IOS_PULL=0
        names = {p.name for p in romfs.Path(str(sub)).iterdir()}
        self.assertIn(K['v_src'] + T.SUFFIX, names); self.assertIn(T.INDEX, names)

    def test_count(self):
        self.assertEqual(len(T.read_used([self.fx['used'], self.fx['seen']])[0]), 6)


def fixture(out):
    """The host test's library (t_shader_trim.m): out/msl/b-<chain>.img with v_src, f_src, v_src2, f_src2 and f_bad packed (f_bad's frame damaged), out/shader_map.tsv, out/keys.tsv"""
    out = Path(out); out.mkdir(parents=True, exist_ok=True)
    fx = library(out / 'src', real=True)
    T.split(fx['lib'], fx['map'], [fx['used'], fx['seen']], str(out / 'msl'), level=3, jobs=2, say=lambda *_: None)
    img = out / 'msl' / f'b-{CHAIN}.img'
    files = {p.name: p.read_bytes() for p in romfs.Path(str(img)).iterdir()}
    fr = bytearray(files[K['f_bad'] + T.SUFFIX]); fr[len(fr) // 2] ^= 0xff; files[K['f_bad'] + T.SUFFIX] = bytes(fr)
    os.unlink(img); shader_lib.write(files, str(img))
    shutil.copy(fx['map'], out / 'shader_map.tsv')
    (out / 'keys.tsv').write_text(''.join(f'{n}\t{k}\n' for n, k in K.items()))
    shutil.rmtree(out / 'src')


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == '--fixture': fixture(sys.argv[2])
    else: unittest.main()
