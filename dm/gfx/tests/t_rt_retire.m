// Render targets dead by overwrite (DM_NVN_RT_RETIRE, nvn_mtl.m rt_retire, wm_rect), through the real replay on the GPU: GPU-only targets in one pool, drawn green with a full-screen
// triangle under each viewport and scissor of the list, as Ocarina of Time's frame graph reuses its 305 MB target pool. A target stays live while no pass into other textures has reached
// all of its storage since its last use; after that, unused for RR_IDLE submissions and RR_MS, it is retired: out of the sharing table and its serial, its texture ID's cached view gone,
// its placement heap waiting for the next target, a pool table showing it as a target no pass has written. Each rule:
//  1. covered: a newer target of another format drawn over all of an older one's storage retires the older; the texture ID's view goes; drawn again, it gets a new texture with its pixels
//  2. PR #1453: a target in the part of a larger target that the larger one's passes leave unused (they draw its top-left quarter only) keeps its texture and pixels, however long unused;
//     the same larger target drawn whole then retires it
//  3. a newer target over part of an older one's storage leaves it
//  4. a target used in every frame (a frame graph's transient) stays, though another one covers it every frame
//  5. GOB columns: a pass into the left half of a wide target credits the left half of each block row; a target in the right half of a block row stays, and goes once the right half is drawn
//  6. a clear (a clear-only pass) covers the whole target
//  7. a copy into the target (a blit, not a pass) credits nothing
//  8. a pinned target stays
//  9. a target made again after it was retired is held twice the pause it came back after before it goes again
// ./t_rt_retire [log|off]: DM_NVN_RT_RETIRE=log counts what would go and keeps it; =0 keeps everything
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
static NVNqueue queue; static prog_t pg = {.serial = 931001}; static void *vertices; static pool_t g_pool;
static void submit(void) { static uint64_t list; list = ctl_e(CTL_CHUNK, commands, used) | CTL_LAST; NVNcommandHandle hd = (NVNcommandHandle)&list;
    P(nvnQueueSubmitCommands)(&queue, 1, &hd); P(nvnQueueFinish)(&queue); used = 0; }
static tex_t target(uint64_t serial, uint64_t off, int fmt, uint32_t w, uint32_t h) {
    tex_t t = {.magic = MAGIC('T','E','X',0), .serial = serial, .pool = &g_pool, .mem = (uint8_t *)g_pool.mem + off, .off = (int64_t)off};
    t.d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = fmt, .flags = NVN_TEXTURE_FLAGS_COMPRESSIBLE, .width = w, .height = h, .depth = 1, .levels = 1, .samples = 1};
    nvn_tex_layout(&t.d, &t.L); mtl_tex_init(&t); return t;
}
// One pass into t (pass): a full-screen triangle drawn green with viewport and scissor [x0, x1) x [y0, y1)
static void pass(tex_t *t, int x0, int y0, int x1, int y1) {
    const float tri[3][4] = {{-1, -1, .5f, 1}, {3, -1, .5f, 1}, {-1, 3, .5f, 1}}; memcpy(vertices, tri, sizeof tri);
    p_set_rt rt = {.n = 1}; rt.color[0] = t; emit(OP_SET_RT, &rt, sizeof rt);
    p_bind_program bp = {.prog = &pg, .stages = 3}; emit(OP_BIND_PROGRAM, &bp, sizeof bp);
    ds_st ds = {.df = NVN_DEPTH_FUNC_ALWAYS}; p_bind_state bs = {.kind = 5}; memcpy(bs.bytes, &ds, sizeof ds); emit(OP_BIND_STATE, &bs, sizeof bs);
    poly_st poly = {.cull = NVN_FACE_NONE, .mode = NVN_POLYGON_MODE_FILL}; bs.kind = 4; memcpy(bs.bytes, &poly, sizeof poly); emit(OP_BIND_STATE, &bs, sizeof bs);
    struct { int32_t first, n; va_st attr; } attr = {0, 1, {.fmt = NVN_FORMAT_RGBA32F}}; emit(OP_BIND_VATTR, &attr, sizeof attr);
    struct { int32_t first, n; vs_st stream; } stream = {0, 1, {.stride = 16}}; emit(OP_BIND_VSTREAM, &stream, sizeof stream);
    p_bind_vbuf1 vb = {.index = 0, .size = sizeof tri, .addr = (uint64_t)vertices}; emit(OP_BIND_VBUF1, &vb, sizeof vb);
    p_scissor sc = {x0, y0, x1 - x0, y1 - y0}; emit(OP_SCISSOR, &sc, sizeof sc);
    p_viewports v = {.first = 0, .n = 1}; v.v[0][0] = (float)x0; v.v[0][1] = (float)y0; v.v[0][2] = (float)(x1 - x0); v.v[0][3] = (float)(y1 - y0); v.v[0][4] = 0; v.v[0][5] = 1; emit(OP_VIEWPORTS, &v, sizeof v);
    p_draw d = {.prim = NVN_DRAW_PRIMITIVE_TRIANGLES, .count = 3, .instances = 1}; emit(OP_DRAW, &d, sizeof d);
    submit();
}
static void draw_all(tex_t *t) { pass(t, 0, 0, (int)t->d.width, (int)t->d.height); }
static void clear(tex_t *t) {   // a clear with no draw: a pass of its own; NVN clears within the scissor
    p_set_rt rt = {.n = 1}; rt.color[0] = t; emit(OP_SET_RT, &rt, sizeof rt);
    p_scissor sc = {0, 0, (int32_t)t->d.width, (int32_t)t->d.height}; emit(OP_SCISSOR, &sc, sizeof sc);
    p_clear_color c = {.rgba = {0, 0, 1, 1}, .mask = 15}; emit(OP_CLEAR_COLOR, &c, sizeof c); submit();
}
static void tick(int n) { for (int i = 0; i < n; i++) { mtl_sub_begin(); mtl_sub_commit(); mtl_drain(); } }
static void settle(void) { tick(2); dispatch_sync(g_feedback_q, ^{}); defer_drain(); }
// Unused long enough: RR_MS of wall time, then RR_IDLE submissions and the scans after them
static void idle(void) { usleep((RR_MS + 150) * 1000); tick(RR_IDLE + 2 * RR_EVERY); settle(); }
// The texture the sharing table holds for t's storage, by address: no reference is taken (a test that held one would keep a retired texture and its heap)
static uintptr_t shared_tex(const tex_t *t) { alias_key k = tex_alias_key(t); pthread_mutex_lock(&g_smu); void *o = nvn_hm_get(&g_alias, &k); pthread_mutex_unlock(&g_smu); return (uintptr_t)o; }
static int serial_has(const tex_t *t) { return serial_get(t->serial) != nil; }
static int live(const tex_t *t) { return shared_tex(t) && serial_has(t); }
static int read_px(tex_t *t, uint8_t *out) {   // RGBA8
    int w = (int)t->d.width, h = (int)t->d.height;
    id<MTLBuffer> px = [g_dev newBufferWithLength:(NSUInteger)(w * h * 4) options:MTLResourceStorageModeShared];
    mtl_sub_begin(); res_add(px);
    enc_b_copy_texture_buffer(blit(), tex_mtl(t), 0, 0, MTLOriginMake(0, 0, 0), MTLSizeMake((NSUInteger)w, (NSUInteger)h, 1), px, 0, (NSUInteger)(w * 4), (NSUInteger)(w * h * 4));
    int ok = mtl_wait(mtl_sub_commit(), 5000000000ull); memcpy(out, px.contents, (size_t)(w * h * 4)); res_remove(px); return ok;
}
static int all_green(tex_t *t) {
    size_t n = (size_t)t->d.width * t->d.height * 4; uint8_t *px = malloc(n); int ok = read_px(t, px);
    for (size_t i = 0; ok && i < n; i += 4) ok = px[i] == 0 && px[i + 1] == 255 && px[i + 2] == 0 && px[i + 3] == 255;
    free(px); return ok;
}
int main(int argc, char **argv) { @autoreleasepool {
    int log = argc > 1 && !strcmp(argv[1], "log"), off = argc > 1 && !strcmp(argv[1], "off");
    if (log) setenv("DM_NVN_RT_RETIRE", "log", 1); else if (off) setenv("DM_NVN_RT_RETIRE", "0", 1);
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
    void *mem = NULL; if (posix_memalign(&mem, 16384, 64 << 20)) return 1;
    g_pool = (pool_t){.magic = MAGIC('P','O','O','L'), .flags = NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS | NVN_MEMORY_POOL_FLAGS_GPU_CACHED | NVN_MEMORY_POOL_FLAGS_COMPRESSIBLE, .mem = mem, .size = 64 << 20};
    static NVNdevice device; NVNdeviceBuilder db = {0}; P(nvnDeviceBuilderSetDefaults)(&db); CHECK(P(nvnDeviceInitialize)(&device, &db), "device initialized");
    NVNqueueBuilder qb = {0}; P(nvnQueueBuilderSetDefaults)(&qb); P(nvnQueueBuilderSetDevice)(&qb, &device); CHECK(P(nvnQueueInitialize)(&queue, &qb), "queue initialized");
    mtl_queue_activate(((queue_t *)&queue)->serial);
    const uint64_t MB = 1 << 20; int on = !log && !off;
    CHECK(rr_mode() == (off ? 0 : log ? 2 : 1), "the switch: on by default, =log counts, =0 keeps");

    // 1. covered: B (RGBA16F, 640x360, 1.76 MB) drawn over all of A's storage (RGBA8 640x360, 0.88 MB) after A's last use
    tex_t A = target(931101, 0, NVN_FORMAT_RGBA8, 640, 360), B = target(931102, 0, NVN_FORMAT_RGBA16F, 640, 360);
    mtl_reg_tex(931, &A, NULL);
    { view_t v = {0}; v.set_format = 1; v.format = NVN_FORMAT_RGBA8_SRGB; mtl_reg_tex(932, &A, &v); }   // an sRGB view of A: a view the view cache (g_vc) keeps for A's serial
    draw_all(&A); uintptr_t tA = shared_tex(&A);
    @autoreleasepool { id<MTLTexture> a = (__bridge id<MTLTexture>)(void *)tA; CHECK(a && a.heap && objc_getAssociatedObject(a, &g_rh_owner_key), "A is a GPU-only target in a placement heap of its own"); }
    os_unfair_lock_lock(&g_rmu); void *tv = NULL; tex_fast_rid(931, &tv); os_unfair_lock_unlock(&g_rmu);
    CHECK((uintptr_t)tv == tA && g_treg[931].view, "A's texture ID resolves to it and keeps a view");
    os_unfair_lock_lock(&g_rmu); tv = NULL; tex_fast_rid(932, &tv); int vc = nvn_hm_get(&g_vc, &A.serial) != NULL; os_unfair_lock_unlock(&g_rmu);
    CHECK(tv && (uintptr_t)(__bridge void *)((__bridge id<MTLTexture>)tv).parentTexture == tA && vc, "the sRGB ID reads a view of A that the view cache keeps");
    tick(1);   // the binding above stamped the next submission (a use and a write in one submission tell nothing): one passes
    draw_all(&B);
    CHECK(off ? !wm_min(&g_pool, 0, A.L.size) : wm_min(&g_pool, 0, A.L.size) > 0, off ? "off: no write map is kept" : "the write map holds B's pass over A's storage");
    uint64_t n0 = g_rr_n, l0 = g_rr_log_n; unsigned w0 = g_rh_n;
    idle();
    if (on) {
        CHECK(!live(&A) && g_rr_n > n0, "A, unused and covered, is retired: out of the sharing table and its serial");
        CHECK(!g_treg[931].view && !g_treg[932].view, "A's texture IDs' cached views went with it");
        os_unfair_lock_lock(&g_rmu); vc = nvn_hm_get(&g_vc, &A.serial) != NULL; os_unfair_lock_unlock(&g_rmu);
        CHECK(!vc, "so did A's views in the view cache (they hold A)");
        CHECK(pool_unwritten_target(&A), "a pool table shows A as a target no pass has written (the zero texture), not a texture made again");
        CHECK(g_rh_n > w0, "A's placement heap waits for the next target");
        CHECK(live(&B), "B, the newer one, stays");
        uint64_t again = g_rr_again; draw_all(&A);
        CHECK(live(&A) && g_rr_again == again + 1, "drawn again, A gets a new texture, counted as made again");
        CHECK(all_green(&A), "A's new texture holds what its pass drew");
    } else {
        CHECK(live(&A) && shared_tex(&A) == tA && g_rr_n == n0, off ? "off: A keeps its texture" : "log: A keeps its texture");
        CHECK(!log || (g_rr_log_n == l0 + 1 && g_rr_log_now_n >= 1), "log: A is counted, once, and would go now");
        CHECK(all_green(&A), "A keeps its pixels");
    }

    // 2. PR #1453: X lives in the tail of T (1280x720 RGBA8, 3.6 MB); T's passes draw its top-left 640x360 (the first block rows), so X's storage is never reached
    uint64_t base = 4 * MB;
    tex_t T = target(931201, base, NVN_FORMAT_RGBA8, 1280, 720);
    tex_t X = target(931202, base + T.L.size - 256 * 1024, NVN_FORMAT_RGBA8, 256, 128);   // 128 KB at the end of T's storage
    CHECK(X.L.size <= 256 * 1024, "X fits in T's last 256 KB");
    draw_all(&X); uintptr_t tX = shared_tex(&X); uint64_t fx = atomic_load(&g_fence);
    for (int i = 0; i < 4; i++) pass(&T, 0, 0, 640, 360);
    CHECK(off || (wm_min(&g_pool, base, base + 64 * 1024) > fx && wm_min(&g_pool, (uint64_t)X.off, (uint64_t)X.off + X.L.size) <= fx), "T's passes reach its first block rows, not X's storage (its own pass the last there)");
    idle(); pass(&T, 0, 0, 640, 360); idle();
    CHECK(live(&X) && shared_tex(&X) == tX, "X, unused but in the part of T its passes leave, keeps its texture");
    CHECK(all_green(&X), "X keeps its pixels");
    pass(&T, 0, 0, 1280, 720); idle();
    CHECK(on ? !live(&X) : live(&X), on ? "T drawn whole reaches X's storage: X is retired" : "T drawn whole: X stays (switch)");

    // 3. part: N2 (RGBA16F 320x180 = 0.44 MB) over the first part of O (RGBA8 640x360 = 0.88 MB) only
    base = 12 * MB;
    tex_t O = target(931301, base, NVN_FORMAT_RGBA8, 640, 360), N2 = target(931302, base, NVN_FORMAT_RGBA16F, 320, 180);
    draw_all(&O); draw_all(&N2);
    CHECK(N2.L.size < O.L.size, "N2's storage is shorter than O's");
    idle();
    CHECK(live(&O) && all_green(&O), "O, covered only in part, keeps its texture and pixels");

    // 4. a transient used every frame: F and G share storage, F drawn then read, G drawn over it, frame after frame
    base = 16 * MB;
    tex_t F = target(931401, base, NVN_FORMAT_RGBA8, 640, 360), G = target(931402, base, NVN_FORMAT_RGBA16F, 640, 360);
    uintptr_t tF = 0;
    for (int i = 0; i < 40; i++) { draw_all(&F); if (!i) tF = shared_tex(&F); draw_all(&G); usleep(40 * 1000); tick(RR_EVERY / 2); }
    CHECK(live(&F) && shared_tex(&F) == tF, "F, drawn every frame, keeps its texture although G covers it every frame");

    // 5. GOB columns: W is 1024x256 RGBA8 (64 GOB columns; block rows of 16 GOBs, 128 rows, 512 KB); Y (64x64 RGBA8, 16 KB) sits in the right half of W's first block row
    base = 20 * MB;
    unsigned wth = 0, wtd = 0; nvn_texdesc wd = {.target = NVN_TEXTURE_TARGET_2D, .format = NVN_FORMAT_RGBA8, .flags = NVN_TEXTURE_FLAGS_COMPRESSIBLE, .width = 1024, .height = 256, .depth = 1, .levels = 1, .samples = 1};
    nvn_tex_level_tiles(&wd, 0, &wth, &wtd); uint32_t wg = nvn_tex_level_gobs(&wd, 0);
    CHECK(wth == 4 && wg == 64, "W's block rows are 16 GOBs (128 rows) high and 64 GOBs wide");
    tex_t W = target(931501, base, NVN_FORMAT_RGBA8, 1024, 256), Y = target(931502, base + (uint64_t)(wg / 2) * (512u << wth), NVN_FORMAT_RGBA8, 64, 64);
    CHECK(Y.L.size <= (uint64_t)(wg / 2) * (512u << wth), "Y fits in the right half of W's first block row");
    draw_all(&Y); uintptr_t tY = shared_tex(&Y);
    pass(&W, 0, 0, 512, 256); idle();
    CHECK(live(&Y) && shared_tex(&Y) == tY && all_green(&Y), "W's left half reaches the left half of each block row: Y, in the right half, stays");
    pass(&W, 512, 0, 1024, 256); idle();
    CHECK(on ? !live(&Y) : live(&Y), on ? "W's right half drawn: Y is retired" : "W's right half drawn: Y stays (switch)");

    // 6. a clear covers the whole target
    base = 24 * MB;
    tex_t C1 = target(931601, base, NVN_FORMAT_RGBA8, 320, 180), C2 = target(931602, base, NVN_FORMAT_RGBA16F, 320, 180);
    draw_all(&C1); clear(&C2); idle();
    CHECK(on ? !live(&C1) : live(&C1), on ? "a clear of C2 over C1's storage retires C1" : "a clear over C1: C1 stays (switch)");

    // 7. a copy credits nothing: K2's storage over K1's is filled by a blit, not a pass
    base = 28 * MB;
    tex_t K1 = target(931701, base, NVN_FORMAT_RGBA8, 320, 180), K2 = target(931702, base, NVN_FORMAT_RGBA16F, 320, 180);
    draw_all(&K1);
    { id<MTLTexture> k2 = tex_mtl(&K2); NSUInteger row = 320 * 8, bytes = row * 180; id<MTLBuffer> b = [g_dev newBufferWithLength:bytes options:MTLResourceStorageModeShared]; memset(b.contents, 0x3c, bytes);
      mtl_sub_begin(); res_add(b); enc_b_copy_buffer_texture(blit(), b, 0, row, bytes, MTLSizeMake(320, 180, 1), k2, 0, 0, MTLOriginMake(0, 0, 0)); mtl_wait(mtl_sub_commit(), 5000000000ull); res_remove(b); }
    idle();
    CHECK(live(&K1) && all_green(&K1), "a copy into K2 credits nothing: K1 keeps its texture and pixels");

    // 8. a pinned target stays
    base = 32 * MB;
    tex_t P1 = target(931801, base, NVN_FORMAT_RGBA8, 320, 180), P2 = target(931802, base, NVN_FORMAT_RGBA16F, 320, 180);
    draw_all(&P1); uintptr_t tP = shared_tex(&P1); CHECK(tP, "P1 is a shared texture");
    mtl_tex_pin(P1.serial);   // as a deferred command descriptor or a persistent binding pins it
    draw_all(&P2); idle();
    CHECK(live(&P1) && shared_tex(&P1) == tP, "a pinned target keeps its texture");
    mtl_tex_unpin(P1.serial); idle();
    CHECK(on ? !live(&P1) : live(&P1), on ? "unpinned, P1 is retired" : "unpinned, P1 stays (switch)");

    // 9. storage the game came back to after it was retired is held twice the pause (plus RR_MS) before it goes again
    if (on) {
        base = 36 * MB;
        tex_t H1 = target(931901, base, NVN_FORMAT_RGBA8, 320, 180), H2 = target(931902, base, NVN_FORMAT_RGBA16F, 320, 180);
        draw_all(&H1); draw_all(&H2); idle();
        CHECK(!live(&H1), "H1, covered and unused, is retired");
        usleep(300 * 1000); draw_all(&H1);   // the game comes back to it 0.3 s later
        alias_key hk = tex_alias_key(&H1); pthread_mutex_lock(&g_smu); uint64_t pause = (uint64_t)(uintptr_t)nvn_hm_get(&g_rr_hold, &hk); pthread_mutex_unlock(&g_smu);
        uint64_t hold = pause ? MIN(2 * (pause - 1 + RR_MS), (uint64_t)RR_HOLD_MS) : 0;
        CHECK(pause > 300 && hold >= 2 * (300 + RR_MS), "the pause it came back after is kept: it is held at least twice that plus RR_MS");
        draw_all(&H2); idle();   // covered again and unused for RR_MS and more, within the hold
        CHECK(live(&H1), "made again, it stays past RR_MS");
        usleep((useconds_t)(hold * 1000)); tick(RR_IDLE + 2 * RR_EVERY); settle();
        CHECK(!live(&H1), "past the hold it is retired");
    }

    settle();
    CHECK(!mtl_last_commit_error(), "no GPU error");
    mtl_pool_del(vertices); free(vertices);
    printf("t_rt_retire%s: %d checks, %d failed (retired %llu, %llu MB; counted by log %llu storages; made again %llu)\n", log ? " (log)" : off ? " (off)" : "", checks, fails,
           (unsigned long long)g_rr_n, (unsigned long long)(g_rr_b >> 20), (unsigned long long)g_rr_log_n, (unsigned long long)g_rr_again);
    return fails != 0;
} }
