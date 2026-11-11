// A window texture's corner area (DM_NVN_WINDOW_AREA, on by default), through the real replay on the GPU: a target is filled blue, then a pass draws green with a full-screen triangle.
// 1. A 32x32 window texture drawn with a scissor and viewport on its 16x16 top-left corner (the game's last pass into a larger swapchain texture): the pass covers only that corner, the corner
// is green and the rest keeps its blue. 2. A second draw in the same pass with the whole texture's scissor ends the corner pass and reaches the rest. 3. A scissor over 30x30 of it leaves too little
// out: no area. 4. A plain (not window) target with the same corner scissor: no area. With DM_NVN_LOAD_ELIDE=1 (./t_window_area elide) the corner pass still loads: the GPU stores whole tiles, and a
// skipped load would write undefined pixels outside a corner that does not end on a tile boundary (16x16 inside a 32x32 tile here).
// ./t_window_area [elide|off]  (off: DM_NVN_WINDOW_AREA=0, no area, the same pixels)
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
#define CHECK(c, label) do { checks++; if (!(c)) { fails++; fprintf(stderr, "FAIL: %s\n", label); } } while (0)
static uint8_t commands[8192] __attribute__((aligned(8))); static size_t used;
static void emit(unsigned op, const void *p, size_t n) {
    size_t size = (8 + n + 7) & ~7ull; op_hdr h = {op, (uint32_t)size};
    memcpy(commands + used, &h, 8); if (n) memcpy(commands + used + 8, p, n); used += size;
}
static NVNqueue queue; static prog_t pg = {.serial = 930001}; static void *vertices;
static void submit(void) {   // the records' control list, one piece (nvn_obj.h ctl_e): a handle is a control list since upstream f02d0474
    static uint64_t list; list = ctl_e(CTL_CHUNK, commands, used) | CTL_LAST; NVNcommandHandle hd = (NVNcommandHandle)&list;
    P(nvnQueueSubmitCommands)(&queue, 1, &hd); P(nvnQueueFinish)(&queue); used = 0; }
static void fill_blue(tex_t *t) {   // a clear with no draw after it lands in a pass of its own at the end of the command list; NVN clears within the scissor, so it covers the target first
    p_set_rt rt = {.n = 1}; rt.color[0] = t; emit(OP_SET_RT, &rt, sizeof rt);
    p_scissor sc = {0, 0, (int32_t)t->d.width, (int32_t)t->d.height}; emit(OP_SCISSOR, &sc, sizeof sc);
    p_clear_color c = {.rgba = {0, 0, 1, 1}, .mask = 15}; emit(OP_CLEAR_COLOR, &c, sizeof c); submit();
}
// One pass into t: a full-screen triangle drawn green with each scissor / viewport of the list
static void draw_green(tex_t *t, int nd, const p_scissor *sc, const float (*vp)[4]) {
    const float tri[3][4] = {{-1, -1, .5f, 1}, {3, -1, .5f, 1}, {-1, 3, .5f, 1}}; memcpy(vertices, tri, sizeof tri);
    p_set_rt rt = {.n = 1}; rt.color[0] = t; emit(OP_SET_RT, &rt, sizeof rt);
    p_bind_program bp = {.prog = &pg, .stages = 3}; emit(OP_BIND_PROGRAM, &bp, sizeof bp);
    ds_st ds = {.df = NVN_DEPTH_FUNC_ALWAYS}; p_bind_state bs = {.kind = 5}; memcpy(bs.bytes, &ds, sizeof ds); emit(OP_BIND_STATE, &bs, sizeof bs);
    poly_st poly = {.cull = NVN_FACE_NONE, .mode = NVN_POLYGON_MODE_FILL}; bs.kind = 4; memcpy(bs.bytes, &poly, sizeof poly); emit(OP_BIND_STATE, &bs, sizeof bs);
    struct { int32_t first, n; va_st attr; } attr = {0, 1, {.fmt = NVN_FORMAT_RGBA32F}}; emit(OP_BIND_VATTR, &attr, sizeof attr);
    struct { int32_t first, n; vs_st stream; } stream = {0, 1, {.stride = 16}}; emit(OP_BIND_VSTREAM, &stream, sizeof stream);
    p_bind_vbuf1 vb = {.index = 0, .size = sizeof tri, .addr = (uint64_t)vertices}; emit(OP_BIND_VBUF1, &vb, sizeof vb);
    for (int k = 0; k < nd; k++) {
        emit(OP_SCISSOR, &sc[k], sizeof sc[k]);
        p_viewports v = {.first = 0, .n = 1}; memcpy(v.v[0], vp[k], 16); v.v[0][4] = 0; v.v[0][5] = 1; emit(OP_VIEWPORTS, &v, sizeof v);
        p_draw draw = {.prim = NVN_DRAW_PRIMITIVE_TRIANGLES, .count = 3, .instances = 1}; emit(OP_DRAW, &draw, sizeof draw);
    }
    submit();
}
static int read_px(tex_t *t, int w, int h, uint8_t *out) {
    id<MTLBuffer> px = [g_dev newBufferWithLength:(NSUInteger)(w * h * 4) options:MTLResourceStorageModeShared];
    mtl_sub_begin(); res_add(px);
    enc_b_copy_texture_buffer(blit(), tex_mtl(t), 0, 0, MTLOriginMake(0, 0, 0), MTLSizeMake((NSUInteger)w, (NSUInteger)h, 1), px, 0, (NSUInteger)(w * 4), (NSUInteger)(w * h * 4));
    int ok = mtl_wait(mtl_sub_commit(), 5000000000ull); memcpy(out, px.contents, (size_t)(w * h * 4)); return ok;
}
static int is(const uint8_t *p, int g) { return p[0] == 0 && p[1] == (g ? 255 : 0) && p[2] == (g ? 0 : 255) && p[3] == 255; }
static int corner(const uint8_t *px, int w, int c) { int g = 1; for (int i = 0; i < w * w; i++) g &= is(px + 4 * i, (i % w) < c && (i / w) < c); return g; }
int main(int argc, char **argv) { @autoreleasepool {
    int off = argc > 1 && !strcmp(argv[1], "off"), elide = argc > 1 && !strcmp(argv[1], "elide");
    if (off) setenv("DM_NVN_WINDOW_AREA", "0", 1);
    if (elide) setenv("DM_NVN_LOAD_ELIDE", "1", 1);
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
    static NVNdevice device; NVNdeviceBuilder db = {0}; P(nvnDeviceBuilderSetDefaults)(&db); CHECK(P(nvnDeviceInitialize)(&device, &db), "device initialized");
    NVNqueueBuilder qb = {0}; P(nvnQueueBuilderSetDefaults)(&qb); P(nvnQueueBuilderSetDevice)(&qb, &device); CHECK(P(nvnQueueInitialize)(&queue, &qb), "queue initialized");
    mtl_queue_activate(((queue_t *)&queue)->serial);
    uint8_t px[32 * 32 * 4]; uint64_t st0[24], st1[24];
    tex_t w = {.magic = MAGIC('T','E','X',0), .serial = 930003}; w.d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = NVN_FORMAT_RGBA8, .width = 32, .height = 32, .depth = 1, .levels = 1, .samples = 1};
    tex_t a = {.magic = MAGIC('T','E','X',0), .serial = 930002}; a.d = w.d;
    mtl_xv_window_tex(w.serial);
    // 1. the window texture's 16x16 corner
    fill_blue(&w); mtl_gpupass_stats(st0);
    { p_scissor sc = {0, 0, 16, 16}; const float vp[1][4] = {{0, 0, 16, 16}}; draw_green(&w, 1, &sc, vp); }
    mtl_gpupass_stats(st1);
    CHECK(st1[22] - st0[22] == (off ? 0u : 1u), off ? "off: the window pass covers the whole texture" : "the window pass covers only its scissor's corner");
    CHECK(off || st1[23] - st0[23] == 2u * (32 * 32 - 16 * 16) * 4, "the bytes outside the corner are counted as not loaded or stored");
    CHECK(st1[2] == st0[2], "the corner pass loads (with DM_NVN_LOAD_ELIDE too: the triangle covers the corner, not the texture)");
    CHECK(read_px(&w, 32, 32, px), "readback 1 completes");
    CHECK(corner(px, 32, 16), "the corner is green, the rest of the window texture keeps its blue");
    // 2. a second draw that leaves the corner
    fill_blue(&w);
    { p_scissor sc[2] = {{0, 0, 16, 16}, {0, 0, 32, 32}}; const float vp[2][4] = {{0, 0, 16, 16}, {0, 0, 32, 32}}; draw_green(&w, 2, sc, vp); }
    CHECK(read_px(&w, 32, 32, px), "readback 2 completes");
    CHECK(corner(px, 32, 32), "a second draw that leaves the corner reaches the whole window texture");
    // 3. a scissor over 30x30: too little left out for an area
    fill_blue(&w); mtl_gpupass_stats(st0);
    { p_scissor sc = {0, 0, 30, 30}; const float vp[1][4] = {{0, 0, 30, 30}}; draw_green(&w, 1, &sc, vp); }
    mtl_gpupass_stats(st1);
    CHECK(st1[22] == st0[22], "a scissor over 88% of the window texture: no area");
    CHECK(read_px(&w, 32, 32, px), "readback 3 completes");
    CHECK(corner(px, 32, 30), "the 30x30 corner is green, the rest keeps its blue");
    // 4. a plain target with the corner scissor: no area
    fill_blue(&a); mtl_gpupass_stats(st0);
    { p_scissor sc = {0, 0, 16, 16}; const float vp[1][4] = {{0, 0, 16, 16}}; draw_green(&a, 1, &sc, vp); }
    mtl_gpupass_stats(st1);
    CHECK(st1[22] == st0[22], "a target that is not a window texture: no area");
    CHECK(read_px(&a, 32, 32, px), "readback 4 completes");
    CHECK(corner(px, 32, 16), "the plain target's corner is green, the rest keeps its blue");
    mtl_pool_del(vertices); free(vertices);
    printf("window area%s: %d checks, %d failed\n", off ? " (off)" : elide ? " (with load elision)" : "", checks, fails); return fails != 0;
} }
