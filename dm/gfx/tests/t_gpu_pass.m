// GPU pass efficiency (DM_NVN_BARRIER_HEAP, DM_NVN_LAZY_CLEAR_BINDLESS, DM_NVN_STORE_ELIDE): the draw-pass entry barrier decision with an image heap present, the waiting clears' sampling test
// for texture-handle programs, and the store lookahead's verdicts for a texture-handle draw, a partial clear and a copy. ./t_gpu_pass [global]  (global: DM_NVN_BARRIER_HEAP=global, the old behaviour)
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
static void barrier_case(int global) {
    uint64_t w0[6], w1[6], s0, f0, s1, f1;
    id<MTLTexture> plain = tex_mtl(&ta);
    // 1. no image heap: the relaxed barriers as before (the first pass of a run is full, the rest saved; a game barrier makes one full)
    state_reset(); memset(&R, 0, sizeof R); mtl_sub_begin(); g_last_end_relaxed = 0; g_last_end_heap = 0; g_game_barrier = 0;
    mtl_barrier_stats(&s0, &f0); mtl_barrier_why(w0);
    pass(plain, "a"); pass(plain, "b"); pass(plain, "c"); g_game_barrier = 1; pass(plain, "d"); pass(plain, "e");
    mtl_barrier_stats(&s1, &f1); mtl_barrier_why(w1);
    CHECK(f1 - f0 == 2 && s1 - s0 == 3, "no heap: first pass and the pass after a game barrier are full, the other three saved");
    CHECK(w1[4] - w0[4] == 1 && w1[3] - w0[3] == 1, "no heap: reasons are 'previous encoder not relaxed' and 'game barrier'");
    CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull), "submission completes");
    // 2. an image heap exists (one live family)
    NvImageHeap *owner = [NvImageHeap new]; owner->heap = g_heap; atomic_fetch_add(&g_image_heap_n, 1);
    objc_setAssociatedObject(g_ha, &g_image_heap_owner_key, owner, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(g_hb, &g_image_heap_owner_key, owner, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    CHECK(tex_heap_backed(g_ha) && tex_heap_backed(g_hb) && !tex_heap_backed(plain), "heap-backed textures are recognised, a plain one is not");
    state_reset(); memset(&R, 0, sizeof R); mtl_sub_begin(); g_last_end_relaxed = 0; g_last_end_heap = 0; g_game_barrier = 0; g_pass_swrite = 0;
    mtl_barrier_stats(&s0, &f0); mtl_barrier_why(w0);
    pass(plain, "1"); pass(plain, "2"); pass(plain, "3");   // full, saved, saved
    pass(g_ha, "h");                                        // heap attachment: full (and a full end)
    pass(plain, "4"); pass(plain, "5");                     // after a heap pass: full; then saved
    g_game_barrier = 1; pass(plain, "6"); pass(plain, "7"); // game barrier: full; saved
    pass(plain, "8"); g_pass_swrite = 1; enc_r_end_pass(enc_r_begin_pass(({ MTL4RenderPassDescriptor *p = [MTL4RenderPassDescriptor new]; p.colorAttachments[0].texture = plain; p.colorAttachments[0].loadAction = MTLLoadActionClear; p.colorAttachments[0].storeAction = MTLStoreActionStore; p; })));   // shader writes with a heap present: full end
    g_pass_swrite = 0; pass(plain, "9");                    // after it: full
    mtl_barrier_stats(&s1, &f1); mtl_barrier_why(w1);
    if (global) {
        CHECK(s1 - s0 == 0 && f1 - f0 == 11, "global: every pass is full while an image heap exists");
        CHECK(w1[0] - w0[0] == 11, "global: the reason is 'an image heap in the game'");
    } else {
        // passes: 1 full, 2 s, 3 s, h full, 4 full, 5 s, 6 full (game), 7 s, 8 s, swrite pass s, 9 full
        CHECK(f1 - f0 == 5 && s1 - s0 == 6, "pass: only the first, the heap, the one after it, the game barrier and the one after shader writes are full");
        CHECK(w1[4] - w0[4] == 1 && w1[1] - w0[1] == 1 && w1[2] - w0[2] == 2 && w1[3] - w0[3] == 1 && w1[0] - w0[0] == 0, "pass: reasons are first, heap attachment, after a heap pass (twice), game barrier");
    }
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

// ---- store lookahead verdicts (sdx_decide) on hand-built streams
static uint8_t g_code[4096]; static size_t g_len; static const uint8_t *g_opat[64]; static int g_nop;
static void emit(uint32_t op, const void *pl, size_t n) { size_t sz = (8 + n + 7) & ~(size_t)7; op_hdr h = {op, (uint32_t)sz}; g_opat[g_nop++] = g_code + g_len; memset(g_code + g_len, 0, sz); memcpy(g_code + g_len, &h, 8); if (n) memcpy(g_code + g_len + 8, pl, n); g_len += sz; }
static void e_rt(const tex_t *t) { p_set_rt r = {0}; r.n = 1; r.color[0] = t; emit(OP_SET_RT, &r, sizeof r); }
static void e_clear(void) { p_clear_color c = {.index = 0, .mask = 0xf, .rgba = {0, 0, 1, 1}}; emit(OP_CLEAR_COLOR, &c, sizeof c); }
static void e_draw(void) { p_draw d = {NVN_DRAW_PRIMITIVE_TRIANGLES, 0, 3}; emit(OP_DRAW, &d, sizeof d); }
static void e_prog(prog_t *pg) { p_bind_program b = {pg, 3}; emit(OP_BIND_PROGRAM, &b, sizeof b); }
// verdict for the attachment ta at the pass end `at` (the op index), the stream built by `build`; returns sdx_decide's byte (2 = redundant, else why << 2)
static int verdict(int at) {
    emit(OP_END, NULL, 0); uint64_t h = (uint64_t)(uintptr_t)g_code;
    state_reset(); memset(&R, 0, sizeof R); mtl_sub_begin(); mtl_sub_index(&h, 1);
    for (int i = 0; i <= at; i++) { g_exec_cur = g_opat[i]; sdx_seq(g_opat[i]); }
    g_nsd = 1; g_sd[0] = (sd_att){.ser = ta.serial, .bytes = 256, .idx = 0}; uint8_t st[SD_ATT_MAX] = {0};
    int ok = sdx_decide(st); g_nsd = 0; mtl_sub_commit();
    if (getenv("GP_DEBUG")) fprintf(stderr, "verdict at %d: ok %d st %d (index ok %d nop %u nev %u)\n", at, ok, st[0], g_sdx_ok, g_sdx_nop, g_sdx_n);
    return ok ? st[0] : -1;
}
static prog_t pg_plain = {.serial = 99611}, pg_bl = {.serial = 99612}, pg_tex = {.serial = 99613};
static void lookahead_case(void) {
    // stream: 0 bind program 1 SET_RT(ta) 2 draw   [the pass ends at op 3]   3 SET_RT(tb) 4 draw   5 SET_RT(ta) 6 clear 7 draw
    g_len = 0; g_nop = 0; e_prog(&pg_tex); { p_bind_handles b = {.stage = 1, .first = 0, .n = 1}; b.h[0] = 9; emit(OP_BIND_TEX, &b, sizeof b); } e_rt(&ta); e_draw(); e_rt(&tb); e_draw(); e_rt(&ta); e_clear(); e_draw();
    CHECK(verdict(4) == (1 << 2), "sampled in a texture slot by a later draw before the clear: needed (never elided)");
    #define BEGIN g_len = 0; g_nop = 0; e_prog(&pg_plain); e_rt(&ta); e_draw(); e_rt(&tb)
    BEGIN; e_draw(); e_rt(&ta); e_clear(); e_draw();
    CHECK(verdict(3) == 2, "cleared whole before its next use: redundant");
    BEGIN; e_draw(); e_rt(&ta); e_draw();
    CHECK(verdict(3) == (2 << 2), "drawn into again before any clear (loaded): needed");
    BEGIN; e_draw(); e_rt(&ta); { p_scissor sc = {0, 0, 4, 4}; emit(OP_SCISSOR, &sc, sizeof sc); } e_clear(); e_draw();
    CHECK(verdict(3) == (2 << 2), "a partial-scissor clear is not a whole overwrite: needed");
    BEGIN; { p_copy_t2t c = {0}; c.src = &ta; c.dst = &tc; emit(OP_COPY_T2T, &c, sizeof c); } e_rt(&ta); e_clear(); e_draw();
    CHECK(verdict(3) == (3 << 2), "copied from before the clear: needed");
    BEGIN; e_prog(&pg_bl); e_draw(); e_rt(&ta); e_clear(); e_draw();
    CHECK(verdict(3) == (9 << 2), "a texture-handle draw comes before the clear and the texture has a descriptor: kept");
    // the same draw, a texture no descriptor was ever written for
    ta.serial = 99650;
    BEGIN; e_prog(&pg_bl); e_draw(); e_rt(&ta); e_clear(); e_draw();
    CHECK(verdict(3) == 2, "...but redundant for a texture no descriptor names (nothing can sample it)");
    BEGIN; e_prog(&pg_plain); e_draw(); e_rt(&ta); e_clear(); e_draw();
    CHECK(verdict(3) == 2, "a plain draw in between does not keep it");
    BEGIN; e_draw();
    CHECK(verdict(3) == (5 << 2), "no later event in the submission: kept (a later frame may read it)");
    ta.serial = 99601;
}
static void store_case(void) {
    // end-to-end: store elision turns the store into DontCare for a texture a later pass clears whole, and the picture is right
    uint64_t n0 = g_el_store_n, b0 = g_el_store_bytes;
    ta.serial = 99660; tex_mtl(&ta);
    g_len = 0; g_nop = 0; e_rt(&ta); e_prog(&pg_plain); e_draw(); e_rt(&tb); e_draw(); e_rt(&ta); e_clear(); e_draw(); emit(OP_END, NULL, 0);
    uint64_t h = (uint64_t)(uintptr_t)g_code;
    state_reset(); memset(&R, 0, sizeof R); mtl_sub_begin(); mtl_sub_index(&h, 1); mtl_exec(g_code);
    id<MTLBuffer> bf = [g_dev newBufferWithLength:256 options:MTLResourceStorageModeShared];
    [blit() copyFromTexture:tex_mtl(&ta) sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(8, 8, 1) toBuffer:bf destinationOffset:0 destinationBytesPerRow:32 destinationBytesPerImage:256];
    CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull) && !mtl_last_commit_error(), "store elision submission completes");
    CHECK(g_el_store_n == n0 + 1 && g_el_store_bytes > b0, "the first pass's store of ta was elided");
    const uint8_t *px = bf.contents; int red = 1; for (int i = 0; i < 64; i++) red &= px[4 * i] == 255 && px[4 * i + 1] == 0 && px[4 * i + 2] == 0;
    CHECK(red, "the final picture is the last pass's draw over the later clear");
    ta.serial = 99601;
}
int main(int argc, char **argv) { @autoreleasepool {
    int global = argc > 1 && !strcmp(argv[1], "global");
    setenv("DM_NVN_BARRIER", "game", 1); setenv("DM_NVN_TBDR", "0", 1); setenv("DM_NVN_STORE_ELIDE", "1", 1);
    setenv("DM_NVN_BARRIER_HEAP", global ? "global" : "pass", 1); setenv("DM_NVN_LAZY_CLEAR_BINDLESS", global ? "0" : "1", 1);
    mtl_init(); CHECK(barrier_game() == 1 && barrier_heap_pass() == !global, "switches read");
    tex_t *all[] = {&ta, &tb, &tc};
    for (int i = 0; i < 3; i++) all[i]->d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = NVN_FORMAT_RGBA8, .width = 8, .height = 8, .depth = 1, .levels = 1, .samples = 1};
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:8 height:8 mipmapped:NO];
    d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; d.storageMode = MTLStorageModePrivate;
    MTLHeapDescriptor *hd = [MTLHeapDescriptor new]; hd.type = MTLHeapTypePlacement; hd.storageMode = MTLStorageModePrivate; hd.hazardTrackingMode = MTLHazardTrackingModeUntracked;
    hd.size = [g_dev heapTextureSizeAndAlignWithDescriptor:d].size; g_heap = [g_dev newHeapWithDescriptor:hd];
    g_ha = [g_heap newTextureWithDescriptor:d offset:0]; g_hb = [g_heap newTextureWithDescriptor:d offset:0];
    CHECK(g_heap && g_ha && g_hb, "placement heap with two aliased variants");
    NSError *error = nil;
    id<MTLLibrary> lib = [g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;vertex float4 v(uint n[[vertex_id]]){float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};return float4(p[n],.5,1);}\nfragment float4 f(){return float4(1,0,0,1);}" options:nil error:&error];
    CHECK(lib != nil, "literal test shaders compile"); if (!lib) return 1;
    NvProg *pp = [NvProg new]; pp->sh[0] = [NvShader new]; pp->sh[1] = [NvShader new]; pp->sh[0]->fn = [lib newFunctionWithName:@"v"]; pp->sh[1]->fn = [lib newFunctionWithName:@"f"]; pp->sh[1]->stage = 1; pp->sh[1]->rf.color_mask = 1;
    serial_put(pg_plain.serial, pp);
    NvProg *pb = [NvProg new]; pb->sh[0] = pp->sh[0]; pb->sh[1] = [NvShader new]; pb->sh[1]->fn = pp->sh[1]->fn; pb->sh[1]->stage = 1; pb->sh[1]->rf.color_mask = 1; pb->sh[1]->rf.bindless = 1; pb->sh[1]->rf.nb = 1; pb->sh[1]->rf.b[0] = (nvn_rbind){.kind = NVN_RB_TEXU};
    serial_put(pg_bl.serial, pb);
    NvProg *pt = [NvProg new]; pt->sh[0] = pp->sh[0]; pt->sh[1] = [NvShader new]; pt->sh[1]->fn = pp->sh[1]->fn; pt->sh[1]->stage = 1; pt->sh[1]->rf.color_mask = 1; pt->sh[1]->rf.nb = 1; pt->sh[1]->rf.b[0] = (nvn_rbind){.kind = NVN_RB_TEX, .reg = 0};
    serial_put(pg_tex.serial, pt);
    barrier_case(global);
    lazy_clear_case(!global);
    if (!global) { mtl_reg_tex(9, &ta, NULL); lookahead_case(); store_case(); }
    printf("GPU_PASS %s: %d checks, %d failed\n", global ? "global" : "pass", checks, failed); return failed != 0;
} }
