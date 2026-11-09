#!/usr/bin/env python3
"""Two cheaper forms of the raw global memory lookup (GlobalToStorage.TryGenerateRawStorageOp), each behind its own profile key:
- shader_raw_loop (the job's raw_loop): the binary search over the pool table's starts is a loop of the same 13 steps instead of 13 unrolled steps at every lookup of a shader;
- shader_raw_regs (the job's raw_regs): the entry a helper chose last keeps its start, end and delta words in private words of the invocation (zero at the start, as entry 0 is
  empty), written when the hint or the search chooses, so a hit reads no table word.
Through the offline translator (dmsh_xlate, arch sm86): without the options the helper is the old one; with raw_loop it has a loop and no unrolled steps; with raw_regs it takes a
6-word array beside its last entry and a hit's range test reads it; and on this Mac's GPU each form reads what the pool table names over test_dmsh_raw_last's run of addresses that hit,
leave and come back to pools (adjacent pools, a gap, a hinted chunk above 4 GiB), with both options together too.
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
from test_dmsh_raw_last import MAC_METAL, LDG, STORE, EXIT, RUNNER, HELPER, Translated, inst, waiting, s2r_tid   # noqa: E402

REGS_HELPER = re.compile(r'(?m)^int (_\d+)\(thread const int& _\d+, thread const int& _\d+, const device (_\d+)& \w+, thread uint& (_\d+), thread spvUnsafeArray<uint, 6>& (_\d+)\)\n\{\n')


@unittest.skipUnless(os.environ.get('DMSH_TEST_XLATE'), 'set DMSH_TEST_XLATE to the offline translator')
class RawCompact(Translated):
    def msl(self, **opt):
        code = (s2r_tid(9), s2r_tid(5), LDG, STORE, (LDG[0], LDG[1] | 4 << 40), STORE)   # test_dmsh_raw_last's two loads
        return self.translate(b''.join(inst(*waiting(i)) for i in code) + inst(*EXIT), shared=0x1000, **opt)

    @staticmethod
    def helper(msl, m): return msl[m.end():msl.index('\n}\n', m.end())]

    def test_without_the_options_the_helper_is_the_old_one(self):
        msl = self.msl()
        self.assertEqual(msl, self.msl(raw_loop=False, raw_regs=False))
        m = HELPER.search(msl)
        self.assertTrue(m)
        self.assertEqual(self.helper(msl, m).count('+ 4096;'), 1)   # the unrolled search's first step

    def test_loop_search(self):
        plain, msl = self.msl(), self.msl(raw_loop=True)
        m = HELPER.search(msl)
        self.assertTrue(m, msl[:3000])
        h = self.helper(msl, m)
        self.assertNotIn('+ 4096;', h)
        self.assertRegex(h, r'\b(for|do|while)\b')
        self.assertLess(len(h), len(self.helper(plain, HELPER.search(plain))) * 0.7)

    def test_range_words(self):
        msl = self.msl(raw_regs=True)
        m = REGS_HELPER.search(msl)
        self.assertTrue(m, msl[:3000])
        h, rng = self.helper(msl, m), m.group(4)
        first_if = h.index('if (')
        self.assertRegex(h[:first_if], re.escape(rng) + r'\[1\]')   # the hit's test reads the private words, not the table
        self.assertNotRegex(h[:first_if], r'\w+\._m0\[')
        self.assertEqual(len(re.findall(re.escape(rng) + r'\[\d\] = ', h)), 6)   # a choice writes all six
        main = msl[msl.index('kernel void main0'):]
        self.assertRegex(main, r'spvUnsafeArray<uint, 6> _\d+ = spvUnsafeArray<uint, 6>\(\{ 0u, 0u, 0u, 0u, 0u, 0u \}\);')   # zero at the start

    @unittest.skipUnless(shutil.which('xcrun') and sys.platform == 'darwin', 'needs Metal')
    def test_reads_on_gpu(self):
        for opt in (dict(raw_loop=True), dict(raw_regs=True), dict(raw_loop=True, raw_regs=True)):
            msl = self.msl(**opt)
            regs = opt.get('raw_regs')
            m = (REGS_HELPER if regs else HELPER).search(msl)
            self.assertTrue(m, opt)
            decl = '    uint last = 0u;\n' + ('    spvUnsafeArray<uint, 6> range = spvUnsafeArray<uint, 6>({ 0u, 0u, 0u, 0u, 0u, 0u });\n' if regs else '')
            kernel = (msl[:msl.index('kernel void main0')] +
                      f'kernel void k(const device {m.group(2)}& map [[buffer(0)]], const device uint2* addr [[buffer(1)]], device int* out [[buffer(2)]], uint id [[thread_position_in_grid]])\n'
                      '{\n' + decl + '    for (int s = 0; s < 16; s++)\n    {\n        int lo = int(addr[id * 16 + s].x), hi = int(addr[id * 16 + s].y);\n'
                      f'        out[id * 16 + s] = {m.group(1)}(lo, hi, map, last{", range" if regs else ""});\n    }}\n}}\n')
            with tempfile.TemporaryDirectory() as w:
                w = Path(w)
                (w / 'k.metal').write_text(kernel)
                r = subprocess.run(MAC_METAL + [str(w / 'k.metal'), '-o', str(w / 'k.air')], capture_output=True, text=True)
                self.assertEqual(r.returncode, 0, r.stderr[-3000:])
                subprocess.run(['xcrun', '-sdk', 'macosx', 'metallib', str(w / 'k.air'), '-o', str(w / 'k.metallib')], check=True)
                (w / 'r.m').write_text(RUNNER)
                subprocess.run(['clang', '-fobjc-arc', '-framework', 'Metal', '-framework', 'Foundation', str(w / 'r.m'), '-o', str(w / 'r')], check=True, capture_output=True)
                out = subprocess.run([str(w / 'r'), str(w / 'k.metallib')], capture_output=True, text=True)
                self.assertIn('bad 0 of 1024', out.stdout, f'{opt}: {out.stdout}{out.stderr}')


if __name__ == '__main__':
    unittest.main()
