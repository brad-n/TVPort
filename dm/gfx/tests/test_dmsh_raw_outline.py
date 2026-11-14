#!/usr/bin/env python3
"""A raw global memory lookup's miss path out of line (the profile key shader_raw_outline, the job's raw_outline; GlobalToStorage.GetRawMissFunction, dmsh_rewrite.raw_miss_noinline): a lookup whose
last entry does not hold the address calls one miss function of the shader (the hint of its 2 MiB chunk, the binary search over the pool table, the read log), which the shader build makes noinline,
instead of carrying that code inline at each lookup.
Through the offline translator (dmsh_xlate, arch sm86): without the option the MSL is the same as before; with it the shader has one miss function (one more with the read log), every helper calls it
and carries no hint or search of its own, a store or atomic keeps its write log inline; the rewrite makes the function noinline with its address words by value and leaves other MSL alone; and on this
Mac's GPU, in the Mac's and the Apple TV's math modes, the outlined form reads and logs what the pool table names, bit for bit as the inline form: test_dmsh_raw_last's walk (adjacent pools, a gap, a
hinted chunk above 4 GiB, with and without the range words and the search loop), its 128-bit loads, and test_dmsh_raw_log's resident pools, stub and read log bits.
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
from test_dmsh_raw_last import MAC_METAL, LDG, LDG128, STORE, EXIT, RUNNER as WALK, Translated, inst, sts, waiting, s2r_tid   # noqa: E402
from test_dmsh_raw_log import RUNNER as LOG   # noqa: E402
from test_dmsh_ampere_alu import FloatRed   # noqa: E402
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import dmsh_rewrite   # noqa: E402

# a raw helper: the address words, the pool table (and the log buffer), the last entry, its range words with shader_raw_regs, gmem_vec for a vector load
HELPER = re.compile(r'(?m)^int (_\d+)\(thread const int& _\d+, thread const int& _\d+, (?:const )?device (_\d+)& \w+(?:, device (_\d+)& \w+)?, thread uint& _\d+'
                    r'(, thread spvUnsafeArray<uint, 6>& _\d+)?(, thread spvUnsafeArray<uint, 3>& _\d+)?\)\n\{\n')
MISS_DEF = re.compile(r'(?m)^int (dmsh_raw_miss(?:_rlog)?)\(')
IOS_LIKE = MAC_METAL[:5] + ['-fmetal-math-mode=relaxed'] + MAC_METAL[5:]   # the iPhone / Apple TV math mode (ios_metal.py), on this Mac's GPU
TWO_LOADS = (s2r_tid(9), s2r_tid(5), LDG, STORE, (LDG[0], LDG[1] | 4 << 40), STORE)   # test_dmsh_raw_compact's two loads
VECTOR = (s2r_tid(9), s2r_tid(5), LDG128, sts(12, 0), sts(13, 4), sts(14, 8), sts(15, 12))   # test_dmsh_raw_last.RawVector's LDG.128


def body(msl, start): return msl[start:msl.index('\n}\n', start)]


@unittest.skipUnless(os.environ.get('DMSH_TEST_XLATE'), 'set DMSH_TEST_XLATE to the offline translator')
class RawOutline(Translated):
    def msl(self, code=TWO_LOADS, **opt):
        return self.translate(b''.join(inst(*waiting(i)) for i in code) + inst(*EXIT), shared=0x1000, **opt)

    def helpers(self, msl): return [m for m in HELPER.finditer(msl)]

    def test_without_the_option_the_msl_is_the_same(self):
        for opt in ({}, dict(raw_regs=True), dict(raw_read_log=True)):
            msl = self.msl(**opt)
            self.assertEqual(msl, self.msl(raw_outline=False, **opt))
            self.assertNotIn('dmsh_raw_miss', msl)

    def test_one_miss_function_that_every_helper_calls(self):
        for opt in ({}, dict(raw_regs=True), dict(raw_regs=True, raw_loop=True)):
            msl = self.msl(raw_outline=True, **opt)
            self.assertEqual(MISS_DEF.findall(msl), ['dmsh_raw_miss'], opt)
            miss = body(msl, MISS_DEF.search(msl).end())
            self.assertIn('>> uint(21)', miss)   # the hint's chunk
            if opt.get('raw_loop'): self.assertRegex(miss, r'\b(for|do|while)\b')
            else: self.assertIn('+ 4096;', miss)   # the unrolled search's first step
            hs = self.helpers(msl)
            self.assertTrue(hs, msl[:3000])
            for h in hs:
                hb = body(msl, h.end())
                self.assertEqual(hb.count('dmsh_raw_miss('), 1, opt)
                self.assertNotIn('>> uint(21)', hb)
                self.assertNotIn('+ 4096;', hb)
                self.assertLess(len(hb), len(miss) if not opt.get('raw_loop') else 10 ** 9)
            main = msl[msl.index('kernel void main0'):]
            self.assertNotIn('dmsh_raw_miss(', main)   # only the helpers call it
            # the range words are still the invocation's private words: the miss function takes none of them, only the address words and buffers
            sig = msl[MISS_DEF.search(msl).start():].split('\n')[0]
            self.assertNotRegex(sig, r'thread (?!const int&)')

    def test_the_read_log_moves_into_its_own_miss_function(self):
        msl = self.msl(raw_outline=True, raw_read_log=True)
        self.assertEqual(MISS_DEF.findall(msl), ['dmsh_raw_miss_rlog'])
        miss = body(msl, MISS_DEF.search(msl).end())
        self.assertEqual(miss.count('atomic_fetch_or_explicit'), 1)
        self.assertIn('+ 256;', miss)   # GmemReadLogWords: past the write bitmap
        for h in self.helpers(msl): self.assertNotIn('atomic_fetch_or', body(msl, h.end()))

    def test_an_atomic_keeps_its_write_log_and_calls_the_miss_function_without_the_read_log(self):
        code = (s2r_tid(6), s2r_tid(8), s2r_tid(9), FloatRed.RED)   # a compare-and-swap loop: a load of the word (the read log's function) and the swap (the other one)
        plain, msl = self.msl(code, raw_read_log=True), self.msl(code, raw_outline=True, raw_read_log=True)
        self.assertNotIn('dmsh_raw_miss', plain)
        self.assertEqual(sorted(MISS_DEF.findall(msl)), ['dmsh_raw_miss', 'dmsh_raw_miss_rlog'])
        plain_miss = [m for m in MISS_DEF.finditer(msl) if m.group(1) == 'dmsh_raw_miss'][0]
        self.assertNotIn('atomic_fetch_or', body(msl, plain_miss.end()))
        self.assertEqual(plain.count('atomic_fetch_or_explicit'), msl.count('atomic_fetch_or_explicit'))   # the write log still at the access, the read log moved
        self.assertIn('atomic_compare_exchange_weak_explicit', msl)

    def test_the_build_makes_it_noinline_with_the_address_by_value(self):
        for opt in (dict(raw_regs=True), dict(raw_regs=True, raw_read_log=True)):
            msl = self.msl(raw_outline=True, **opt)
            out = dmsh_rewrite.raw_miss_noinline(msl)
            m = re.search(r'__attribute__\(\(noinline\)\)\nstatic int (dmsh_raw_miss(?:_rlog)?)\(int (_\d+), int (_\d+), (const )?device _\d+& \w+(, device _\d+& \w+)?\)\n\{', out)
            self.assertTrue(m, out[:3000])
            self.assertNotIn('always_inline))\nint dmsh_raw_miss', out)
            self.assertEqual(out.replace(m.group(0), ''), msl.replace(re.search(r'static inline __attribute__\(\(always_inline\)\)\nint dmsh_raw_miss[^\n]*\n\{', msl).group(0), ''))
        plain = self.msl(raw_regs=True)
        self.assertEqual(dmsh_rewrite.raw_miss_noinline(plain), plain)
        with self.assertRaises(ValueError):
            dmsh_rewrite.raw_miss_noinline('int dmsh_raw_miss(thread uint& a)\n{\n}\n')

    def run_kernel(self, msl, kernel_src, runner, want, what):
        with tempfile.TemporaryDirectory() as w:
            w = Path(w)
            (w / 'r.m').write_text(runner)
            subprocess.run(['clang', '-fobjc-arc', '-framework', 'Metal', '-framework', 'Foundation', str(w / 'r.m'), '-o', str(w / 'r')], check=True, capture_output=True)
            for mode, cmd in (('mac', MAC_METAL), ('relaxed', IOS_LIKE)):
                (w / 'k.metal').write_text(dmsh_rewrite.raw_miss_noinline(msl[:msl.index('kernel void main0')]) + kernel_src)
                r = subprocess.run(cmd + [str(w / 'k.metal'), '-o', str(w / 'k.air')], capture_output=True, text=True)
                self.assertEqual(r.returncode, 0, r.stderr[-3000:])
                subprocess.run(['xcrun', '-sdk', 'macosx', 'metallib', str(w / 'k.air'), '-o', str(w / 'k.metallib')], check=True)
                out = subprocess.run([str(w / 'r'), str(w / 'k.metallib')], capture_output=True, text=True)
                self.assertIn(want, out.stdout, f'{what}, {mode} math: {out.stdout}{out.stderr}')

    @staticmethod
    def decls(h):
        return ('    uint last = 0u;\n' + ('    spvUnsafeArray<uint, 6> range = spvUnsafeArray<uint, 6>({ 0u, 0u, 0u, 0u, 0u, 0u });\n' if h.group(4) else '') +
                ('    spvUnsafeArray<uint, 3> vec;\n' if h.group(5) else ''))

    @staticmethod
    def args(h, log=False): return ', map' + (', log' if log else '') + ', last' + (', range' if h.group(4) else '') + (', vec' if h.group(5) else '')

    @unittest.skipUnless(shutil.which('xcrun') and sys.platform == 'darwin', 'needs Metal')
    def test_reads_on_gpu(self):   # test_dmsh_raw_last's walk, each lane 16 lookups that hit, leave and come back to pools
        for opt in ({}, dict(raw_regs=True), dict(raw_regs=True, raw_loop=True)):
            for outline in (False, True):
                msl = self.msl(raw_outline=outline, **opt)
                h = self.helpers(msl)[0]
                k = (f'kernel void k(const device {h.group(2)}& map [[buffer(0)]], const device uint2* addr [[buffer(1)]], device int* out [[buffer(2)]], uint id [[thread_position_in_grid]])\n'
                     '{\n' + self.decls(h) + '    for (int s = 0; s < 16; s++)\n    {\n        int lo = int(addr[id * 16 + s].x), hi = int(addr[id * 16 + s].y);\n'
                     f'        out[id * 16 + s] = {h.group(1)}(lo, hi{self.args(h)});\n    }}\n}}\n')
                self.run_kernel(msl, k, WALK, 'bad 0 of 1024', f'{opt} outline {outline}')

    @unittest.skipUnless(shutil.which('xcrun') and sys.platform == 'darwin', 'needs Metal')
    def test_vector_reads_on_gpu(self):   # test_dmsh_raw_last.RawVector's check: word 0, and words 1..3 the next three of its pool, or all four 0 where it reads no pool
        for opt in ({}, dict(raw_regs=True)):
            for outline in (False, True):
                msl = self.msl(VECTOR, raw_outline=outline, **opt)
                h = [m for m in self.helpers(msl) if m.group(5)][0]
                k = (f'kernel void k(const device {h.group(2)}& map [[buffer(0)]], const device uint2* addr [[buffer(1)]], device int* out [[buffer(2)]], uint id [[thread_position_in_grid]])\n'
                     '{\n' + self.decls(h) + '    for (int s = 0; s < 16; s++)\n    {\n        int lo = int(addr[id * 16 + s].x), hi = int(addr[id * 16 + s].y);\n'
                     f'        vec[0] = vec[1] = vec[2] = 0xdeadu; int w = {h.group(1)}(lo, hi{self.args(h)});\n'
                     '        out[id * 16 + s] = (w == 0 && vec[0] == 0u && vec[1] == 0u && vec[2] == 0u) || (vec[0] == uint(w) + 1u && vec[1] == uint(w) + 2u && vec[2] == uint(w) + 3u) ? w : int(0xdead);\n    }\n}\n')
                self.run_kernel(msl, k, WALK, 'bad 0 of 1024', f'vector {opt} outline {outline}')

    @unittest.skipUnless(shutil.which('xcrun') and sys.platform == 'darwin', 'needs Metal')
    def test_reads_and_logs_on_gpu(self):   # test_dmsh_raw_log's pools: two resident, a stub, one never read; each read entry's bit set once, the write bitmap empty
        for opt in (dict(raw_read_log=True), dict(raw_read_log=True, raw_regs=True)):
            for outline in (False, True):
                msl = self.msl((s2r_tid(9), s2r_tid(5), LDG, STORE), raw_outline=outline, **opt)
                h = self.helpers(msl)[0]
                self.assertTrue(h.group(3), msl[:2000])
                k = (f'kernel void k(device {h.group(2)}& map [[buffer(0)]], device {h.group(3)}& log [[buffer(1)]], const device uint2* addr [[buffer(2)]], device uint* out [[buffer(3)]], uint id [[thread_position_in_grid]])\n'
                     '{\n' + self.decls(h) + '    for (int s = 0; s < 8; s++)\n    {\n        int lo = int(addr[id * 8 + s].x), hi = int(addr[id * 8 + s].y);\n'
                     f'        out[id * 8 + s] = uint({h.group(1)}(lo, hi{self.args(h, log=True)}));\n    }}\n}}\n')
                self.run_kernel(msl, k, LOG, 'bad 0 of 512, write bits 0, read bits 3 (word 0: 0xe)', f'log {opt} outline {outline}')


if __name__ == '__main__':
    unittest.main()
