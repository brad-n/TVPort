"""Border colours Metal has no sampler state for (dmsh_rewrite.py border_emu): the rewrite of a shader's samples, the reflection of the twins and the block, the readable-tile variant
of a rewritten shader, the compile on both platforms, and with DM_TEST_BORDER (the t_border executable) the samples on the GPU."""
import ast
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

TOOLS = Path(__file__).resolve().parents[1] / 'tools'
sys.path.insert(0, str(TOOLS))
import dmsh_abi as abi   # noqa: E402
import dmsh_fetch   # noqa: E402
import dmsh_geometry   # noqa: E402

from dmsh_reflect import reflect   # noqa: E402
from dmsh_rewrite import border_emu   # noqa: E402
GAMES = Path(__file__).resolve().parents[2] / 'games'
BUILD_SRC = (TOOLS / 'dmsh_build.py').read_text()

HEAD = '#include <metal_stdlib>\n#include <simd/simd.h>\n\nusing namespace metal;\n\n'
# Tears of the Kingdom's ff9def5b3c418851 as spirv-cross writes it, cut down: a uniform segment, the bend map and its sampler
GRASS = HEAD + '''struct _16
{
    float4 _m0[4096];
};

struct spvDescriptorSetBuffer0
{
    constant _16* fp_c1 [[id(0)]];
    texture2d<float> fp_t_tcb_8 [[id(1)]];
    sampler fp_t_tcb_8Smplr [[id(2)]];
    array<texture2d<float>, 4> fp_t2d_cb14_0 [[id(3)]];
    array<sampler, 4> fp_t2d_cb14_0Smplr [[id(7)]];
};

struct main0_out
{
    float4 m_32 [[color(0)]];
};

struct main0_in
{
    float4 m_29 [[user(locn0), center_no_perspective]];
};

fragment main0_out main0(main0_in in [[stage_in]], constant spvDescriptorSetBuffer0& spvDescriptorSet0 [[buffer(0)]])
{
    main0_out out = {};
    float _39 = in.m_29.x;
    float _41 = in.m_29.y;
    float2 _182 = float2(_39, _41);
    float2 _45 = spvDescriptorSet0.fp_t_tcb_8.sample(spvDescriptorSet0.fp_t_tcb_8Smplr, select(_182, float2(0.0), isnan(_182))).xy;
    float4 _50 = spvDescriptorSet0.fp_t_tcb_8.sample(spvDescriptorSet0.fp_t_tcb_8Smplr, spvDescriptorSet0.fp_t_tcb_8.sample(spvDescriptorSet0.fp_t_tcb_8Smplr, _182, level(0.0)).xy, bias(0.5));
    float4 _51 = spvDescriptorSet0.fp_t2d_cb14_0[1].sample(spvDescriptorSet0.fp_t2d_cb14_0Smplr[1], _182);
    out.m_32 = float4(_45, _50.x + _51.y, spvDescriptorSet0.fp_c1->_m0[0].x);
    return out;
}
'''
# what t_border runs: one texture and its sampler, sampled at explicit coordinates
KERNEL = HEAD + '''struct spvDescriptorSetBuffer0
{
    texture2d<float> cp_t_tcb_8 [[id(0)]];
    sampler cp_t_tcb_8Smplr [[id(1)]];
};

kernel void main0(constant spvDescriptorSetBuffer0& spvDescriptorSet0 [[buffer(0)]], device float4* out [[buffer(1)]], constant float2* uv [[buffer(2)]], uint i [[thread_position_in_grid]])
{
    out[i] = spvDescriptorSet0.cp_t_tcb_8.sample(spvDescriptorSet0.cp_t_tcb_8Smplr, uv[i], level(0.0));
}
'''

# an integer texture beside a float one, each with its sampler, and an image with an attribute after its id (SPIRV-Cross's interlock) as the last member
INTEGER = HEAD + '''struct spvDescriptorSetBuffer0
{
    texture2d<uint> fp_t_tcb_8 [[id(0)]];
    sampler fp_t_tcb_8Smplr [[id(1)]];
    texture2d<float> fp_t_tcb_9 [[id(2)]];
    sampler fp_t_tcb_9Smplr [[id(3)]];
    texture2d<float, access::read_write> fp_i_0 [[id(4), raster_order_group(0)]];
};

struct main0_out
{
    float4 m_32 [[color(0)]];
};

fragment main0_out main0(constant spvDescriptorSetBuffer0& spvDescriptorSet0 [[buffer(0)]])
{
    main0_out out = {};
    uint4 _10 = spvDescriptorSet0.fp_t_tcb_8.sample(spvDescriptorSet0.fp_t_tcb_8Smplr, float2(0.5), level(0.0));
    float4 _11 = spvDescriptorSet0.fp_t_tcb_9.sample(spvDescriptorSet0.fp_t_tcb_9Smplr, float2(0.5));
    out.m_32 = float4(_10) + _11;
    return out;
}
'''


def members(msl):
    body = re.search(r'struct spvDescriptorSetBuffer0\s*\{(.*?)\};', msl, re.S).group(1)
    return [(m.group(1), m.group(2), int(m.group(3))) for m in re.finditer(r'^\s*(.+?)\s+(\w+)\s*\[\[id\((\d+)\)\]\];', body, re.M)]


class Rewrite(unittest.TestCase):
    def test_members_follow_every_entry(self):
        got = members(border_emu(GRASS))
        self.assertEqual(got[-2:], [('sampler', 'fp_t_tcb_8Smplr' + abi.BORDER_TWIN, 11), ('constant dm_border_t*', abi.BORDER_MEMBER, 12)],
                         'the twin and the block come after the sampler array (ids 7-10)')

    def test_samples_are_wrapped(self):
        out = border_emu(GRASS)
        self.assertIn('dm_bs(spvDescriptorSet0.fp_t_tcb_8.sample(spvDescriptorSet0.fp_t_tcb_8Smplr, select(_182, float2(0.0), isnan(_182))), spvDescriptorSet0.dm_border, 0u, '
                      'spvDescriptorSet0.fp_t_tcb_8, spvDescriptorSet0.fp_t_tcb_8Smplr_w, select(_182, float2(0.0), isnan(_182))).xy', out)
        self.assertEqual(out.count('dm_bs('), 5, 'the helper, and four samples through the scalar sampler: one, one inside another (copied into its twin sample), the outer one')
        self.assertIn('spvDescriptorSet0.fp_t2d_cb14_0[1].sample(spvDescriptorSet0.fp_t2d_cb14_0Smplr[1], _182)', out, 'a sampler array keeps its samples')
        inner = 'dm_bs(spvDescriptorSet0.fp_t_tcb_8.sample(spvDescriptorSet0.fp_t_tcb_8Smplr, _182, level(0.0)), spvDescriptorSet0.dm_border, 0u, spvDescriptorSet0.fp_t_tcb_8, spvDescriptorSet0.fp_t_tcb_8Smplr_w, _182, level(0.0))'
        self.assertEqual(out.count(inner), 2, 'the inner sample, rewritten, in both of the outer one\'s samples')

    def test_integer_textures_keep_their_samples(self):
        out = border_emu(INTEGER)
        self.assertIn('uint4 _10 = spvDescriptorSet0.fp_t_tcb_8.sample(spvDescriptorSet0.fp_t_tcb_8Smplr, float2(0.5), level(0.0));', out, 'an integer sample is not wrapped')
        self.assertNotIn('fp_t_tcb_8Smplr' + abi.BORDER_TWIN, out, 'nor its sampler twinned')
        self.assertIn('dm_bs(spvDescriptorSet0.fp_t_tcb_9.sample(', out)

    def test_members_follow_an_attributed_member(self):
        body = re.search(r'struct spvDescriptorSetBuffer0\s*\{(.*?)\};', border_emu(INTEGER), re.S).group(1)
        self.assertIn('sampler fp_t_tcb_9Smplr' + abi.BORDER_TWIN + ' [[id(5)]];', body, 'after the image at id 4, which has raster_order_group')
        self.assertIn(abi.BORDER_MEMBER + ' [[id(6)]];', body)

    def test_unchanged_without_samples(self):
        src = HEAD + 'struct spvDescriptorSetBuffer0\n{\n    texture2d<float> fp_t_tcb_8 [[id(0)]];\n};\n\nfragment void main0() {}\n'
        self.assertEqual(border_emu(src), src)

    def test_reflection(self):
        b = {e['msl_name']: e for e in reflect('k', 'ps', border_emu(GRASS), {'sbufs': []})}
        base, twin = b['fp_t_tcb_8Smplr'], b['fp_t_tcb_8Smplr' + abi.BORDER_TWIN]
        self.assertEqual((twin['kind'], twin.get('reg'), twin['border_bit'], twin['arg_id']), (base['kind'], base.get('reg'), 0, 11))
        self.assertNotIn('border_bit', base)
        self.assertEqual((b[abi.BORDER_MEMBER]['kind'], b[abi.BORDER_MEMBER]['arg_id']), (abi.KIND_BORDER, 12))

    def test_readable_tile_variant_takes_the_wrapped_sample(self):
        plain = re.sub(r'    float4 _50 = .*\n', '    float4 _50 = float4(0.0);\n', GRASS.replace(', center_no_perspective', ''))   # a plain interpolated input, one sample left
        src = border_emu(plain)
        refl = reflect('k', 'ps', src, {'sbufs': []})
        fv, meta = dmsh_fetch.fold(src, refl)
        self.assertIsNotNone(fv, meta)
        self.assertEqual(len(meta['calls']), 1)
        self.assertEqual(meta['mixed_regs'], [])
        self.assertRegex(fv, r'\(fx0 == 0 \? fb0 : [^;]*fx0 == 7 \? fb7 : dm_bs\(spvDescriptorSet0\.fp_t_tcb_8\.sample\(','a tile read replaces the corrected sample')

    @unittest.skipUnless(shutil.which('xcrun'), 'requires Metal compilers')
    def test_compiles(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name, src in (('grass', GRASS), ('kernel', KERNEL), ('integer', INTEGER)):
                msl = root / (name + '.metal'); msl.write_text(border_emu(src))
                for sdk in ('macosx', 'iphoneos'):
                    with self.subTest(shader=name, sdk=sdk):
                        r = subprocess.run(['xcrun', '-sdk', sdk, 'metal', '-c', '-fmodules-cache-path=' + str(root / sdk), str(msl), '-o', str(root / f'{name}_{sdk}.air')], capture_output=True, text=True)
                        self.assertEqual(r.returncode, 0, r.stderr)

    @unittest.skipUnless(os.environ.get('DM_TEST_BORDER'), 'set DM_TEST_BORDER to the native t_border executable')
    def test_gpu(self):
        out = border_emu(KERNEL)
        self.assertEqual([n for _, n, _ in members(out)], ['cp_t_tcb_8', 'cp_t_tcb_8Smplr', 'cp_t_tcb_8Smplr' + abi.BORDER_TWIN, abi.BORDER_MEMBER], 't_border fills these four')
        with tempfile.TemporaryDirectory(prefix='border_') as directory:
            path = Path(directory) / 'kernel.metal'; path.write_text(out)
            r = subprocess.run([os.environ['DM_TEST_BORDER'], str(path)], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)


# border_emu as it was before the profile key shader_border_emu: the first 16 digits of the sha256 of its output for these three shaders
GOLDEN = {'GRASS': '012df75c8740d7b0', 'KERNEL': 'c0297a275bef153d', 'INTEGER': '1aa0c9b68612f3d4'}
TWIN_OR_BLOCK = re.compile(r'dm_bs|dm_bmix|dm_border|' + re.escape(abi.BORDER_TWIN) + r'\b')


class KeyOn(unittest.TestCase):
    """shader_border_emu 1 (the default) is the old behaviour, byte for byte"""
    def test_output_unchanged(self):
        for name, src in (('GRASS', GRASS), ('KERNEL', KERNEL), ('INTEGER', INTEGER)):
            with self.subTest(shader=name):
                self.assertEqual(hashlib.sha256(border_emu(src).encode()).hexdigest()[:16], GOLDEN[name])
                self.assertEqual(border_emu(src, True), border_emu(src))

    def test_build_reads_the_key_with_default_one(self):
        self.assertRegex(BUILD_SRC, r"(?m)^BORDER_EMU = GAME\.get\('shader_border_emu', '1'\) == '1'")
        self.assertIn('src = dmsh_rewrite.border_emu(src, BORDER_EMU)', BUILD_SRC)


class KeyOff(unittest.TestCase):
    """shader_border_emu 0: no twin members, no block member, no dm_bs"""
    def test_source_untouched(self):
        for name, src in (('GRASS', GRASS), ('KERNEL', KERNEL), ('INTEGER', INTEGER)):
            with self.subTest(shader=name):
                out = border_emu(src, False)
                self.assertEqual(out, src)
                self.assertIsNone(TWIN_OR_BLOCK.search(out))

    def test_reflection_has_no_twin_or_block(self):
        refl = reflect('k', 'ps', border_emu(GRASS, False), {'sbufs': []})
        self.assertEqual([e['msl_name'] for e in refl if 'border_bit' in e or e.get('kind') == abi.KIND_BORDER], [])
        self.assertEqual([e['msl_name'] for e in refl], ['fp_c1', 'fp_t_tcb_8', 'fp_t_tcb_8Smplr', 'fp_t2d_cb14_0', 'fp_t2d_cb14_0Smplr'])

    def test_readable_tile_variant_without_the_wrap(self):
        plain = re.sub(r'    float4 _50 = .*\n', '    float4 _50 = float4(0.0);\n', GRASS.replace(', center_no_perspective', ''))
        src = border_emu(plain, False)
        fv, meta = dmsh_fetch.fold(src, reflect('k', 'ps', src, {'sbufs': []}))
        self.assertIsNotNone(fv, meta)
        self.assertNotIn('dm_bs', fv)

    @unittest.skipUnless(shutil.which('xcrun'), 'requires Metal compilers')
    def test_compiles(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name, src in (('grass', GRASS), ('kernel', KERNEL), ('integer', INTEGER)):
                msl = root / (name + '.metal'); msl.write_text(border_emu(src, False))
                for sdk in ('macosx', 'iphoneos'):
                    with self.subTest(shader=name, sdk=sdk):
                        r = subprocess.run(['xcrun', '-sdk', sdk, 'metal', '-c', '-fmodules-cache-path=' + str(root / sdk), str(msl), '-o', str(root / f'{name}_{sdk}.air')], capture_output=True, text=True)
                        self.assertEqual(r.returncode, 0, r.stderr)

    @unittest.skipUnless(os.environ.get('DM_TEST_BORDER'), 'set DM_TEST_BORDER to the native t_border executable')
    def test_gpu_with_a_metal_border(self):
        out = border_emu(KERNEL, False)
        self.assertEqual([n for _, n, _ in members(out)], ['cp_t_tcb_8', 'cp_t_tcb_8Smplr'], 't_border --plain fills these two')
        with tempfile.TemporaryDirectory(prefix='border_') as directory:
            path = Path(directory) / 'kernel.metal'; path.write_text(out)
            r = subprocess.run([os.environ['DM_TEST_BORDER'], '--plain', str(path)], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertIn('plain cases', r.stdout)


class Profile(unittest.TestCase):
    """the key in a game profile: validated, a define for the host, and part of what a shader library is keyed by"""
    def profile(self, root, value):
        d = root / '0400486024DEC000'
        d.mkdir(parents=True, exist_ok=True)
        rows = [l for l in (GAMES / '0400486024DEC000' / 'game.tsv').read_text().splitlines() if not l.startswith('shader_border_emu')]
        if value is not None: rows.append(f'shader_border_emu\t{value}')
        (d / 'game.tsv').write_text('\n'.join(rows) + '\n')
        return d

    def header(self, root, value):
        self.profile(root, value); h = root / 'out.h'
        env = dict(os.environ, DM_GAMES_DIR=str(root), DM_GAMES_FIRST='1')
        r = subprocess.run([sys.executable, str(GAMES / 'game.py'), 'header', '0400486024DEC000', str(h)], capture_output=True, text=True, env=env)
        return r, (h.read_text() if h.exists() else '')

    def test_define(self):
        for value, want in ((None, 1), ('1', 1), ('0', 0)):
            with self.subTest(value=value), tempfile.TemporaryDirectory() as t:
                r, text = self.header(Path(t), value)
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertIn(f'#define DM_GAME_SHADER_BORDER_EMU {want}\n', text)

    def test_bad_value_refused(self):
        with tempfile.TemporaryDirectory() as t:
            r, _ = self.header(Path(t), '2')
            self.assertNotEqual(r.returncode, 0)
            self.assertIn('shader_border_emu must be 0 or 1', r.stdout + r.stderr)

    def test_ocarina_turns_it_off(self):
        self.assertRegex((GAMES / '0400486024DEC000' / 'game.tsv').read_text(), r'(?m)^shader_border_emu\t0$')

    def test_key_changes_the_cache_keys(self):
        sys.path.insert(0, str(GAMES)); sys.path.insert(0, str(TOOLS))
        import game; import dmsh_chain
        with tempfile.TemporaryDirectory() as t:
            got = {}
            for value in ('0', '1'):
                root = Path(t) / value
                g = game.Game(self.profile(root, value)); got[value] = (dmsh_chain.profile_rows(g), dmsh_chain.inputs(g))
            self.assertNotEqual(got['0'][0], got['1'][0], 'the per-shader cache key (PROFILE_ROWS)')
            self.assertNotEqual(got['0'][1], got['1'][1], 'the library stamp (b-<V>/inputs.tsv)')


if __name__ == '__main__':
    unittest.main()
