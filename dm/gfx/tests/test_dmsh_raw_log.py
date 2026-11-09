#!/usr/bin/env python3
"""The raw global memory read log (GlobalToStorage GmemReadLogWords, the job's raw_read_log; the profile key shader_raw_read_log): through the offline translator (dmsh_xlate, arch sm86) a raw load's
helper takes the log buffer too and sets the bit of the pool table entry it chose, past the write bitmap's words, only when the hint or the search chose it; without the option the helper is the old one;
and on this Mac's GPU, with a table of two resident pools and a stub (an entry whose delta points into a page of zeros, nvn_mtl.m DM_NVN_GMEM_MODE=learned), a load of a resident pool reads its bytes, a
load of the stub reads 0, each sets exactly its own entry's read bit once, a pool nobody reads sets none, and the write bitmap stays empty.
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
from test_dmsh_raw_last import MAC_METAL, LDG, STORE, EXIT, Translated, inst, waiting, s2r_tid   # noqa: E402

LOG_HELPER = re.compile(r'(?m)^int (_\d+)\(thread const int& _\d+, thread const int& _\d+, device (_\d+)& \w+, device (_\d+)& \w+, thread uint& (_\d+)\)\n\{\n')
PLAIN_HELPER = re.compile(r'(?m)^int (_\d+)\(thread const int& _\d+, thread const int& _\d+, const device (_\d+)& \w+, thread uint& (_\d+)\)\n\{\n')

# Pools A (entry 1), B (entry 2, a stub), C (entry 3) and D (entry 4, never read), disjoint 4 KiB ranges. A, C and D are real buffers; B's delta points into the zero page, whose bytes are 0
RUNNER = '''#import <Metal/Metal.h>
#include <stdio.h>
#include <string.h>
enum { POOLS = 4, WORDS = 1024, LANES = 64, STEPS = 8, ENTRIES = 8192 };
static const uint64_t GUEST[POOLS] = {0x10000000ull, 0x10001000ull, 0x10002000ull, 0x10003000ull};
static uint32_t value(int p, uint64_t off) { return (uint32_t)(p + 1) << 24 | (uint32_t)(off / 4); }
int main(int ac, char **av) { @autoreleasepool {
    id<MTLDevice> d = MTLCreateSystemDefaultDevice(); NSError *e = nil;
    id<MTLLibrary> l = [d newLibraryWithURL:[NSURL fileURLWithPath:@(av[1])] error:&e]; if (!l) { puts(e.description.UTF8String); return 2; }
    id<MTLComputePipelineState> ps = [d newComputePipelineStateWithFunction:[l newFunctionWithName:@"k"] error:&e]; if (!ps) { puts(e.description.UTF8String); return 2; }
    id<MTLBuffer> pool[POOLS], zero = [d newBufferWithLength:WORDS * 4 options:MTLResourceStorageModeShared], map = [d newBufferWithLength:ENTRIES * 32 options:MTLResourceStorageModeShared];
    id<MTLBuffer> log = [d newBufferWithLength:ENTRIES / 8 * 2 options:MTLResourceStorageModeShared];
    memset(zero.contents, 0, WORDS * 4); memset(log.contents, 0, ENTRIES / 8 * 2);
    uint32_t *t = map.contents; memset(t, 0, ENTRIES * 32); for (int k = 1; k < ENTRIES; k++) memset(t + k * 8, 0xff, 8);
    for (int p = 0; p < POOLS; p++) {
        pool[p] = [d newBufferWithLength:WORDS * 4 options:MTLResourceStorageModeShared]; uint32_t *w = pool[p].contents; for (int i = 0; i < WORDS; i++) w[i] = value(p, i * 4);
        uint64_t s = GUEST[p], end = s + WORDS * 4, delta = (p == 1 ? zero.gpuAddress : pool[p].gpuAddress) - s, *ent = (uint64_t *)(t + (p + 1) * 8); ent[0] = s; ent[1] = end; ent[2] = delta;
        if (p == 1) t[(p + 1) * 8 + 7] = 1;
    }
    // each lane: A, A again (the same entry), B, C, B again, A, C, an address in no pool
    static const int64_t SEQ[STEPS][2] = {{0, 0}, {0, 4}, {1, 8}, {2, 16}, {1, 12}, {0, 20}, {2, 24}, {-1, 0x20000000}};
    id<MTLBuffer> addr = [d newBufferWithLength:LANES * STEPS * 8 options:MTLResourceStorageModeShared], out = [d newBufferWithLength:LANES * STEPS * 4 options:MTLResourceStorageModeShared];
    uint64_t *a = addr.contents; uint32_t want[LANES * STEPS];
    for (int lane = 0; lane < LANES; lane++) for (int s = 0; s < STEPS; s++) {
        int64_t p = SEQ[s][0]; uint64_t off = (uint64_t)SEQ[s][1] + (uint64_t)(lane * 8) % (WORDS * 4 - 64);
        a[lane * STEPS + s] = p < 0 ? (uint64_t)SEQ[s][1] : GUEST[p] + off; want[lane * STEPS + s] = p < 0 || p == 1 ? 0 : value((int)p, off);
    }
    id<MTLCommandQueue> q = [d newCommandQueue]; id<MTLCommandBuffer> c = [q commandBuffer]; id<MTLComputeCommandEncoder> ce = [c computeCommandEncoder];
    [ce setComputePipelineState:ps]; [ce setBuffer:map offset:0 atIndex:0]; [ce setBuffer:log offset:0 atIndex:1]; [ce setBuffer:addr offset:0 atIndex:2]; [ce setBuffer:out offset:0 atIndex:3];
    for (int p = 0; p < POOLS; p++) [ce useResource:pool[p] usage:MTLResourceUsageRead]; [ce useResource:zero usage:MTLResourceUsageRead];
    [ce dispatchThreads:MTLSizeMake(LANES, 1, 1) threadsPerThreadgroup:MTLSizeMake(32, 1, 1)]; [ce endEncoding]; [c commit]; [c waitUntilCompleted];
    const uint32_t *got = out.contents; int bad = 0;
    for (int i = 0; i < LANES * STEPS; i++) if (got[i] != want[i]) { if (bad++ < 8) printf("lane %d step %d: read 0x%x, want 0x%x\\n", i / STEPS, i % STEPS, got[i], want[i]); }
    const uint32_t *lg = log.contents; int wset = 0, rset = 0; uint32_t rbits = 0;
    for (int i = 0; i < ENTRIES / 32; i++) { wset += __builtin_popcount(lg[i]); rset += __builtin_popcount(lg[ENTRIES / 32 + i]); }
    rbits = lg[ENTRIES / 32];
    printf("bad %d of %d, write bits %d, read bits %d (word 0: 0x%x)\\n", bad, LANES * STEPS, wset, rset, rbits); return 0;
} }
'''


@unittest.skipUnless(os.environ.get('DMSH_TEST_XLATE'), 'set DMSH_TEST_XLATE to the offline translator')
class RawLog(Translated):
    def msl(self, **opt):
        code = (s2r_tid(9), s2r_tid(5), LDG, STORE)
        return self.translate(b''.join(inst(*waiting(i)) for i in code) + inst(*EXIT), shared=0x1000, **opt)

    def test_without_the_option_the_helper_is_the_old_one(self):
        msl = self.msl()
        self.assertTrue(PLAIN_HELPER.search(msl), msl[:2000])
        self.assertFalse(LOG_HELPER.search(msl))
        self.assertNotIn('atomic_fetch_or', msl)

    def test_with_the_option_a_load_logs_its_entry_past_the_write_bitmap(self):
        msl = self.msl(raw_read_log=True)
        m = LOG_HELPER.search(msl)
        self.assertTrue(m, msl[:2000])
        helper = msl[m.end():msl.index('\n}\n', m.end())]
        self.assertEqual(len(re.findall(r'atomic_fetch_or_explicit', helper)), 1)   # one log per helper, the load's
        self.assertRegex(helper, r'\+ 256;')   # GmemReadLogWords: 8,192 entries / 32
        self.assertLess(helper.index('>> uint(21)'), helper.index('atomic_fetch_or_explicit'))   # the hint or the search chose the entry before it is logged
        # the entry the helper chose last is not logged again: the logging comes after the "last entry holds it" jump
        self.assertLess(helper.index(m.group(4)), helper.index('atomic_fetch_or_explicit'))

    @unittest.skipUnless(shutil.which('xcrun') and sys.platform == 'darwin', 'needs Metal')
    def test_reads_and_logs_on_gpu(self):
        msl = self.msl(raw_read_log=True)
        m = LOG_HELPER.search(msl)
        kernel = (msl[:msl.index('kernel void main0')] +
                  f'kernel void k(device {m.group(2)}& map [[buffer(0)]], device {m.group(3)}& log [[buffer(1)]], const device uint2* addr [[buffer(2)]], device uint* out [[buffer(3)]], uint id [[thread_position_in_grid]])\n'
                  '{\n    uint last = 0u;\n    for (int s = 0; s < 8; s++)\n    {\n        int lo = int(addr[id * 8 + s].x), hi = int(addr[id * 8 + s].y);\n'
                  f'        out[id * 8 + s] = uint({m.group(1)}(lo, hi, map, log, last));\n    }}\n}}\n')
        with tempfile.TemporaryDirectory() as w:
            w = Path(w)
            (w / 'k.metal').write_text(kernel)
            r = subprocess.run(MAC_METAL + [str(w / 'k.metal'), '-o', str(w / 'k.air')], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stderr[-3000:])
            subprocess.run(['xcrun', '-sdk', 'macosx', 'metallib', str(w / 'k.air'), '-o', str(w / 'k.metallib')], check=True)
            (w / 'r.m').write_text(RUNNER)
            subprocess.run(['clang', '-fobjc-arc', '-framework', 'Metal', '-framework', 'Foundation', str(w / 'r.m'), '-o', str(w / 'r')], check=True, capture_output=True)
            out = subprocess.run([str(w / 'r'), str(w / 'k.metallib')], capture_output=True, text=True)
            self.assertIn('bad 0 of 512, write bits 0, read bits 3 (word 0: 0xe)', out.stdout, out.stdout + out.stderr)   # entries 1, 2 and 3: 0b1110; entry 4 (D) unread


if __name__ == '__main__':
    unittest.main()
