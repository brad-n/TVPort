// Memory pools the GPU stops addressing leave the residency set (nvn_mtl.m pool_age): a pool a copy used goes after POOL_AGE_IDLE submissions with no lookup, comes back
// at its next use with the copy's literal bytes, and a pinned pool (a texture made on its buffer) stays. Runs with Metal validation, which reports a non-resident buffer the GPU reads.
// The window is time as well (pool_age_ns, DM_NVN_POOL_AGE_MS): with it, a pool looked up every 200 submissions stays through 600 quick ones, and an idle pool leaves once it has passed
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

static int resident(const void *mem) { pthread_mutex_lock(&g_mu); int i = pool_find((uint64_t)(uintptr_t)mem, 1), r = i >= 0 && g_pools[i].res; pthread_mutex_unlock(&g_mu); return r; }
static void *pool_mem(size_t n) { void *m = NULL; if (posix_memalign(&m, getpagesize(), n)) abort(); memset(m, 0, n); return m; }
// One submission: copy 16 bytes from src to dst, with the command memory in cmd_mem
static void copy_sub(void *cmd_mem, const uint8_t *src, uint8_t *dst) {
    pool_t pool = {.mem=cmd_mem, .size=65536};
    NVNcommandBuffer cmd; h_nvnCommandBufferInitialize(&cmd, NULL);
    h_nvnCommandBufferAddCommandMemory(&cmd, (const NVNmemoryPool *)&pool, 0, 65536);
    h_nvnCommandBufferBeginRecording(&cmd);
    h_nvnCommandBufferCopyBufferToBuffer(&cmd, (NVNbufferAddress)src, (NVNbufferAddress)dst, 16, 0);
    NVNsync sync; h_nvnSyncInitialize(&sync, NULL);
    h_nvnCommandBufferFenceSync(&cmd, &sync, NVN_SYNC_CONDITION_ALL_GPU_COMMANDS_COMPLETE, 0);
    NVNcommandHandle h = h_nvnCommandBufferEndRecording(&cmd);
    state_reset(); memset(&R, 0, sizeof R); mtl_sub_begin(); mtl_exec(nvn_rec_linear(h, NULL)); mtl_sub_commit();
    h_nvnSyncWait(&sync, 5000000000ull);
}
static void empty_subs(int n) { for (int i = 0; i < n; i++) { mtl_sub_begin(); mtl_sub_commit(); mtl_wait_at(atomic_load(&g_fence), UINT64_MAX, WS_SYNC); } }

int main(void) { @autoreleasepool {
    setenv("DM_NVN_POOL_UNWIRE", "1", 1);
    g_pool_age_ns = 0;   // submissions only, for the first part
    mtl_init();
    uint8_t *ps = pool_mem(65536), *pd = pool_mem(65536), *pp = pool_mem(65536), *cmd = pool_mem(65536);
    mtl_pool_add(ps, 65536); mtl_pool_add(pd, 65536); mtl_pool_add(pp, 65536); mtl_pool_add(cmd, 65536);
    for (int i = 0; i < 16; i++) ps[i] = (uint8_t)(i * 7 + 1);
    copy_sub(cmd, ps, pd);
    EXPECT("first copy: literal bytes", 0, memcmp(ps, pd, 16));
    void *mb; uint64_t mo; mtl_addr((uint64_t)(uintptr_t)pp, 16, &mb, &mo); pool_pin_buf((__bridge id<MTLBuffer>)mb);   // as a linear or buffer texture on its buffer does
    EXPECT("source pool resident after the copy", 1, resident(ps));
    EXPECT("destination pool resident after the copy", 1, resident(pd));
    EXPECT("pinned pool resident", 1, resident(pp));
    empty_subs(POOL_AGE_EVERY + POOL_AGE_IDLE + 8);
    EXPECT("source pool out of the residency set when no submission addressed it", 0, resident(ps));
    EXPECT("destination pool out of the residency set when no submission addressed it", 0, resident(pd));
    EXPECT("pinned pool stays", 1, resident(pp));
    EXPECT("pools counted as taken out", 1, g_pool_aged_n >= 2);
    for (int i = 0; i < 16; i++) ps[i] = (uint8_t)(200 - i * 3);
    copy_sub(cmd, ps, pd);
    EXPECT("copy after they left: literal bytes", 0, memcmp(ps, pd, 16));
    EXPECT("source pool back in the residency set", 1, resident(ps));
    EXPECT("destination pool back in the residency set", 1, resident(pd));
    EXPECT("pools counted as addressed again", 1, g_pool_rewired_n >= 2);
    // The time window: 600 submissions in well under it, pd looked up every 200 (more than POOL_AGE_IDLE apart): nothing leaves; once the window has passed the idle source does
    g_pool_age_ns = 3000000000ull;
    empty_subs(POOL_AGE_EVERY + POOL_AGE_IDLE + 8);   // a round with the window still at 0 may be under way: let it finish
    uint64_t rw0 = g_pool_rewired_n, t0 = clock_gettime_nsec_np(CLOCK_MONOTONIC); void *b2; uint64_t o2;
    mtl_addr((uint64_t)(uintptr_t)ps, 16, &b2, &o2);
    for (int i = 0; i < 3; i++) { mtl_addr((uint64_t)(uintptr_t)pd, 16, &b2, &o2); empty_subs(200); }
    double took = (clock_gettime_nsec_np(CLOCK_MONOTONIC) - t0) / 1e9;
    if (took < 2.5) {   // a machine this slow cannot tell the window from the submissions
        EXPECT("a pool looked up every 200 submissions stays inside the time window", 1, resident(pd));
        EXPECT("so does an idle one", 1, resident(ps));
        EXPECT("nothing left and came back", 1, g_pool_rewired_n == rw0);
    } else printf("600 submissions took %.1f s: the inside-the-window checks skipped\n", took);
    int pd_out = 0; uint64_t t1 = clock_gettime_nsec_np(CLOCK_MONOTONIC);   // a round takes 3 s and the next starts 3 s after it: within 12 s the idle pool goes
    while (resident(ps) && clock_gettime_nsec_np(CLOCK_MONOTONIC) - t1 < 12000000000ull) { mtl_addr((uint64_t)(uintptr_t)pd, 16, &b2, &o2); empty_subs(100); pd_out += !resident(pd); usleep(300000); }
    EXPECT("past the window the idle pool left", 0, resident(ps));
    EXPECT("the pool still looked up stayed throughout", 1, pd_out == 0 && resident(pd));
    EXPECT("GPU success", 0, mtl_last_commit_error());
    printf("POOL AGE cases=%d failed=%d\n", cases, failed); return failed != 0;
} }
