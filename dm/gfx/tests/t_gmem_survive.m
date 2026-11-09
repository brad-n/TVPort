// The raw global-memory table and the residency budget (nvn_mtl.m gmem_map, res_budget_step): a pool the table lists for a submission is stamped as used by it, so a budget round does not take it out
// from under the raw shaders (the thrash of the Apple TV run 11: 107 pools and 280 residency commits per 300 frames re-added by the table after the budget evicted them); the pools the table leaves out
// are the ones evicted; and under a steady workload the residency commits stay flat once the round has settled
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(label, c) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } } while (0)
enum { NP = 8, PSZ = 512 << 10 };
static int resident(const void *mem) { pthread_mutex_lock(&g_mu); int i = pool_find((uint64_t)(uintptr_t)mem, 1), r = i >= 0 && g_pools[i].res; pthread_mutex_unlock(&g_mu); return r; }
static void touch_sub(void *mem) { void *b; uint64_t o; mtl_sub_begin(); mtl_addr((uint64_t)(uintptr_t)mem, 16, &b, &o); mtl_sub_commit(); mtl_wait_at(atomic_load(&g_fence), UINT64_MAX, WS_SYNC); }
static void raw_subs(int n) { for (int i = 0; i < n; i++) { mtl_sub_begin(); (void)gmem_map(); mtl_sub_commit(); mtl_wait_at(atomic_load(&g_fence), UINT64_MAX, WS_SYNC); } }   // a raw-memory draw in every submission
int main(void) { @autoreleasepool {
    g_rb_window_ns = 0;   // rounds as soon as their submissions have completed: the checks count submissions (t_res_window checks the window)
    mtl_init();
    uint8_t *d[NP];
    for (int i = 0; i < NP; i++) { if (posix_memalign((void **)&d[i], getpagesize(), PSZ)) abort(); memset(d[i], 0, PSZ); mtl_pool_add(d[i], PSZ); mtl_pool_addressed(d[i], PSZ); }
    g_rb_init = 1; g_rb_budget = 0;
    for (int i = 0; i < NP; i++) touch_sub(d[i]);   // pool 7 the most recently looked up
    int all = 1; for (int i = 0; i < NP; i++) all &= resident(d[i]);
    CHECK("all pools resident", all);
    // learned mode: pools 0 and 1 are the oldest looked up, but loads read their stubs (want), so the table lists them resident and nothing else (the others are wired by lookups only)
    pthread_mutex_lock(&g_mu); for (int i = 0; i < 2; i++) { int k = pool_find((uint64_t)(uintptr_t)d[i], 1); g_pools[k].want = 1; g_pools[k].rd = 1ull << 40; } pthread_mutex_unlock(&g_mu);
    atomic_fetch_add(&g_gmem_stale, 1);
    raw_subs(2);   // the first table: it makes the page of zeros the stubs point into resident
    uint64_t z = PSZ;
    g_rb_budget = res_bytes_now() - 3 * z;   // three pools have to go
    raw_subs(12);   // a raw-memory draw in every submission: the budget round bumps the generations, the table is built again and lists them
    CHECK("the pools the table lists stay (0)", resident(d[0]));
    CHECK("the pools the table lists stay (1)", resident(d[1]));
    CHECK("the three oldest of the others went", !resident(d[2]) && !resident(d[3]) && !resident(d[4]));
    CHECK("the newest stay", resident(d[6]) && resident(d[7]));   // (a log buffer made meanwhile can make the round take one pool more: pool 5)
    CHECK("the set fits the budget", res_bytes_now() <= g_rb_budget);
    CHECK("no over-budget report", g_rb_over_n == 0);
    // steady workload: no more residency commits, no more eviction rounds
    uint64_t c0 = g_rs_commits, ev0 = g_rb_evicted_n, ph0 = g_rb_phases;
    raw_subs(200);
    CHECK("residency commits stay flat under a steady workload", g_rs_commits == c0);
    CHECK("no more pools evicted", g_rb_evicted_n == ev0);
    CHECK("no more cache-flushing rounds", g_rb_phases == ph0);
    CHECK("the listed pools are still there", resident(d[0]) && resident(d[1]));
    // churn back-off: a round whose pools come straight back makes the next one wait
    g_rb_budget = res_bytes_now() - z;   // one more has to go
    uint64_t ph1 = g_rb_phases;
    for (int round = 0; round < 6; round++) { raw_subs(3); for (int i = 0; i < 4; i++) touch_sub(d[i]); }   // every pool is addressed again after it left
    CHECK("churn is held back: fewer rounds than submissions allow", g_rb_phases - ph1 < 6);
    printf("t_gmem_survive: %d checks, %d failed\n", checks, failed); return failed != 0;
} }
