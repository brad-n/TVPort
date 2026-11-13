// Memory relief (DM_NVN_MEM_RELIEF, nvn_mtl.m mr_step) and the ledger's heap holders (nvn_ledger.inc lh_tally), through the real replay on the GPU. The held-heap pattern of
// Ocarina of Time on the Apple TV (run 19, ended at its memory limit 954 s in): recycled render-target heaps that nothing live needs, kept while the process ran out of memory by
//  1. the waiting list (RH): heaps whose targets are gone, under the cap and the idle time
//  2. a target dead by overwrite (another target's pass reached all of its storage after its last use) that its live texture object still names, inside rt_retire's hold for storage
//     the game came back to
//  3. unreferenced shared targets (their objects finalized), under the sweep's cap
// With plenty of memory the ledger names each heap's holder (every byte of the dm.rt heaps in the residency set) and all of them stay. Once the process is short of memory (the
// available memory faked under DM_NVN_MEM_RELIEF_MB) they go within a few submissions, out of the residency set, and Metal's allocation comes back by their heaps; the target still
// in use keeps its texture and its pixels, and the dead one drawn again holds its new ones. The look's hysteresis: on under the threshold, off 64 MB above it.
//  4. (with or without the relief: rt_retire's rule) a resolution family (image_texture: two sizes at one offset sharing a heap) whose every texture another target has drawn over
//     goes whole, its heap with it; a family with a texture still in use stays
// ./t_mem_relief [off]: DM_NVN_MEM_RELIEF=0 keeps them all under the same shortage
#define nvn_game_fps nvn_game_fps_mtl_default
#include "../nvn/nvn_mtl.m"
#undef nvn_game_fps
#define g_ft g_ft_hle
#include "../nvn/hle_nvn.c"
#undef g_ft
#define P(name) ((NVNT_##name)nvn_lookup(#name))
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, fails;
#define CHECK(c, label) do { checks++; if (!(c)) { fails++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } } while (0)
static uint8_t commands[16384] __attribute__((aligned(8))); static size_t used;
static void emit(unsigned op, const void *p, size_t n) {
    size_t size = (8 + n + 7) & ~7ull; op_hdr h = {op, (uint32_t)size};
    memcpy(commands + used, &h, 8); if (n) memcpy(commands + used + 8, p, n); used += size;
}
static NVNqueue queue; static prog_t pg = {.serial = 941001}; static void *vertices; static pool_t g_pool, g_pool2;
static void submit(void) { static uint64_t list; list = ctl_e(CTL_CHUNK, commands, used) | CTL_LAST; NVNcommandHandle hd = (NVNcommandHandle)&list;
    P(nvnQueueSubmitCommands)(&queue, 1, &hd); P(nvnQueueFinish)(&queue); used = 0; }
static tex_t target(pool_t *pool, uint64_t serial, uint64_t off, int fmt, uint32_t w, uint32_t h) {
    tex_t t = {.magic = MAGIC('T','E','X',0), .serial = serial, .pool = pool, .mem = (uint8_t *)pool->mem + off, .off = (int64_t)off};
    t.d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = fmt, .flags = NVN_TEXTURE_FLAGS_COMPRESSIBLE, .width = w, .height = h, .depth = 1, .levels = 1, .samples = 1};
    nvn_tex_layout(&t.d, &t.L); mtl_tex_init(&t); return t;
}
static void draw_all(tex_t *t) {   // one pass into t: a full-screen triangle drawn green
    const float tri[3][4] = {{-1, -1, .5f, 1}, {3, -1, .5f, 1}, {-1, 3, .5f, 1}}; memcpy(vertices, tri, sizeof tri);
    p_set_rt rt = {.n = 1}; rt.color[0] = t; emit(OP_SET_RT, &rt, sizeof rt);
    p_bind_program bp = {.prog = &pg, .stages = 3}; emit(OP_BIND_PROGRAM, &bp, sizeof bp);
    ds_st ds = {.df = NVN_DEPTH_FUNC_ALWAYS}; p_bind_state bs = {.kind = 5}; memcpy(bs.bytes, &ds, sizeof ds); emit(OP_BIND_STATE, &bs, sizeof bs);
    poly_st poly = {.cull = NVN_FACE_NONE, .mode = NVN_POLYGON_MODE_FILL}; bs.kind = 4; memcpy(bs.bytes, &poly, sizeof poly); emit(OP_BIND_STATE, &bs, sizeof bs);
    struct { int32_t first, n; va_st attr; } attr = {0, 1, {.fmt = NVN_FORMAT_RGBA32F}}; emit(OP_BIND_VATTR, &attr, sizeof attr);
    struct { int32_t first, n; vs_st stream; } stream = {0, 1, {.stride = 16}}; emit(OP_BIND_VSTREAM, &stream, sizeof stream);
    p_bind_vbuf1 vb = {.index = 0, .size = sizeof tri, .addr = (uint64_t)vertices}; emit(OP_BIND_VBUF1, &vb, sizeof vb);
    int w = (int)t->d.width, h = (int)t->d.height;
    p_scissor sc = {0, 0, w, h}; emit(OP_SCISSOR, &sc, sizeof sc);
    p_viewports v = {.first = 0, .n = 1}; v.v[0][2] = (float)w; v.v[0][3] = (float)h; v.v[0][5] = 1; emit(OP_VIEWPORTS, &v, sizeof v);
    p_draw d = {.prim = NVN_DRAW_PRIMITIVE_TRIANGLES, .count = 3, .instances = 1}; emit(OP_DRAW, &d, sizeof d);
    submit();
}
static void tick(int n) { for (int i = 0; i < n; i++) { mtl_sub_begin(); mtl_sub_commit(); mtl_drain(); } }
static void settle(void) { tick(2); dispatch_sync(g_feedback_q, ^{}); defer_drain(); tick(2); dispatch_sync(g_feedback_q, ^{}); defer_drain(); }
static void idle(void) { usleep((RR_MS + 150) * 1000); tick(RR_IDLE + 2 * RR_EVERY); settle(); }   // unused long enough for rt_retire
static void look(uint64_t avail_mb) { g_mr_fake = (int64_t)avail_mb; usleep(25 * 1000); tick(1); }   // the next look (every 20 ms) sees this much available
static uintptr_t shared_tex(const tex_t *t) { alias_key k = tex_alias_key(t); pthread_mutex_lock(&g_smu); void *o = nvn_hm_get(&g_alias, &k); pthread_mutex_unlock(&g_smu); return (uintptr_t)o; }
static int live(const tex_t *t) { return shared_tex(t) && serial_get(t->serial) != nil; }
static uintptr_t heap_of(const tex_t *t) { @autoreleasepool { uintptr_t a = shared_tex(t); return a ? (uintptr_t)(__bridge void *)((__bridge id<MTLTexture>)(void *)a).heap : 0; } }   // no reference kept
static int resident_addr(uintptr_t a) { if (!a) return 0; int r = 0; @autoreleasepool { pthread_mutex_lock(&g_res_mu); for (id o in g_res_objects) if ((uintptr_t)(__bridge void *)o == a) { r = 1; break; } pthread_mutex_unlock(&g_res_mu); } return r; }
static unsigned waiting(void) { os_unfair_lock_lock(&g_rh_lk); unsigned n = g_rh_n; os_unfair_lock_unlock(&g_rh_lk); return n; }
static uint64_t rt_heaps_b(void) {   // the dm.rt heaps the residency set holds (in a pool of its own: an array left in main's would keep every heap alive)
    uint64_t b = 0; @autoreleasepool { pthread_mutex_lock(&g_res_mu); NSArray *a = g_res_objects.allObjects; pthread_mutex_unlock(&g_res_mu);
        for (id o in a) if ([o conformsToProtocol:@protocol(MTLHeap)] && [((id<MTLHeap>)o).label isEqualToString:@"dm.rt"]) b += ((id<MTLHeap>)o).size; }
    return b;
}
static void ledger_lines(void) { @autoreleasepool { pthread_mutex_lock(&g_res_mu); NSArray *a = g_res_objects.allObjects; pthread_mutex_unlock(&g_res_mu); lg_heaps(a); } }
static void tally(lh_tot *t) { @autoreleasepool { pthread_mutex_lock(&g_res_mu); NSArray *a = g_res_objects.allObjects; pthread_mutex_unlock(&g_res_mu); lh_tally(a, t); } }
static uint64_t tsum(const lh_tot *t, int k) { uint64_t b = 0; for (int h = 0; h < LH_N; h++) b += t->b[k][h]; return b; }
static uint64_t tlive(const lh_tot *t, int k) { return t->b[k][LH_LIVE0] + t->b[k][LH_LIVE1] + t->b[k][LH_LIVE2] + t->b[k][LH_LIVE3]; }
static int all_green(tex_t *t) { @autoreleasepool {   // RGBA8 (0, 255, 0, 255) or RGBA16F (0, 1, 0, 1: half 0x3c00)
    int w = (int)t->d.width, h = (int)t->d.height, half = t->d.format == NVN_FORMAT_RGBA16F, bpp = half ? 8 : 4; size_t n = (size_t)w * h * bpp;
    id<MTLBuffer> px = [g_dev newBufferWithLength:n options:MTLResourceStorageModeShared];
    mtl_sub_begin(); res_add(px);
    enc_b_copy_texture_buffer(blit(), tex_mtl(t), 0, 0, MTLOriginMake(0, 0, 0), MTLSizeMake((NSUInteger)w, (NSUInteger)h, 1), px, 0, (NSUInteger)(w * bpp), n);
    int ok = mtl_wait(mtl_sub_commit(), 5000000000ull); const uint8_t *p = px.contents; const uint16_t *q = px.contents;
    if (half) for (size_t i = 0; ok && i < n / 2; i += 4) ok = q[i] == 0 && q[i + 1] == 0x3c00 && q[i + 2] == 0 && q[i + 3] == 0x3c00;
    else for (size_t i = 0; ok && i < n; i += 4) ok = p[i] == 0 && p[i + 1] == 255 && p[i + 2] == 0 && p[i + 3] == 255;
    res_remove(px); return ok;
} }
int main(int argc, char **argv) { @autoreleasepool {
    int off = argc > 1 && !strcmp(argv[1], "off");
    setenv("DM_NVN_MEM_RELIEF", off ? "0" : "1", 1); setenv("DM_NVN_MEM_RELIEF_FAKE_AVAIL_MB", "4096", 1);   // plenty to begin with
    setenv("DM_NVN_RH_CAP_MB", "256", 1); setenv("DM_NVN_RH_IDLE_MS", "60000", 1); setenv("DM_NVN_ALIAS_SWEEP_MB", "256", 1);   // the cap, idle time and sweep cap keep what the relief gives back
    mtl_init(); NSError *error = nil;
    id<MTLLibrary> library = [g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
        "struct I { float4 p [[attribute(0)]]; };\n"
        "vertex float4 v(I i [[stage_in]]) { return i.p; }\n"
        "fragment float4 f() { return float4(0, 1, 0, 1); }\n" options:nil error:&error];
    CHECK(library != nil, "test shaders compile"); if (!library) return 1;
    NvProg *program = [NvProg new];
    NvShader *vs = [NvShader new]; vs->fn = [library newFunctionWithName:@"v"]; vs->rf.nv = 1; vs->rf.v[0].ct = NVN_CT_FLOAT;
    memset(vs->rf.v[0].sh, 0xff, sizeof vs->rf.v[0].sh); vs->rf.pos_attr = 0; vs->rf.pos_w1 = 1; program->sh[0] = vs;
    NvShader *fs = [NvShader new]; fs->fn = [library newFunctionWithName:@"f"]; fs->stage = 1; fs->rf.color_mask = 1; program->sh[1] = fs; serial_put(pg.serial, program);
    if (posix_memalign(&vertices, (size_t)getpagesize(), 65536)) return 1;
    memset(vertices, 0, 65536); mtl_pool_add(vertices, 65536);
    const uint64_t MB = 1 << 20; void *mem = NULL, *mem2 = NULL;
    if (posix_memalign(&mem, 16384, 64 * MB) || posix_memalign(&mem2, 16384, 32 * MB)) return 1;
    const uint32_t gpu_only = NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS | NVN_MEMORY_POOL_FLAGS_GPU_CACHED | NVN_MEMORY_POOL_FLAGS_COMPRESSIBLE;
    g_pool = (pool_t){.magic = MAGIC('P','O','O','L'), .flags = gpu_only, .mem = mem, .size = 64 * MB};
    g_pool2 = (pool_t){.magic = MAGIC('P','O','O','L'), .flags = gpu_only, .mem = mem2, .size = 32 * MB};
    static NVNdevice device; NVNdeviceBuilder db = {0}; P(nvnDeviceBuilderSetDefaults)(&db); CHECK(P(nvnDeviceInitialize)(&device, &db), "device initialized");
    NVNqueueBuilder qb = {0}; P(nvnQueueBuilderSetDefaults)(&qb); P(nvnQueueBuilderSetDevice)(&qb, &device); CHECK(P(nvnQueueInitialize)(&queue, &qb), "queue initialized");
    mtl_queue_activate(((queue_t *)&queue)->serial);
    tick(1);
    CHECK(mr_mode() == !off && !mr_active(), off ? "the switch off" : "the switch on (set here; the Mac's default is off), not short of memory");
    CHECK(rr_mode() == 1, "render targets dead by overwrite are retired (DM_NVN_RT_RETIRE's default)");

    // 1. waiting: W1-W3 in a second pool, drawn, finalized and the pool gone: their heaps wait for the next target (the cap and idle time keep them)
    tex_t W1 = target(&g_pool2, 941101, 0, NVN_FORMAT_RGBA16F, 1280, 720), W2 = target(&g_pool2, 941102, 8 * MB, NVN_FORMAT_RGBA16F, 1280, 720), W3 = target(&g_pool2, 941103, 16 * MB, NVN_FORMAT_RGBA16F, 1280, 720);
    draw_all(&W1); draw_all(&W2); draw_all(&W3);
    uintptr_t hW[3] = {heap_of(&W1), heap_of(&W2), heap_of(&W3)};
    mtl_tex_release(&W1); mtl_tex_release(&W2); mtl_tex_release(&W3); mtl_alias_drop_pool(&g_pool2);
    // 3. unreferenced: U1, U2 drawn (the replay's pass state lets W3 go: it holds the last pass's target), then their objects finalized; the sweep's cap (256 MB here) keeps them
    tex_t U1 = target(&g_pool, 941301, 24 * MB, NVN_FORMAT_RGBA8, 1280, 720), U2 = target(&g_pool, 941302, 32 * MB, NVN_FORMAT_RGBA8, 1280, 720);
    draw_all(&U1); draw_all(&U2);
    uintptr_t hU1 = heap_of(&U1), hU2 = heap_of(&U2);
    CHECK(hU1 && hU2 && hU1 != hU2, "U1 and U2 are GPU-only targets in placement heaps of their own");
    mtl_tex_release(&U1); mtl_tex_release(&U2);
    for (int i = 0; i < 20 && waiting() < 3; i++) settle();   // W1-W3's textures go once the submissions that used them complete
    CHECK(waiting() == 3 && resident_addr(hW[0]) && resident_addr(hW[1]) && resident_addr(hW[2]), "W1-W3's heaps wait, resident");
    usleep(1100 * 1000);   // the sweep takes only entries unused for ALIAS_SWEEP_MS too
    // 2. dead by overwrite: A (RGBA8) drawn, then B (RGBA16F, twice its size) drawn over all of A's storage; A's object lives on, unused. Its storage is one the game came back to
    // after a retire (the hold: twice that pause plus RR_MS, at most RR_HOLD_MS)
    tex_t A = target(&g_pool, 941201, 0, NVN_FORMAT_RGBA8, 1920, 1080), B = target(&g_pool, 941202, 0, NVN_FORMAT_RGBA16F, 1920, 1080);
    draw_all(&A); uintptr_t hA = heap_of(&A); tick(1); draw_all(&B); uintptr_t hB = heap_of(&B);
    { alias_key k = tex_alias_key(&A); pthread_mutex_lock(&g_smu); nvn_hm_put(&g_rr_hold, &k, (void *)(uintptr_t)(RR_HOLD_MS + 1)); pthread_mutex_unlock(&g_smu); }
    uint64_t t_dead = clock_gettime_nsec_np(CLOCK_MONOTONIC);
    tick(RR_IDLE + 2 * RR_EVERY); settle(); draw_all(&B);   // B, the target in use, is used again
    double since = (clock_gettime_nsec_np(CLOCK_MONOTONIC) - t_dead) / 1e9;
    CHECK(since < RR_HOLD_MS / 1000.0 * 0.8, "the steps so far ran well inside the hold");
    CHECK(live(&A) && live(&B) && hA && hB && hA != hB, "A, dead by overwrite, is still named by its live object (the hold), as is B");
    CHECK(shared_tex(&U1) && shared_tex(&U2) && !serial_get(U1.serial), "U1 and U2 wait in the sharing table, unreferenced (under the sweep's cap)");

    // the ledger names a holder for every MB of the recycled heaps
    lh_tot t0; tally(&t0);
    uint64_t heaps0 = rt_heaps_b(), hsz = 0;
    @autoreleasepool { for (int i = 0; i < 3; i++) hsz += ((__bridge id<MTLHeap>)(void *)hW[i]).size; }
    CHECK(tsum(&t0, 0) == heaps0 && heaps0 > 0, "the holders' MB add up to the dm.rt heaps in the residency set");
    CHECK(t0.n[0][LH_WAIT] == 3 && t0.b[0][LH_WAIT] == hsz, "the three waiting heaps are named as waiting (RH), with their sizes");
    CHECK(t0.n[0][LH_UNREF] == 2, "U1 and U2's heaps: unreferenced shared textures");
    CHECK(t0.n[0][LH_LIVE0] + t0.n[0][LH_LIVE1] + t0.n[0][LH_LIVE2] + t0.n[0][LH_LIVE3] == 2 && t0.dn[0] == 1 && t0.an[0] == 1, "A and B's heaps: live texture objects', A's drawn over since its last use, over storage the game came back to");
    CHECK(t0.n[0][LH_ELSE] == 0, "no heap is left without a holder the host's tables show");
    CHECK(tlive(&t0, 0) + t0.b[0][LH_WAIT] + t0.b[0][LH_UNREF] == heaps0, "nothing else holds a recycled heap here");
    ledger_lines();   // the ledger's lines (printed)

    // short of memory: under DM_NVN_MEM_RELIEF_MB
    uint64_t alloc0 = g_dev.currentAllocatedSize, rr0 = g_rr_n;
    look(g_mr_low - 1);
    CHECK(mr_active() == !off, off ? "off: never short of memory" : "under the threshold: short of memory");
    tick(RR_EVERY); settle(); tick(RR_EVERY / 4); settle();
    uint64_t alloc1 = g_dev.currentAllocatedSize, heaps1 = rt_heaps_b();
    if (!off) {
        CHECK(!live(&A) && g_rr_n > rr0 && g_mr_n[MR_RETIRE] >= 1, "A, dead by overwrite, is retired inside its hold");
        CHECK(live(&B) && heap_of(&B) == hB, "B, in use, keeps its texture");
        CHECK(!shared_tex(&U1) && !shared_tex(&U2) && g_mr_n[MR_SWEEP] >= 2, "U1 and U2 are swept under the sweep's cap");
        CHECK(waiting() == 0 && g_mr_n[MR_RH] >= 3, "every waiting heap is freed");
        CHECK(!resident_addr(hW[0]) && !resident_addr(hW[1]) && !resident_addr(hW[2]) && !resident_addr(hA) && !resident_addr(hU1) && !resident_addr(hU2), "and those heaps left the residency set");
        CHECK(resident_addr(hB), "B's heap stays");
        CHECK(heaps0 - heaps1 >= hsz && heaps1 > 0, "the recycled heaps in the set come down by at least the waiting ones");
        CHECK(alloc0 > alloc1 && alloc0 - alloc1 >= (heaps0 - heaps1) * 9 / 10, "Metal's allocation comes back by about what the heaps held");
        lh_tot t1; tally(&t1);
        CHECK(t1.n[0][LH_WAIT] == 0 && t1.n[0][LH_UNREF] == 0 && t1.dn[0] == 0 && tsum(&t1, 0) == heaps1, "the ledger: no waiting, unreferenced or dead heap left; what is left adds up");
        printf("t_mem_relief: recycled heaps %.1f -> %.1f MB, Metal allocation %.1f -> %.1f MB\n", heaps0 / (double)MB, heaps1 / (double)MB, alloc0 / (double)MB, alloc1 / (double)MB);
        CHECK(all_green(&B), "B keeps its pixels");
        uint64_t again = g_rr_again; draw_all(&A);
        CHECK(live(&A) && g_rr_again == again + 1 && all_green(&A), "A drawn again gets a new texture with its new pixels");
        // the hysteresis: on under the threshold, off 64 MB above it
        look(g_mr_low + 32); CHECK(mr_active(), "within 64 MB above the threshold it stays short of memory");
        look(g_mr_high); CHECK(!mr_active(), "64 MB above it: no longer");
        look(g_mr_low + 32); CHECK(!mr_active(), "and between the two it stays so");
        look(g_mr_low - 1); CHECK(mr_active() && g_mr_episodes == 2, "under it again: a second episode");
        look(4096); CHECK(!mr_active(), "plenty again");
    } else {
        CHECK(shared_tex(&U1) && shared_tex(&U2) && waiting() == 3, "off: U1, U2 and the waiting heaps all stay");
        if ((clock_gettime_nsec_np(CLOCK_MONOTONIC) - t_dead) / 1e6 < RR_HOLD_MS * 0.9) CHECK(live(&A) && heaps1 == heaps0, "off: A stays inside its hold, and the heaps as they were");
    }
    // 4. resolution families: F1 / F2 (RGBA8 1280x720 and 960x540 at one offset) share a heap; D (RGBA16F) is drawn over all of it after their last use. G1 / G2 the same at
    // another offset, but G2 is drawn again after D2 covers them
    look(4096);
    tex_t F1 = target(&g_pool, 941401, 40 * MB, NVN_FORMAT_RGBA8, 1280, 720), F2 = target(&g_pool, 941402, 40 * MB, NVN_FORMAT_RGBA8, 960, 540), D = target(&g_pool, 941403, 40 * MB, NVN_FORMAT_RGBA16F, 1280, 720);
    tex_t G1 = target(&g_pool, 941501, 52 * MB, NVN_FORMAT_RGBA8, 640, 360), G2 = target(&g_pool, 941502, 52 * MB, NVN_FORMAT_RGBA8, 480, 270), D2 = target(&g_pool, 941503, 52 * MB, NVN_FORMAT_RGBA16F, 640, 360);
    draw_all(&F1); draw_all(&F2); draw_all(&G1); draw_all(&G2);
    uintptr_t hF = heap_of(&F1), hG = heap_of(&G1);
    @autoreleasepool { CHECK(hF && hF == heap_of(&F2) && [((__bridge id<MTLHeap>)(void *)hF).label isEqualToString:@"dm.image"], "F1 and F2 share an image family's heap"); }
    CHECK(hG && hG == heap_of(&G2), "so do G1 and G2");
    uint64_t fam0 = g_rr_fam_n;
    tick(1); draw_all(&D); draw_all(&D2); tick(1); draw_all(&G2);   // D over F1 and F2; D2 over G1 and G2, then G2 drawn again
    idle(); draw_all(&G2); draw_all(&D); idle();
    CHECK(!shared_tex(&F1) && !shared_tex(&F2) && g_rr_fam_n == fam0 + 1, "the family every texture of which was drawn over is retired whole");
    settle();
    CHECK(!resident_addr(hF), "and its heap leaves the residency set");
    CHECK(live(&G1) && live(&G2) && heap_of(&G1) == hG && resident_addr(hG), "the family with a texture still in use stays, G1 with it");
    CHECK(g_rr_kept_n[RRK_FAMILY] >= 1, "the ledger's retire line counts it: a family with a member that stays");
    draw_all(&F1);
    CHECK(live(&F1) && all_green(&F1), "F1 drawn again gets a new texture with its pixels");
    settle();
    CHECK(!mtl_last_commit_error(), "no GPU error");
    mtl_pool_del(vertices); free(vertices);
    printf("t_mem_relief%s: %d checks, %d failed (given back: waiting heaps %llu, swept %llu, retired early %llu)\n", off ? " (off)" : "", checks, fails,
           (unsigned long long)g_mr_n[MR_RH], (unsigned long long)g_mr_n[MR_SWEEP], (unsigned long long)g_mr_n[MR_RETIRE]);
    return fails != 0;
} }
