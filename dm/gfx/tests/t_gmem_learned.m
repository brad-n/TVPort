// Raw global memory's pool table in learned mode (nvn_mtl.m DM_NVN_GMEM_MODE=learned, gmem_learned_entries / gml_rd_read): every addressed pool has an entry, but only pools that are wired, written or read stand
// resident behind it; the others are stubs (the entry's last word 1, its delta into a page of zeros) that a load reads as 0 while it sets the entry's bit in the read log. A raw read of a pool the old
// byte cap (DM_NVN_GMEM_BUDGET_MB, gmem_pick) would have left out must return the pool's bytes after the log has been read and the new table is bound, a large pool must be made resident one 16 MiB
// window at a time, and the resident bytes must stay at what was read
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(label, c) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } } while (0)
enum { MB = 1 << 20, N = 6, ENTRIES = DMSH_GMEM_MAP_ENTRIES };
static uint32_t value(int p, uint64_t off) { return (uint32_t)(p + 1) << 24 | (uint32_t)(off / 4); }
// The table entry holding addr: its index, or 0; *stub: its last word
static int entry_of(id<MTLBuffer> map, uint64_t addr, int *stub) {
    const uint8_t *t = (const uint8_t *)map.contents;
    for (int k = 1; k < ENTRIES; k++) { uint64_t e[2]; memcpy(e, t + (size_t)k * DMSH_GMEM_MAP_ENTRY, sizeof e); if (e[0] == ~0ull) break;
        if (addr >= e[0] && addr < e[1]) { uint32_t f; memcpy(&f, t + (size_t)k * DMSH_GMEM_MAP_ENTRY + 28, 4); if (stub) *stub = (int)f; return k; } }
    return 0;
}
static int stubs_in(id<MTLBuffer> map) {
    const uint8_t *t = (const uint8_t *)map.contents; int n = 0;
    for (int k = 1; k < ENTRIES; k++) { uint64_t e0; memcpy(&e0, t + (size_t)k * DMSH_GMEM_MAP_ENTRY, 8); if (e0 == ~0ull) break; uint32_t f; memcpy(&f, t + (size_t)k * DMSH_GMEM_MAP_ENTRY + 28, 4); n += f != 0; }
    return n;
}
// What a translated raw load does (GlobalToStorage): find the entry, set its bit in the read log (second half), read the word at address + delta; an address in no entry reads 0
static NSString *const SRC = @"#include <metal_stdlib>\nusing namespace metal;\nstruct Ent { ulong lo, hi, delta; uint hint, stub; };\n"
    "kernel void rd(device const Ent* map [[buffer(0)]], device atomic_uint* log [[buffer(1)]], device const ulong* addr [[buffer(2)]], device uint* out [[buffer(3)]], uint id [[thread_position_in_grid]]) {\n"
    "  ulong a = addr[id]; out[id] = 0;\n"
    "  for (uint k = 1; k < 8192; k++) { Ent e = map[k]; if (e.lo == ~0ul) break;\n"
    "    if (a >= e.lo && a < e.hi) { atomic_fetch_or_explicit(&log[256 + (k >> 5)], 1u << (k & 31), memory_order_relaxed); out[id] = *reinterpret_cast<device const uint*>(a + e.delta); return; } } }\n";
static id<MTLComputePipelineState> g_ps;
static void gpu_read(id<MTLBuffer> map, id<MTLBuffer> log, const uint64_t *addr, int n, uint32_t *out) {
    if (!g_ps) { NSError *e = nil; id<MTLLibrary> l = [g_dev newLibraryWithSource:SRC options:nil error:&e]; if (!l) { fprintf(stderr, "%s\n", e.description.UTF8String); abort(); }
        g_ps = [g_dev newComputePipelineStateWithFunction:[l newFunctionWithName:@"rd"] error:&e]; if (!g_ps) abort(); }
    id<MTLBuffer> ab = [g_dev newBufferWithBytes:addr length:(NSUInteger)n * 8 options:MTLResourceStorageModeShared], ob = [g_dev newBufferWithLength:(NSUInteger)n * 4 options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb = q_cb(); id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
    [ce setComputePipelineState:g_ps]; [ce setBuffer:map offset:0 atIndex:0]; [ce setBuffer:log offset:0 atIndex:1]; [ce setBuffer:ab offset:0 atIndex:2]; [ce setBuffer:ob offset:0 atIndex:3];
    [ce dispatchThreads:MTLSizeMake((NSUInteger)n, 1, 1) threadsPerThreadgroup:MTLSizeMake((NSUInteger)n, 1, 1)]; [ce endEncoding]; [cb commit]; [cb waitUntilCompleted];
    CHECK("GPU read has no error", cb.error == nil);
    memcpy(out, ob.contents, (size_t)n * 4);
}
static int wired(uint64_t a) { pthread_mutex_lock(&g_mu); int i = pool_find(a, 1), r = i >= 0 && g_pools[i].res; pthread_mutex_unlock(&g_mu); return r; }
int main(void) { @autoreleasepool {
    // The ranking: a pool nobody wired, wrote or read is skipped even when the budget would fit it; one that was read comes before a wired one
    {
        gmem_cand c[4] = {{MB, 5, 1, 1, 0, 0, 0}, {MB, 0, 2, 0, 0, 0, 1}, {MB, 0, 3, 0, 0, 1, 0}, {MB, 0, 4, 0, 1, 0, 0}};
        uint8_t k[4];
        CHECK("no budget keeps all but the skipped", gmem_pick(c, 4, 0, k) == 3 * MB && k[0] && !k[1] && k[2] && k[3]);
        CHECK("a learned write, then a read, then a wired one", gmem_pick(c, 4, 2 * MB, k) == 2 * MB && k[3] && k[2] && !k[0] && !k[1]);   // the learned is kept past the budget; the read fits the rest
        CHECK("a skipped pool is never kept", gmem_pick(c, 4, 100 * MB, k) == 3 * MB && !k[1]);
    }
    mtl_init();
    CHECK("learned mode on", gmem_learned());
    CHECK("no byte budget", gmem_budget() == 0);
    uint8_t *p[N];
    for (int i = 0; i < N; i++) { if (posix_memalign((void **)&p[i], getpagesize(), MB)) abort(); for (int w = 0; w < MB / 4; w++) ((uint32_t *)p[i])[w] = value(i, (uint64_t)w * 4); mtl_pool_add(p[i], MB); mtl_pool_addressed(p[i], MB); }
    const uint64_t BIGSZ = 640ull * MB, S = 16ull * MB;
    uint8_t *big = mmap(NULL, BIGSZ, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); if (big == MAP_FAILED) abort();
    uint64_t bigw = (uint64_t)(uintptr_t)big + 20 * S + 4096;   // in window 20 of the large pool
    for (uint64_t o = 0; o < 4096; o += 4) *(uint32_t *)(uintptr_t)(bigw + o) = 0xb16b0000u | (uint32_t)o / 4;
    mtl_pool_add(big, BIGSZ); mtl_pool_addressed(big, BIGSZ);
    uint64_t res0 = g_pool_res_n;
    mtl_sub_begin(); id<MTLBuffer> map = gmem_map(); CHECK("table made", map != nil); CHECK("submission completes", mtl_wait(mtl_sub_commit(), 5000000000ull));
    // Every pool has an entry and all of them are stubs: nothing was wired
    int stub = 0; uint64_t a2 = (uint64_t)(uintptr_t)p[2] + 16, a4 = (uint64_t)(uintptr_t)p[4] + 64, a0 = (uint64_t)(uintptr_t)p[0] + 8;
    CHECK("pool 2 listed as a stub", entry_of(map, a2, &stub) && stub == 1);
    CHECK("the large pool's window 20 listed as a stub", entry_of(map, bigw, &stub) && stub == 1);
    CHECK("the large pool has a stub per 16 MiB window, the pools one each", stubs_in(map) == N + 40);
    CHECK("nothing was wired", g_pool_res_n == res0 && !wired(a2) && !wired(a4) && !g_big[0].chunk[20]);
    // The shader reads three of them: 0 each (the page of zeros), and the log names exactly those entries
    id<MTLBuffer> log = [g_dev newBufferWithLength:2 * ENTRIES / 8 options:MTLResourceStorageModeShared]; memset(log.contents, 0, log.length);
    uint64_t addr[3] = {a2, a4, bigw}; uint32_t got[3];
    gpu_read(map, log, addr, 3, got);
    CHECK("a stub reads zeros", got[0] == 0 && got[1] == 0 && got[2] == 0);
    { const uint32_t *l = log.contents; int w = 0, r = 0; for (int i = 0; i < ENTRIES / 32; i++) { w += __builtin_popcount(l[i]); r += __builtin_popcount(l[ENTRIES / 32 + i]); }
      CHECK("the log has three read bits and no write bit", r == 3 && w == 0); }
    // The log is read on completion: the three are wanted, a new table is asked for
    uint64_t stale0 = atomic_load(&g_gmem_stale);
    gml_rd_read(log, map, 500);
    CHECK("a new table is asked for", atomic_load(&g_gmem_stale) != stale0);
    CHECK("three stubs made resident", g_gmem_prom_n == 3 && g_gmem_prom_b == 2 * MB + S);
    mtl_sub_begin(); id<MTLBuffer> map2 = gmem_map(); CHECK("submission completes", mtl_wait(mtl_sub_commit(), 5000000000ull)); finish_noop:;
    CHECK("a new table", map2 != map);
    CHECK("pool 2, pool 4 and the window are resident entries now", entry_of(map2, a2, &stub) && !stub && entry_of(map2, a4, &stub) && !stub && entry_of(map2, bigw, &stub) && !stub);
    CHECK("the others are still stubs", entry_of(map2, a0, &stub) && stub == 1 && stubs_in(map2) == N - 2 + 39);
    { pthread_mutex_lock(&g_mu); int i = g_big[0].chunk[20] - 1; uint64_t bytes = i >= 0 ? g_pools[i].end - g_pools[i].lo : 1ull << 40; pthread_mutex_unlock(&g_mu); CHECK("the window's buffer is 16 MiB", bytes == S); }
    CHECK("only what was read is wired", g_pool_res_n - res0 == 3 && wired(a2) && wired(a4) && g_pools[g_big[0].chunk[20] - 1].res && !wired(a0));
    // The same reads now return the pools' bytes
    memset(log.contents, 0, log.length);
    uint64_t addr2[4] = {a2, a4, bigw, a0}; uint32_t got2[4];
    gpu_read(map2, log, addr2, 4, got2);
    CHECK("pool 2 reads its bytes", got2[0] == value(2, 16));
    CHECK("pool 4 reads its bytes", got2[1] == value(4, 64));
    CHECK("the large pool's window reads its bytes", got2[2] == 0xb16b0000u);
    CHECK("an unread pool still reads zeros", got2[3] == 0);
    gml_rd_read(log, map2, 501);
    CHECK("reading again wants nothing more", g_gmem_prom_n == 4);   // pool 0 is a stub read now: the one new
    mtl_sub_begin(); id<MTLBuffer> map3 = gmem_map(); CHECK("submission completes", mtl_wait(mtl_sub_commit(), 5000000000ull));
    CHECK("pool 0 is resident in its turn", entry_of(map3, a0, &stub) && !stub);
    CHECK("the same table while nothing changes", gmem_map() == map3);
    CHECK("the pools' read was recorded (rd, and the use stamp for pool_age)", ({ pthread_mutex_lock(&g_mu); int i = pool_find(a2, 1); uint64_t u = g_pools[i].rd; pthread_mutex_unlock(&g_mu); u >= 501; }));
    CHECK("GPU success", !mtl_last_commit_error());
    printf("t_gmem_learned: %d checks, %d failed\n", checks, failed); return failed != 0;
} }
