// Residency rounds against what the GPU still reads (nvn_mtl.m res_budget_step / res_budget_window_ns, pool_pin_buf, gmem_map in learned mode). Runs with Metal validation.
// 1. A budget round waits its window (DM_NVN_RESIDENCY_WINDOW_MS) before it takes anything: with frames of 6 submissions and two pools each looked up once a frame, only the idle pools
//    go, the set stays over the budget with the over-budget report, and no pool a frame uses leaves and comes back. The round used to run once submission B had completed, two or three
//    submissions on, and took a pool the next frame read (Ocarina of Time on the Apple TV: 150-300 pools a round out and straight back)
// 2. Learned raw memory: a pool the raw draw of each frame reads stays resident and listed in the table through the rounds. It used to be evicted between table builds and turn into a
//    stub of zeros until its next read was logged (on a Mac mini at a 1,536 MB budget the GPU hung in Link's house within a minute)
// 3. A buffer texture in a large pool in chunks keeps the buffer it was made on in the residency set after a longer lookup has replaced that chunk and a round takes every pool it may:
//    the pin goes with the buffer. pool_pin_at's lookup of unknown length used to make a new, longer chunk and pin that one, and the round took the texture's buffer out of the set (an
//    Apple TV reads it as zeros then; a Mac goes on reading the pages, so this checks membership)
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(label, c) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } else printf("ok: %s\n", label); } while (0)
enum { PSZ = 512 << 10, SUBS = 6 };
static int resident(const void *mem) { pthread_mutex_lock(&g_mu); int i = pool_find((uint64_t)(uintptr_t)mem, 1), r = i >= 0 && g_pools[i].res; pthread_mutex_unlock(&g_mu); return r; }
static int in_set(id o) { pthread_mutex_lock(&g_res_mu); int r = [g_res_objects containsObject:o]; pthread_mutex_unlock(&g_res_mu); return r; }
static void look(const void *mem) { void *b; uint64_t o; mtl_addr((uint64_t)(uintptr_t)mem, 16, &b, &o); }
static void *pool_mem(void) { void *m = NULL; if (posix_memalign(&m, getpagesize(), PSZ)) abort(); memset(m, 0, PSZ); mtl_pool_add(m, PSZ); return m; }
static void end_sub(void) { mtl_sub_commit(); mtl_wait_at(atomic_load(&g_fence), UINT64_MAX, WS_SYNC); }
// One frame: SUBS submissions; a in the first, b in the fourth; raw: the raw pool table used in the third (a raw-memory draw), whose loads read pool r (as gml_rd_read records on completion)
static void frame(const void *a, const void *b, const void *r) {
    for (int s = 0; s < SUBS; s++) {
        mtl_sub_begin();
        if (s == 0 && a) look(a);
        if (s == 3 && b) look(b);
        if (s == 2 && r) (void)gmem_map();
        end_sub();
        if (s == 2 && r) { uint64_t f = atomic_load(&g_fence); pthread_mutex_lock(&g_mu); int k = pool_find((uint64_t)(uintptr_t)r, 1);
            if (k >= 0) { pool_ent *q = &g_pools[k]; if (atomic_load(q->used) < f) atomic_store(q->used, f); q->rd = f; q->rd_t = clock_gettime_nsec_np(CLOCK_MONOTONIC); }
            pthread_mutex_unlock(&g_mu); }
    }
    usleep(4000);   // about 30 ms frames would make the test long; 4 ms keeps a 200 ms window at about 40 frames
}
static int listed_resident(const void *mem) { pthread_mutex_lock(&g_mu); int i = pool_find((uint64_t)(uintptr_t)mem, 1), r = i >= 0 && g_pools[i].gm && g_pools[i].res; pthread_mutex_unlock(&g_mu); return r; }
int main(void) { @autoreleasepool {
    mtl_init();
    g_rb_window_ns = 200000000;   // 200 ms (1 s by default)
    g_rb_init = 1; g_rb_budget = 0;
    uint8_t *h0 = pool_mem(), *h1 = pool_mem(), *c0 = pool_mem(), *c1 = pool_mem();
    frame(c0, c1, NULL); frame(h0, h1, NULL);
    CHECK("all four pools resident", resident(h0) && resident(h1) && resident(c0) && resident(c1));

    // 1. Three pools' worth over the budget, two of them idle: the idle two go, the ones each frame looks up stay
    g_rb_budget = res_bytes_now() - 3 * (uint64_t)PSZ;
    uint64_t rw0 = g_pool_rewired_n, over0 = g_rb_over_n, ph0 = g_rb_phases;
    uint64_t t0 = clock_gettime_nsec_np(CLOCK_MONOTONIC); int hot_out = 0;
    while (clock_gettime_nsec_np(CLOCK_MONOTONIC) - t0 < 1000000000ull) { frame(h0, h1, NULL); hot_out += !resident(h0) || !resident(h1); }
    CHECK("rounds ran", g_rb_phases > ph0);
    CHECK("the idle pools went", !resident(c0) && !resident(c1));
    CHECK("the pools every frame looks up never left", hot_out == 0 && resident(h0) && resident(h1));
    CHECK("no pool left and came back", g_pool_rewired_n == rw0);
    CHECK("the set held over the budget is reported", g_rb_over_n > over0);

    // 2. Learned raw memory: r is read by the raw draw of every frame, h0 and h1 are now idle; the round needs one pool more than the idle ones
    uint8_t *r = pool_mem(); mtl_pool_addressed(r, PSZ);
    pthread_mutex_lock(&g_mu); { int k = pool_find((uint64_t)(uintptr_t)r, 1); g_pools[k].want = 1; } pthread_mutex_unlock(&g_mu);   // a load read its stub: the next table lists it resident
    atomic_fetch_add(&g_gmem_stale, 1);
    frame(h0, h1, r); frame(h0, h1, r);
    CHECK("the table lists the read pool resident", listed_resident(r));
    g_rb_budget = res_bytes_now() - 3 * (uint64_t)PSZ;
    uint64_t rw1 = g_pool_rewired_n, ph1 = g_rb_phases; int r_out = 0;
    t0 = clock_gettime_nsec_np(CLOCK_MONOTONIC);
    while (clock_gettime_nsec_np(CLOCK_MONOTONIC) - t0 < 1000000000ull) { frame(NULL, NULL, r); r_out += !listed_resident(r); }
    CHECK("rounds ran", g_rb_phases > ph1);
    CHECK("the idle pools went", !resident(h0) && !resident(h1));
    CHECK("the pool raw loads read stayed resident and listed (never a stub of zeros)", r_out == 0 && listed_resident(r));
    CHECK("nothing left and came back", g_pool_rewired_n == rw1);

    // 3. A buffer texture in a large pool in chunks: its buffer stays resident after its chunk is replaced and a round takes everything it may
    const uint64_t GB = 1ull << 30, MB = 1ull << 20;
    uint8_t *mem = mmap(NULL, GB, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); if (mem == MAP_FAILED) abort();
    mtl_pool_add(mem, GB);
    pool_t pool = {.magic = MAGIC('P', 'O', 'O', 'L'), .mem = mem, .size = GB, .flags = NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED};
    tex_t t = {.magic = MAGIC('T', 'E', 'X', 0), .serial = 99950};   // no packaged layout: a buffer texture is a view on its storage, not an upload
    t.d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_BUFFER, .format = NVN_FORMAT_R32F, .width = 4096, .height = 1, .depth = 1, .levels = 1, .samples = 1}; nvn_tex_layout(&t.d, &t.L);
    t.pool = &pool; t.mem = mem + 100 * MB; t.off = 100 * MB;
    mtl_sub_begin(); id<MTLTexture> tex = tex_mtl(&t); end_sub();   // storage the CPU wrote before the first use would be uploaded instead (tex_cpu_content): written after
    for (int i = 0; i < 4096; i++) ((float *)t.mem)[i] = (float)i;
    CHECK("buffer texture made on a chunk", tex && tex.buffer);
    if (!tex.buffer) { printf("t_res_window: %d checks, %d failed\n", checks, failed); return 1; }
    id<MTLBuffer> tb = tex.buffer;
    CHECK("its buffer is resident", in_set(tb));
    void *mb = NULL; uint64_t mo = 0, gpu = 0;
    CHECK("a longer lookup in its stride", mtl_gpu_addr((uint64_t)(uintptr_t)(mem + 100 * MB + 64), 300 * MB, &mb, &mo, &gpu));
    CHECK("it made a new chunk", (__bridge id<MTLBuffer>)mb != tb);
    res_evict_to_budget(1, atomic_load(&g_fence) + 1);   // every unpinned pool may go
    CHECK("the replaced chunk the texture is made on stays in the residency set", in_set(tb));
    CHECK("an unpinned chunk went", !in_set((__bridge id<MTLBuffer>)mb));
    CHECK("the texture still reads the pool's bytes", ((const float *)((const uint8_t *)tb.contents + tex.bufferOffset))[4095] == 4095.0f);
    CHECK("GPU success", !mtl_last_commit_error());
    printf("t_res_window: %d checks, %d failed\n", checks, failed); return failed != 0;
} }
