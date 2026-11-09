// The raw pool table's page table (nvn_mtl.m gmem_pt_span / gmem_pt_fill, dmsh_abi.h DMSH_GMEM_PT_*; shaders built with the profile key shader_raw_ptable): every address resolves to the entry and GPU address the
// search over the table's ranges resolves it to, whatever way the shader goes. Pools from mtl_pool_add over one mapping: two sharing a 16 KiB page, one with partial first and last pages, one overlapping
// another (the table keeps the second's part past the first), a pool smaller than a page, gaps. A sweep of addresses, every 512 bytes and around each boundary, is resolved both ways on the CPU; a GPU kernel
// that looks up as the translated helper does (page table, else the search) reads the words and sets the read log; a table is never changed once built (a submission keeps its version); a deleted pool's
// pages go back to the search. With DM_NVN_GMEM_PT_SHARED=1 (the default) a page two pools share and a pool's partial page point into one of the buffers that touch it (both alias
// the same memory): the GPU reads every pooled word through either way, and a write logged against such a page is learned over its whole pages. Learned mode (DM_NVN_GMEM_MODE=learned!): stubs read zeros through the page table too, and the read log the page table's way sets promotes the same pools. DM_NVN_GMEM_PT=0: the
// header is there with no pages, and every address searches. Also the window a span wider than DM_NVN_GMEM_PT_MAX_MB takes, and entries above 2^46
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(label, c) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } } while (0)
enum { KB = 1024, MB = 1 << 20, ENTRIES = DMSH_GMEM_MAP_ENTRIES };
static uint32_t word_at(uint64_t a) { return (uint32_t)(a * 2654435761u >> 7) | 1u; }   // what the mapping holds at a (never 0)
// The search (GlobalToStorage): the last entry starting at or below a; a hit if a is below its end. *gpu: a + delta
static int search(const uint8_t *t, uint64_t a, uint64_t *gpu, int *stub) {
    int lo = 0;
    for (int step = ENTRIES / 2; step; step >>= 1) { uint64_t s; memcpy(&s, t + (size_t)(lo + step) * DMSH_GMEM_MAP_ENTRY, 8); if (s <= a) lo += step; }
    uint64_t e[3]; uint32_t f; memcpy(e, t + (size_t)lo * DMSH_GMEM_MAP_ENTRY, sizeof e); memcpy(&f, t + (size_t)lo * DMSH_GMEM_MAP_ENTRY + 28, 4);
    if (a >= e[1]) return 0;
    *gpu = a + e[2]; *stub = f != 0; return lo;
}
// The page table's way: 0 = the search decides (entry 0, out of the table, or a page no one entry holds)
static int pt_way(const uint8_t *t, size_t len, uint64_t a, uint64_t *gpu) {
    uint32_t head[2]; memcpy(head, t + DMSH_GMEM_PT_OFF, 8);
    uint32_t page = (uint32_t)(a >> 14), i = page - head[0]; if (i > head[1]) i = head[1]; if (a >> 46) i = head[1];
    if (DMSH_GMEM_PT_OFF + DMSH_GMEM_PT_HEAD + ((size_t)i + 1) * 8 > len) return -1;   // the table is shorter than its header says
    uint64_t e; memcpy(&e, t + DMSH_GMEM_PT_OFF + DMSH_GMEM_PT_HEAD + (size_t)i * 8, 8);
    if (!e) return 0;
    *gpu = (e & ~0x3fffull) | (a & 0x3fff); return (int)(e & 0x3fff);
}
static uint64_t zero_lo, zero_hi; static int shared;
static int touches(const uint8_t *t, int k, uint64_t a) { uint64_t e[2]; memcpy(e, t + (size_t)k * DMSH_GMEM_MAP_ENTRY, 16); uint64_t pg = a & ~0x3fffull; return e[0] < pg + 0x4000 && pg < e[1]; }
// Both ways agree on every address of the sweep: the same entry, the same GPU address (a stub: both in the page of zeros). Returns the addresses the page table resolved
static int agree(id<MTLBuffer> map, const uint64_t *addr, int n, const char *what) {
    const uint8_t *t = map.contents; int bad = 0, fast = 0, short_ = 0;
    for (int i = 0; i < n; i++) {
        uint64_t g1 = 0, g2 = 0; int s1 = 0, k1 = search(t, addr[i], &g1, &s1), k2 = pt_way(t, map.length, addr[i], &g2);
        if (k2 < 0) { short_++; continue; }
        if (!k2) continue;
        fast++;
        int ok = k1 == k2 && (s1 ? g2 >= zero_lo && g2 < zero_hi && g1 >= zero_lo && g1 < zero_hi : g1 == g2);
        if (shared && !ok) {   // a page the entry only touches: its buffer covers the page, so the address goes by that entry's delta (a stub: into the page of zeros)
            uint64_t e[3]; uint32_t f; memcpy(e, t + (size_t)k2 * DMSH_GMEM_MAP_ENTRY, sizeof e); memcpy(&f, t + (size_t)k2 * DMSH_GMEM_MAP_ENTRY + 28, 4);
            ok = touches(t, k2, addr[i]) && (f ? g2 >= zero_lo && g2 < zero_hi : g2 == addr[i] + e[2]) && (!k1 || !s1 || f || 1); }
        if (!ok && bad++ < 6) fprintf(stderr, "%s: address %#llx: search entry %d gpu %#llx, page table entry %d gpu %#llx\n", what, (unsigned long long)addr[i], k1, (unsigned long long)g1, k2, (unsigned long long)g2);
    }
    CHECK(what, bad == 0 && short_ == 0);
    return fast;
}
// The translated helper's lookup on the GPU: the page table, else the search; a read sets the entry's bit in the read log (second half). Out: the word, 0 on a miss
static NSString *const SRC = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "kernel void rd(device const uint* m [[buffer(0)]], device atomic_uint* log [[buffer(1)]], device const ulong* addr [[buffer(2)]], device uint* out [[buffer(3)]], device uint* way [[buffer(4)]], uint id [[thread_position_in_grid]]) {\n"
    "  ulong a = addr[id]; uint lo = uint(a), hi = uint(a >> 32); uint n = m[65537]; uint i = min(((hi << 18) | (lo >> 14)) - m[65536], n); if (hi >= 16384u) i = n;\n"
    "  uint e0 = m[65540 + 2 * i], e1 = m[65540 + 2 * i + 1]; ulong p; uint k;\n"
    "  if (e0 != 0u) { k = e0 & 16383u; p = (ulong(e1) << 32) | ulong((e0 & ~16383u) | (lo & 16383u)); way[id] = 1u; }\n"
    "  else { k = 0u; for (uint s = 4096u; s != 0u; s >>= 1) { uint c = k + s; ulong st = ulong(m[c * 8]) | (ulong(m[c * 8 + 1]) << 32); if (st <= a) k = c; }\n"
    "    ulong en = ulong(m[k * 8 + 2]) | (ulong(m[k * 8 + 3]) << 32); if (a >= en) { out[id] = 0u; way[id] = 2u; return; }\n"
    "    p = a + (ulong(m[k * 8 + 4]) | (ulong(m[k * 8 + 5]) << 32)); way[id] = 0u; }\n"
    "  atomic_fetch_or_explicit(&log[256 + (k >> 5)], 1u << (k & 31), memory_order_relaxed); out[id] = *reinterpret_cast<device const uint*>(p); }\n";
static id<MTLComputePipelineState> g_ps;
static void gpu_read(id<MTLBuffer> map, id<MTLBuffer> log, const uint64_t *addr, int n, uint32_t *out, uint32_t *way) {
    if (!g_ps) { NSError *e = nil; id<MTLLibrary> l = [g_dev newLibraryWithSource:SRC options:nil error:&e]; if (!l) { fprintf(stderr, "%s\n", e.description.UTF8String); abort(); }
        g_ps = [g_dev newComputePipelineStateWithFunction:[l newFunctionWithName:@"rd"] error:&e]; if (!g_ps) abort(); }
    id<MTLBuffer> ab = [g_dev newBufferWithBytes:addr length:(NSUInteger)n * 8 options:MTLResourceStorageModeShared], ob = [g_dev newBufferWithLength:(NSUInteger)n * 4 options:MTLResourceStorageModeShared];
    id<MTLBuffer> wb = [g_dev newBufferWithLength:(NSUInteger)n * 4 options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb = q_cb(); id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
    [ce setComputePipelineState:g_ps]; [ce setBuffer:map offset:0 atIndex:0]; [ce setBuffer:log offset:0 atIndex:1]; [ce setBuffer:ab offset:0 atIndex:2]; [ce setBuffer:ob offset:0 atIndex:3]; [ce setBuffer:wb offset:0 atIndex:4];
    [ce dispatchThreads:MTLSizeMake((NSUInteger)n, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)]; [ce endEncoding]; [cb commit]; [cb waitUntilCompleted];
    CHECK("GPU read has no error", cb.error == nil);
    memcpy(out, ob.contents, (size_t)n * 4); memcpy(way, wb.contents, (size_t)n * 4);
}
static int in_pool(const uint64_t (*P)[2], int np, uint64_t a) { for (int i = 0; i < np; i++) if (a >= P[i][0] && a < P[i][1]) return 1; return 0; }
static int readable(const uint64_t (*P)[2], int np, uint64_t a) {   // what a raw read returns the guest's word for: a pooled address; with shared pages also any address of a page a pool touches
    if (in_pool(P, np, a)) return 1; if (!shared || a >> 46) return 0; uint64_t pg = a & ~0x3fffull;
    for (int i = 0; i < np; i++) if (P[i][0] < pg + 0x4000 && pg < P[i][1]) return 1; return 0; }
// One synthetic entry for the pure functions
static void ent(uint8_t *t, int k, uint64_t lo, uint64_t hi, uint64_t delta, int stub) { uint64_t e[3] = {lo, hi, delta}; memcpy(t + (size_t)k * DMSH_GMEM_MAP_ENTRY, e, sizeof e); uint32_t f = (uint32_t)stub; memcpy(t + (size_t)k * DMSH_GMEM_MAP_ENTRY + 28, &f, 4); }
int main(void) { @autoreleasepool {
    // The pure functions: the span, the window of a wide span, entries above 2^46, and which pages one entry holds
    {
        uint8_t *t = calloc(1, DMSH_GMEM_PT_OFF); for (int k = 1; k < ENTRIES; k++) memset(t + (size_t)k * DMSH_GMEM_MAP_ENTRY, 0xff, 8);
        const uint64_t G = 1ull << 30, B = 0x7000000000ull;
        ent(t, 1, B, B + 0x6000, 0x100000000ull - B, 0);   // pages B (whole), B + 0x4000 (partial)
        ent(t, 2, B + 0x6000, B + 0x10000, 0x200000000ull - B, 0);   // B + 0x4000 shared with entry 1; B + 0x8000, B + 0xC000 whole
        ent(t, 3, B + 0x10000, B + 0x14000, 0x300001000ull - B, 0);   // a whole page whose GPU address is not 16 KiB aligned
        ent(t, 4, B + 0x20000, B + 0x30000, 0x400000000ull - B - 0x20000, 1);   // a stub: four pages into the page of zeros
        ent(t, 5, B + 200 * G, B + 200 * G + 0x4000, 0, 0);   // far away
        ent(t, 6, (1ull << 46) + 0x4000, (1ull << 46) + 0x8000, 0, 0);   // above 2^46: never in the page table
        uint32_t first, n; gmem_pt_span(t, 7, 1ull << 30, &first, &n);
        CHECK("a span that fits: from the first entry's page to the last one's below 2^46", first == (uint32_t)(B >> 14) && n == (uint32_t)((B + 200 * G + 0x4000 - B) >> 14));
        gmem_pt_span(t, 7, 1ull << 20, &first, &n);
        CHECK("a span too wide: the window with the most entry bytes", first == (uint32_t)(B >> 14) && n == 1u << 20);
        gmem_pt_span(t, 7, 0, &first, &n); CHECK("no pages allowed: no page table", n == 0);
        gmem_pt_span(t, 1, 1ull << 20, &first, &n); CHECK("no entries: no page table", n == 0);
        uint64_t *pt = calloc((size_t)(1 << 20) + 1, 8); gmem_pt_info info;
        gmem_pt_fill(pt, t, 7, (uint32_t)(B >> 14), 1u << 20, 0x400000000ull, 0, &info);
        CHECK("entry 1's whole page", pt[0] == (0x100000000ull | 1));
        CHECK("the page entries 1 and 2 share: the search", pt[1] == 0);
        CHECK("entry 2's whole pages", pt[2] == (0x200000000ull + 0x8000 | 2) && pt[3] == (0x200000000ull + 0xC000 | 2));
        CHECK("a page whose GPU address is not aligned: the search", pt[4] == 0 && info.misaligned == 1);
        CHECK("a stub's pages into the page of zeros, one word per address as the search's delta gives", pt[8] == (0x400000000ull | 4) && pt[11] == (0x400000000ull + 0xC000 | 4));
        CHECK("gaps: the search", pt[5] == 0 && pt[7] == 0 && pt[12] == 0);
        CHECK("entries outside the window", info.outside == 1 + 1 && info.fast == 1 + 2 + 4);
        memset(pt, 0, ((size_t)(1 << 20) + 1) * 8);
        gmem_pt_fill(pt, t, 7, (uint32_t)(B >> 14), 1u << 20, 0x400000000ull, 1, &info);
        CHECK("shared: the page entries 1 and 2 share is entry 1's", pt[1] == (0x100000000ull + 0x4000 | 1));
        CHECK("shared: whole pages as before", pt[0] == (0x100000000ull | 1) && pt[2] == (0x200000000ull + 0x8000 | 2) && pt[8] == (0x400000000ull | 4));
        CHECK("shared: gaps still search", pt[5] == 0 && pt[7] == 0 && pt[12] == 0);
        {   // a stub and a resident entry sharing a page: the resident one's buffer, whichever comes first
            uint8_t *u = calloc(1, DMSH_GMEM_PT_OFF); for (int k = 1; k < ENTRIES; k++) memset(u + (size_t)k * DMSH_GMEM_MAP_ENTRY, 0xff, 8);
            ent(u, 1, B, B + 0x2000, 0x400000000ull - B, 1); ent(u, 2, B + 0x2000, B + 0x6000, 0x100000000ull - B, 0); ent(u, 3, B + 0x6000, B + 0x9000, 0x400000000ull - B - 0x6000, 1);
            uint64_t q[4] = {0}; gmem_pt_fill(q, u, 4, (uint32_t)(B >> 14), 3, 0x400000000ull, 1, &info);
            CHECK("shared: a resident entry's buffer before a stub's, either order", q[0] == (0x100000000ull | 2) && q[1] == (0x100000000ull + 0x4000 | 2) && (q[2] & 0x3fff) == 3);
            free(u); }
        free(pt); free(t);
    }
    mtl_init();
    int pt_on = gmem_pt_on(), learned = gmem_learned(); shared = pt_on && gmem_pt_shared();
    // One mapping of 24 MiB, filled; pools over parts of it
    uint8_t *mem = mmap(NULL, 24 * MB, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); if (mem == MAP_FAILED) abort();
    uint64_t m0 = (uint64_t)(uintptr_t)mem; for (uint64_t o = 0; o < 24 * MB; o += 4) *(uint32_t *)(mem + o) = word_at(m0 + o);
    const uint64_t P[][2] = {{m0, m0 + 40 * KB}, {m0 + 40 * KB, m0 + 80 * KB}, {m0 + MB + 4 * KB, m0 + MB + 104 * KB}, {m0 + 4 * MB, m0 + 8 * MB}, {m0 + 6 * MB, m0 + 10 * MB}, {m0 + 16 * MB + 12 * KB, m0 + 16 * MB + 20 * KB}};
    enum { NP = sizeof P / sizeof P[0] };
    for (int i = 0; i < NP; i++) { mtl_pool_add((void *)(uintptr_t)P[i][0], P[i][1] - P[i][0]); mtl_pool_addressed((void *)(uintptr_t)P[i][0], P[i][1] - P[i][0]); }
    // The sweep: every 512 bytes from 64 KiB below to 64 KiB past the mapping's pools, and 4 bytes either side of each pool's ends and of each 16 KiB page boundary near them
    static uint64_t A[200000]; int na = 0;
    for (uint64_t a = m0 - 64 * KB; a < m0 + 17 * MB; a += 512) A[na++] = a;
    for (int i = 0; i < NP; i++) for (int j = 0; j < 2; j++) for (int d = -8; d <= 8; d += 4) { A[na++] = P[i][j] + d; A[na++] = ((P[i][j] + 0x3fff) & ~0x3fffull) + d; A[na++] = (P[i][j] & ~0x3fffull) + d; }
    A[na++] = (1ull << 46) + m0 + 4 * MB;   // its page number in 32 bits is a pooled page's
    for (int i = 0; i < na; i++) if (A[i] < m0 || A[i] >= m0 + 24 * MB) { if (A[i] >> 46) continue; A[i] = m0; }   // only addresses the mapping holds, so a wrong way reads something; the 2^46 one stays
    mtl_sub_begin();
    id<MTLBuffer> map = gmem_map(); CHECK("table made", map != nil);
    { pthread_mutex_lock(&g_mu); id<MTLBuffer> z = gmem_zero(); zero_lo = z.gpuAddress; zero_hi = zero_lo + z.length; pthread_mutex_unlock(&g_mu); }
    uint32_t head[2]; memcpy(head, (uint8_t *)map.contents + DMSH_GMEM_PT_OFF, 8);
    if (!pt_on) {
        CHECK("DM_NVN_GMEM_PT=0: the header is there, with no pages but entry n (0)", head[1] == 0 && map.length == DMSH_GMEM_PT_OFF + DMSH_GMEM_PT_HEAD + 8);
    } else {
        CHECK("the page table covers the pools from the first one's page", head[0] == (uint32_t)(m0 >> 14) && head[1] >= (uint32_t)((P[NP - 1][1] - m0) >> 14));
        CHECK("its buffer holds the n + 1 entries", map.length == DMSH_GMEM_PT_OFF + DMSH_GMEM_PT_HEAD + ((size_t)head[1] + 1) * 8);
    }
    int fast = agree(map, A, na, "every address of the sweep: the page table's way agrees with the search"), whole = 0;
    for (int i = 0; i < na; i++) { uint64_t g, pg = A[i] & ~0x3fffull, e[3]; int s, k = search(map.contents, A[i], &g, &s); if (!k) continue;
        memcpy(e, (const uint8_t *)map.contents + (size_t)k * DMSH_GMEM_MAP_ENTRY, sizeof e); whole += e[0] <= pg && pg + 0x4000 <= e[1] && (s || !((pg + e[2]) & 0x3fff)); }
    if (shared) { whole = 0; for (int i = 0; i < na; i++) { uint64_t pg = A[i] & ~0x3fffull; int hit = 0; for (int j = 0; j < NP && !hit; j++) hit = P[j][0] < pg + 0x4000 && pg < P[j][1]; whole += hit && !(A[i] >> 46); } }
    CHECK(!pt_on ? "every address searches" : shared ? "exactly the addresses in a page a pool touches go the page table's way" : "exactly the addresses whose whole page one entry holds go the page table's way", pt_on ? fast == whole && whole > 0 : fast == 0);
    // Two pools share the page at m0 + 32 KiB, pool 2's first and last pages are partial, pool 5 holds no whole page: the search decides them
    { uint64_t g; const uint8_t *t = map.contents;
      int w = shared ? 1 : 0;
      CHECK(w ? "the shared page goes the table's way" : "the shared page searches", (pt_way(t, map.length, m0 + 36 * KB, &g) > 0) == w && (pt_way(t, map.length, m0 + 44 * KB, &g) > 0) == w);
      CHECK(w ? "a partial first page goes the table's way" : "a partial first page searches", (pt_way(t, map.length, m0 + MB + 8 * KB, &g) > 0) == w);
      CHECK(w ? "a pool smaller than a page goes the table's way" : "a pool smaller than a page searches", (pt_way(t, map.length, m0 + 16 * MB + 14 * KB, &g) > 0) == w);
      CHECK("a page no pool touches searches", pt_way(t, map.length, m0 + 2 * MB, &g) == 0);
      CHECK("an address at 2^46 + a pooled one searches", pt_way(t, map.length, (1ull << 46) + m0 + 4 * MB, &g) == 0);
      if (pt_on) CHECK("the overlap's second pool's own pages go the table's way, to its entry", pt_way(t, map.length, m0 + 9 * MB, &g) > 0 && pt_way(t, map.length, m0 + 9 * MB, &g) != pt_way(t, map.length, m0 + 5 * MB, &g)); }
    // On the GPU: each address reads its word (0 where no pool holds it; learned mode: 0 until the log has been read), by the way the CPU predicts, and the read log names the entries
    static uint32_t got[200000], way[200000];
    id<MTLBuffer> log = [g_dev newBufferWithLength:2 * ENTRIES / 8 options:MTLResourceStorageModeShared]; memset(log.contents, 0, log.length);
    gpu_read(map, log, A, na, got, way);
    int bad = 0, ways_bad = 0;
    for (int i = 0; i < na; i++) { uint32_t want = !learned && readable(P, NP, A[i]) ? word_at(A[i]) : 0; if (got[i] != want && bad++ < 6) fprintf(stderr, "address %#llx read %#x, want %#x (way %u)\n", (unsigned long long)A[i], got[i], want, way[i]);
        uint64_t g; int k = pt_way(map.contents, map.length, A[i], &g); if ((k > 0) != (way[i] == 1)) ways_bad++; }
    CHECK(learned ? "learned: every address reads 0 before the log is read (stubs)" : "every address reads its word, 0 outside the pools", bad == 0);
    CHECK("the GPU went the way the CPU predicts", ways_bad == 0);
    { const uint32_t *l = log.contents; int r = 0; for (int i = 0; i < ENTRIES / 32; i++) r += __builtin_popcount(l[ENTRIES / 32 + i]);
      int want = 0; const uint8_t *t = map.contents; static uint8_t seen[ENTRIES]; memset(seen, 0, sizeof seen);
      for (int i = 0; i < na; i++) { uint64_t g; int s, k = pt_way(t, map.length, A[i], &g); if (k <= 0) k = search(t, A[i], &g, &s); if (k && !seen[k]) { seen[k] = 1; want++; } }
      CHECK("the read log names the entries the lookup chose (the page table's, else the search's) for the addresses read", r == want); }
    if (learned) {   // the log read on completion promotes the pools read, through whichever way the bits were set
        gml_rd_read(log, map, 500);
        id<MTLBuffer> map2 = gmem_map(); CHECK("a new table", map2 != map);
        agree(map2, A, na, "learned, after promotion: the page table's way agrees with the search");
        memset(log.contents, 0, log.length); gpu_read(map2, log, A, na, got, way); bad = 0;
        for (int i = 0; i < na; i++) { uint32_t want = readable(P, NP, A[i]) ? word_at(A[i]) : 0; if (got[i] != want && bad++ < 6) fprintf(stderr, "learned: address %#llx read %#x, want %#x\n", (unsigned long long)A[i], got[i], want); }
        CHECK("learned, after promotion: every address reads its word", bad == 0);
        map = map2;
    }
    // A store logged against the entry of a pool that shares a page is learned over its whole pages (the page table may have named it for the neighbour's part)
    { id<MTLBuffer> wl = [g_dev newBufferWithLength:2 * ENTRIES / 8 options:MTLResourceStorageModeShared]; memset(wl.contents, 0, wl.length);
      uint64_t g; int s, k = search(map.contents, P[1][0] + 8, &g, &s); ((uint32_t *)wl.contents)[k >> 5] |= 1u << (k & 31);
      gml_read(wl, map, 0, 600); int found = 0; pthread_mutex_lock(&g_gml_mu);
      for (int i = 0; i < g_gml_n; i++) if (g_gml_lo[i] <= P[1][0] && g_gml_hi[i] >= P[1][1]) found = 1 + (g_gml_lo[i] == (P[1][0] & ~0x3fffull) && g_gml_hi[i] == ((P[1][1] + 0x3fff) & ~0x3fffull));
      pthread_mutex_unlock(&g_gml_mu);
      CHECK(shared ? "a logged store's range is learned over whole pages" : "a logged store's range is learned as the entry's", found == (shared ? 2 : 1) || (!shared && found == 2 && !(P[1][0] & 0x3fff) && !(P[1][1] & 0x3fff))); }
    // A table is never changed once built: a pool coming makes a new one, and the old keeps its bytes (a submission encoded with it reads that version)
    NSData *before = [NSData dataWithBytes:map.contents length:map.length];
    mtl_pool_add(mem + 20 * MB, 2 * MB); mtl_pool_addressed(mem + 20 * MB, 2 * MB);
    id<MTLBuffer> map3 = gmem_map();
    CHECK("a pool added: a new table", map3 != map);
    CHECK("the old table is unchanged", !memcmp(before.bytes, map.contents, map.length));
    { uint64_t g = 0; int s; CHECK("the new pool is in the new table", search(map3.contents, m0 + 21 * MB, &g, &s) > 0); }
    // A pool deleted: its addresses miss both ways in the next table
    mtl_pool_del(mem + 4 * MB);
    id<MTLBuffer> map4 = gmem_map();
    { uint64_t g = 0; int s; const uint8_t *t = map4.contents; CHECK("a deleted pool's page misses the search", search(t, m0 + 5 * MB, &g, &s) == 0);
      CHECK("and its page goes to the search", pt_way(t, map4.length, m0 + 5 * MB, &g) == 0); }
    agree(map4, A, na, "after a pool came and one went: the page table's way agrees with the search");
    uint64_t nb, ns, mx, pns, pmx, pb; mtl_gmem_pt_stats(&nb, &ns, &mx, &pns, &pmx, &pb);
    printf("t_gmem_pt (page table %s%s, %s): %d addresses, %d by the page table; %llu table builds, %.3f ms average, page table %.3f ms most, %llu KB\n", pt_on ? "on" : "off", shared ? ", shared pages" : "", learned ? "learned" : "budget",
        na, fast, (unsigned long long)nb, ns / 1e6 / (double)(nb ? nb : 1), pmx / 1e6, (unsigned long long)(pb >> 10));
    CHECK("submission completes", mtl_wait(mtl_sub_commit(), 5000000000ull));
    CHECK("GPU success", !mtl_last_commit_error());
    printf("t_gmem_pt: %d checks, %d failed\n", checks, failed); return failed != 0;
} }
