#!/usr/bin/env python3
"""The w multiply of perspective inputs (Optimizer.EliminateMultiplyByFragmentCoordW; the job's fragw_fold, the profile key shader_fragw_fold): Ampere's IPA reads a perspective input as
x * gl_FragCoord.w and the shader multiplies it by 1 / gl_FragCoord.w with an FMUL of its own (InstEmitAmpereMem.AIpa), whose operands come in either order. Upstream's pass folds only
the order (x * w) * (1 / w). Through the offline translator (dmsh_xlate, arch sm86): without the option the reciprocal-first product keeps both multiplies and the reciprocal; with it both
products fold to the input, no multiply by gl_FragCoord.w and no reciprocal is left, and the shader still compiles. On this Mac's GPU the folded and the unfolded MSL draw the same colours
(no value more than 1 ulp apart; identical on an M2 Pro) for a perspective-interpolated triangle.
Needs DMSH_TEST_XLATE (the translator) like the other translator tests."""
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_dmsh_ampere_mem import EXIT, inst, TOOLS   # noqa: E402
from test_dmsh_ampere_alu import waiting   # noqa: E402

# SPH as PixelCovered's (colour 0 written), with attribute 0's four components perspective (imap word 6, 2 bits a component)
SPH = struct.pack('<32I', *([0x000c5482] + [0] * 4 + [0xb0000000, 0xaa] + [0] * 11 + [0xf] + [0] * 13))
def ipa(rd, addr): return (0x000e2600000e0000 | addr >> 2, 0x000000ffff007326 | rd << 16)   # IPA Rd, a[addr] (frequency pass), write barrier 0
RCP = waiting((0x000fe60000001000, 0x0000000400047308))   # MUFU.RCP R4, R4 (op 4 at 74..80)
def fmul(rd, ra, rb, wait=False):
    i = (0x000fe20000400000, 0x0000000000007220 | rd << 16 | ra << 24 | rb << 32)   # FMUL Rd, Ra, Rb
    return waiting(i) if wait else i
# w = 1 / a[0x7c]; R0 = w * a[0x80] (the reciprocal first: the order upstream misses); R1 = a[0x84] * w (upstream's order); R2, R3 = a[0x88], a[0x8c] times w, the reciprocal first
CODE = [ipa(4, 0x7c), RCP, ipa(0, 0x80), ipa(1, 0x84), ipa(2, 0x88), ipa(3, 0x8c), fmul(0, 4, 0, True), fmul(1, 1, 4), fmul(2, 4, 2), fmul(3, 4, 3), EXIT]


def translate(**opt):   # reduced: the build's default (dmsh_build.py job_for), plain products rather than spvFMul
    with tempfile.TemporaryDirectory(prefix='fragw_') as d:
        work = Path(d); (work / 'k.bin').write_bytes(SPH + b''.join(inst(*c) for c in CODE))
        (work / 'jobs.json').write_text(json.dumps([dict(key='k', stage='ps', arch='sm86', code=str(work / 'k.bin'), tex={}, img={}, attr={}, fout={}, debug=True, reduced=True, **opt)]))
        r = subprocess.run([os.environ['DMSH_TEST_XLATE'], str(work / 'jobs.json'), d], capture_output=True, text=True)
        if not (work / 'k.spv').exists(): raise AssertionError(r.stdout + r.stderr)
        sys.path.insert(0, str(TOOLS)); import dmsh_geometry
        dmsh_geometry.flatten_sets(work / 'k.spv')
        m = subprocess.run([str(TOOLS / 'spirv_cross_bin/spirv-cross'), '--msl', '--msl-version', '20300', '--msl-argument-buffers', str(work / 'k.spv')], capture_output=True, text=True)
        if m.returncode: raise AssertionError(m.stderr)
        return m.stdout


def body(msl): return msl[msl.index('fragment '):]
def w_products(msl):   # products with a value read from gl_FragCoord.w, directly or through a variable
    b = body(msl); ws = set(re.findall(r'float (_\d+) = gl_FragCoord\.w;', b))
    return [m for m in re.findall(r'= (\S+) \* (\S+);', b) if any(x.rstrip(';') in ws or x.startswith('gl_FragCoord.w') for x in m)]


# Draws one triangle with very different w at its corners into a 64x64 RGBA32F target; the four colour outputs are the attribute's components, so both shaders should agree
RUNNER = r'''#import <Metal/Metal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
static const char *VS = "#include <metal_stdlib>\nusing namespace metal;\nstruct V { float4 p [[position]]; float4 a [[user(locn0)]]; };\n"
  "vertex V vmain(uint i [[vertex_id]]) { float4 P[3] = { float4(-1, -1, 0.1, 1), float4(3, -1, 0.5, 4), float4(-1, 3, 2.9, 7) }; float4 A[3] = { float4(0.1, 2, -3, 40), float4(5, 0.25, 7, -1), float4(-2, 9, 0.5, 3) };\n"
  "  V o; o.p = float4(P[i].xy * P[i].w, P[i].z, P[i].w); o.a = A[i]; return o; }\n";
int main(int ac, char **av) { @autoreleasepool {
    id<MTLDevice> d = MTLCreateSystemDefaultDevice(); NSError *e = nil;
    id<MTLLibrary> vl = [d newLibraryWithSource:@(VS) options:nil error:&e]; if (!vl) { puts(e.description.UTF8String); return 2; }
    float *img[2]; int W = 64;
    for (int k = 0; k < 2; k++) {
        id<MTLLibrary> fl = [d newLibraryWithURL:[NSURL fileURLWithPath:@(av[1 + k])] error:&e]; if (!fl) { puts(e.description.UTF8String); return 2; }
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new]; pd.vertexFunction = [vl newFunctionWithName:@"vmain"]; pd.fragmentFunction = [fl newFunctionWithName:@"main0"];
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA32Float;
        id<MTLRenderPipelineState> ps = [d newRenderPipelineStateWithDescriptor:pd error:&e]; if (!ps) { puts(e.description.UTF8String); return 2; }
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float width:W height:W mipmapped:NO]; td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModeShared;
        id<MTLTexture> t = [d newTextureWithDescriptor:td];
        id<MTLBuffer> ab = [d newBufferWithLength:4096 options:MTLResourceStorageModeShared];   // the argument buffer: the shader declares none it reads
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor]; rp.colorAttachments[0].texture = t; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLCommandQueue> q = [d newCommandQueue]; id<MTLCommandBuffer> c = [q commandBuffer]; id<MTLRenderCommandEncoder> re = [c renderCommandEncoderWithDescriptor:rp];
        [re setRenderPipelineState:ps]; [re setFragmentBuffer:ab offset:0 atIndex:0]; [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [re endEncoding]; [c commit]; [c waitUntilCompleted];
        img[k] = malloc(W * W * 16); [t getBytes:img[k] bytesPerRow:W * 16 fromRegion:MTLRegionMake2D(0, 0, W, W) mipmapLevel:0];
    }
    int bad = 0, n = 0, ulp = 0, off = 0; double worst = 0;
    for (int i = 0; i < W * W * 4; i++) {
        float a = img[0][i], b = img[1][i]; if (a == 0 && b == 0) continue; n++;
        double r = fabs((double)a - b) / fmax(fabs(a), 1e-30); if (r > worst) worst = r;
        int32_t ia, ib; memcpy(&ia, &a, 4); memcpy(&ib, &b, 4);   // units in the last place: same-sign floats are ordered as their bit patterns
        int u = (ia < 0) != (ib < 0) ? 1 << 30 : abs(ia - ib); if (u > ulp) ulp = u; off += u != 0;
        if (u > 1) bad++;
    }
    printf("compared %d, differ %d, worst relative %.3g, max ulp %d, values not identical %d\n", n, bad, worst, ulp, off); return 0;
} }
'''


@unittest.skipUnless(os.environ.get('DMSH_TEST_XLATE'), 'set DMSH_TEST_XLATE to the offline translator')
class FragW(unittest.TestCase):
    def test_without_the_option_the_reciprocal_first_products_stay(self):
        msl = translate()
        self.assertIn('1.0 / ', body(msl))
        self.assertGreaterEqual(len(w_products(msl)), 3, body(msl))   # x * w for R0, R2, R3 (R1's is folded upstream)

    def test_with_the_option_every_product_folds(self):
        msl = translate(fragw_fold=True)
        b = body(msl)
        self.assertEqual(w_products(msl), [], b)
        self.assertNotIn('1.0 / ', b)   # the reciprocal has no use left
        for c in 'xyzw': self.assertRegex(b, rf'= in\.\w+\.{c};')   # each output a component of the input

    @unittest.skipUnless(shutil.which('xcrun') and sys.platform == 'darwin', 'needs Metal')
    def test_folded_and_unfolded_draw_the_same(self):
        sys.path.insert(0, str(Path(__file__).resolve().parent)); from test_dmsh_raw_last import MAC_METAL
        with tempfile.TemporaryDirectory() as w:
            w = Path(w); libs = []
            for name, msl in (('plain', translate()), ('fold', translate(fragw_fold=True))):
                (w / f'{name}.metal').write_text(msl)
                r = subprocess.run(MAC_METAL + [str(w / f'{name}.metal'), '-o', str(w / f'{name}.air')], capture_output=True, text=True)
                self.assertEqual(r.returncode, 0, r.stderr[-3000:])
                subprocess.run(['xcrun', '-sdk', 'macosx', 'metallib', str(w / f'{name}.air'), '-o', str(w / f'{name}.metallib')], check=True)
                libs.append(str(w / f'{name}.metallib'))
            (w / 'r.m').write_text(RUNNER)
            subprocess.run(['clang', '-fobjc-arc', '-framework', 'Metal', '-framework', 'Foundation', str(w / 'r.m'), '-o', str(w / 'r')], check=True, capture_output=True)
            out = subprocess.run([str(w / 'r'), *libs], capture_output=True, text=True)
            m = re.search(r'compared (\d+), differ (\d+)', out.stdout)
            self.assertTrue(m, out.stdout + out.stderr)
            self.assertGreater(int(m.group(1)), 4000, out.stdout)   # most of the 64x64x4 values are covered
            self.assertEqual(int(m.group(2)), 0, out.stdout)   # no value more than 1 ulp apart (the key is on by default: the M2 Pro draws them identical)


@unittest.skipUnless(os.environ.get('DMSH_TEST_XLATE'), 'set DMSH_TEST_XLATE to the offline translator')
class NoRescale(unittest.TestCase):
    """shader_no_rescale (the job's no_rescale): gl_FragCoord.xy read through IPA a[0x70] / a[0x74] is divided by the support buffer's render scale (InstEmitAttribute.EmitIpa), which the
    host always fills with 1.0 (nvn_mtl.m support_buf): with the option the division and the support buffer read are gone"""
    CODE = [ipa(0, 0x70), ipa(1, 0x74), ipa(2, 0x80), ipa(3, 0x84), EXIT]

    def msl(self, **opt):
        global CODE
        keep = CODE
        try:
            CODE = self.CODE
            return translate(**opt)
        finally:
            CODE = keep

    def test_without_the_option_the_coordinate_is_divided(self):
        b = body(self.msl())
        self.assertIn('support_buffer', b)
        self.assertRegex(b, r'gl_FragCoord\.x;\s+float _\d+ = \(?\*?spvDescriptorSet0|/ ')

    def test_with_the_option_no_division(self):
        b = body(self.msl(no_rescale=True))
        self.assertNotIn('support_buffer', b)
        self.assertNotIn(' / ', b)
        self.assertIn('gl_FragCoord.x', b)
        self.assertIn('gl_FragCoord.y', b)


if __name__ == '__main__':
    unittest.main()
