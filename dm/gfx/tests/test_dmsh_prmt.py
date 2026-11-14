#!/usr/bin/env python3
"""Ampere PRMT with a constant selector written by runs of bytes (InstEmitAmpereAlu.APrmtRuns; the job's prmt_runs, the profile key shader_prmt_runs): result bytes that take consecutive
bytes of one source in order are one shift and one mask, where the byte form takes an extract, a mask, a shift and an OR for each byte. Ocarina of Time's selectors are half swaps (0x5410,
0x5432, 0x7610, 0x7632: 26 in its ALU-bound compute f8965bffbdf51d78, 100 in its upscaler d99fbeeb53d38847). Through the offline translator (dmsh_xlate, arch sm86): without the option the
MSL is the byte form; with it the half swaps have no byte extract left. On this Mac's GPU a pixel shader of 48 PRMTs chained over interpolated inputs (the game's selectors, identity,
reversals, funnels and seeded random ones with sign-repeating bytes) writes the same bits in both forms at every pixel. Needs DMSH_TEST_XLATE (the translator) like the other translator tests."""
import json
import os
from pathlib import Path
import random
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
from test_dmsh_fragw import SPH, ipa   # noqa: E402   (colour 0 written, attribute 0's four components perspective)


def prmt(rd, ra, sel, rc):   # PRMT Rd, Ra, sel, Rc (immediate form 0x816, mode 0), as Ocarina of Time encodes it (f8965bffbdf51d78: PRMT R19, R19, 0x5410, R17)
    return waiting((0x000fe20000000000 | rc, 0x0000000000007816 | rd << 16 | ra << 24 | sel << 32))


GAME = (0x5410, 0x5432, 0x7610, 0x7632)
FIXED = GAME + (0x3210, 0x7654, 0x0123, 0x1032, 0x4321, 0x6543, 0x2107, 0x5555)
rng = random.Random(1)
CHAIN = FIXED + tuple(rng.getrandbits(16) for _ in range(36))   # random nibbles: sign-repeating bytes (8..15) among them
assert any(n & 8 for s in CHAIN for n in (s & 15, s >> 4 & 15, s >> 8 & 15, s >> 12 & 15))
INPUTS = [ipa(4 + i, 0x80 + 4 * i) for i in range(4)]   # R4..R7 = attribute 0 (its bits: the PRMTs read them as integers)


def chained():   # R0..R3 from R4..R7, then each step R(k % 4) = PRMT(R(k % 4), sel, R((k + 1) % 4)); colour 0 is R0..R3
    code = list(INPUTS) + [prmt(i, 4 + i, CHAIN[i], 4 + (i + 1) % 4) for i in range(4)]
    code += [prmt(k % 4, k % 4, s, (k + 1) % 4) for k, s in enumerate(CHAIN[4:])]
    return code + [EXIT]


def one_each(sels):   # R0..R3 = PRMT(R4 + i, sel i, R5 + i)
    return list(INPUTS) + [prmt(i, 4 + i, s, 4 + (i + 1) % 4) for i, s in enumerate(sels)] + [EXIT]


def translate(code, **opt):
    with tempfile.TemporaryDirectory(prefix='prmt_') as d:
        work = Path(d); (work / 'k.bin').write_bytes(SPH + b''.join(inst(*c) for c in code))
        (work / 'jobs.json').write_text(json.dumps([dict(key='k', stage='ps', arch='sm86', code=str(work / 'k.bin'), tex={}, img={}, attr={}, fout={'0': 'uint'}, debug=True, reduced=True, **opt)]))
        r = subprocess.run([os.environ['DMSH_TEST_XLATE'], str(work / 'jobs.json'), d], capture_output=True, text=True)
        if not (work / 'k.spv').exists(): raise AssertionError(r.stdout + r.stderr)
        sys.path.insert(0, str(TOOLS)); import dmsh_geometry
        dmsh_geometry.flatten_sets(work / 'k.spv')
        m = subprocess.run([str(TOOLS / 'spirv_cross_bin/spirv-cross'), '--msl', '--msl-version', '20300', '--msl-argument-buffers', str(work / 'k.spv')], capture_output=True, text=True)
        if m.returncode: raise AssertionError(m.stderr)
        return m.stdout


def body(msl): return msl[msl.index('fragment '):]
BYTE = re.compile(r'extract_bits\([^;]*, 8u\)')


# Draws one triangle with very different attribute values at its corners into a 64x64 RGBA32Uint target with each library, and compares the words
RUNNER = r'''#import <Metal/Metal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static const char *VS = "#include <metal_stdlib>\nusing namespace metal;\nstruct V { float4 p [[position]]; float4 a [[user(locn0)]]; };\n"
  "vertex V vmain(uint i [[vertex_id]]) { float4 P[3] = { float4(-1, -1, 0.1, 1), float4(3, -1, 0.5, 4), float4(-1, 3, 2.9, 7) }; float4 A[3] = { float4(0.1, -2e5, -3, 4e-3), float4(5e7, 0.25, -7e-6, -1), float4(-2e-4, 9, 6e5, 3e9) };\n"
  "  V o; o.p = float4(P[i].xy * P[i].w, P[i].z, P[i].w); o.a = A[i]; return o; }\n";
int main(int ac, char **av) { @autoreleasepool {
    id<MTLDevice> d = MTLCreateSystemDefaultDevice(); NSError *e = nil;
    id<MTLLibrary> vl = [d newLibraryWithSource:@(VS) options:nil error:&e]; if (!vl) { puts(e.description.UTF8String); return 2; }
    uint32_t *img[2]; int W = 64;
    for (int k = 0; k < 2; k++) {
        id<MTLLibrary> fl = [d newLibraryWithURL:[NSURL fileURLWithPath:@(av[1 + k])] error:&e]; if (!fl) { puts(e.description.UTF8String); return 2; }
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new]; pd.vertexFunction = [vl newFunctionWithName:@"vmain"]; pd.fragmentFunction = [fl newFunctionWithName:@"main0"];
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA32Uint;
        id<MTLRenderPipelineState> ps = [d newRenderPipelineStateWithDescriptor:pd error:&e]; if (!ps) { puts(e.description.UTF8String); return 2; }
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Uint width:W height:W mipmapped:NO]; td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModeShared;
        id<MTLTexture> t = [d newTextureWithDescriptor:td];
        id<MTLBuffer> ab = [d newBufferWithLength:4096 options:MTLResourceStorageModeShared];   // the argument buffer: the shader declares none it reads
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor]; rp.colorAttachments[0].texture = t; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLCommandQueue> q = [d newCommandQueue]; id<MTLCommandBuffer> c = [q commandBuffer]; id<MTLRenderCommandEncoder> re = [c renderCommandEncoderWithDescriptor:rp];
        [re setRenderPipelineState:ps]; [re setFragmentBuffer:ab offset:0 atIndex:0]; [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [re endEncoding]; [c commit]; [c waitUntilCompleted];
        img[k] = malloc(W * W * 16); [t getBytes:img[k] bytesPerRow:W * 16 fromRegion:MTLRegionMake2D(0, 0, W, W) mipmapLevel:0];
    }
    int n = 0, differ = 0, distinct = 0;
    for (int i = 0; i < W * W * 4; i++) { if (img[0][i] == 0 && img[1][i] == 0) continue; n++; differ += img[0][i] != img[1][i]; distinct += i >= 4 && img[0][i] != img[0][i - 4]; }
    printf("compared %d, differ %d, changing from pixel to pixel %d\n", n, differ, distinct); return 0;
} }
'''


@unittest.skipUnless(os.environ.get('DMSH_TEST_XLATE'), 'set DMSH_TEST_XLATE to the offline translator')
class Prmt(unittest.TestCase):
    def test_without_the_option_the_byte_form(self):
        b = body(translate(one_each(GAME)))
        self.assertGreaterEqual(len(BYTE.findall(b)), 16, b)   # four extracts a PRMT
        self.assertEqual(translate(one_each(GAME)), translate(one_each(GAME), prmt_runs=False))

    def test_half_swaps_without_byte_extracts(self):
        b = body(translate(one_each(GAME), prmt_runs=True))
        self.assertEqual(BYTE.findall(b), [], b)
        self.assertNotIn('extract_bits', b)
        self.assertRegex(b, r'& 65535\b')                                   # 0x5410 and 0x7610 keep a's low half
        self.assertRegex(b, r'& \(?(-65536|4294901760u?)\)?')               # 0x7610 and 0x7632 keep c's high half
        self.assertRegex(b, r'<< 16')                                       # 0x5410, 0x5432: c's low half up
        self.assertRegex(b, r'>> (uint\()?16')                             # 0x5432, 0x7632: a's high half down

    def test_identity_is_the_register(self):
        b = body(translate(one_each((0x3210, 0x7654, 0x3210, 0x7654)), prmt_runs=True))
        self.assertNotRegex(b, r'extract_bits|<<|>>|&', b)

    def test_sign_bytes_keep_the_byte_form(self):
        b = body(translate(one_each((0x8888, 0x5410, 0x5410, 0x5410)), prmt_runs=True))
        self.assertEqual(len(BYTE.findall(b)), 4, b)   # only the sign-repeating PRMT extracts, one a byte

    @unittest.skipUnless(shutil.which('xcrun') and sys.platform == 'darwin', 'needs Metal')
    def test_both_forms_draw_the_same_bits(self):
        sys.path.insert(0, str(Path(__file__).resolve().parent)); from test_dmsh_raw_last import MAC_METAL
        ios_like = MAC_METAL[:5] + ['-fmetal-math-mode=relaxed'] + MAC_METAL[5:]   # the iPhone / Apple TV math mode (ios_metal.py), on this Mac's GPU
        with tempfile.TemporaryDirectory() as w:
            w = Path(w)
            (w / 'r.m').write_text(RUNNER)
            subprocess.run(['clang', '-fobjc-arc', '-framework', 'Metal', '-framework', 'Foundation', str(w / 'r.m'), '-o', str(w / 'r')], check=True, capture_output=True)
            srcs = {'bytes': translate(chained()), 'runs': translate(chained(), prmt_runs=True)}
            self.assertEqual(BYTE.findall(body(srcs['runs'])) != [], True)   # the chain's sign-repeating bytes keep theirs
            self.assertLess(len(BYTE.findall(body(srcs['runs']))), len(BYTE.findall(body(srcs['bytes']))) * 2 // 3)   # about half the random nibbles repeat a sign
            for mode, cmd in (('mac', MAC_METAL), ('relaxed', ios_like)):
                libs = []
                for name, msl in srcs.items():
                    (w / f'{name}.metal').write_text(msl)
                    r = subprocess.run(cmd + [str(w / f'{name}.metal'), '-o', str(w / f'{name}.air')], capture_output=True, text=True)
                    self.assertEqual(r.returncode, 0, r.stderr[-3000:])
                    subprocess.run(['xcrun', '-sdk', 'macosx', 'metallib', str(w / f'{name}.air'), '-o', str(w / f'{mode}_{name}.metallib')], check=True)
                    libs.append(str(w / f'{mode}_{name}.metallib'))
                out = subprocess.run([str(w / 'r'), *libs], capture_output=True, text=True)
                m = re.search(r'compared (\d+), differ (\d+), changing from pixel to pixel (\d+)', out.stdout)
                self.assertTrue(m, out.stdout + out.stderr)
                self.assertGreater(int(m.group(1)), 4000, out.stdout)   # most of the 64x64x4 words are covered
                self.assertGreater(int(m.group(3)), 2000, out.stdout)   # and they vary across the triangle
                self.assertEqual(int(m.group(2)), 0, f'{mode}: {out.stdout}')


if __name__ == '__main__':
    unittest.main()
