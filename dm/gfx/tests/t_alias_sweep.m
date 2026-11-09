// alias_sweep (nvn_mtl.m, DM_NVN_ALIAS_SWEEP_MB): the sharing table's unreferenced textures past the cap go when a submission begins, the longest unused first, once no lookup has
// found them for ALIAS_SWEEP_IDLE submissions. A live texture, one a finalized object in the ghost ring resolves, a pinned one and the base of a view a live serial holds stay; so does
// everything below the cap or with the switch at 0. A swept texture stays alive and resident until the submissions up to the sweep complete, then its placement heap waits for the
// next target (rh_take); every texture ID's cached view is checked again (a generation bump with no note); a texture made again over swept storage is counted. Last, the memory the
// residency set's objects hold of their own (res_size): a texture over a buffer or a view counts nothing, its buffer or parent counts (the ledger's 8 MB "UI text targets")
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } } while (0)

static tex_t target(pool_t *pool, uint64_t serial, uint64_t off) {   // 640x360 RGBA16F: about 1.8 MB
    tex_t t = {.magic = MAGIC('T','E','X',0), .serial = serial, .pool = pool, .mem = pool->mem + off, .off = (int64_t)off};
    t.d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = NVN_FORMAT_RGBA16F, .flags = NVN_TEXTURE_FLAGS_COMPRESSIBLE, .width = 640, .height = 360, .depth = 1, .levels = 1, .samples = 1};
    nvn_tex_layout(&t.d, &t.L); return t;
}
static int shared(id t) { pthread_mutex_lock(&g_smu); int r = t && CFSetContainsValue(g_alias_set, (__bridge const void *)t); pthread_mutex_unlock(&g_smu); return r; }
static int resident(id o) { pthread_mutex_lock(&g_res_mu); int r = [g_res_objects containsObject:o]; pthread_mutex_unlock(&g_res_mu); return r; }
static unsigned waiting(void) { os_unfair_lock_lock(&g_rh_lk); unsigned n = g_rh_n; os_unfair_lock_unlock(&g_rh_lk); return n; }
static void subs(int n) { for (int i = 0; i < n; i++) { mtl_sub_commit(); mtl_drain(); mtl_sub_begin(); } }
static void settle(void) { mtl_sub_commit(); mtl_drain(); mtl_sub_begin(); mtl_sub_commit(); mtl_drain(); dispatch_sync(g_feedback_q, ^{}); defer_drain(); mtl_sub_begin(); }
static alias_key key_of(const tex_t *t) { return tex_alias_key(t); }
static void seen_at(const tex_t *t, uint64_t fence) { alias_key k = key_of(t); pthread_mutex_lock(&g_smu); nvn_hm_put(&g_alias_seen, &k, (void *)(uintptr_t)fence); pthread_mutex_unlock(&g_smu); }
static void fill(id<MTLTexture> t, uint8_t v) {
    NSUInteger row = t.width * 8, bytes = row * t.height;
    id<MTLBuffer> b = [g_dev newBufferWithLength:bytes options:MTLResourceStorageModeShared]; memset(b.contents, v, bytes); res_add(b);
    enc_b_copy_buffer_texture(blit(), b, 0, row, bytes, MTLSizeMake(t.width, t.height, 1), t, 0, 0, MTLOriginMake(0, 0, 0));
    mtl_sub_commit(); mtl_drain(); CHECK(!mtl_last_commit_error(), "the fill completes without GPU error"); res_remove(b); mtl_sub_begin();
}
static int all_zero(id<MTLTexture> t) {
    NSUInteger row = t.width * 8, bytes = row * t.height;
    id<MTLBuffer> b = [g_dev newBufferWithLength:bytes options:MTLResourceStorageModeShared]; res_add(b);
    enc_b_copy_texture_buffer(blit(), t, 0, 0, MTLOriginMake(0, 0, 0), MTLSizeMake(t.width, t.height, 1), b, 0, row, bytes);
    mtl_sub_commit(); mtl_drain(); CHECK(!mtl_last_commit_error(), "the read completes without GPU error"); res_remove(b); mtl_sub_begin();
    const uint8_t *p = b.contents; for (NSUInteger i = 0; i < bytes; i++) if (p[i]) return 0;
    return 1;
}

int main(void) { @autoreleasepool {
    CHECK(alias_sweep_default_mb(1, 64ull << 30) == 64 && alias_sweep_default_mb(0, 5ull << 30) == 64 && alias_sweep_default_mb(0, (16ull << 30) - 1) == 64 && alias_sweep_default_mb(0, 16ull << 30) == 0
          && alias_sweep_default_mb(0, 25ull << 30) == 0, "on by default on iOS / tvOS and on a Mac with under 16 GB of Metal working set, off on larger Macs");
    if (!getenv("DM_NVN_ALIAS_SWEEP_MB")) setenv("DM_NVN_ALIAS_SWEEP_MB", "1", 1);   // this test's cap (this Mac's default may be off)
    mtl_init(); void *mem = NULL; posix_memalign(&mem, 16384, 64 << 20); memset(mem, 0, 64 << 20);
    pool_t pool = {.magic = MAGIC('P','O','O','L'), .flags = NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS | NVN_MEMORY_POOL_FLAGS_GPU_CACHED | NVN_MEMORY_POOL_FLAGS_COMPRESSIBLE, .mem = mem, .size = 64 << 20};
    mtl_sub_begin();
    const uint64_t MB = 1 << 20;
    // live L; finalized U1, U2, U3 (unreferenced); finalized G (a ghost entry holds it), P (pinned), V (a live serial holds a view of it)
    tex_t L = target(&pool, 96001, 0), U1 = target(&pool, 96002, 4 * MB), U2 = target(&pool, 96003, 8 * MB), U3 = target(&pool, 96004, 12 * MB),
          G = target(&pool, 96005, 16 * MB), P = target(&pool, 96006, 20 * MB), V = target(&pool, 96007, 24 * MB);
    tex_t *all[] = {&L, &U1, &U2, &U3, &G, &P, &V};
    id<MTLTexture> t[7];
    for (int i = 0; i < 7; i++) { mtl_tex_init(all[i]); t[i] = tex_mtl(all[i]); CHECK(t[i] && t[i].heap && shared(t[i]), "each target is a shared texture in a recycled heap"); }
    id<MTLTexture> tL = t[0], tU1 = t[1], tU2 = t[2], tU3 = t[3], tG = t[4], tP = t[5], tV = t[6];
    fill(tU1, 0x5a);
    id view = [tV newTextureViewWithPixelFormat:MTLPixelFormatRGBA16Float]; tex_put(96107, view);   // a live twin's serial holds a view of V's texture
    for (int i = 1; i < 7; i++) mtl_tex_release(all[i]);
    { uintptr_t a = (uintptr_t)(__bridge void *)tG; pthread_mutex_lock(&g_smu); nvn_hm_put(&g_ghost_held, &a, (void *)1); pthread_mutex_unlock(&g_smu); }
    { uintptr_t a = (uintptr_t)(__bridge void *)tP; pthread_mutex_lock(&g_smu); nvn_hm_put(&g_tex_pin_objects, &a, (void *)1); pthread_mutex_unlock(&g_smu); }
    CHECK(alias_sweep_cap() == (getenv("DM_NVN_ALIAS_SWEEP_MB") && atoi(getenv("DM_NVN_ALIAS_SWEEP_MB")) > 0 ? (uint64_t)atoi(getenv("DM_NVN_ALIAS_SWEEP_MB")) << 20 : 0), "the cap follows the switch");
    if (!alias_sweep_cap()) {   // DM_NVN_ALIAS_SWEEP_MB=0
        subs(ALIAS_SWEEP_IDLE + 2 * ALIAS_SWEEP_EVERY);
        CHECK(shared(tU1) && shared(tU2) && shared(tU3) && g_alias_swept == 0, "with the switch at 0 nothing is swept");
        printf("t_alias_sweep (off): %d checks, %d failed\n", checks, failed); return failed != 0;
    }
    subs(2 * ALIAS_SWEEP_EVERY);
    CHECK(shared(tU1) && shared(tU2) && shared(tU3) && g_alias_swept == 0, "unreferenced textures a lookup found lately stay");
    {   // found more than ALIAS_SWEEP_IDLE submissions ago but less than ALIAS_SWEEP_MS: they stay
        uint64_t f0 = atomic_load(&g_fence); g_alias_sweep_cap = (int64_t)(1024 * 1024 * 1024); subs(ALIAS_SWEEP_IDLE + 1); g_alias_sweep_cap = (int64_t)MB;
        seen_at(&U1, f0); seen_at(&U2, f0); seen_at(&U3, f0); g_fence_ns[f0 % FENCE_NS] = clock_gettime_nsec_np(CLOCK_MONOTONIC);
        subs(ALIAS_SWEEP_EVERY + 1);
        CHECK(shared(tU1) && shared(tU2) && shared(tU3) && g_alias_swept == 0, "unreferenced textures found less than ALIAS_SWEEP_MS ago stay, however many submissions passed");
    }

    // The longest unused first, down to the cap: with a cap of 4.5 MB of the 5.5 MB U1-U3 hold (G, P, V are not unreferenced), only the oldest goes
    g_alias_sweep_cap = (int64_t)(1024 * MB); subs(ALIAS_SWEEP_IDLE);   // time passes with a cap nothing reaches
    CHECK(g_alias_swept == 0, "under the cap nothing goes, however long unused");
    seen_at(&U1, 1); seen_at(&U2, 2); seen_at(&U3, 3);   // long ago, U1 first
    g_fence_ns[1] = 1; g_fence_ns[2] = 2; g_fence_ns[3] = 3;   // and more than ALIAS_SWEEP_MS ago (the test runs in less)
    seen_at(&G, 1); seen_at(&P, 1); seen_at(&V, 1);
    g_alias_sweep_cap = (int64_t)(9 * MB / 2);
    uint64_t gen0 = g_ser_gen; __weak id<MTLTexture> wU1 = tU1; __weak id<MTLHeap> hU1 = tU1.heap;
    tU1 = nil; t[1] = nil; unsigned w0 = waiting();
    for (int i = 0; i <= ALIAS_SWEEP_EVERY && !g_alias_swept; i++) subs(1);   // up to the submission whose start sweeps
    CHECK(g_alias_swept == 1, "one texture is swept");
    CHECK(wU1 && waiting() == w0, "the swept texture stays alive (and its heap with it) until the submissions up to the sweep complete");
    pthread_mutex_lock(&g_deferred_mu); int queued = 0; for (NvDeferredRelease *d in g_deferred) queued |= d->object == wU1 && d->fence == atomic_load(&g_fence) + 1; pthread_mutex_unlock(&g_deferred_mu);
    CHECK(queued, "its release waits for the submission the sweep began");
    CHECK(!shared(wU1) && shared(tU2) && shared(tU3), "the longest unused goes first, the rest stay under the cap");
    CHECK(g_ser_gen > gen0, "the sweep sends every texture ID's cached view to be checked again");
    CHECK(shared(tL) && shared(tG) && shared(tP) && shared(tV), "a live, ghost-held, pinned texture and a live view's base stay");
    CHECK(hU1 && resident(hU1), "its heap is resident");
    settle(); settle();
    CHECK(!wU1, "then it is released");
    CHECK(hU1 && waiting() == w0 + 1, "and its heap waits for the next target");

    // Below the cap nothing goes; at 1 MB the rest of the unreferenced go (G, P and V still stay)
    g_alias_sweep_cap = (int64_t)(8 * MB); subs(ALIAS_SWEEP_EVERY + 1);
    CHECK(shared(tU2) && shared(tU3) && g_alias_swept == 1, "below the cap nothing goes");
    g_alias_sweep_cap = (int64_t)MB; subs(ALIAS_SWEEP_EVERY + 1);
    CHECK(!shared(tU2) && !shared(tU3) && g_alias_swept == 3, "past the cap the rest go");
    CHECK(shared(tL) && shared(tG) && shared(tP) && shared(tV), "and the held ones still stay");
    settle(); settle();

    // Made again over U1's storage, same description: counted, placed in a waiting heap and cleared as a new allocation is (NVN would still hold the 0x5a bytes)
    uint64_t again0 = g_alias_again, reused0 = g_rh_reused;
    tex_t U1b = target(&pool, 96012, 4 * MB); mtl_tex_init(&U1b);
    id<MTLTexture> tU1b = tex_mtl(&U1b);
    CHECK(tU1b && g_alias_again == again0 + 1, "a texture made again over swept storage is counted");
    CHECK(g_rh_reused > reused0, "it takes a waiting heap");
    CHECK(all_zero(tU1b), "and starts from zeros");
    mtl_tex_release(&U1b); tU1b = nil;

    // Accounting: a texture over a buffer and a view hold nothing of their own (res_size); the ledger runs over all of it
    {
        id<MTLBuffer> b = [g_dev newBufferWithLength:8 * MB options:MTLResourceStorageModeShared];
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm width:256 height:46 mipmapped:NO]; d.resourceOptions = b.resourceOptions;
        id<MTLTexture> lt = [b newTextureWithDescriptor:d offset:0 bytesPerRow:256];
        CHECK(lt && lt.allocatedSize >= 8 * MB, "Metal reports the whole buffer as a texture over it's allocated size");
        CHECK(res_size(lt) == 0 && res_size(view) == 0 && res_size(b) == b.allocatedSize, "res_size counts the buffer, not the texture over it or a view");
        pthread_mutex_lock(&g_res_mu); uint64_t r0 = g_res_bytes; pthread_mutex_unlock(&g_res_mu);
        res_add(b); res_add(lt);
        pthread_mutex_lock(&g_res_mu); uint64_t r1 = g_res_bytes; pthread_mutex_unlock(&g_res_mu);
        CHECK(r1 - r0 == b.allocatedSize, "the residency count takes the buffer once");
        lg_dump();
        res_remove(lt); res_remove(b);
        pthread_mutex_lock(&g_res_mu); uint64_t r2 = g_res_bytes; pthread_mutex_unlock(&g_res_mu);
        CHECK(r2 == r0, "and gives it back once");
    }
    serial_del(96107); view = nil;
    mtl_tex_release(&L);
    mtl_alias_drop_pool(&pool); settle(); free(mem);
    printf("t_alias_sweep: %d checks, %d failed\n", checks, failed); return failed != 0;
} }
