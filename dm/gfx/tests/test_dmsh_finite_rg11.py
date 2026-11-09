"""dmsh_build.py finite_rg11 on synthetic MSL in the translator's shapes: before each `return out;` of main0 (or its dm_body_main0) every float / half colour output n is made
`if (dm_nf_mask & <1 << n>u) out.<member> = dm_nf_fix(out.<member>);`, the declarations come once after `using namespace metal;`, integer outputs are left alone, and a source with no such
output or already rewritten stays as it is. dm_nf_mask is the function constant dm_nf_fc (DMSH_FINITE_FC), 0 unless the pipeline sets it, so no other pipeline's code changes. The rewritten
source compiles where xcrun is. With --fixture <dir>, writes the rewritten shader (a division by 0 and a 0 / 0 written to a colour output) as finite.metal for t_finite_rg11.m
(make check_t_finite_rg11), which draws it into an R11G11B10F target with the constant set and unset."""
import ast
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
import dmsh_side  # noqa: E402


def load():
    tree = ast.parse((TOOLS / 'dmsh_build.py').read_text())
    nodes: list[ast.stmt] = [n for n in tree.body if (isinstance(n, ast.FunctionDef) and n.name in ('finite_rg11', 'block_end'))
                             or (isinstance(n, ast.Assign) and any(getattr(t, 'id', None) in ('FINITE_DECL', 'BRACE') for t in n.targets))]
    ns = {'re': re, 'dmsh_side': dmsh_side, 'abi': dmsh_abi}
    exec(compile(ast.Module(body=nodes, type_ignores=[]), str(TOOLS / 'dmsh_build.py'), 'exec'), ns)
    return ns


NS = load()
HEAD = '''#include <metal_stdlib>
using namespace metal;

struct main0_out
{
    float4 m_16 [[color(0)]];
    half4 m_17 [[color(1)]];
    uint4 m_18 [[color(2)]];
    float4 m_19 [[color(3)]];
};
'''
# A mist-like tail: a division by a weight sum of exactly 0 (Ocarina of Time's 5ad65c0eefd09c7f, issue #1839), an early return, and a NaN read from the buffer
SHADER = HEAD + '''
fragment main0_out main0(constant float4* c [[buffer(0)]])
{
    main0_out out = {};
    float _633 = c[0].x;
    if (c[0].w > 0.5)
    {
        out.m_16 = float4(1.0);
        return out;
    }
    float _727 = 1.0 / _633;
    out.m_16 = float4(_727, c[0].y, 2.0, 1.0);
    out.m_17 = half4(half(_727));
    out.m_18 = uint4(1u);
    out.m_19 = float4(_727);
    return out;
}
'''
_UNUSED = HEAD + '''
static __attribute__((always_inline)) main0_out dm_body_main0(constant float4* c)
{
    main0_out out = {};
    out.m_16 = float4(c[0].x);
    return out;
}

fragment main0_out main0(constant float4* c [[buffer(0)]])
{
    main0_out out = dm_body_main0(c);
    return out;
}
'''


class FiniteRg11(unittest.TestCase):
    def test_every_return_and_float_output(self):
        out = NS['finite_rg11'](SHADER)
        self.assertEqual(out.count('using namespace metal;'), 1)
        self.assertEqual(out.count('dm_nf_fix(float4 v)'), 1)
        self.assertIn(f'function_constant({dmsh_abi.FINITE_FC})', out)
        for m, n in (('m_16', 1), ('m_17', 2), ('m_19', 8)):
            self.assertEqual(out.count(f'if (dm_nf_mask & {n}u) out.{m} = dm_nf_fix(out.{m});'), 2, m)   # the early return and the last
        self.assertNotIn('out.m_18 = dm_nf_fix', out)
        self.assertEqual(out.count('        return out;'), 1)
        self.assertEqual(out.count('    return out;'), 2)
        self.assertEqual(out.count('return out;'), 2)   # the returns themselves stay as they were, for the passes that read them
        self.assertTrue(out.rstrip().endswith('}'))

    def test_the_shared_body_takes_it_along(self):
        # finite_rg11 runs on the source with only main0; dmsh_side.shared_body then moves main0's body to dm_body_main0 (fs_uint, fs_dual, the alpha / logic / fetch units), rewrite included
        shared = dmsh_side.shared_body(NS['finite_rg11'](SHADER))
        self.assertTrue(shared)
        self.assertIn('if (dm_nf_mask & 1u) out.m_16 = dm_nf_fix(out.m_16);', shared)
        self.assertEqual(shared.count('dm_nf_fix(float4 v)'), 1)

    def test_left_alone(self):
        ints = HEAD.replace('float4 m_16', 'uint4 m_16').replace('half4 m_17', 'uint4 m_17').replace('float4 m_19', 'uint4 m_19')
        cases = {'integer outputs': ints + SHADER[len(HEAD):], 'no return out': SHADER.replace('return out;', 'return main0_out{};'),
                 'no main0': HEAD, 'a vertex shader': SHADER.replace('fragment main0_out main0', 'vertex main0_out main0')}
        for why, msl in cases.items():
            with self.subTest(why):
                self.assertEqual(NS['finite_rg11'](msl), msl)
        once = NS['finite_rg11'](SHADER)
        self.assertEqual(NS['finite_rg11'](once), once)

    @unittest.skipUnless(shutil.which('xcrun'), 'needs xcrun')
    def test_compiles(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / 's.metal'; p.write_text(NS['finite_rg11'](SHADER))
            r = subprocess.run(['xcrun', '-sdk', 'macosx', 'metal', '-c', '-O1', '-fwrapv', str(p), '-o', str(Path(d) / 's.air')], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stderr)


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == '--fixture':
        Path(sys.argv[2], 'finite.metal').write_text(NS['finite_rg11'](SHADER).replace('#include <metal_stdlib>\n', '', 1))
        del sys.argv[1:]
    unittest.main()
