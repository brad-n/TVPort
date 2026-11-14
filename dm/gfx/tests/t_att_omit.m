// Attachments a pass does not use (DM_NVN_DS_OMIT, DM_NVN_COLOR_OMIT; att_need in nvn_mtl.m), through the real replay on the GPU, colour and depth read back. A 32x32 RGBA8 target and a
// 32x32 Depth32F target are cleared (blue, 0.25), then:
// 1. A pass whose only draw tests and writes no depth: the depth is left out (counted, 4 KB), the colour is drawn green and the depth keeps 0.25.
// 2. A pass whose second draw tests depth (LESS at the triangle's depth, behind 0.25): the depth stays attached, so the red draw fails the test and the target stays green.
// 3. A depth-only pass (every channel masked, a fragment shader with no colour output): the colour is left out and keeps its blue; the depth is written.
// 4. The same pass with a later draw that writes the colour: the colour stays attached and is drawn green.
// 5. A draw with every channel masked whose fragment shader writes colour 0: the colour is left out too (the pipeline's write mask is the channel mask) and keeps its blue.
// 6. A draw with only the green channel enabled: the colour stays attached and only green is written.
// 7. Draws with the stencil test on over this depth-only target (no stencil plane): the depth is left out and nothing splits the pass.
// ./t_att_omit [off]  (off: DM_NVN_DS_OMIT=0 DM_NVN_COLOR_OMIT=0, nothing left out, the same pixels)
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
static uint8_t commands[16384] __attribute__((aligned(8))); static size_t used;
static void emit(unsigned op, const void *p, size_t n) {
    size_t size = (8 + n + 7) & ~7ull; op_hdr h = {op, (uint32_t)size};
    memcpy(commands + used, &h, 8); if (n) memcpy(commands + used + 8, p, n); used += size;
}
static NVNqueue queue; static prog_t pg_green = {.serial = 931001}, pg_red = {.serial = 931004}, pg_none = {.serial = 931005}; static void *vertices;
static tex_t col, dep;
static void submit(void) { static uint64_t list; list = ctl_e(CTL_CHUNK, commands, used) | CTL_LAST; NVNcommandHandle hd = (NVNcommandHandle)&list;
    P(nvnQueueSubmitCommands)(&queue, 1, &hd); P(nvnQueueFinish)(&queue); used = 0; }
static void set_rt(void) { p_set_rt rt = {.n = 1}; rt.color[0] = &col; rt.depth = &dep; emit(OP_SET_RT, &rt, sizeof rt); }
static void reset(void) {   // blue and 0.25, each in a pass of its own at the end of the command list
    set_rt(); p_scissor sc = {0, 0, 32, 32}; emit(OP_SCISSOR, &sc, sizeof sc);
    p_clear_color c = {.rgba = {0, 0, 1, 1}, .mask = 15}; emit(OP_CLEAR_COLOR, &c, sizeof c);
    p_clear_ds d = {.depth = 0.25f, .depth_mask = 1}; emit(OP_CLEAR_DS, &d, sizeof d); submit();
}
static void state(int dt, int dw, unsigned df, uint32_t chmask) {
    ds_st ds = {.dt = (uint8_t)dt, .dw = (uint8_t)dw, .df = df}; p_bind_state bs = {.kind = 5}; memcpy(bs.bytes, &ds, sizeof ds); emit(OP_BIND_STATE, &bs, sizeof bs);
    chmask_st cm = {.mask = chmask}; bs.kind = 2; memset(bs.bytes, 0, sizeof bs.bytes); memcpy(bs.bytes, &cm, sizeof cm); emit(OP_BIND_STATE, &bs, sizeof bs);
}
static void begin(void) {   // targets, the full-screen triangle at depth 0.5, no culling
    const float tri[3][4] = {{-1, -1, .5f, 1}, {3, -1, .5f, 1}, {-1, 3, .5f, 1}}; memcpy(vertices, tri, sizeof tri);
    set_rt(); p_scissor sc = {0, 0, 32, 32}; emit(OP_SCISSOR, &sc, sizeof sc);
    p_viewports v = {.first = 0, .n = 1}; v.v[0][2] = 32; v.v[0][3] = 32; v.v[0][5] = 1; emit(OP_VIEWPORTS, &v, sizeof v);
    poly_st poly = {.cull = NVN_FACE_NONE, .mode = NVN_POLYGON_MODE_FILL}; p_bind_state bs = {.kind = 4}; memcpy(bs.bytes, &poly, sizeof poly); emit(OP_BIND_STATE, &bs, sizeof bs);
    struct { int32_t first, n; va_st attr; } attr = {0, 1, {.fmt = NVN_FORMAT_RGBA32F}}; emit(OP_BIND_VATTR, &attr, sizeof attr);
    struct { int32_t first, n; vs_st stream; } stream = {0, 1, {.stride = 16}}; emit(OP_BIND_VSTREAM, &stream, sizeof stream);
    p_bind_vbuf1 vb = {.index = 0, .size = sizeof tri, .addr = (uint64_t)vertices}; emit(OP_BIND_VBUF1, &vb, sizeof vb);
}
static void draw_with(prog_t *pg) { p_bind_program bp = {.prog = pg, .stages = 3}; emit(OP_BIND_PROGRAM, &bp, sizeof bp);
    p_draw d = {.prim = NVN_DRAW_PRIMITIVE_TRIANGLES, .count = 3, .instances = 1}; emit(OP_DRAW, &d, sizeof d); }
static int read_back(tex_t *t, void *out) {
    id<MTLBuffer> px = [g_dev newBufferWithLength:32 * 32 * 4 options:MTLResourceStorageModeShared];
    mtl_sub_begin(); res_add(px);
    enc_b_copy_texture_buffer(blit(), tex_mtl(t), 0, 0, MTLOriginMake(0, 0, 0), MTLSizeMake(32, 32, 1), px, 0, 32 * 4, 32 * 32 * 4);
    int ok = mtl_wait(mtl_sub_commit(), 5000000000ull); memcpy(out, px.contents, 32 * 32 * 4); return ok;
}
static int all_rgba(const uint8_t *p, uint8_t r, uint8_t g, uint8_t b) { for (int i = 0; i < 32 * 32; i++) if (p[4 * i] != r || p[4 * i + 1] != g || p[4 * i + 2] != b || p[4 * i + 3] != 255) return 0; return 1; }
static int all_depth(const float *d, float v) { for (int i = 0; i < 32 * 32; i++) if (d[i] != v) return 0; return 1; }
static NvShader *fs_of(id<MTLLibrary> lib, NSString *name, uint32_t mask) { NvShader *f = [NvShader new]; f->fn = [lib newFunctionWithName:name]; f->stage = 1; f->rf.color_known = 1; f->rf.color_mask = mask; return f; }
int main(int argc, char **argv) { @autoreleasepool {
    int off = argc > 1 && !strcmp(argv[1], "off");
    if (off) { setenv("DM_NVN_DS_OMIT", "0", 1); setenv("DM_NVN_COLOR_OMIT", "0", 1); }
    mtl_init(); NSError *error = nil;
    id<MTLLibrary> library = [g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
        "struct I { float4 p [[attribute(0)]]; };\n"
        "vertex float4 v(I i [[stage_in]]) { return i.p; }\n"
        "fragment float4 green() { return float4(0, 1, 0, 1); }\n"
        "fragment float4 red() { return float4(1, 0, 0, 1); }\n"
        "fragment void none() {}\n" options:nil error:&error];
    CHECK(library != nil, "test shaders compile"); if (!library) return 1;
    NvShader *vs = [NvShader new]; vs->fn = [library newFunctionWithName:@"v"]; vs->rf.nv = 1; vs->rf.v[0].ct = NVN_CT_FLOAT;
    memset(vs->rf.v[0].sh, 0xff, sizeof vs->rf.v[0].sh); vs->rf.pos_attr = 0; vs->rf.pos_w1 = 1;
    NvProg *g = [NvProg new]; g->sh[0] = vs; g->sh[1] = fs_of(library, @"green", 1); serial_put(pg_green.serial, g);
    NvProg *r = [NvProg new]; r->sh[0] = vs; r->sh[1] = fs_of(library, @"red", 1); serial_put(pg_red.serial, r);
    NvProg *z = [NvProg new]; z->sh[0] = vs; z->sh[1] = fs_of(library, @"none", 0); serial_put(pg_none.serial, z);
    if (posix_memalign(&vertices, (size_t)getpagesize(), 65536)) return 1;
    memset(vertices, 0, 65536); mtl_pool_add(vertices, 65536);
    static NVNdevice device; NVNdeviceBuilder db = {0}; P(nvnDeviceBuilderSetDefaults)(&db); CHECK(P(nvnDeviceInitialize)(&device, &db), "device initialized");
    NVNqueueBuilder qb = {0}; P(nvnQueueBuilderSetDefaults)(&qb); P(nvnQueueBuilderSetDevice)(&qb, &device); CHECK(P(nvnQueueInitialize)(&queue, &qb), "queue initialized");
    mtl_queue_activate(((queue_t *)&queue)->serial);
    col = (tex_t){.magic = MAGIC('T','E','X',0), .serial = 931002}; col.d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = NVN_FORMAT_RGBA8, .width = 32, .height = 32, .depth = 1, .levels = 1, .samples = 1};
    dep = (tex_t){.magic = MAGIC('T','E','X',0), .serial = 931003}; dep.d = col.d; dep.d.format = NVN_FORMAT_DEPTH32F;
    uint8_t px[32 * 32 * 4]; float dz[32 * 32]; uint64_t o0[5], o1[5];
    // 1. no draw uses the depth: left out, kept
    reset(); mtl_omit_stats(o0); begin(); state(0, 0, NVN_DEPTH_FUNC_ALWAYS, 0xffffffffu); draw_with(&pg_green); submit(); mtl_omit_stats(o1);
    CHECK(o1[0] - o0[0] == (off ? 0u : 1u), off ? "off: the depth stays attached" : "a pass that never tests or writes depth leaves it out");
    CHECK(off || o1[1] - o0[1] == 32 * 32 * 4, "the depth bytes not loaded are counted");
    CHECK(o1[2] == o0[2], "the colour it writes stays attached");
    CHECK(read_back(&col, px) && all_rgba(px, 0, 255, 0), "1: the colour is drawn green");
    CHECK(read_back(&dep, dz) && all_depth(dz, 0.25f), "1: the depth left out keeps its 0.25");
    // 2. a later draw of the pass tests depth: it stays attached and the test sees 0.25
    reset(); mtl_omit_stats(o0); begin(); state(0, 0, NVN_DEPTH_FUNC_ALWAYS, 0xffffffffu); draw_with(&pg_green); state(1, 1, NVN_DEPTH_FUNC_LESS, 0xffffffffu); draw_with(&pg_red); submit(); mtl_omit_stats(o1);
    CHECK(o1[0] == o0[0] && o1[4] == o0[4], "a pass with a depth-testing draw keeps its depth (no omission, no split)");
    CHECK(read_back(&col, px) && all_rgba(px, 0, 255, 0), "2: the red draw behind the 0.25 depth fails the test, the target stays green");
    CHECK(read_back(&dep, dz) && all_depth(dz, 0.25f), "2: the depth keeps 0.25");
    // 3. a depth-only pass: the colour is left out, keeps its blue, the depth is written
    reset(); mtl_omit_stats(o0); begin(); state(1, 1, NVN_DEPTH_FUNC_ALWAYS, 0); draw_with(&pg_none); submit(); mtl_omit_stats(o1);
    CHECK(o1[2] - o0[2] == (off ? 0u : 1u), off ? "off: the colour stays attached" : "a pass that never writes its colour leaves it out");
    CHECK(off || o1[3] - o0[3] == 32 * 32 * 4, "the colour bytes not loaded are counted");
    CHECK(o1[0] == o0[0], "the depth it writes stays attached");
    CHECK(read_back(&col, px) && all_rgba(px, 0, 0, 255), "3: the colour left out keeps its blue");
    CHECK(read_back(&dep, dz) && dz[0] != 0.25f && dz[0] > 0 && dz[0] < 1 && all_depth(dz, dz[0]), "3: the depth is written");
    // 4. a later draw writes the colour: it stays attached
    reset(); mtl_omit_stats(o0); begin(); state(1, 1, NVN_DEPTH_FUNC_ALWAYS, 0); draw_with(&pg_none); state(0, 0, NVN_DEPTH_FUNC_ALWAYS, 0xffffffffu); draw_with(&pg_green); submit(); mtl_omit_stats(o1);
    CHECK(o1[2] == o0[2] && o1[4] == o0[4], "a pass with a draw that writes the colour keeps it (no omission, no split)");
    CHECK(read_back(&col, px) && all_rgba(px, 0, 255, 0), "4: the colour is drawn green");
    // 5. every channel masked, the shader writing colour 0: left out all the same (the pipeline's write mask is the channel mask), the blue kept
    reset(); mtl_omit_stats(o0); begin(); state(1, 1, NVN_DEPTH_FUNC_ALWAYS, 0); draw_with(&pg_green); submit(); mtl_omit_stats(o1);
    CHECK(o1[2] - o0[2] == (off ? 0u : 1u), off ? "off: the masked colour stays attached" : "a draw with every channel masked leaves the colour out, whatever its shader writes");
    CHECK(read_back(&col, px) && all_rgba(px, 0, 0, 255), "5: masked, the colour keeps its blue");
    // 6. one channel enabled: kept, and only that channel written (green over blue: 0,255,255)
    reset(); mtl_omit_stats(o0); begin(); state(0, 0, NVN_DEPTH_FUNC_ALWAYS, 0x2); draw_with(&pg_green); submit(); mtl_omit_stats(o1);
    CHECK(o1[2] == o0[2], "a draw that writes one channel keeps the colour attached");
    CHECK(read_back(&col, px) && all_rgba(px, 0, 255, 255), "6: only the green channel is written");
    // 7. a draw with the stencil test on, over this depth-only target, in a pass that left the depth out: it uses no plane that was left out, so no split
    reset(); mtl_omit_stats(o0); begin(); state(0, 0, NVN_DEPTH_FUNC_ALWAYS, 0xffffffffu); draw_with(&pg_green);
    { ds_st ds = {.df = NVN_DEPTH_FUNC_ALWAYS, .st = 1}; p_bind_state bs = {.kind = 5}; memcpy(bs.bytes, &ds, sizeof ds); emit(OP_BIND_STATE, &bs, sizeof bs); }
    draw_with(&pg_red); draw_with(&pg_green); submit(); mtl_omit_stats(o1);
    CHECK(o1[0] - o0[0] == (off ? 0u : 1u) && o1[4] == o0[4], off ? "off: the depth stays attached" : "stencil tests over a target with no stencil plane leave the depth out and split nothing");
    CHECK(read_back(&col, px) && all_rgba(px, 0, 255, 0), "7: the last draw is green");
    CHECK(read_back(&dep, dz) && all_depth(dz, 0.25f), "7: the depth keeps 0.25");
    mtl_pool_del(vertices); free(vertices);
    printf("attachments a pass does not use%s: %d checks, %d failed\n", off ? " (off)" : "", checks, fails); return fails != 0;
} }
