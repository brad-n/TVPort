// DM_NVN_ENC_ASYNC (with DM_NVN_ENC_THREAD): a submission's end hands its records to the encode thread and returns without waiting for them. With the encode thread held
// (a queue block that waits on a gate), two submissions return, their fences are not reached while their commits are still records, and once the gate opens the queue gets them
// in order: the buffer both fill holds the second value. A present's note (pres_commit_mark) is passed only after everything recorded before it, so a presenting thread waiting
// for it (pres_commit_wait) waits while the frame's commits are still records. Without the switch a submission's end drains the records, as before
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
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } } while (0)

static id<MTLBuffer> g_out;
// A submission whose GPU work fills the first word of g_out with byte v (on the replay's own command buffer, as its copies are)
static uint64_t fill_sub(uint8_t v, dispatch_semaphore_t gate) {
    mtl_sub_begin();
    if (gate) rec_queue_block(^{ dispatch_semaphore_wait(gate, DISPATCH_TIME_FOREVER); });
    id ce = [g_cb computeCommandEncoder]; [ce fillBuffer:g_out range:NSMakeRange(0, 4) value:v]; [ce endEncoding];
    return mtl_sub_commit();
}
static int encode_idle(void) { pthread_mutex_lock(&g_rb_mu); int idle = !g_rb_head && !g_rb_busy; pthread_mutex_unlock(&g_rb_mu); return idle; }
static uint32_t word(void) { return *(const uint32_t *)g_out.contents; }

int main(void) { @autoreleasepool {
    setenv("DM_NVN_ENC_THREAD", "1", 1); setenv("DM_NVN_ENC_ASYNC", "1", 1);
    mtl_init();
    g_out = [g_dev newBufferWithLength:256 options:MTLResourceStorageModeShared]; res_add(g_out); memset(g_out.contents, 0, 4);
    CHECK(mtl_wait(fill_sub(0x11, nil), 5000000000ull) && word() == 0x11111111u, "a submission's fill lands (and the encode thread exists)");
    CHECK(rec_on() && enc_async(), "deferred encoding without the wait at a submission's end");

    // The encode thread held: both submissions return with their commits still records
    dispatch_semaphore_t gate = dispatch_semaphore_create(0);
    uint64_t f1 = fill_sub(0x22, gate);
    uint64_t f2 = fill_sub(0x33, nil);
    CHECK(f2 == f1 + 1, "fences in submission order");
    CHECK(!encode_idle(), "the submissions returned before the encode thread made their records");
    uint64_t pv = pres_commit_mark();
    CHECK(pv && atomic_load(&g_pres_cmt) < pv, "a present's note is behind the held records");
    CHECK(!mtl_wait(f1, 100000000ull) && mtl_completed_fence() < f1, "the first fence is not reached while its commit is a record");
    __block _Atomic int presented = 0;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ pres_commit_wait(pv); atomic_store(&presented, 1); dispatch_semaphore_signal(done); });
    usleep(100000);
    CHECK(!atomic_load(&presented), "the presenting thread waits for the note");
    dispatch_semaphore_signal(gate);
    CHECK(mtl_wait(f2, 5000000000ull) && mtl_completed_fence() >= f2, "both fences are reached once the encode thread goes on");
    CHECK(word() == 0x33333333u, "the queue ran the two in order: the second fill is last");
    CHECK(!dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5000000000ll)) && atomic_load(&presented) && atomic_load(&g_pres_cmt) >= pv, "the presenting thread goes on");

    // Off: the end of a submission drains the records
    g_enc_async = 0;
    CHECK(!pres_commit_mark(), "no present note without the switch");
    uint64_t f3 = fill_sub(0x44, nil);
    CHECK(encode_idle(), "without the switch a submission's end waits for the encode thread");
    CHECK(mtl_wait(f3, 5000000000ull) && word() == 0x44444444u, "and its fill lands");
    printf("t_enc_async: %d checks, %d failed\n", checks, failed); return failed != 0;
} }
