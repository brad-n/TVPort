// The global residency budget (nvn_mtl.m res_budget_step / res_evict_to_budget, DM_NVN_RESIDENCY_BUDGET_MB): over the budget the least recently addressed memory pools leave the residency set,
// never one the current or a running submission addressed; when what is referenced alone exceeds the budget it is logged and nothing referenced is evicted. Runs with Metal validation, which reports a
// non-resident buffer the GPU reads
#define nvn_game_fps nvn_game_fps_mtl_default
#include "../nvn/nvn_mtl.m"
#undef nvn_game_fps
#define g_ft g_ft_hle
#include "../nvn/hle_nvn.c"
#undef g_ft
uint64_t g_t0_ns;
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int cases, failed;
#define EXPECT(n,w,v) do { int a=(w), b=(v); cases++; printf("%s expected %d -> got %d %s\n",n,a,b,a==b?"PASS":"FAIL"); failed+=a!=b; } while (0)

enum { NP = 8, PSZ = 512 << 10 };
static int resident(const void *mem) { pthread_mutex_lock(&g_mu); int i = pool_find((uint64_t)(uintptr_t)mem, 1), r = i >= 0 && g_pools[i].res; pthread_mutex_unlock(&g_mu); return r; }
static void *pool_mem(size_t n) { void *m = NULL; if (posix_memalign(&m, getpagesize(), n)) abort(); memset(m, 0, n); return m; }
static void empty_subs(int n) { for (int i = 0; i < n; i++) { mtl_sub_begin(); mtl_sub_commit(); mtl_wait_at(atomic_load(&g_fence), UINT64_MAX, WS_SYNC); } }
static void touch_sub(void *mem) { void *b; uint64_t o; mtl_sub_begin(); mtl_addr((uint64_t)(uintptr_t)mem, 16, &b, &o); mtl_sub_commit(); mtl_wait_at(atomic_load(&g_fence), UINT64_MAX, WS_SYNC); }
static void copy_sub(void *cmd_mem, const uint8_t *src, uint8_t *dst) {
    pool_t pool = {.mem=cmd_mem, .size=65536};
    NVNcommandBuffer cmd; h_nvnCommandBufferInitialize(&cmd, NULL);
    h_nvnCommandBufferAddCommandMemory(&cmd, (const NVNmemoryPool *)&pool, 0, 65536);
    h_nvnCommandBufferBeginRecording(&cmd);
    h_nvnCommandBufferCopyBufferToBuffer(&cmd, (NVNbufferAddress)src, (NVNbufferAddress)dst, 16, 0);
    NVNsync sync; h_nvnSyncInitialize(&sync, NULL);
    h_nvnCommandBufferFenceSync(&cmd, &sync, NVN_SYNC_CONDITION_ALL_GPU_COMMANDS_COMPLETE, 0);
    NVNcommandHandle h = h_nvnCommandBufferEndRecording(&cmd);
    state_reset(); memset(&R, 0, sizeof R); mtl_sub_begin(); mtl_exec((const uint8_t *)h); mtl_sub_commit();
    h_nvnSyncWait(&sync, 5000000000ull);
}
static uint64_t pool_bytes(void *mem) { pthread_mutex_lock(&g_mu); int i = pool_find((uint64_t)(uintptr_t)mem, 1); uint64_t z = i >= 0 ? g_pools[i].buf.allocatedSize : 0; pthread_mutex_unlock(&g_mu); return z; }
static void set_used(void *mem, uint64_t v) { pthread_mutex_lock(&g_mu); int i = pool_find((uint64_t)(uintptr_t)mem, 1); if (i >= 0) atomic_store(g_pools[i].used, v); pthread_mutex_unlock(&g_mu); }

int main(void) { @autoreleasepool {
    setenv("DM_NVN_POOL_UNWIRE", "0", 1);   // pool_age out of the way
    mtl_init();
    uint8_t *cmd = pool_mem(65536), *d[NP]; mtl_pool_add(cmd, 65536);
    for (int i = 0; i < NP; i++) { d[i] = pool_mem(PSZ); mtl_pool_add(d[i], PSZ); }
    g_rb_init = 1; g_rb_budget = 0;   // off while the pools are made resident, one submission each, oldest first
    for (int i = 0; i < NP; i++) touch_sub(d[i]);
    uint64_t z = pool_bytes(d[0]); EXPECT("pool size seen", 1, z >= PSZ);
    int all = 1; for (int i = 0; i < NP; i++) all &= resident(d[i]);
    EXPECT("all pools resident before a budget", 1, all);

    // 1. LRU: three pools over the budget, the three oldest go once the submissions that could read them have completed
    g_rb_budget = res_bytes_now() - 3 * z;
    EXPECT("phase 1 starts at the next submission, nothing taken yet", 1, (mtl_sub_begin(), mtl_sub_commit(), mtl_wait_at(atomic_load(&g_fence), UINT64_MAX, WS_SYNC), resident(d[0])));
    empty_subs(10);
    EXPECT("oldest pool 0 evicted", 0, resident(d[0]));
    EXPECT("pool 1 evicted", 0, resident(d[1]));
    EXPECT("pool 2 evicted", 0, resident(d[2]));
    EXPECT("pool 3 kept", 1, resident(d[3]));
    EXPECT("newest pool 7 kept", 1, resident(d[7]));
    EXPECT("exactly three evicted", 3, (int)g_rb_evicted_n);
    EXPECT("set within the budget", 1, res_bytes_now() <= g_rb_budget);
    EXPECT("fits: no over-budget report", 0, (int)g_rb_over_n);

    // 2. An address refreshes a pool: pool 3 is the oldest of the rest, looked up again it outlives pool 4
    touch_sub(d[3]);
    g_rb_budget = res_bytes_now() - z; empty_subs(10);
    EXPECT("refreshed pool 3 kept", 1, resident(d[3]));
    EXPECT("pool 4 (now the oldest) evicted", 0, resident(d[4]));

    // 3. A pool the current submission addressed stays; every older one goes (the budget cannot be met without it), and the report says so
    mtl_sub_begin();
    { void *b; uint64_t o; mtl_addr((uint64_t)(uintptr_t)d[7], 16, &b, &o); }
    uint64_t before = g_rb_over_n;
    res_evict_to_budget(1, atomic_load(&g_fence));
    EXPECT("pool of the current submission stays", 1, resident(d[7]));
    EXPECT("older pool 5 evicted", 0, resident(d[5]));
    EXPECT("older pool 6 evicted", 0, resident(d[6]));
    EXPECT("over-budget case counted", 1, g_rb_over_n > before);
    EXPECT("report names the referenced pools", 1, strstr(g_rb_over_msg, "current or a running submission 1 ") != NULL);
    EXPECT("report says the frame is too big", 1, strstr(g_rb_over_msg, "too big") != NULL);
    mtl_sub_commit(); mtl_wait_at(atomic_load(&g_fence), UINT64_MAX, WS_SYNC);

    // 4. A submission still running (stamp past what is safe) keeps its pools, one stamped within it goes
    for (int i = 0; i < NP; i++) touch_sub(d[i]);
    uint64_t safe = atomic_load(&g_fence);
    set_used(d[1], safe + 1);   // addressed by a submission after the safe point (running, or encoded since)
    set_used(d[2], safe);
    res_evict_to_budget(1, safe);
    EXPECT("pool addressed by the running submission stays", 1, resident(d[1]));
    EXPECT("pool last addressed within the safe point goes", 0, resident(d[2]));
    // 5. A pinned pool (a texture made on its buffer) is never taken
    for (int i = 0; i < NP; i++) touch_sub(d[i]);
    pool_pin_at(d[4]); safe = atomic_load(&g_fence);
    res_evict_to_budget(1, safe);
    EXPECT("pinned pool stays", 1, resident(d[4]));
    EXPECT("other pool goes", 0, resident(d[5]));

    // 6. A pool taken out is wired again at its next use, and the GPU reads it
    g_rb_budget = 0;
    for (int i = 0; i < NP; i++) d[0][i] = (uint8_t)(i * 5 + 3);
    copy_sub(cmd, d[0], d[5]);
    EXPECT("copy from and to evicted pools: literal bytes", 0, memcmp(d[0], d[5], 16));
    EXPECT("evicted source back", 1, resident(d[0]));
    EXPECT("GPU success", 0, mtl_last_commit_error());
    printf("RESIDENCY BUDGET cases=%d failed=%d\n", cases, failed); return failed != 0;
} }
