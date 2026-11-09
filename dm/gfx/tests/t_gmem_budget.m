// Raw global memory's pool table under a residency budget (nvn_mtl.m gmem_pick / gmem_map, DM_NVN_GMEM_BUDGET_MB): without it every addressed pool is wired at each table rebuild; with it the table
// wires and lists pools by rank (learned write ranges, wired, most recently looked up, newest) while the bytes fit, leaves the rest out, and a pool a draw wires later gets a new table
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(label, c) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } } while (0)
static void finish(void) { CHECK("submission completes", mtl_wait(mtl_sub_commit(), 5000000000ull)); CHECK("GPU has no submission error", !mtl_last_commit_error()); }
enum { MB = 1 << 20 };
// Whether the table lists the pool at mem, and whether the pool is wired
static int in_table(id<MTLBuffer> map, const void *mem) {
    const uint8_t *t = (const uint8_t *)map.contents;
    for (int k = 1; k < DMSH_GMEM_MAP_ENTRIES; k++) { uint64_t e[2]; memcpy(e, t + (size_t)k * DMSH_GMEM_MAP_ENTRY, sizeof e); if (e[0] == ~0ull) break; if ((uint64_t)(uintptr_t)mem >= e[0] && (uint64_t)(uintptr_t)mem < e[1]) return 1; }
    return 0;
}
static int wired(const void *mem) { pthread_mutex_lock(&g_mu); int i = pool_find((uint64_t)(uintptr_t)mem, 1), r = i >= 0 && g_pools[i].res; pthread_mutex_unlock(&g_mu); return r; }
static void stamp(const void *mem, uint64_t v) { pthread_mutex_lock(&g_mu); int i = pool_find((uint64_t)(uintptr_t)mem, 1); if (i >= 0) atomic_store(g_pools[i].used, v); pthread_mutex_unlock(&g_mu); }
int main(void) { @autoreleasepool {
    // The ranking, without a GPU
    {
        gmem_cand c[5] = {{2 * MB, 10, 1, 0, 0}, {2 * MB, 5, 2, 0, 0}, {2 * MB, 1, 3, 0, 0}, {2 * MB, 0, 9, 0, 0}, {2 * MB, 0, 4, 0, 0}};
        uint8_t k[5];
        CHECK("off keeps all", gmem_pick(c, 5, 0, k) == 10 * MB && k[0] && k[1] && k[2] && k[3] && k[4]);
        CHECK("most recently looked up first", gmem_pick(c, 5, 4 * MB, k) == 4 * MB && k[0] && k[1] && !k[2] && !k[3] && !k[4]);
        c[4].learned = 1; CHECK("a learned one is kept before the recent", gmem_pick(c, 5, 4 * MB, k) == 4 * MB && k[4] && k[0] && !k[1]);
        c[4].learned = 0; c[3].res = 1; CHECK("a wired one is kept before an unwired recent one", gmem_pick(c, 5, 4 * MB, k) == 4 * MB && k[3] && k[0] && !k[1]);
        c[3].res = 0; c[2].used = c[3].used = 0; CHECK("never looked up: the newest first", gmem_pick(c, 5, 6 * MB, k) == 6 * MB && k[0] && k[1] && k[3] && !k[2] && !k[4]);
        c[2].learned = c[3].learned = c[4].learned = 1; CHECK("learned ones are kept past the budget, nothing else fits", gmem_pick(c, 5, 2 * MB, k) == 6 * MB && k[2] && k[3] && k[4] && !k[0] && !k[1]);
        gmem_cand big = {3 * MB, 9, 9, 0, 0}, small = {MB, 1, 1, 0, 0}; gmem_cand two[2] = {big, small};
        CHECK("a pool that does not fit leaves room for a smaller one", gmem_pick(two, 2, 2 * MB, k) == MB && !k[0] && k[1]);
        CHECK("nothing", gmem_pick(c, 0, 4 * MB, k) == 0);
    }
    // The table: six 1 MB pools, all addressed, a 3 MB budget
    mtl_init();
    CHECK("budget read from the environment", gmem_budget() == 3 * MB);
    enum { N = 6 }; uint8_t *p[N];
    for (int i = 0; i < N; i++) { if (posix_memalign((void **)&p[i], getpagesize(), MB)) abort(); memset(p[i], 0, MB); mtl_pool_add(p[i], MB); mtl_pool_addressed(p[i], MB); }
    for (int i = 0; i < N; i++) stamp(p[i], (uint64_t)(100 + i));   // 5 the most recent, 0 the oldest
    uint64_t wired0 = g_pool_res_n;
    mtl_sub_begin(); id<MTLBuffer> map = gmem_map(); CHECK("table made", map != nil); finish();
    CHECK("the three most recent are listed", in_table(map, p[5]) && in_table(map, p[4]) && in_table(map, p[3]));
    CHECK("the others are not", !in_table(map, p[2]) && !in_table(map, p[1]) && !in_table(map, p[0]));
    CHECK("the listed ones are wired", wired(p[5]) && wired(p[4]) && wired(p[3]));
    CHECK("the others are not wired", !wired(p[2]) && !wired(p[1]) && !wired(p[0]));
    CHECK("only the budget was wired", g_pool_res_n - wired0 == 3);
    CHECK("the same table while nothing changed", gmem_map() == map);
    // A draw looks up an unlisted pool: it is wired and the next table lists it, the least recent listed one making room
    void *mb; uint64_t mo; mtl_addr((uint64_t)(uintptr_t)p[0], 16, &mb, &mo);
    CHECK("the lookup wired it", wired(p[0])); stamp(p[0], 200);   // a real lookup stamps the current fence, the newest value
    mtl_sub_begin(); id<MTLBuffer> map2 = gmem_map(); finish();
    CHECK("a new table", map2 != map);
    CHECK("it lists the pool a draw wired", in_table(map2, p[0]));
    CHECK("it is still within the budget", ({ int n = 0; for (int i = 0; i < N; i++) n += in_table(map2, p[i]); n; }) == 3);
    CHECK("GPU success", !mtl_last_commit_error());
    printf("t_gmem_budget: %d checks, %d failed\n", checks, failed); return failed != 0;
} }
