#!/usr/bin/env python3
"""The raw global memory page table (GlobalToStorage.TryGenerateRawStorageOp with the job's raw_ptable; the profile key shader_raw_ptable; dmsh_abi.h DMSH_GMEM_PT_*): through the offline translator (dmsh_xlate,
arch sm86) a raw lookup reads the page table the host appends to the pool table, one 64-bit entry per 16 KiB guest page, and searches only where the entry is 0; without the key the helpers are the old ones.
On this Mac's GPU, with a table laid out as nvn_mtl.m gmem_map lays it out, every address resolves to what the search resolves it to: two pools sharing a 16 KiB page (each pool's part read from its own
buffer), a pool's partial last page, a page in no pool, an address above 4 GiB, a stub (learned mode's page of zeros), addresses below and above the table and one at 2^46 + a pooled address (whose 32-bit
page number would alias). The page table's entries point at mirror buffers whose words carry a tag, so the run also shows which way each address went: the whole pages of one entry through the page table, the
others through the search. The read log names each entry read once (a load), the write log each entry written (an ATOMG.CAS through the same lookup), and a CAS writes where the lookup points and nowhere else.
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

CAS = (0x000fe200001ee116, 0x00000013140673a9)   # ATOMG.E.CAS.STRONG.GPU PT, R6, [R20], R19, R22: an address the translator traces to no storage buffer
LOAD_HELPER = re.compile(r'(?m)^int (_\d+)\(thread const int& _\d+, thread const int& _\d+, (?:const )?device (_\d+)& \w+(, device _\d+& \w+)?, thread uint& _\d+(, thread spvUnsafeArray<uint, 6>& _\d+)?\)\n\{\n')
CAS_HELPER = re.compile(r'(?m)^int (_\d+)\(thread const int& _\d+, thread const int& _\d+, thread const int& _\d+, thread const int& _\d+, device (_\d+)& \w+(, device _\d+& \w+), thread uint& _\d+(, thread spvUnsafeArray<uint, 6>& _\d+)?\)\n\{\n')

# Pools (entries 1..5): A and B share the 16 KiB page at 0x10008000 (A to 0x1000A000, B from there); a gap; C above 4 GiB; D a stub with a partial first page; E never touched. Each pool's buffer covers its
# pages from its first page's start, words outside the pool poisoned, so a page read through the other pool's buffer shows. The page table points the whole pages of one entry at a mirror of the pool whose
# words carry TAG (a stub's into the page of zeros, a word of its own for each address of the stub, as the search's delta gives it), as gmem_pt_fill does, and leaves the others 0. The stub's writes, through
# the search on its partial page and through the table on its whole page, must not land on each other's words: each reads 0 before it writes
RUNNER = r'''#import <Metal/Metal.h>
#include <stdio.h>
#include <string.h>
enum { POOLS = 5, LANES = 64, STEPS = 16, ENTRIES = 8192, TAG = 0x00800000 };
static const struct { uint64_t lo, hi; int stub; } P[POOLS] = {{0x10000000ull, 0x1000A000ull, 0}, {0x1000A000ull, 0x10014000ull, 0}, {0x200040000ull, 0x200048000ull, 0}, {0x200049000ull, 0x200050000ull, 1}, {0x200060000ull, 0x200064000ull, 0}};
static uint64_t pstart(int p) { return P[p].lo & ~0x3fffull; }
static uint64_t pend(int p) { return (P[p].hi + 0x3fff) & ~0x3fffull; }
static uint32_t value(int p, uint64_t a) { return (uint32_t)(p + 1) << 24 | (uint32_t)((a - P[p].lo) / 4); }
static int pool_of(uint64_t a) { for (int p = 0; p < POOLS; p++) if (a >= P[p].lo && a < P[p].hi) return p; return -1; }
static int fast(uint64_t a) { int p = pool_of(a); uint64_t pg = a & ~0x3fffull; return p >= 0 && pg >= P[p].lo && pg + 0x4000 <= P[p].hi; }
static int search_entry(uint64_t a) { int k = 0; for (int p = 0; p < POOLS; p++) if (P[p].lo <= a) k = p + 1; return k; }   // the last entry starting at or below a (the search's choice)
// Which way a lane's access goes: 1 the page table (the mirror), 0 the entry's delta (the pool's buffer), -1 nowhere (no pool, or a stub: zeros). With the range words (regs) an access in the entry the
// lane chose last takes that entry's delta; else a whole page of one entry takes the page table and the rest the search, which records its choice
static int way(uint64_t a, int regs, int *last) {
    int e = pool_of(a) + 1, w;
    if (regs && e && e == *last) w = 0;
    else if (fast(a)) { w = 1; *last = e; }
    else { w = 0; *last = search_entry(a); }
    return e && !P[e - 1].stub ? w : -1;
}
int main(int ac, char **av) { @autoreleasepool {
    int cas = ac > 2 && strstr(av[2], "cas") != NULL, regs = ac > 2 && strstr(av[2], "regs") != NULL;
    id<MTLDevice> d = MTLCreateSystemDefaultDevice(); NSError *e = nil;
    id<MTLLibrary> l = [d newLibraryWithURL:[NSURL fileURLWithPath:@(av[1])] error:&e]; if (!l) { puts(e.description.UTF8String); return 2; }
    id<MTLComputePipelineState> ps = [d newComputePipelineStateWithFunction:[l newFunctionWithName:@"k"] error:&e]; if (!ps) { puts(e.description.UTF8String); return 2; }
    id<MTLBuffer> buf[POOLS], mir[POOLS], zero = [d newBufferWithLength:65536 options:MTLResourceStorageModeShared];
    memset(zero.contents, 0, 65536);
    for (int p = 0; p < POOLS; p++) {
        uint64_t n = (pend(p) - pstart(p)) / 4;
        buf[p] = [d newBufferWithLength:n * 4 options:MTLResourceStorageModeShared]; mir[p] = [d newBufferWithLength:n * 4 options:MTLResourceStorageModeShared];
        uint32_t *w = buf[p].contents, *m = mir[p].contents;
        for (uint64_t i = 0; i < n; i++) { uint64_t a = pstart(p) + 4 * i; int in = a >= P[p].lo && a < P[p].hi; w[i] = in ? value(p, a) : 0xBAD00000u | (uint32_t)i; m[i] = in ? value(p, a) | TAG : 0xBAD10000u | (uint32_t)i; }
        if ((buf[p].gpuAddress | mir[p].gpuAddress | zero.gpuAddress) & 0x3fff) { puts("a buffer's GPU address is not 16 KiB aligned"); return 3; }
    }
    uint64_t first = P[0].lo >> 14, n = ((P[POOLS - 1].hi + 0x3fff) >> 14) - first;
    id<MTLBuffer> map = [d newBufferWithLength:ENTRIES * 32 + 16 + (n + 1) * 8 options:MTLResourceStorageModeShared];
    uint8_t *mb = map.contents; memset(mb, 0, map.length); for (int k = 1; k < ENTRIES; k++) memset(mb + k * 32, 0xff, 8);
    uint32_t head[4] = {(uint32_t)first, (uint32_t)n, 0, 0}; memcpy(mb + ENTRIES * 32, head, 16);
    uint64_t *pt = (uint64_t *)(mb + ENTRIES * 32 + 16);
    for (int p = 0; p < POOLS; p++) {
        uint64_t ent[3] = {P[p].lo, P[p].hi, P[p].stub ? zero.gpuAddress - P[p].lo : buf[p].gpuAddress - pstart(p)}; memcpy(mb + (p + 1) * 32, ent, 24);
        if (P[p].stub) { uint32_t one = 1; memcpy(mb + (p + 1) * 32 + 28, &one, 4); }
        for (uint64_t pg = (P[p].lo + 0x3fff) & ~0x3fffull; pg + 0x4000 <= P[p].hi; pg += 0x4000) pt[(pg >> 14) - first] = ((P[p].stub ? zero.gpuAddress : mir[p].gpuAddress) + (pg - pstart(p))) | (uint64_t)(p + 1);
    }
    id<MTLBuffer> log = [d newBufferWithLength:ENTRIES / 8 * 2 options:MTLResourceStorageModeShared]; memset(log.contents, 0, log.length);
    // each lane: A, A again, A's part and B's part of the shared page, B, a gap, C above 4 GiB, D's partial page before D, D's partial page in D, D's whole page, below the table, above it,
    // 2^46 + A's address, B's last page, A's second page, C's second page
    static const uint64_t SEQ[STEPS] = {0x10000000ull, 0x10000100ull, 0x10008000ull, 0x1000A000ull, 0x1000C000ull, 0x10018000ull, 0x200040000ull, 0x200048000ull, 0x200049000ull, 0x20004C000ull,
        0x0FFFC000ull, 0x300000000ull, (1ull << 46) + 0x10000000ull, 0x10010000ull, 0x10004000ull, 0x200044000ull};
    id<MTLBuffer> addr = [d newBufferWithLength:LANES * STEPS * 8 options:MTLResourceStorageModeShared], out = [d newBufferWithLength:LANES * STEPS * 4 options:MTLResourceStorageModeShared];
    id<MTLBuffer> cv = [d newBufferWithLength:LANES * STEPS * 8 options:MTLResourceStorageModeShared];
    uint64_t *a = addr.contents; uint32_t *c = cv.contents; uint32_t want[LANES * STEPS]; int ways[LANES * STEPS], writes = 0;
    for (int lane = 0; lane < LANES; lane++) { int last = 0;
        for (int s = 0; s < STEPS; s++) {
            int i = lane * STEPS + s; a[i] = SEQ[s] + (uint64_t)lane * 8 + (s == 1 ? 4 : 0); ways[i] = way(a[i], regs, &last);
            want[i] = ways[i] < 0 ? 0 : value(pool_of(a[i]), a[i]) | (ways[i] ? TAG : 0);
            c[2 * i] = want[i]; c[2 * i + 1] = 0xC0000000u | (uint32_t)lane << 8 | (uint32_t)s;   // CAS: compare with what the lookup reads, swap in a marker
            writes += ways[i] >= 0;
        } }
    id<MTLCommandQueue> q = [d newCommandQueue]; id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
    [ce setComputePipelineState:ps]; [ce setBuffer:map offset:0 atIndex:0]; [ce setBuffer:log offset:0 atIndex:1]; [ce setBuffer:addr offset:0 atIndex:2]; [ce setBuffer:out offset:0 atIndex:3]; [ce setBuffer:cv offset:0 atIndex:4];
    for (int p = 0; p < POOLS; p++) { [ce useResource:buf[p] usage:MTLResourceUsageRead | MTLResourceUsageWrite]; [ce useResource:mir[p] usage:MTLResourceUsageRead | MTLResourceUsageWrite]; }
    [ce useResource:zero usage:MTLResourceUsageRead | MTLResourceUsageWrite];
    [ce dispatchThreads:MTLSizeMake(LANES, 1, 1) threadsPerThreadgroup:MTLSizeMake(32, 1, 1)]; [ce endEncoding]; [cb commit]; [cb waitUntilCompleted];
    if (cb.error) { printf("GPU error %s\n", cb.error.description.UTF8String); return 4; }
    const uint32_t *got = out.contents; int bad = 0;
    for (int i = 0; i < LANES * STEPS; i++) if (got[i] != want[i]) { if (bad++ < 8) printf("lane %d step %d: address 0x%llx read 0x%x, want 0x%x\n", i / STEPS, i % STEPS, a[i], got[i], want[i]); }
    int changed = 0, misplaced = 0;   // CAS: each marker lands where its way points (the mirror or the pool's buffer), and no other word changes
    for (int p = 0; p < POOLS; p++) { uint64_t nw = (pend(p) - pstart(p)) / 4; const uint32_t *w = buf[p].contents, *m = mir[p].contents;
        for (uint64_t k = 0; k < nw; k++) { uint64_t aa = pstart(p) + 4 * k; int in = aa >= P[p].lo && aa < P[p].hi;
            uint32_t w0 = in ? value(p, aa) : 0xBAD00000u | (uint32_t)k, m0 = in ? value(p, aa) | TAG : 0xBAD10000u | (uint32_t)k, we = w0, me = m0;
            if (cas && in) for (int i = 0; i < LANES * STEPS; i++) if (a[i] == aa && ways[i] >= 0) { if (ways[i]) me = c[2 * i + 1]; else we = c[2 * i + 1]; }
            changed += (w[k] != w0) + (m[k] != m0); misplaced += (w[k] != we) + (m[k] != me); } }
    const uint32_t *lg = log.contents; int wset = 0, rset = 0;
    for (int i = 0; i < ENTRIES / 32; i++) { wset += __builtin_popcount(lg[i]); rset += __builtin_popcount(lg[ENTRIES / 32 + i]); }
    printf("bad %d of %d, changed %d of %d, misplaced %d, write bits %d (0x%x), read bits %d (0x%x)\n", bad, LANES * STEPS, changed, cas ? writes : 0, misplaced, wset, lg[0], rset, lg[ENTRIES / 32]);
    return 0;
} }
'''


@unittest.skipUnless(os.environ.get('DMSH_TEST_XLATE'), 'set DMSH_TEST_XLATE to the offline translator')
class RawPageTable(Translated):
    def load_msl(self, **opt):
        code = (s2r_tid(9), s2r_tid(5), LDG, STORE, (LDG[0], LDG[1] | 4 << 40), STORE)   # test_dmsh_raw_last's two loads
        return self.translate(b''.join(inst(*waiting(i)) for i in code) + inst(*EXIT), shared=0x1000, **opt)

    def cas_msl(self, **opt):
        code = (s2r_tid(9), s2r_tid(20), s2r_tid(19), s2r_tid(22), CAS)
        return self.translate(b''.join(inst(*waiting(i)) for i in code) + inst(*EXIT), shared=0x1000, **opt)

    @staticmethod
    def helper(msl, m): return msl[m.end():msl.index('\n}\n', m.end())]

    def test_without_the_key_nothing_changes(self):
        for opt in ({}, dict(raw_regs=True), dict(raw_loop=True, raw_regs=True), dict(raw_read_log=True, raw_regs=True)):
            self.assertEqual(self.load_msl(**opt), self.load_msl(**opt, raw_ptable=False), opt)
            self.assertNotIn('65536', self.load_msl(**opt))

    def test_the_page_table_first(self):
        msl = self.load_msl(raw_ptable=True)
        m = LOAD_HELPER.search(msl)
        self.assertTrue(m, msl[:3000])
        self.assertIsNone(m.group(4), 'no range words without shader_raw_regs')
        h = self.helper(msl, m)
        self.assertIn('= 65536 + 1;', h)   # the header's page count, past the 8,192 entries of 8 words
        self.assertIn('+ 65540;', h)   # the page entries after the 4-word header
        self.assertIn('& 16383;', h)   # the entry index in the low 14 bits
        self.assertNotIn('>> uint(21)', h)   # no 2 MiB hint: the page table replaces it
        self.assertRegex(h, r'\b(do|while|for)\b')   # the search, for what the table leaves to it, as the loop
        self.assertLess(h.index('65536'), h.index('do'))
        regs = self.load_msl(raw_ptable=True, raw_regs=True)
        m = LOAD_HELPER.search(regs)
        self.assertTrue(m and m.group(4), regs[:3000])
        h = self.helper(regs, m)
        rng = m.group(4).split('& ')[1]
        self.assertLess(h.index(rng + '[1]'), h.index('65536'))   # with shader_raw_regs the last entry's range is tried first

    def test_a_write_logs_its_entry(self):
        msl = self.cas_msl(raw_ptable=True)
        m = CAS_HELPER.search(msl)
        self.assertTrue(m, msl[:3000])
        h = self.helper(msl, m)
        self.assertEqual(h.count('atomic_fetch_or_explicit'), 1)   # one write-log update, where the page table's way and the search's meet
        self.assertLess(h.index('65536'), h.index('atomic_fetch_or_explicit'))

    def run_gpu(self, msl, m, cas):
        regs = m.group(4) is not None
        log = ', log' if m.group(3) else ''
        call = (f'{m.group(1)}(lo, hi, int(cv[i].x), int(cv[i].y), map, log, last{", range" if regs else ""})' if cas else
                f'{m.group(1)}(lo, hi, map{log}, last{", range" if regs else ""})')
        kernel = (msl[:msl.index('kernel void main0')] +
                  f'kernel void k(device {m.group(2)}& map [[buffer(0)]], device {m.group(2)}& log [[buffer(1)]], const device uint2* addr [[buffer(2)]], device uint* out [[buffer(3)]], const device uint2* cv [[buffer(4)]], uint id [[thread_position_in_grid]])\n'
                  '{\n    uint last = 0u;\n' + ('    spvUnsafeArray<uint, 6> range = spvUnsafeArray<uint, 6>({ 0u, 0u, 0u, 0u, 0u, 0u });\n' if regs else '') +
                  '    for (int s = 0; s < 16; s++)\n    {\n        uint i = id * 16 + s;\n        int lo = int(addr[i].x), hi = int(addr[i].y);\n'
                  f'        out[i] = uint({call});\n    }}\n}}\n')
        with tempfile.TemporaryDirectory() as w:
            w = Path(w)
            (w / 'k.metal').write_text(kernel)
            r = subprocess.run(MAC_METAL + [str(w / 'k.metal'), '-o', str(w / 'k.air')], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stderr[-3000:])
            subprocess.run(['xcrun', '-sdk', 'macosx', 'metallib', str(w / 'k.air'), '-o', str(w / 'k.metallib')], check=True)
            (w / 'r.m').write_text(RUNNER)
            subprocess.run(['clang', '-fobjc-arc', '-framework', 'Metal', '-framework', 'Foundation', str(w / 'r.m'), '-o', str(w / 'r')], check=True, capture_output=True)
            return subprocess.run([str(w / 'r'), str(w / 'k.metallib'), ('cas' if cas else 'load') + ('-regs' if regs else '')], capture_output=True, text=True)

    @unittest.skipUnless(shutil.which('xcrun') and sys.platform == 'darwin', 'needs Metal')
    def test_reads_on_gpu(self):
        for opt in (dict(), dict(raw_regs=True), dict(raw_read_log=True), dict(raw_read_log=True, raw_regs=True), dict(raw_regs=True, raw_loop=True)):
            msl = self.load_msl(raw_ptable=True, **opt)
            m = LOAD_HELPER.search(msl)
            self.assertTrue(m, f'{opt}: {msl[:3000]}')
            out = self.run_gpu(msl, m, cas=False)
            bits = '0x1e' if opt.get('raw_read_log') else '0x0'   # entries 1 to 4 read (A, B, C, the stub D), E not
            self.assertIn(f'bad 0 of 1024, changed 0 of 0, misplaced 0, write bits 0 (0x0), read bits {4 if bits != "0x0" else 0} ({bits})', out.stdout, f'{opt}: {out.stdout}{out.stderr}')

    @unittest.skipUnless(shutil.which('xcrun') and sys.platform == 'darwin', 'needs Metal')
    def test_atomics_on_gpu(self):
        for opt in (dict(), dict(raw_regs=True)):
            msl = self.cas_msl(raw_ptable=True, **opt)
            m = CAS_HELPER.search(msl)
            self.assertTrue(m, f'{opt}: {msl[:3000]}')
            out = self.run_gpu(msl, m, cas=True)
            # 64 lanes x 9 steps in a resident pool; the stub's writes land in the page of zeros, which the host clears (gml_read); entries 1 to 4 written
            self.assertIn('bad 0 of 1024, changed 576 of 576, misplaced 0, write bits 4 (0x1e), read bits 0 (0x0)', out.stdout, f'{opt}: {out.stdout}{out.stderr}')


if __name__ == '__main__':
    unittest.main()
