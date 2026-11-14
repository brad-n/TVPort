// The store lookahead (DM_NVN_STORE_ELIDE=1; the same index serves DM_NVN_TBDR and the cross-submission ledger) through the real replay on the GPU, pixels read back. A 32x32 target T is
// filled blue in a submission of its own; then one command list draws it green (pass A), sets another target (which ends A) and comes back to T:
// 1. T cleared red, whole: nothing reads A's green before it, so A's store is skipped (counted) and T ends red.
// 2. The same clear inside a SetRenderEnable(false) block, which the replay skips: A keeps its store and T stays green. The index counted such a clear as a whole overwrite, so the green
//    was never stored and T read back blue (Ocarina of Time's balcony lost a 480x270 target's content this way, behind a conditional render that evaluated false).
// 3. A draw into T's red channel only (T loaded): A keeps its store, the result is green with red added.
// ./t_store_elide [off]  (off: DM_NVN_STORE_ELIDE unset: nothing skipped, the same pixels)
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
static NVNqueue queue; static prog_t pg_green = {.serial = 932001}, pg_red = {.serial = 932004}; static void *vertices;
static tex_t col, other;
static void submit(void) { static uint64_t list; list = ctl_e(CTL_CHUNK, commands, used) | CTL_LAST; NVNcommandHandle hd = (NVNcommandHandle)&list;
    P(nvnQueueSubmitCommands)(&queue, 1, &hd); P(nvnQueueFinish)(&queue); used = 0; }
static void set_rt(tex_t *t) { p_set_rt rt = {.n = 1}; rt.color[0] = t; emit(OP_SET_RT, &rt, sizeof rt); }
static void clear(float r, float g, float b) { p_scissor sc = {0, 0, 32, 32}; emit(OP_SCISSOR, &sc, sizeof sc); p_clear_color c = {.rgba = {r, g, b, 1}, .mask = 15}; emit(OP_CLEAR_COLOR, &c, sizeof c); }
static void render_enable(int on) { p_render_cond rc = {.mode = on ? 2 : 3}; emit(OP_RENDER_COND, &rc, sizeof rc); }
static void draw_with(prog_t *pg, uint32_t chmask) {   // a full-screen triangle, no depth
    const float tri[3][4] = {{-1, -1, .5f, 1}, {3, -1, .5f, 1}, {-1, 3, .5f, 1}}; memcpy(vertices, tri, sizeof tri);
    p_scissor sc = {0, 0, 32, 32}; emit(OP_SCISSOR, &sc, sizeof sc);
    p_viewports v = {.first = 0, .n = 1}; v.v[0][2] = 32; v.v[0][3] = 32; v.v[0][5] = 1; emit(OP_VIEWPORTS, &v, sizeof v);
    ds_st ds = {.df = NVN_DEPTH_FUNC_ALWAYS}; p_bind_state bs = {.kind = 5}; memcpy(bs.bytes, &ds, sizeof ds); emit(OP_BIND_STATE, &bs, sizeof bs);
    chmask_st cm = {.mask = chmask}; bs.kind = 2; memset(bs.bytes, 0, sizeof bs.bytes); memcpy(bs.bytes, &cm, sizeof cm); emit(OP_BIND_STATE, &bs, sizeof bs);
    poly_st poly = {.cull = NVN_FACE_NONE, .mode = NVN_POLYGON_MODE_FILL}; bs.kind = 4; memset(bs.bytes, 0, sizeof bs.bytes); memcpy(bs.bytes, &poly, sizeof poly); emit(OP_BIND_STATE, &bs, sizeof bs);
    struct { int32_t first, n; va_st attr; } attr = {0, 1, {.fmt = NVN_FORMAT_RGBA32F}}; emit(OP_BIND_VATTR, &attr, sizeof attr);
    struct { int32_t first, n; vs_st stream; } stream = {0, 1, {.stride = 16}}; emit(OP_BIND_VSTREAM, &stream, sizeof stream);
    p_bind_vbuf1 vb = {.index = 0, .size = sizeof tri, .addr = (uint64_t)vertices}; emit(OP_BIND_VBUF1, &vb, sizeof vb);
    p_bind_program bp = {.prog = pg, .stages = 3}; emit(OP_BIND_PROGRAM, &bp, sizeof bp);
    p_draw d = {.prim = NVN_DRAW_PRIMITIVE_TRIANGLES, .count = 3, .instances = 1}; emit(OP_DRAW, &d, sizeof d);
}
static int read_back(tex_t *t, uint8_t *out) {
    id<MTLBuffer> px = [g_dev newBufferWithLength:32 * 32 * 4 options:MTLResourceStorageModeShared];
    mtl_sub_begin(); res_add(px);
    enc_b_copy_texture_buffer(blit(), tex_mtl(t), 0, 0, MTLOriginMake(0, 0, 0), MTLSizeMake(32, 32, 1), px, 0, 32 * 4, 32 * 32 * 4);
    int ok = mtl_wait(mtl_sub_commit(), 5000000000ull); memcpy(out, px.contents, 32 * 32 * 4); return ok;
}
static int all_rgba(const uint8_t *p, uint8_t r, uint8_t g, uint8_t b) { for (int i = 0; i < 32 * 32; i++) if (p[4 * i] != r || p[4 * i + 1] != g || p[4 * i + 2] != b || p[4 * i + 3] != 255) return 0; return 1; }
static NvShader *fs_of(id<MTLLibrary> lib, NSString *name) { NvShader *f = [NvShader new]; f->fn = [lib newFunctionWithName:name]; f->stage = 1; f->rf.color_known = 1; f->rf.color_mask = 1; return f; }
static void fill_blue(void) { set_rt(&col); clear(0, 0, 1); submit(); }
static void green_then_away(void) { set_rt(&col); draw_with(&pg_green, 0xffffffffu); set_rt(&other); set_rt(&col); }   // pass A, ended by the other target, then T set again
int main(int argc, char **argv) { @autoreleasepool {
    int off = argc > 1 && !strcmp(argv[1], "off");
    if (!off) setenv("DM_NVN_STORE_ELIDE", "1", 1);
    mtl_init(); NSError *error = nil;
    id<MTLLibrary> library = [g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
        "struct I { float4 p [[attribute(0)]]; };\n"
        "vertex float4 v(I i [[stage_in]]) { return i.p; }\n"
        "fragment float4 green() { return float4(0, 1, 0, 1); }\n"
        "fragment float4 red() { return float4(1, 0, 0, 1); }\n" options:nil error:&error];
    CHECK(library != nil, "test shaders compile"); if (!library) return 1;
    NvShader *vs = [NvShader new]; vs->fn = [library newFunctionWithName:@"v"]; vs->rf.nv = 1; vs->rf.v[0].ct = NVN_CT_FLOAT;
    memset(vs->rf.v[0].sh, 0xff, sizeof vs->rf.v[0].sh); vs->rf.pos_attr = 0; vs->rf.pos_w1 = 1;
    NvProg *g = [NvProg new]; g->sh[0] = vs; g->sh[1] = fs_of(library, @"green"); serial_put(pg_green.serial, g);
    NvProg *r = [NvProg new]; r->sh[0] = vs; r->sh[1] = fs_of(library, @"red"); serial_put(pg_red.serial, r);
    if (posix_memalign(&vertices, (size_t)getpagesize(), 65536)) return 1;
    memset(vertices, 0, 65536); mtl_pool_add(vertices, 65536);
    static NVNdevice device; NVNdeviceBuilder db = {0}; P(nvnDeviceBuilderSetDefaults)(&db); CHECK(P(nvnDeviceInitialize)(&device, &db), "device initialized");
    NVNqueueBuilder qb = {0}; P(nvnQueueBuilderSetDefaults)(&qb); P(nvnQueueBuilderSetDevice)(&qb, &device); CHECK(P(nvnQueueInitialize)(&queue, &qb), "queue initialized");
    mtl_queue_activate(((queue_t *)&queue)->serial);
    col = (tex_t){.magic = MAGIC('T','E','X',0), .serial = 932002}; col.d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = NVN_FORMAT_RGBA8, .width = 32, .height = 32, .depth = 1, .levels = 1, .samples = 1};
    other = (tex_t){.magic = MAGIC('T','E','X',0), .serial = 932003}; other.d = col.d;
    uint8_t px[32 * 32 * 4]; uint64_t s0[24], s1[24];
    // 1. an unconditional whole clear after A: A's store skipped, T red
    fill_blue(); mtl_gpupass_stats(s0); green_then_away(); clear(1, 0, 0); submit(); mtl_gpupass_stats(s1);
    CHECK(s1[0] - s0[0] == (off ? 0u : 1u), off ? "off: A stores" : "A's store is skipped: T is cleared whole before anything reads it");
    CHECK(read_back(&col, px) && all_rgba(px, 255, 0, 0), "1: T ends red");
    // 2. the clear in a render-enable-false block: skipped by the replay, so A must store
    fill_blue(); mtl_gpupass_stats(s0); green_then_away(); render_enable(0); clear(1, 0, 0); render_enable(1); submit(); mtl_gpupass_stats(s1);
    CHECK(s1[0] == s0[0], "a clear the replay may skip (render enable false) does not count as a whole overwrite: A keeps its store");
    CHECK(read_back(&col, px) && all_rgba(px, 0, 255, 0), "2: T keeps A's green");
    // 3. T loaded by the next draw (red channel only): A keeps its store
    fill_blue(); mtl_gpupass_stats(s0); green_then_away(); draw_with(&pg_red, 0x1); submit(); mtl_gpupass_stats(s1);
    CHECK(s1[0] == s0[0], "a pass whose attachment the next pass loads keeps its store");
    CHECK(read_back(&col, px) && all_rgba(px, 255, 255, 0), "3: red added over A's green");
    mtl_pool_del(vertices); free(vertices);
    printf("store lookahead%s: %d checks, %d failed\n", off ? " (off)" : "", checks, fails); return fails != 0;
} }
