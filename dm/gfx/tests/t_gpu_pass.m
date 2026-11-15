// GPU pass efficiency (DM_NVN_BARRIER=game, DM_NVN_LAZY_CLEAR_BINDLESS): the draw-pass entry barrier decision, with an image heap present too (upstream's draw barriers, e7750541: no full
// barrier for it, the start barriers flush the aliases), and the waiting clears' sampling test for texture-handle programs. ./t_gpu_pass [global]  (global: DM_NVN_LAZY_CLEAR_BINDLESS=0)
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } } while (0)
static tex_t ta = {.magic=MAGIC('T','E','X',0), .serial=99601}, tb = {.magic=MAGIC('T','E','X',0), .serial=99602}, tc = {.magic=MAGIC('T','E','X',0), .serial=99603};
static id<MTLTexture> g_ha, g_hb; static id<MTLHeap> g_heap;

static void pass(id<MTLTexture> t, const char *what) {
    (void)what;
    MTL4RenderPassDescriptor *p = [MTL4RenderPassDescriptor new];
    p.colorAttachments[0].texture = t; p.colorAttachments[0].loadAction = MTLLoadActionClear; p.colorAttachments[0].storeAction = MTLStoreActionStore;
    p.colorAttachments[0].clearColor = MTLClearColorMake(1, 0, 0, 1);
    id<MTL4RenderCommandEncoder> e = enc_r_begin_pass(p); enc_r_end_pass(e);
}
static void barrier_case(void) {
    uint64_t w0[6], w1[6], s0, f0, s1, f1;
    id<MTLTexture> plain = tex_mtl(&ta);
    // 1. no image heap: the relaxed barriers as before (the first pass of a run is full, the rest saved; a game barrier makes one full)
    state_reset(); memset(&R, 0, sizeof R); mtl_sub_begin(); g_last_end_relaxed = 0; g_game_barrier = 0;
    mtl_barrier_stats(&s0, &f0); mtl_barrier_why(w0);
    pass(plain, "a"); pass(plain, "b"); pass(plain, "c"); g_game_barrier = 1; pass(plain, "d"); pass(plain, "e");
    mtl_barrier_stats(&s1, &f1); mtl_barrier_why(w1);
    CHECK(f1 - f0 == 2 && s1 - s0 == 3, "no heap: first pass and the pass after a game barrier are full, the other three saved");
    CHECK(w1[4] - w0[4] == 1 && w1[3] - w0[3] == 1, "no heap: reasons are 'previous encoder not relaxed' and 'game barrier'");
    CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull), "submission completes");
    // 2. an image heap exists (one live family): no pass takes the full barrier for it; every start barrier carries the resource-alias flush (start_vis), a skipped one before the fragments
    NvImageHeap *owner = [NvImageHeap new]; owner->heap = g_heap; atomic_fetch_add(&g_image_heap_n, 1);
    objc_setAssociatedObject(g_ha, &g_image_heap_owner_key, owner, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(g_hb, &g_image_heap_owner_key, owner, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    state_reset(); memset(&R, 0, sizeof R); mtl_sub_begin(); g_last_end_relaxed = 0; g_game_barrier = 0; g_pass_swrite = 0;
    CHECK(start_vis() & MTL4VisibilityOptionResourceAlias, "with an image heap the start barriers carry the resource-alias flush");
    mtl_barrier_stats(&s0, &f0); mtl_barrier_why(w0);
    pass(plain, "1"); pass(plain, "2"); pass(plain, "3");   // full, saved, saved
    pass(g_ha, "h");                                        // heap attachment: saved (its aliases flushed before its fragments)
    pass(plain, "4"); pass(plain, "5");                     // saved, saved
    g_game_barrier = 1; pass(plain, "6"); pass(plain, "7"); // game barrier: full; saved
    pass(plain, "8"); g_pass_swrite = 1; enc_r_end_pass(enc_r_begin_pass(({ MTL4RenderPassDescriptor *p = [MTL4RenderPassDescriptor new]; p.colorAttachments[0].texture = plain; p.colorAttachments[0].loadAction = MTLLoadActionClear; p.colorAttachments[0].storeAction = MTLStoreActionStore; p; })));   // shader writes: the next start barrier flushes (alias_mark), no full barrier
    g_pass_swrite = 0; pass(plain, "9");                    // saved
    mtl_barrier_stats(&s1, &f1); mtl_barrier_why(w1);
    // passes: 1 full, 2 s, 3 s, h s, 4 s, 5 s, 6 full (game), 7 s, 8 s, swrite pass s, 9 s
    CHECK(f1 - f0 == 2 && s1 - s0 == 9, "image heap: only the first pass and the one after a game barrier are full");
    CHECK(w1[4] - w0[4] == 1 && w1[3] - w0[3] == 1 && w1[0] - w0[0] == 0 && w1[1] - w0[1] == 0 && w1[2] - w0[2] == 0, "image heap: reasons are first and game barrier, none for the heap");
    // the data a heap pass wrote through one variant is there through the other after the relaxed passes that follow
    id<MTLBuffer> bf = [g_dev newBufferWithLength:256 options:MTLResourceStorageModeShared];
    [blit() copyFromTexture:g_hb sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(8, 8, 1) toBuffer:bf destinationOffset:0 destinationBytesPerRow:32 destinationBytesPerImage:256];
    CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull) && !mtl_last_commit_error(), "heap submission completes");
    const uint8_t *px = bf.contents; int red = 1; for (int i = 0; i < 64; i++) red &= px[4 * i] == 255 && px[4 * i + 1] == 0 && px[4 * i + 3] == 255;
    CHECK(red, "the red a pass wrote to one heap variant reads back through the aliased variant");
    objc_setAssociatedObject(g_ha, &g_image_heap_owner_key, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(g_hb, &g_image_heap_owner_key, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    owner = nil;
}

static NvProg *handle_prog(int kind) {   // a fragment shader with texture handles the host cannot read (kind) beside a bindless flag
    NvProg *pr = [NvProg new]; pr->sh[1] = [NvShader new]; pr->sh[1]->stage = 1; pr->sh[1]->rf.bindless = 1; pr->sh[1]->rf.nb = 1; pr->sh[1]->rf.b[0] = (nvn_rbind){.kind = kind};
    return pr;
}
static void lazy_clear_case(int bindless_on) {
    state_reset(); memset(&R, 0, sizeof R); mtl_sub_begin(); g_nlc = 0;
    R.rt.n = 1; R.rt.color[0] = &tb; R.has_rt = 1; R.clear_c[0] = 1; R.cc[0] = MTLClearColorMake(0, 1, 0, 1); lc_push();
    CHECK(g_nlc == 1 && !R.clear_c[0], "a clear with no draw waits");
    NvProg *pr = handle_prog(NVN_RB_TEXA);
    if (!bindless_on) { CHECK(lc_sampled(pr) == 1 && g_lc_reason == 1, "off: a texture-handle program counts as sampling the waiting clear"); }
    else {
        CHECK(lc_sampled(pr) == 0, "a texture-handle program does not sample a texture no descriptor was ever written for");
        // the draw attaches the cleared target: the clear is its load action, no pass of its own
        uint64_t t0 = g_lc_taken, l0 = g_lc_landed;
        memset(&R, 0, sizeof R); R.rt.n = 1; R.rt.color[0] = &tb; R.has_rt = 1;
        lc_take(pr);
        CHECK(g_lc_taken == t0 + 1 && g_lc_landed == l0 && R.clear_c[0] == 1 && g_nlc == 0, "bindless draw: the waiting clear became the pass's load action (taken, nothing landed)");
        // a texture with a descriptor may be sampled through a handle table: the clear lands first
        state_reset(); memset(&R, 0, sizeof R); g_nlc = 0;
        R.rt.n = 1; R.rt.color[0] = &tc; R.has_rt = 1; R.clear_c[0] = 1; lc_push();
        mtl_reg_tex(7, &tc, NULL);
        CHECK(tex_ever_registered(tc.serial) && !tex_ever_registered(tb.serial), "registration is remembered per serial");
        CHECK(lc_sampled(pr) == 1 && g_lc_reason == 1, "a registered texture may be sampled by a handle-table draw: counts as sampled");
        uint64_t y0 = g_lc_why[1]; memset(&R, 0, sizeof R); R.rt.n = 1; R.rt.color[0] = &tb; R.has_rt = 1; lc_take(pr);
        CHECK(g_lc_why[1] == y0 + 1 && g_nlc == 0, "...and lands in a pass of its own, counted under that reason");
        // the draw attaches other targets: the leftover lands (reason 2)
        state_reset(); memset(&R, 0, sizeof R); g_nlc = 0;
        R.rt.n = 1; R.rt.color[0] = &tb; R.has_rt = 1; R.clear_c[0] = 1; lc_push();
        uint64_t z0 = g_lc_why[2]; memset(&R, 0, sizeof R); R.rt.n = 1; R.rt.color[0] = &ta; R.has_rt = 1; lc_take(pr);
        CHECK(g_lc_why[2] == z0 + 1 && g_nlc == 0, "a waiting clear of a target the draw does not attach lands, counted as such");
    }
    CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull) && !mtl_last_commit_error(), "lazy clear submission completes");
}

int main(int argc, char **argv) { @autoreleasepool {
    int global = argc > 1 && !strcmp(argv[1], "global");
    setenv("DM_NVN_BARRIER", "game", 1); setenv("DM_NVN_LAZY_CLEAR_BINDLESS", global ? "0" : "1", 1);
    mtl_init(); CHECK(barrier_game() == 1, "switches read");
    tex_t *all[] = {&ta, &tb, &tc};
    for (int i = 0; i < 3; i++) all[i]->d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = NVN_FORMAT_RGBA8, .width = 8, .height = 8, .depth = 1, .levels = 1, .samples = 1};
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:8 height:8 mipmapped:NO];
    d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; d.storageMode = MTLStorageModePrivate;
    MTLHeapDescriptor *hd = [MTLHeapDescriptor new]; hd.type = MTLHeapTypePlacement; hd.storageMode = MTLStorageModePrivate; hd.hazardTrackingMode = MTLHazardTrackingModeUntracked;
    hd.size = [g_dev heapTextureSizeAndAlignWithDescriptor:d].size; g_heap = [g_dev newHeapWithDescriptor:hd];
    g_ha = [g_heap newTextureWithDescriptor:d offset:0]; g_hb = [g_heap newTextureWithDescriptor:d offset:0];
    CHECK(g_heap && g_ha && g_hb, "placement heap with two aliased variants");
    barrier_case();
    lazy_clear_case(!global);
    printf("GPU_PASS %s: %d checks, %d failed\n", global ? "global" : "pass", checks, failed); return failed != 0;
} }
