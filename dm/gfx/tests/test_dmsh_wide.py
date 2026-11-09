"""Storage words the translator split, read whole again (dmsh_wide.py wide_loads): which words become one read, which are left alone, and the compile."""
from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from dmsh_wide import wide_loads   # noqa: E402

# Splatoon Raiders' Hoian_UBER (3e5a302ac52b73bf) as spirv-cross writes it, cut down: one light's words from fp_s3 at 80 * index + 16 .. 44, a written buffer,
# and words in two blocks
LIGHT = '''#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _29
{
    uint _m0[1];
};

struct spvDescriptorSetBuffer0
{
    const device _29* fp_s2 [[id(0)]];
    const device _29* fp_s3 [[id(1)]];
    device _29* fp_s4 [[id(2)]];
};

struct main0_out
{
    float4 m_0 [[color(0)]];
};

struct main0_in
{
    float4 m_1 [[user(locn0)]];
};

fragment main0_out main0(main0_in in [[stage_in]], constant spvDescriptorSetBuffer0& spvDescriptorSet0 [[buffer(0)]])
{
    main0_out out = {};
    int _3483 = int(in.m_1.x) * 80;
    int _3485 = _3483 + 16;
    int _3487 = _3483 + 32;
    uint _3493 = uint(int(uint(_3485) >> uint(2)));
    float _3495 = as_type<float>((*spvDescriptorSet0.fp_s3)._m0[int(_3493)]);
    uint _3499 = uint(int(uint(_3487) >> uint(2)));
    float _3501 = as_type<float>((*spvDescriptorSet0.fp_s3)._m0[int(_3499)]);
    int _3503 = _3487 + 4;
    uint _3505 = uint(int(uint(_3503) >> uint(2)));
    float _3507 = as_type<float>((*spvDescriptorSet0.fp_s3)._m0[int(_3505)]);
    int _3509 = _3487 + 8;
    uint _3511 = uint(int(uint(_3509) >> uint(2)));
    float _3513 = as_type<float>((*spvDescriptorSet0.fp_s3)._m0[int(_3511)]);
    int _3515 = _3487 + 12;
    uint _3517 = uint(int(uint(_3515) >> uint(2)));
    uint _3519 = (*spvDescriptorSet0.fp_s3)._m0[int(_3517)];
    uint _20 = uint(int(uint(_3483) >> uint(2)));
    uint _21 = (*spvDescriptorSet0.fp_s4)._m0[int(_20)];
    int _22 = _3483 + 4;
    uint _23 = uint(int(uint(_22) >> uint(2)));
    uint _24 = (*spvDescriptorSet0.fp_s4)._m0[int(_23)];
    int _30 = _3483 + 64;
    int _31 = _3483 + 68;
    uint _32 = uint(int(uint(_30) >> uint(2)));
    uint _33 = uint(int(uint(_31) >> uint(2)));
    uint _34 = (*spvDescriptorSet0.fp_s2)._m0[int(_33)];
    uint _35 = (*spvDescriptorSet0.fp_s2)._m0[int(_32)];
    int _40 = _3483 + 48;
    uint _41 = uint(int(uint(_40) >> uint(2)));
    uint _42 = (*spvDescriptorSet0.fp_s2)._m0[int(_41)];
    if (_3495 > 0.0)
    {
        int _43 = _40 + 4;
        uint _44 = uint(int(uint(_43) >> uint(2)));
        _42 += (*spvDescriptorSet0.fp_s2)._m0[int(_44)];
    }
    out.m_0 = float4(_3495 + _3501, _3507 + _3513, as_type<float>(_3519 + _21 + _24), as_type<float>(_34 + _35 + _42));
    return out;
}
'''


class WideLoads(unittest.TestCase):
    def test_words_of_one_light(self):
        out = wide_loads(LIGHT)
        # bytes 32..44 from one value: one packed_uint4 at the first word, each word its lane (float or uint alike)
        self.assertIn('packed_uint4 _dmw0 = *(const device packed_uint4*)&(*spvDescriptorSet0.fp_s3)._m0[int(_3499)];', out)
        for lane, var in zip('xyz', ('_3501', '_3507', '_3513')): self.assertIn(f'float {var} = as_type<float>(_dmw0.{lane});', out)
        self.assertIn('uint _3519 = _dmw0.w;', out)
        # byte 16 is alone on its 16-byte step: as it was
        self.assertIn('float _3495 = as_type<float>((*spvDescriptorSet0.fp_s3)._m0[int(_3493)]);', out)
        self.assertEqual(out.count('_dmw'), 5)   # one declaration, four lanes

    def test_left_alone(self):
        out = wide_loads(LIGHT)
        self.assertIn('(*spvDescriptorSet0.fp_s4)._m0[int(_20)]', out)   # a buffer the shader may write
        self.assertIn('(*spvDescriptorSet0.fp_s4)._m0[int(_23)]', out)
        self.assertIn('(*spvDescriptorSet0.fp_s2)._m0[int(_33)]', out)   # the higher word read first
        self.assertIn('(*spvDescriptorSet0.fp_s2)._m0[int(_32)]', out)
        self.assertIn('(*spvDescriptorSet0.fp_s2)._m0[int(_41)]', out)   # its neighbour is in another block
        self.assertIn('(*spvDescriptorSet0.fp_s2)._m0[int(_44)]', out)

    def test_writes_end_a_run(self):
        # a store through another binding (which may be the same memory), an atomic, a barrier or a new common value between the words: each word read where it was
        first = '    float _3501 = as_type<float>((*spvDescriptorSet0.fp_s3)._m0[int(_3499)]);\n'
        for between in ('    (*spvDescriptorSet0.fp_s4)._m0[int(_20)] = 1u;', '    (*spvDescriptorSet0.fp_s4)._m0[int(_20)] += 1u;',
                        '    uint _90 = atomic_fetch_add_explicit((device atomic_uint*)&(*spvDescriptorSet0.fp_s4)._m0[int(_20)], 1u, memory_order_relaxed);',
                        '    threadgroup_barrier(mem_flags::mem_device);', '    _3487 = _3483 + 48;'):
            out = wide_loads(LIGHT.replace(first, first + between + '\n'))
            self.assertNotIn('_dmw', out, between)
            self.assertIn('(*spvDescriptorSet0.fp_s3)._m0[int(_3505)]', out)

    def test_nothing_to_do(self):
        plain = LIGHT.replace('const device', 'device')
        self.assertEqual(wide_loads(plain), plain)

    # shader_wide_device: every buffer device, as the translator declares them once one is written (a raw read log). fp_s4 is written below, fp_s2 is passed to a function
    DEVICE = LIGHT.replace('const device', 'device').replace('    out.m_0 = float4(', '    (*spvDescriptorSet0.fp_s4)._m0[int(_20)] = 7u;\n    out.m_0 = float4(')

    def test_device_buffers_without_the_option(self):
        self.assertNotIn('_dmw', wide_loads(self.DEVICE))

    def test_unwritten_device_buffers_read_whole(self):
        out = wide_loads(self.DEVICE, True)
        self.assertIn('packed_uint4 _dmw0 = *(const device packed_uint4*)&(*spvDescriptorSet0.fp_s3)._m0[int(_3499)];', out)   # fp_s3 is only read
        self.assertEqual(out.count('_dmw'), wide_loads(LIGHT).count('_dmw'))   # the same runs as with the buffers const (fp_s2's run is in another block there too)
        self.assertIn('(*spvDescriptorSet0.fp_s4)._m0[int(_20)]', out)   # written: left alone

    def test_what_is_not_unwritten(self):
        import dmsh_wide
        self.assertEqual(dmsh_wide.unwritten(self.DEVICE), {'fp_s2', 'fp_s3'})
        call = self.DEVICE.replace('    out.m_0 = float4(', '    uint _91 = _17((*spvDescriptorSet0.fp_s2), 3);\n    out.m_0 = float4(')
        self.assertEqual(dmsh_wide.unwritten(call), {'fp_s3'})   # passed to a function: it may write it
        address = self.DEVICE.replace('    out.m_0 = float4(', '    uint _92 = atomic_fetch_add_explicit((device atomic_uint*)&(*spvDescriptorSet0.fp_s3)._m0[int(_20)], 1u, memory_order_relaxed);\n    out.m_0 = float4(')
        self.assertEqual(dmsh_wide.unwritten(address), {'fp_s2'})
        for raw in ('    *(reinterpret_cast<device uint*>(as_type<ulong>(uint2(uint(_20), uint(_21))))) = uint(_24);',
                    '    uint _93 = atomic_fetch_add_explicit((device atomic_uint*)(reinterpret_cast<device uint*>(as_type<ulong>(uint2(uint(_20), uint(_21))))), 1u, memory_order_relaxed);'):
            self.assertEqual(dmsh_wide.unwritten(self.DEVICE.replace('    out.m_0 = float4(', raw + '\n    out.m_0 = float4(')), set(), raw)   # a raw pointer may write any buffer's memory

    @unittest.skipUnless(shutil.which('xcrun') and sys.platform == 'darwin', 'Metal compiler')
    def test_compiles(self):
        with tempfile.TemporaryDirectory() as d:
            for name, src in (('before', LIGHT), ('after', wide_loads(LIGHT)), ('device', wide_loads(self.DEVICE, True))):
                m = os.path.join(d, name + '.metal'); Path(m).write_text(src)
                r = subprocess.run(['xcrun', '-sdk', 'macosx', 'metal', '-c', '-O1', '-fpreserve-invariance', m, '-o', os.path.join(d, name + '.air')],
                                   capture_output=True, text=True)
                self.assertEqual(r.returncode, 0, r.stderr)


if __name__ == '__main__':
    unittest.main()
