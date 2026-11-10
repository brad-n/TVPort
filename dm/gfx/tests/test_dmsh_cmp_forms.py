#!/usr/bin/env python3
"""Cheaper exact forms of two float comparison shapes the translator writes, each behind its own profile key:
- shader_ftz_cmp (the job's ftz_cmp, InstEmit.GetFtzFPComparison): a .FTZ comparison whose other operand is a constant (RZ, an immediate) flushes nothing the constant decides. Against a
  normal non-zero constant the register is compared as it is; against 0 the flush and the comparison become one comparison with +-FLT_MIN (x > 0: x >= FLT_MIN; x == 0: |x| < FLT_MIN).
- shader_unord_cmp (the job's unord_cmp, InstEmit.GetFPComparison): an unordered comparison is the negation of the ordered opposite (LTU: !(a >= b)), one comparison where
  a cmp b || isnan(a) || isnan(b) took three and two ORs. EQU keeps its form.
Through the offline translator (dmsh_xlate, arch sm86): without the options the MSL is what it was; with them the forms above. On this Mac's GPU, with the iPhone / Apple TV math mode
(relaxed) and the Mac's (fast), every form gives the old form's result for every predicate over values that matter (denormals of both signs, +-0, +-FLT_MIN, normals, +-infinity, NaN).
Needs DMSH_TEST_XLATE (the translator) like the other translator tests."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_dmsh_ampere_mem import EXIT, Translated, inst   # noqa: E402
from test_dmsh_ampere_alu import STORE, waiting, s2r_tid   # noqa: E402

FLUSH_SELECT = re.compile(r'< 1\.17549435\d*e-38;\s+float _\d+ = _\d+ \? 0\.0 :')   # the flush |x| < FLT_MIN ? 0 : x
FSET = (0x000fe2000381d000, 0x800000141306720a)   # FSET.NEU.FTZ.AND R6, R19, -R20, PT (test_dmsh_ampere_alu CompareFtz)
def fset(p, ftz=True, b=None, imm=None):
    """FSET.<p>[.FTZ].AND R6, R19, <R20 | RZ | imm>: p the comparison at 76..80, .FTZ bit 80"""
    hi = (FSET[0] & ~(0x1f << 12)) | p << 12 | (1 << 16 if ftz else 0)
    if imm is not None: return (hi, (imm << 32) | 0x13 << 24 | 0x06 << 16 | 0x780a)   # the immediate form (0x80a), the float's bits at 32..63
    return (hi, (FSET[1] & ~(0xff << 32) & ~(1 << 63)) | (b if b is not None else 0x14) << 32)
NAMES = {1: 'lt', 2: 'eq', 3: 'le', 4: 'gt', 5: 'ne', 6: 'ge', 9: 'ltu', 10: 'equ', 11: 'leu', 12: 'gtu', 13: 'neu', 14: 'geu'}


class Forms(Translated):
    def kept(self, *code, **opt):
        pre = b''.join(inst(*s2r_tid(r)) for r in (9, 19, 20))
        return self.translate(pre + b''.join(inst(*waiting(i)) for i in code) + inst(*waiting(STORE)) + inst(*EXIT), shared=0x1000, **opt)

    def test_without_the_options_nothing_changes(self):
        for code in (fset(13, b=0xff), fset(1, imm=0x3f800000), fset(12, ftz=False)):
            self.assertEqual(self.kept(code), self.kept(code, ftz_cmp=False, unord_cmp=False))
        self.assertTrue(FLUSH_SELECT.search(self.kept(fset(13, b=0xff))))   # the register against RZ is flushed, as before
        self.assertIn('isnan', self.kept(fset(12, ftz=False)))

    def test_against_rz_no_flush(self):
        want = {1: r'<= \(?-1\.17549', 3: r'< 1\.17549', 4: r'>= 1\.17549', 6: r'> \(?-1\.17549', 2: r'(?s)abs\(.*< 1\.17549', 5: r'(?s)abs\(.*>= 1\.17549'}
        for p, w in want.items():
            for u in (0, 8):
                msl = self.kept(fset(p | u, b=0xff), ftz_cmp=True)
                self.assertFalse(FLUSH_SELECT.search(msl), (NAMES[p | u], msl[-1500:]))
                self.assertRegex(msl, w, NAMES[p | u])
                self.assertEqual('isnan' in msl, bool(u), NAMES[p | u])   # the unordered forms keep their NaN test

    def test_rz_first_mirrors_the_comparison(self):   # RZ < x is x > 0: x >= FLT_MIN
        hi, lo = fset(1, b=0x13)
        msl = self.kept((hi, (lo & ~(0xff << 24)) | 0xff << 24), ftz_cmp=True)
        self.assertFalse(FLUSH_SELECT.search(msl), msl[-1500:])
        self.assertRegex(msl, r'>= 1\.17549')

    def test_against_a_normal_immediate_no_flush(self):
        for p in (1, 2, 4, 13):
            msl = self.kept(fset(p, imm=0x3f800000), ftz_cmp=True)   # 1.0
            self.assertNotIn('1.17549', msl, NAMES[p])

    def test_two_registers_still_flush_both(self):
        self.assertEqual(len(FLUSH_SELECT.findall(self.kept(fset(13), ftz_cmp=True))), 2)

    def test_unordered_as_a_negation(self):
        for p in (9, 11, 12, 13, 14):
            msl = self.kept(fset(p, ftz=False), unord_cmp=True)
            self.assertNotIn('isnan', msl, NAMES[p])
            self.assertRegex(msl, r'!\(?_\d+|= !_\d+', NAMES[p])
        self.assertIn('isnan', self.kept(fset(10, ftz=False), unord_cmp=True))   # EQU keeps its form


# The forms' tables restated in MSL and checked against the old forms over every pair of special values, every predicate
KERNEL = r'''#include <metal_stdlib>
using namespace metal;
#define M 1.1754943508222875079687365372222e-38f
static float fl(float v) { return abs(v) < M ? 0.0f : v; }
static bool ord(int p, float a, float b) { switch (p & 7) { case 1: return a < b; case 2: return a == b; case 3: return a <= b; case 4: return a > b; case 5: return a < b || a > b; case 6: return a >= b; case 7: return !isnan(a) && !isnan(b); default: return false; } }
static bool old_cmp(int p, float a, float b) { if (p == 15) return true; if (p == 8) return isnan(a) || isnan(b); bool r = ord(p, a, b); return (p & 8) ? (r || isnan(a) || isnan(b)) : r; }
static bool unord_new(int p, float a, float b) {   // GetFPComparison with unord_cmp
    switch (p) { case 9: return !(a >= b); case 11: return !(a > b); case 12: return !(a <= b); case 13: return !(a == b); case 14: return !(a < b); default: return old_cmp(p, a, b); } }
static bool ftz_new(int p, float x, float c) {   // GetFtzFPComparison with ftz_cmp, the constant second
    int b = p & 7, u = p & 8;
    if (b == 0 || b == 7 || (c != 0.0f && abs(c) >= M) || isnan(c)) return old_cmp(p, x, c);
    switch (b) { case 1: return old_cmp(3 | u, x, -M); case 3: return old_cmp(1 | u, x, M); case 4: return old_cmp(6 | u, x, M); case 6: return old_cmp(4 | u, x, -M);
                 case 2: return old_cmp(1 | u, abs(x), M); default: return old_cmp(6 | u, abs(x), M); } }
kernel void k(device const float *v [[buffer(0)]], constant uint &n [[buffer(1)]], device atomic_uint *bad [[buffer(2)]], uint id [[thread_position_in_grid]]) {
    if (id >= n * n) return;
    float a = v[id / n], b = v[id % n];
    for (int p = 0; p < 16; p++) {
        if (old_cmp(p, fl(a), fl(b)) != ftz_new(p, a, b)) atomic_fetch_add_explicit(&bad[0], 1, memory_order_relaxed);   // b a constant
        if (old_cmp(p, a, b) != unord_new(p, a, b)) atomic_fetch_add_explicit(&bad[1], 1, memory_order_relaxed);
    }
}
'''
RUNNER = r'''#import <Metal/Metal.h>
#include <stdio.h>
#include <math.h>
#include <float.h>
int main(int ac, char **av) { @autoreleasepool {
    id<MTLDevice> d = MTLCreateSystemDefaultDevice(); NSError *e = nil;
    id<MTLLibrary> l = [d newLibraryWithURL:[NSURL fileURLWithPath:@(av[1])] error:&e]; if (!l) { puts(e.description.UTF8String); return 2; }
    id<MTLComputePipelineState> ps = [d newComputePipelineStateWithFunction:[l newFunctionWithName:@"k"] error:&e]; if (!ps) { puts(e.description.UTF8String); return 2; }
    float s[] = { 0.0f, -0.0f, 1e-40f, -1e-40f, 1e-45f, -1e-45f, FLT_MIN, -FLT_MIN, nextafterf(FLT_MIN, 0), -nextafterf(FLT_MIN, 0), nextafterf(FLT_MIN, 1), 1.0f, -1.0f, 0.5f, -2.5f, 3e38f, -3e38f, INFINITY, -INFINITY, NAN, -NAN, 1e-30f, -1e-30f };
    uint32_t n = sizeof s / sizeof s[0];
    id<MTLBuffer> v = [d newBufferWithBytes:s length:sizeof s options:MTLResourceStorageModeShared], bad = [d newBufferWithLength:8 options:MTLResourceStorageModeShared];
    memset(bad.contents, 0, 8);
    id<MTLCommandQueue> q = [d newCommandQueue]; id<MTLCommandBuffer> c = [q commandBuffer]; id<MTLComputeCommandEncoder> ce = [c computeCommandEncoder];
    [ce setComputePipelineState:ps]; [ce setBuffer:v offset:0 atIndex:0]; [ce setBytes:&n length:4 atIndex:1]; [ce setBuffer:bad offset:0 atIndex:2];
    [ce dispatchThreads:MTLSizeMake(n * n, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)]; [ce endEncoding]; [c commit]; [c waitUntilCompleted];
    const uint32_t *b = bad.contents; printf("pairs %u, ftz mismatches %u, unordered mismatches %u\n", n * n, b[0], b[1]); return 0;
} }
'''


@unittest.skipUnless(shutil.which('xcrun') and sys.platform == 'darwin', 'needs Metal')
class FormsOnGpu(unittest.TestCase):
    def test_every_predicate_over_special_values(self):
        sys.path.insert(0, str(Path(__file__).resolve().parent)); from test_dmsh_raw_last import MAC_METAL
        ios_like = MAC_METAL[:5] + ['-fmetal-math-mode=relaxed'] + MAC_METAL[5:]   # the iPhone / Apple TV math mode (ios_metal.py), on this Mac's GPU
        with tempfile.TemporaryDirectory() as w:
            w = Path(w); (w / 'k.metal').write_text(KERNEL); (w / 'r.m').write_text(RUNNER)
            subprocess.run(['clang', '-fobjc-arc', '-framework', 'Metal', '-framework', 'Foundation', str(w / 'r.m'), '-o', str(w / 'r')], check=True, capture_output=True)
            for name, cmd in (('mac', MAC_METAL), ('relaxed', ios_like)):
                r = subprocess.run(cmd + [str(w / 'k.metal'), '-o', str(w / f'{name}.air')], capture_output=True, text=True)
                self.assertEqual(r.returncode, 0, r.stderr[-2000:])
                subprocess.run(['xcrun', '-sdk', 'macosx', 'metallib', str(w / f'{name}.air'), '-o', str(w / f'{name}.metallib')], check=True)
                out = subprocess.run([str(w / 'r'), str(w / f'{name}.metallib')], capture_output=True, text=True).stdout
                # both modes, since shader_unord_cmp is on for every game: under the Mac's fast math the compiler may assume no NaN, and then makes isnan false and the
                # unordered predicate the ordered one, so the old and the new form become the same comparison; a compiler that treated them apart would fail here
                self.assertIn('ftz mismatches 0, unordered mismatches 0', out, f'{name}: {out}')


if __name__ == '__main__':
    unittest.main()
