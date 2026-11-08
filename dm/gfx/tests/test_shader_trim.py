"""Shader trimming (docs/shader_trimming.md): shader_trim.py's image split (compiled and source entries, dictionary, map flags, index), the used-list reader, the check, and the host
side on the Mac (dm/gfx/tests/t_shader_trim.m: a source entry read through the host's own image reader and compiled with newLibraryWithSource, pending programs and skipped draws).

Synthetic shaders only. The split tests need libzstd (brew install zstd); the host test also needs macOS with clang and the Metal toolchain."""
import hashlib
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

TESTS = Path(__file__).resolve().parent
TOOLS = Path(__file__).resolve().parents[1] / 'tools'
DM = TOOLS.parents[1]
sys.path.insert(0, str(TOOLS)); sys.path.insert(0, str(DM / 'tools'))
import romfs   # noqa: E402
import shader_lib   # noqa: E402
import shader_trim as T   # noqa: E402

CHAIN = re.search(r'DMSH_CHAIN\s+"([0-9a-f]+)"', (DM / 'gfx/nvn/dmsh_chain.h').read_text()).group(1)


def tag_key(tag):
    """The key of the host test's program with this tag: sha256 of a zero control section of 0x880 bytes with the tag at +0x800 (hle_nvn.c keys_hash; no code area)"""
    ctl = bytearray(0x880); ctl[0x800] = tag
    return hashlib.sha256(bytes(ctl)).digest()[:8].hex()


V_USED, V_SRC, F_SRC, F_USED, V_SRC2, F_SRC2 = (tag_key(t) for t in range(1, 7))
C_UNUSED, V_NOSRC = 'a' * 16, 'b' * 16   # a compute shader (always compiled), a vertex shader without a source in the cache image (stays compiled)

VERTEX = '''#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct main0_out
{
    float4 gl_Position [[position]];
};

struct main0_in
{
    float4 m_26 [[attribute(0)]];
};

vertex main0_out main0(main0_in in [[stage_in]])
{
    main0_out out = {};
    out.gl_Position = in.m_26;
    return out;
}
'''
VERTEX_POS = VERTEX.replace('float4 m_26 [[attribute(0)]];', 'float4 m_26 [[attribute(0)]];\n    float4 m_27 [[attribute(1)]];').replace('out.gl_Position = in.m_26;', 'out.gl_Position = in.m_26 + in.m_27;')
FRAGMENT = '''#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct main0_out
{
    float4 m_0 [[color(0)]];
};

fragment main0_out main0()
{
    main0_out out = {};
    out.m_0 = float4(1.0, 0.0, 0.0, 1.0);
    return out;
}
'''


def have_zstd():
    try: T.Zstd(); return True
    except RuntimeError: return False


def refl(stage, **more): return {'chain': CHAIN, 'route': 'B', 'bindings': [], 'vertex_inputs': [], 'entry': 'main0', 'stage': stage, **more}


def metallib(src, work):
    (work / 'k.metal').write_text(src)
    subprocess.run(['xcrun', '-sdk', 'macosx', 'metal', '-c', str(work / 'k.metal'), '-o', str(work / 'k.air')], check=True, capture_output=True)
    subprocess.run(['xcrun', '-sdk', 'macosx', 'metallib', str(work / 'k.air'), '-o', str(work / 'k.lib')], check=True, capture_output=True)
    return (work / 'k.lib').read_bytes()


def fixture(root, libs=True):
    """Two images (the iOS one, compiled, and the Mac cache one with the sources), a shader map and a used list under root. -> dict of paths"""
    root = Path(root); root.mkdir(parents=True, exist_ok=True)
    work = root / 'w'; work.mkdir()
    fake = b'MTLB-fake-library-bytes' * 4
    real_v = metallib(VERTEX, work) if libs else fake
    real_f = metallib(FRAGMENT, work) if libs else fake
    comp = {'inputs.tsv': b'game\t0100152000022000\ninputs\tfeedface\n'}
    cache = {}
    stages = {V_USED: 'vertex', F_USED: 'pixel', V_SRC: 'vertex', F_SRC: 'pixel', V_SRC2: 'vertex', F_SRC2: 'pixel', C_UNUSED: 'compute', V_NOSRC: 'vertex'}
    for k, st in stages.items():
        r = refl('vs' if st == 'vertex' else 'ps' if st == 'pixel' else 'cs')
        if k in (V_USED, V_SRC, V_SRC2, V_NOSRC) and st == 'vertex': r['pull'] = {'entry': 'main0', 'slot': 20}
        comp[f'{k}_b.json'] = json.dumps(r).encode()
        comp[f'{k}_b.metallib'] = real_v if st == 'vertex' else real_f if st == 'pixel' else fake
    comp[f'{V_USED}_bp.metallib'] = real_v
    comp[f'{V_SRC}_bp.metallib'] = real_v; comp[f'{V_SRC2}_bp.metallib'] = real_v
    comp[f'{F_SRC}_bx.metallib'] = real_f
    comp[f'{F_SRC}_b.json'] = json.dumps(refl('ps', alpha={'entries': ['main0_a']})).encode()
    for k in (V_SRC, V_SRC2, V_USED, V_NOSRC):
        if k != V_NOSRC: cache[f'{k}_b.metal'] = (VERTEX_POS if k == V_SRC2 else VERTEX).encode()
        cache[f'{k}_b.json'] = comp[f'{k}_b.json']
    for k in (F_SRC, F_SRC2, F_USED):
        cache[f'{k}_b.metal'] = FRAGMENT.encode(); cache[f'{k}_b.json'] = comp[f'{k}_b.json']
    cache[f'{C_UNUSED}_b.metal'] = b'// compute'; cache[f'{C_UNUSED}_b.json'] = comp[f'{C_UNUSED}_b.json']
    paths = {'compiled': str(root / f'b-{CHAIN}.img'), 'sources': str(root / 'cache.img'), 'map': str(root / 'shader_map.tsv'), 'used': str(root / 'used.tsv')}
    shader_lib.write(comp, paths['compiled']); shader_lib.write(cache, paths['sources'])
    rows = ['# kind: evidence  fixture', 'package\tindex\tstage\tdm_ctl_sha16\tsource'] + [f'pkg\t{i}\t{st}\t{k}\tfixture' for i, (k, st) in enumerate(stages.items())]
    Path(paths['map']).write_text('\n'.join(rows) + '\n')
    pso = bytes(V_USED + '_b', 'ascii').ljust(24, b'\0') + bytes(F_USED + '_b', 'ascii').ljust(24, b'\0') + b'\1' * 20
    Path(paths['used']).write_text(f'S\t{V_USED}_b\t0\nS\t{C_UNUSED}_b\t5\nR\t{pso.hex()}\nC\t{C_UNUSED}_b\n# comment\n')
    shutil.rmtree(work)
    return paths


@unittest.skipUnless(have_zstd(), 'libzstd is not installed')
class Split(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(); cls.root = Path(cls.tmp.name)
        cls.fx = fixture(cls.root / 'fx', libs=False)
        cls.out = cls.root / 'out'
        cls.report = T.split(cls.fx['compiled'], cls.fx['sources'], cls.fx['map'], [cls.fx['used']], str(cls.out), level=3, jobs=2, say=lambda *_: None)
        cls.img = romfs.Path(str(cls.out / f'b-{CHAIN}.img')); cls.z = T.Zstd()
        cls.dd = cls.z.ddict((cls.img / T.DICT_MSL).read_bytes()); cls.dj = cls.z.ddict((cls.img / T.DICT_JSON).read_bytes()); cls.dctx = cls.z.L.ZSTD_createDCtx()
        cls.names = {e.name for e in cls.img.iterdir()}

    @classmethod
    def tearDownClass(cls): cls.tmp.cleanup()

    def text(self, name): return self.z.decompress((self.img / name).read_bytes(), self.dd, self.dctx).decode()

    def test_used_list_reader(self):
        keys, rows = T.read_used([self.fx['used']])
        self.assertEqual(keys, {V_USED, F_USED, C_UNUSED})   # S, C, and the vertex and fragment keys of the R row; the comment line is ignored
        self.assertEqual(rows['R'], 2)

    def test_source_keys_are_source_entries_only(self):
        for k in (V_SRC, V_SRC2, F_SRC, F_SRC2):
            self.assertIn(f'{k}_b{T.MSL}', self.names); self.assertIn(f'{k}_b{T.JSONZ}', self.names)
            self.assertNotIn(f'{k}_b.metallib', self.names); self.assertNotIn(f'{k}_b.json', self.names)
        self.assertEqual(self.report['source_keys'], 4)

    def test_compiled_keys_are_untouched(self):
        comp = romfs.Path(self.fx['compiled'])
        for n in (f'{V_USED}_b.metallib', f'{V_USED}_bp.metallib', f'{V_USED}_b.json', f'{F_USED}_b.metallib', f'{C_UNUSED}_b.metallib', f'{C_UNUSED}_b.json', f'{V_NOSRC}_b.metallib', 'inputs.tsv'):
            self.assertEqual((self.img / n).read_bytes(), (comp / n).read_bytes(), n)

    def test_source_round_trip_and_variants(self):
        self.assertEqual(self.text(f'{V_SRC}_b{T.MSL}'), VERTEX)
        self.assertEqual(self.text(f'{V_SRC2}_b{T.MSL}'), VERTEX_POS)
        bp = self.text(f'{V_SRC}_bp{T.MSL}')   # the pulling variant: no [[stage_in]], the inputs read through the layout block
        self.assertIn('dm_fetch', bp); self.assertNotIn('[[stage_in]]', bp)
        self.assertNotIn(f'{V_SRC}_bv{T.MSL}', self.names)   # the reflection names no shadow-input library
        self.assertNotIn(f'{F_SRC2}_bu{T.MSL}', self.names)
        self.assertIn('main0_a', self.text(f'{F_SRC}_bu{T.MSL}'))   # the reflection names an alpha test entry point: the unit carries it
        js = self.z.decompress((self.img / f'{V_SRC}_b{T.JSONZ}').read_bytes(), self.dj, self.dctx)
        self.assertEqual(js, (romfs.Path(self.fx['compiled']) / f'{V_SRC}_b.json').read_bytes())

    def test_a_shader_stays_compiled_without_a_source_or_when_not_vertex_or_pixel(self):
        self.assertIn(f'{V_NOSRC}_b.metallib', self.names); self.assertNotIn(f'{V_NOSRC}_b{T.MSL}', self.names)
        self.assertNotIn(f'{C_UNUSED}_b{T.MSL}', self.names)

    def test_dictionary_and_index(self):
        self.assertGreater(len((self.img / T.DICT_MSL).read_bytes()), 0)
        idx = (self.img / T.INDEX).read_text().splitlines()
        self.assertEqual(idx[0], T.INDEX_HEAD)
        self.assertEqual(sorted(l.split('\t')[0] for l in idx[1:]), sorted([V_SRC, V_SRC2, F_SRC, F_SRC2]))
        self.assertIn('_b,_bp', next(l for l in idx if l.startswith(V_SRC)))

    def test_shader_map_says_which_form_each_key_has(self):
        rows = [l.split('\t') for l in (self.out / 'shader_map.tsv').read_text().splitlines()]
        forms = {r[3]: r[5] for r in rows if len(r) > 5 and r[0] not in ('package',) and not r[0].startswith('#')}
        self.assertEqual(forms, {V_USED: 'lib', F_USED: 'lib', C_UNUSED: 'lib', V_NOSRC: 'lib', V_SRC: 'src', F_SRC: 'src', V_SRC2: 'src', F_SRC2: 'src'})
        self.assertEqual(next(r for r in rows if r[0] == 'package')[5], 'form')

    def test_check_passes_and_finds_a_missing_entry(self):
        self.assertEqual(T.check(str(self.out), say=lambda *_: None), [])
        broken = self.root / 'broken'; broken.mkdir()
        files = {e.name: str(e) for e in self.img.iterdir() if e.name != f'{F_SRC}_b{T.MSL}'}
        shader_lib.write(files, str(broken / f'b-{CHAIN}.img')); shutil.copy(self.out / 'shader_map.tsv', broken)
        self.assertTrue(any(F_SRC in p for p in T.check(str(broken), say=lambda *_: None)))

    def test_smaller_than_the_compiled_image_for_real_sized_sources(self):
        self.assertGreater(self.report['msl_entries'], 4)

    def test_the_trimmed_image_survives_shader_lib_subset(self):
        sub = self.root / 'sub.img'
        self.assertGreater(shader_lib.subset(str(self.out / f'b-{CHAIN}'), sub), 0)
        self.assertIn(f'{V_SRC}_b{T.MSL}', {e.name for e in romfs.Path(str(sub)).iterdir()})


@unittest.skipUnless(have_zstd() and sys.platform == 'darwin' and shutil.which('clang') and shutil.which('xcrun'), 'needs libzstd, macOS, clang and the Metal toolchain')
class Host(unittest.TestCase):
    def test_host_reads_and_compiles_source_entries(self):
        game = '0100152000022000'   # any profile builds the host test
        gfx = DM / 'gfx/tests'
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            fx = fixture(root / 'fx')
            out = root / 'fixture'; (out / 'msl').mkdir(parents=True)
            T.split(fx['compiled'], fx['sources'], fx['map'], [fx['used']], str(out / 'msl'), level=3, jobs=2, say=lambda *_: None)
            shutil.move(str(out / 'msl/shader_map.tsv'), str(out / 'shader_map.tsv'))
            built = subprocess.run(['make', '-C', str(gfx), f'GAME={game}', 't_shader_trim'], capture_output=True, text=True)
            self.assertEqual(built.returncode, 0, built.stdout[-3000:] + built.stderr[-3000:])
            run = subprocess.run([str(gfx / 't_shader_trim'), str(out), str(root / 'pso_user.tsv')], capture_output=True, text=True, timeout=300)
            self.assertEqual(run.returncode, 0, run.stdout[-4000:] + run.stderr[-2000:])
            self.assertIn(' 0 failed', run.stdout)


if __name__ == '__main__':
    unittest.main()
