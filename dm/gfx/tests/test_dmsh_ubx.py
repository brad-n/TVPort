"""dmsh_build.py ub_fixed on synthetic MSL in the translator's shapes (a pixel and a vertex shader) (TranslationFlags.MetalUniformBounds, upstream 26062f9e): each test of a fixed word w of a game uniform slot,
(w < (size >> 2)) with the size from the table of bank DMSH_CBSIZE_BANK, becomes (dmsh_ubx || test), dmsh_ubx the function constant DMSH_UBX_FC (false unless a pipeline sets it), the
declarations come once after `using namespace metal;`, and the needs are 4 (w + 1) bytes for the highest w of each slot. A test of a computed word stays as it is, a source without a
fixed test or already rewritten stays as it is, and dmsh_fetch.unguard reads both forms alike (the analyses that look for a uniform word). The rewritten source compiles where xcrun is.
With --fixture <dir>, writes the rewritten shader as ubx.metal and its needs as ubx.json for t_ubx.m (make check_t_ubx), which proves on the GPU that the shader with DMSH_UBX_FC true
writes the same words as with it unset wherever the host picks it (nvn_mtl.m ubx_want), and that a slot bound shorter than a fixed read reads 0 there with the tests the host keeps."""
import ast
import json
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
import dmsh_abi   # noqa: E402
import dmsh_fetch  # noqa: E402


def load():
    tree = ast.parse((TOOLS / 'dmsh_build.py').read_text())
    nodes: list[ast.stmt] = [n for n in tree.body if (isinstance(n, ast.FunctionDef) and n.name == 'ub_fixed')
                             or (isinstance(n, ast.Assign) and any(getattr(t, 'id', None) in ('UB_TEST', 'UBX_DECL') for t in n.targets))]
    ns = {'re': re, 'abi': dmsh_abi}
    exec(compile(ast.Module(body=nodes, type_ignores=[]), str(TOOLS / 'dmsh_build.py'), 'exec'), ns)
    return ns


NS = load()
ub_fixed = NS['ub_fixed']
BANK = dmsh_abi.CBSIZE_BANK


def test(w, row, comp):   # the translator's test of fixed word w against the size of the slot at the table's row / component, as SPIRV-Cross prints it
    return '(%du < ((*spvDescriptorSet0.fp_c%d)._m0[%d].%s >> 2u))' % (w, BANK, row, comp)


def read(slot, w, kind='float', pre='fp'):   # a guarded read of word w of uniform slot c[slot] (its table entry slot - 3), as the translator writes a fixed-offset one
    i = slot - 3
    zero = {'float': '0.0', 'uint': '0u', 'int': '0'}[kind]
    member = '(*spvDescriptorSet0.%s_c%d)._m0[%d].%s' % (pre, slot, w // 4, 'xyzw'[w % 4])
    return '(%s ? %s : %s)' % (test(w, i // 4, 'xyzw'[i % 4]).replace('fp_c', pre + '_c'), member, zero)


# A pixel shader in the translator's shape: c[3] read at words 5, 17, 63 and 1023 (row 255 .w), c[4] at words 0 and 6, and c[3] at a computed word (its own test, and row 0 when out of
# bounds), every value written as its bits to two RGBA32Uint outputs
SHADER = '''#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _16
{
    float4 _m0[4096];
};

struct _23
{
    uint4 _m0[4];
};

struct spvDescriptorSetBuffer0
{
    constant _16* fp_c3 [[id(0)]];
    constant _23* fp_c%(bank)d [[id(1)]];
    constant _16* fp_c4 [[id(2)]];
};

struct main0_out
{
    uint4 m_0 [[color(0)]];
    uint4 m_1 [[color(1)]];
};

fragment main0_out main0(constant spvDescriptorSetBuffer0& spvDescriptorSet0 [[buffer(0)]], float4 gl_FragCoord [[position]])
{
    main0_out out = {};
    float _10 = %(r5)s;
    float _11 = %(r17)s * 1.0;
    uint _12 = as_type<uint>(%(r63)s);
    float _13 = fma(%(r1023)s, 1.0, 0.0);
    int _14 = as_type<int>(%(c0)s);
    float _15 = %(c6)s;
    int _3 = int(uint(gl_FragCoord.y)) + 2;
    int _4 = int(uint(gl_FragCoord.x) & 3u);
    bool _5 = ((uint(_3) << 2u) | uint(_4)) < ((*spvDescriptorSet0.fp_c%(bank)d)._m0[0].x >> 2u);
    float _6 = _5 ? (*spvDescriptorSet0.fp_c3)._m0[_5 ? _3 : 0][_4] : 0.0;
    out.m_0 = uint4(as_type<uint>(_10), as_type<uint>(_11), _12, as_type<uint>(_13));
    out.m_1 = uint4(uint(_14), as_type<uint>(_15), as_type<uint>(_6), 4660u);
    return out;
}
''' % {'bank': BANK, 'r5': read(3, 5), 'r17': read(3, 17), 'r63': read(3, 63), 'r1023': read(3, 1023), 'c0': read(4, 0), 'c6': read(4, 6)}


# The same reads in a vertex shader (vp_ names), every value as its bits in two flat outputs; the computed word is 4 (instance + 2) + 1
VS_SHADER = SHADER.split('struct main0_out')[0].replace('fp_c', 'vp_c') + """struct main0_out
{
    uint4 m_0 [[user(locn0)]];
    uint4 m_1 [[user(locn1)]];
    float4 gl_Position [[position]];
};

vertex main0_out main0(constant spvDescriptorSetBuffer0& spvDescriptorSet0 [[buffer(0)]], uint gl_VertexIndex [[vertex_id]], uint gl_InstanceIndex [[instance_id]])
{
    main0_out out = {};
    float _10 = %(r5)s;
    float _11 = %(r17)s * 1.0;
    uint _12 = as_type<uint>(%(r63)s);
    float _13 = fma(%(r1023)s, 1.0, 0.0);
    int _14 = as_type<int>(%(c0)s);
    float _15 = %(c6)s;
    int _3 = int(gl_InstanceIndex) + 2;
    int _4 = 1;
    bool _5 = ((uint(_3) << 2u) | uint(_4)) < ((*spvDescriptorSet0.vp_c%(bank)d)._m0[0].x >> 2u);
    float _6 = _5 ? (*spvDescriptorSet0.vp_c3)._m0[_5 ? _3 : 0][_4] : 0.0;
    out.gl_Position = float4(float(gl_VertexIndex & 1u) * 4.0 - 1.0, float(gl_VertexIndex >> 1u) * 4.0 - 1.0, 0.0, 1.0);
    out.m_0 = uint4(as_type<uint>(_10), as_type<uint>(_11), _12, as_type<uint>(_13));
    out.m_1 = uint4(uint(_14), as_type<uint>(_15), as_type<uint>(_6), 4660u);
    return out;
}
""" % {'bank': BANK, 'r5': read(3, 5, pre='vp'), 'r17': read(3, 17, pre='vp'), 'r63': read(3, 63, pre='vp'), 'r1023': read(3, 1023, pre='vp'), 'c0': read(4, 0, pre='vp'), 'c6': read(4, 6, pre='vp')}

def compile_lib(msl, d, name, sdk):
    p = d / (name + '.metal'); p.write_text(msl)
    air = d / (name + '.air')
    subprocess.run(['xcrun', '-sdk', sdk, 'metal', '-c', '-O1', '-fpreserve-invariance', '-fwrapv', str(p), '-o', str(air)], check=True, capture_output=True, text=True)
    subprocess.run(['xcrun', '-sdk', sdk, 'metallib', str(air), '-o', str(d / (name + '.metallib'))], check=True, capture_output=True, text=True)


class UbFixed(unittest.TestCase):
    def test_tests_and_needs(self):
        out, need = ub_fixed(SHADER)
        self.assertEqual(need, {0: 4 * 1024, 1: 4 * 7}, 'c[3] up to word 1023, c[4] up to word 6')
        self.assertEqual(out.count('(dmsh_ubx || ('), 6)
        self.assertIn('(dmsh_ubx || %s)' % test(1023, 0, 'x'), out)
        self.assertIn('(dmsh_ubx || %s)' % test(6, 0, 'y'), out)
        self.assertEqual(out.count(NS['UBX_DECL']), 1)
        self.assertIn('using namespace metal;\n\n' + NS['UBX_DECL'], out)
        self.assertIn('[[function_constant(%d)]]' % dmsh_abi.UBX_FC, out)

    def test_vertex_shader(self):   # the same rewrite for a vertex shader's tests (vp_ names)
        out, need = ub_fixed(VS_SHADER)
        self.assertEqual(need, {0: 4096, 1: 28})
        self.assertEqual(out.count('(dmsh_ubx || ('), 6)
        self.assertIn('bool _5 = ((uint(_3) << 2u) | uint(_4)) < ((*spvDescriptorSet0.vp_c%d)._m0[0].x >> 2u);' % BANK, out)

    def test_a_computed_word_keeps_its_test(self):
        out, _ = ub_fixed(SHADER)
        self.assertIn('bool _5 = ((uint(_3) << 2u) | uint(_4)) < ((*spvDescriptorSet0.fp_c%d)._m0[0].x >> 2u);' % BANK, out)

    def test_the_rest_unchanged(self):   # taking the rewrite out again gives the translator's source back, character for character
        out, _ = ub_fixed(SHADER)
        back = out.replace(NS['UBX_DECL'], '').replace('using namespace metal;\n\n\n', 'using namespace metal;\n\n', 1)
        self.assertEqual(re.sub(r'\(dmsh_ubx \|\| (\(\d+u < [^;]*? >> 2u\)\))\)', r'\1', back), SHADER)

    def test_unchanged_sources(self):
        plain = SHADER.split('fragment ')[0] + 'fragment main0_out main0() { main0_out out = {}; return out; }\n'
        self.assertEqual(ub_fixed(plain), (plain, {}), 'no fixed test')
        once, _ = ub_fixed(SHADER)
        self.assertEqual(ub_fixed(once), (once, {}), 'already rewritten')
        self.assertEqual(ub_fixed(SHADER.replace('using namespace metal;\n', '')), (SHADER.replace('using namespace metal;\n', ''), {}))

    def test_slots_of_every_row_and_component(self):   # slot c[3 + i] is entry i of the table: row i / 4, component i % 4
        for slot in range(3, 17):
            src = SHADER.replace('float _15 = %s;' % read(4, 6), 'float _15 = %s;' % read(slot, 41))
            with self.subTest(slot=slot): self.assertEqual(ub_fixed(src)[1].get(slot - 3), 4 * 42 if slot != 3 else 4 * 1024)

    def test_unguard_reads_both_forms_alike(self):   # frag_pos proofs, raster_facts and int_outputs look for a uniform word through dmsh_fetch.unguard
        out, _ = ub_fixed(SHADER)
        self.assertEqual(dmsh_fetch.unguard(out).replace(NS['UBX_DECL'], '').replace('using namespace metal;\n\n\n', 'using namespace metal;\n\n', 1), dmsh_fetch.unguard(SHADER))
        self.assertIn('float _10 = (*spvDescriptorSet0.fp_c3)._m0[1].y;', dmsh_fetch.unguard(out))

    @unittest.skipUnless(shutil.which('xcrun'), 'no xcrun')
    def test_compiles_on_both_platforms(self):
        out, _ = ub_fixed(SHADER)
        with tempfile.TemporaryDirectory() as d:
            for sdk in ('macosx', 'iphoneos'):
                with self.subTest(sdk=sdk):
                    try: compile_lib(out, Path(d), 'ubx_' + sdk, sdk); compile_lib(ub_fixed(VS_SHADER)[0], Path(d), 'ubx_vs_' + sdk, sdk)
                    except subprocess.CalledProcessError as e: self.fail(e.stderr)


def fixture(d):
    out, need = ub_fixed(SHADER)
    d = Path(d); d.mkdir(parents=True, exist_ok=True)
    (d / 'ubx.metal').write_text(out)
    (d / 'ubx.json').write_text(json.dumps({'ub_fixed': {str(r): n for r, n in sorted(need.items())}}))
    out, need = ub_fixed(VS_SHADER)
    (d / 'ubx_vs.metal').write_text(out)
    (d / 'ubx_vs.json').write_text(json.dumps({'ub_fixed': {str(r): n for r, n in sorted(need.items())}}))


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == '--fixture': fixture(sys.argv[2]); sys.exit(0)
    unittest.main()
