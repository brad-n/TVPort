// Engine-wide resolution scale (DM_RES_SCALE, nvn_rscale.inc) through the real replay on the GPU, at scale 2 with Metal's validation layer:
// 1. Which descriptors scale: a 128x72 render target of a GPU-only pool becomes 256x144; a shader-writable one, a square one, a compressed one, one in a CPU-visible pool, a small
//    one and a window texture keep their size.
// 2. Viewport and scissor: a draw with the game's viewport (0, 0, 64, 36) lands in the target's top-left 128x72; one with the scissor (32, 18, 64, 36) in its pixels 64-191 x 36-107.
// 3. A scaled target sampled through the resolution-scaling code (a fragment shader written as the translator writes it: gl_FragCoord.xy / render_scale[0], texel fetches through
//    TexelFetchScale, sizes through TextureSizeUnscale) with the support buffer the host fills per draw: a 1:1 fetch of a scaled texture into a scaled pass reads each pixel's own
//    texel; into an unscaled pass every second texel; the size query gives the game's size.
// 4. Copies: a scaled target into an unscaled texture of the game's size (drawn down), a region between two scaled ones (a blit), a texture-to-buffer copy that comes back at the
//    game's size, and a buffer-to-texture copy into a scaled target that fills its scaled region.
// 5. A pass that mixes a scaled depth buffer with a colour target of the game's size: drawn at the game's size through a proxy of the depth, so the depth test sees the
//    whole depth buffer (its left half 0.25, its right half 0.75: a draw at 0.5 with LESS passes on the right half only), and the depth it writes reaches the scaled buffer.
// 6. The memory budget: a scaled texture counts what the scale adds while it lives and stops counting when it is freed; a new target past the budget, or while the memory relief finds
//    the process short of memory, is made at the game's size, and every later descriptor of that texture (its twin, a remake) agrees, whatever the budget says then.
// 7. A game upscaler's rectangle (DM_UPSCALER, its push constants in the game's pixels) read from a scaled input in the input's own pixels.
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
static NVNqueue queue; static void *vertices;
static void submit(void) { static uint64_t list; list = ctl_e(CTL_CHUNK, commands, used) | CTL_LAST; NVNcommandHandle hd = (NVNcommandHandle)&list;
    P(nvnQueueSubmitCommands)(&queue, 1, &hd); P(nvnQueueFinish)(&queue); used = 0; }
static pool_t gpu_pool = {.flags = NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS | NVN_MEMORY_POOL_FLAGS_GPU_CACHED}, cpu_pool = {.flags = NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED};
static tex_t desc(uint64_t ser, const pool_t *pool, int fmt, uint32_t w, uint32_t h, int flags) {
    tex_t t = {.magic = MAGIC('T','E','X',0), .serial = ser, .pool = pool};
    t.d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = fmt, .width = w, .height = h, .depth = 1, .levels = 1, .samples = 1, .flags = flags};
    return t;
}
static id<MTLTexture> make(tex_t *t) {   // as the host makes it (tex_desc), registered under its serial
    MTLTextureDescriptor *d = tex_desc(t, 0); id<MTLTexture> x = d ? [g_dev newTextureWithDescriptor:d] : nil;
    CHECK(x != nil, "texture created"); if (!x) return nil;
    rs_track(x, t);   // as tex_mtl_ does
    res_add(x); mtl_tex_init(t); serial_put(t->serial, x); return x;
}
static int read_px(id<MTLTexture> t, uint8_t *out) {   // the whole level 0, RGBA8
    NSUInteger w = t.width, h = t.height; id<MTLBuffer> px = [g_dev newBufferWithLength:w * h * 4 options:MTLResourceStorageModeShared];
    mtl_sub_begin(); res_add(px);
    enc_b_copy_texture_buffer(blit(), t, 0, 0, MTLOriginMake(0, 0, 0), MTLSizeMake(w, h, 1), px, 0, w * 4, w * h * 4);
    int ok = mtl_wait(mtl_sub_commit(), 5000000000ull); memcpy(out, px.contents, w * h * 4); return ok;
}
static void fill(id<MTLTexture> t, void (^f)(int x, int y, uint8_t *p)) {   // a private texture's content through a staging buffer
    NSUInteger w = t.width, h = t.height; id<MTLBuffer> px = [g_dev newBufferWithLength:w * h * 4 options:MTLResourceStorageModeShared];
    uint8_t *p = px.contents; for (int y = 0; y < (int)h; y++) for (int x = 0; x < (int)w; x++) f(x, y, p + 4 * (y * w + x));
    mtl_sub_begin(); res_add(px); enc_b_copy_buffer_texture(blit(), px, 0, w * 4, w * h * 4, MTLSizeMake(w, h, 1), t, 0, 0, MTLOriginMake(0, 0, 0)); mtl_wait(mtl_sub_commit(), 5000000000ull);
}
static void targets(tex_t *c) { p_set_rt rt = {.n = 1}; rt.color[0] = c; emit(OP_SET_RT, &rt, sizeof rt); }
static tex_t *g_depth; static ds_st g_ds = {.df = NVN_DEPTH_FUNC_ALWAYS};   // the depth target and test the next tdraw uses (none, always)
static void clear_blue(tex_t *c) { targets(c); p_scissor sc = {0, 0, (int)c->d.width, (int)c->d.height}; emit(OP_SCISSOR, &sc, sizeof sc);
    p_clear_color cc = {.rgba = {0, 0, 1, 1}, .mask = 15}; emit(OP_CLEAR_COLOR, &cc, sizeof cc); submit(); }
static void tdraw(tex_t *c, prog_t *pg, float vx, float vy, float vw, float vh, p_scissor sc) {   // the full-screen triangle with the game's viewport and scissor
    const float tri[3][4] = {{-1, -1, .5f, 1}, {3, -1, .5f, 1}, {-1, 3, .5f, 1}}; memcpy(vertices, tri, sizeof tri);
    { p_set_rt rt = {.n = 1}; rt.color[0] = c; rt.depth = g_depth; emit(OP_SET_RT, &rt, sizeof rt); } emit(OP_SCISSOR, &sc, sizeof sc);
    p_viewports v = {.first = 0, .n = 1}; v.v[0][0] = vx; v.v[0][1] = vy; v.v[0][2] = vw; v.v[0][3] = vh; v.v[0][5] = 1; emit(OP_VIEWPORTS, &v, sizeof v);
    poly_st poly = {.cull = NVN_FACE_NONE, .mode = NVN_POLYGON_MODE_FILL}; p_bind_state bs = {.kind = 4}; memcpy(bs.bytes, &poly, sizeof poly); emit(OP_BIND_STATE, &bs, sizeof bs);
    ds_st ds = g_ds; bs.kind = 5; memset(bs.bytes, 0, sizeof bs.bytes); memcpy(bs.bytes, &ds, sizeof ds); emit(OP_BIND_STATE, &bs, sizeof bs);
    chmask_st cm = {.mask = 0xffffffffu}; bs.kind = 2; memset(bs.bytes, 0, sizeof bs.bytes); memcpy(bs.bytes, &cm, sizeof cm); emit(OP_BIND_STATE, &bs, sizeof bs);
    struct { int32_t first, n; va_st attr; } attr = {0, 1, {.fmt = NVN_FORMAT_RGBA32F}}; emit(OP_BIND_VATTR, &attr, sizeof attr);
    struct { int32_t first, n; vs_st stream; } stream = {0, 1, {.stride = 16}}; emit(OP_BIND_VSTREAM, &stream, sizeof stream);
    p_bind_vbuf1 vb = {.index = 0, .size = sizeof tri, .addr = (uint64_t)vertices}; emit(OP_BIND_VBUF1, &vb, sizeof vb);
    p_bind_program bp = {.prog = pg, .stages = 3}; emit(OP_BIND_PROGRAM, &bp, sizeof bp);
    p_draw d = {.prim = NVN_DRAW_PRIMITIVE_TRIANGLES, .count = 3, .instances = 1}; emit(OP_DRAW, &d, sizeof d); submit();
}
// A fragment shader as the translator writes one with the resolution-scaling code (Ryujinx InstEmitAttribute.EmitIpa, HelperFunctionManager TexelFetchScale / TextureSizeUnscale),
// its support buffer laid out as SupportBuffer.cs (render_scale at byte 192) and its texture the first descriptor, render_scale[1]
static NSString *const RS_MSL = @"#include <metal_stdlib>\nusing namespace metal;\n"
    "struct SB { uint a; uint4 bgra[8]; float4 vi; float4 vs; int fsc; float4 rs[73]; };\n"
    "struct A { constant SB *support_buffer [[id(0)]]; texture2d<float> fp_t_tcb_8 [[id(1)]]; };\n"
    "struct I { float4 p [[attribute(0)]]; };\n"
    "vertex float4 v(I i [[stage_in]]) { return i.p; }\n"
    "fragment float4 green() { return float4(0, 1, 0, 1); }\n"
    "static int fetch_scale(int x, int si, int axis, constant SB &sb, float4 fc) { float s = sb.rs[1 + si].x; if (s == 1.0) return x;\n"
    "  if (s < 0.0) { float n = -s; float f = axis ? fc.y : fc.x; return int(float(x) * n + (f - n * floor(f / n))); } return int(float(x) * s); }\n"
    "fragment float4 fetch(float4 fc [[position]], constant A &a [[buffer(0)]]) { constant SB &sb = *a.support_buffer;\n"
    "  int2 q = int2(fc.xy / sb.rs[0].x); return a.fp_t_tcb_8.read(uint2(fetch_scale(q.x, 0, 0, sb, fc), fetch_scale(q.y, 0, 1, sb, fc))); }\n"
    "fragment float4 size(float4 fc [[position]], constant A &a [[buffer(0)]]) { float s = abs(a.support_buffer->rs[1].x); int w = int(a.fp_t_tcb_8.get_width()), h = int(a.fp_t_tcb_8.get_height());\n"
    "  if (s != 1.0) { w = int(float(w) / s); h = int(float(h) / s); } return float4(float(w) / 255.0, float(h) / 255.0, 0, 1); }\n";
static NvShader *fs_rs(id<MTLLibrary> lib, NSString *name) {   // its reflection as the build writes it: the support buffer, then texture slot 0
    NvShader *f = [NvShader new]; f->fn = [lib newFunctionWithName:name]; f->stage = 1;
    NSDictionary *j = @{@"route": @"B", @"stage": @"ps", @"bindings": @[
        @{@"msl_name": @"support_buffer", @"msl_type": @"constant _10*", @"arg_id": @0, @"kind": @"support"},
        @{@"msl_name": @"fp_t_tcb_8", @"msl_type": @"texture2d<float>", @"arg_id": @1, @"kind": @"tex", @"reg": @0}]};
    char err[256] = ""; CHECK(!nvn_refl_from_json(j, &f->rf, err, sizeof err), "reflection parses");
    CHECK(f->rf.sup && f->rf.nrsi == 1 && f->rf.b[1].rsi == 1 && !f->rf.b[0].rsi, "the texture takes render_scale[1], the support buffer is noted");
    f->ae = [f->fn newArgumentEncoderWithBufferIndex:0]; f->arg_len = f->ae.encodedLength; f->rf.color_known = 1; f->rf.color_mask = 1; return f;
}
static void bind710(void) { p_bind_handles h = {.stage = 1, .first = 0, .n = 1}; h.h[0] = 710; emit(OP_BIND_TEX, &h, sizeof h); }
int main(void) { @autoreleasepool {
    setenv("DM_NVN_TBDR", "0", 1);
    mtl_init(); rs_init(); g_rs = 2.0f; g_rs_on = 1;   // the test profile's shaders have no rescale code (shader_no_rescale): on, as rs_init sets it for a profile whose shaders have it
    NSError *error = nil;
    id<MTLLibrary> lib = [g_dev newLibraryWithSource:RS_MSL options:nil error:&error];
    CHECK(lib != nil, "test shaders compile"); if (!lib) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 1; }
    // 1. sizes
    struct { int fmt, flags; uint32_t w, h; const pool_t *pool; uint32_t want_w; const char *label; } sz[] = {
        {NVN_FORMAT_RGBA8, NVN_TEXTURE_FLAGS_COMPRESSIBLE, 128, 72, &gpu_pool, 256, "a 16:9 target of a GPU-only pool is made at twice its size"},
        {NVN_FORMAT_DEPTH32F, NVN_TEXTURE_FLAGS_COMPRESSIBLE, 128, 72, &gpu_pool, 256, "its depth buffer too"},
        {NVN_FORMAT_RGBA8, NVN_TEXTURE_FLAGS_COMPRESSIBLE | NVN_TEXTURE_FLAGS_IMAGE, 128, 72, &gpu_pool, 128, "a shader-writable one keeps its size"},
        {NVN_FORMAT_RGBA8, NVN_TEXTURE_FLAGS_COMPRESSIBLE, 128, 128, &gpu_pool, 128, "a square one (a shadow map, an atlas) keeps its size"},
        {NVN_FORMAT_RGBA_DXT1, NVN_TEXTURE_FLAGS_COMPRESSIBLE, 128, 72, &gpu_pool, 128, "a compressed one keeps its size"},
        {NVN_FORMAT_RGBA8, NVN_TEXTURE_FLAGS_COMPRESSIBLE, 128, 72, &cpu_pool, 128, "one in a pool the CPU reads keeps its size"},
        {NVN_FORMAT_RGBA8, NVN_TEXTURE_FLAGS_COMPRESSIBLE, 32, 18, &gpu_pool, 32, "one under 64 pixels keeps its size"},
        {NVN_FORMAT_RGBA8, NVN_TEXTURE_FLAGS_COMPRESSIBLE | NVN_TEXTURE_FLAGS_DISPLAY, 1280, 720, &gpu_pool, 1280, "a window texture keeps its size"},
    };
    for (unsigned i = 0; i < sizeof sz / sizeof *sz; i++) { tex_t t = desc(99700 + i, sz[i].pool, sz[i].fmt, sz[i].w, sz[i].h, sz[i].flags); MTLTextureDescriptor *d = tex_desc(&t, 0);
        CHECK(d && d.width == sz[i].want_w && d.height == (sz[i].want_w == sz[i].w ? sz[i].h : sz[i].h * 2), sz[i].label); }
    CHECK(g_rs_screen_w == 1280 && g_rs_screen_h == 720, "the window texture gives the screen's shape");
    // the replay
    NvShader *vs = [NvShader new]; vs->fn = [lib newFunctionWithName:@"v"]; vs->rf.nv = 1; vs->rf.v[0].ct = NVN_CT_FLOAT;
    memset(vs->rf.v[0].sh, 0xff, sizeof vs->rf.v[0].sh); vs->rf.pos_attr = 0; vs->rf.pos_w1 = 1;
    NvShader *green = [NvShader new]; green->fn = [lib newFunctionWithName:@"green"]; green->stage = 1; green->rf.color_known = 1; green->rf.color_mask = 1;
    static prog_t pg_green = {.serial = 997001}, pg_fetch = {.serial = 997002}, pg_size = {.serial = 997003};
    NvProg *g = [NvProg new]; g->sh[0] = vs; g->sh[1] = green; serial_put(pg_green.serial, g);
    NvProg *f = [NvProg new]; f->sh[0] = vs; f->sh[1] = fs_rs(lib, @"fetch"); serial_put(pg_fetch.serial, f);
    NvProg *s = [NvProg new]; s->sh[0] = vs; s->sh[1] = fs_rs(lib, @"size"); serial_put(pg_size.serial, s);
    if (posix_memalign(&vertices, (size_t)getpagesize(), 65536)) return 1;
    memset(vertices, 0, 65536); mtl_pool_add(vertices, 65536);
    static NVNdevice device; NVNdeviceBuilder db = {0}; P(nvnDeviceBuilderSetDefaults)(&db); CHECK(P(nvnDeviceInitialize)(&device, &db), "device initialized");
    NVNqueueBuilder qb = {0}; P(nvnQueueBuilderSetDefaults)(&qb); P(nvnQueueBuilderSetDevice)(&qb, &device); CHECK(P(nvnQueueInitialize)(&queue, &qb), "queue initialized");
    mtl_queue_activate(((queue_t *)&queue)->serial);
    g_rs_screen_w = 1920; g_rs_screen_h = 1080;
    tex_t col = desc(997100, &gpu_pool, NVN_FORMAT_RGBA8, 128, 72, NVN_TEXTURE_FLAGS_COMPRESSIBLE), src = desc(997101, &gpu_pool, NVN_FORMAT_RGBA8, 128, 72, NVN_TEXTURE_FLAGS_COMPRESSIBLE),
          low = desc(997102, &cpu_pool, NVN_FORMAT_RGBA8, 128, 72, NVN_TEXTURE_FLAGS_COMPRESSIBLE), blk = desc(997103, &gpu_pool, NVN_FORMAT_RGBA8, 128, 72, NVN_TEXTURE_FLAGS_COMPRESSIBLE);
    id<MTLTexture> colt = make(&col), srct = make(&src), lowt = make(&low), blkt = make(&blk);
    CHECK(colt.width == 256 && srct.width == 256 && lowt.width == 128 && blkt.height == 144, "the test's targets: three scaled, one at the game's size");
    CHECK(rs_of(colt, &col) == 2.0f && rs_of(lowt, &low) == 1.0f, "rs_of tells the scaled ones");
    static uint8_t px[256 * 144 * 4];
    // 2. viewport and scissor
    clear_blue(&col); tdraw(&col, &pg_green, 0, 0, 64, 36, (p_scissor){0, 0, 128, 72});
    int ok = read_px(colt, px), in = 1, out = 1;
    for (int y = 0; y < 144; y++) for (int x = 0; x < 256; x++) { const uint8_t *p = px + 4 * (y * 256 + x); int g_ = p[1] == 255 && !p[2]; if (x < 128 && y < 72) in &= g_; else out &= !g_ && p[2] == 255; }
    CHECK(ok && in && out, "the game's viewport 64x36 covers the scaled target's 128x72");
    clear_blue(&col); tdraw(&col, &pg_green, 0, 0, 128, 72, (p_scissor){32, 18, 64, 36});
    ok = read_px(colt, px); in = out = 1;
    for (int y = 0; y < 144; y++) for (int x = 0; x < 256; x++) { const uint8_t *p = px + 4 * (y * 256 + x); int g_ = p[1] == 255 && !p[2]; if (x >= 64 && x < 192 && y >= 36 && y < 108) in &= g_; else out &= !g_; }
    CHECK(ok && in && out, "the game's scissor 32,18 64x36 is the scaled target's 64,36 128x72");
    // 3. the rescale code
    fill(srct, ^(int x, int y, uint8_t *p) { p[0] = (uint8_t)x; p[1] = (uint8_t)y; p[2] = 7; p[3] = 255; });
    mtl_reg_tex(710, &src, NULL);
    bind710(); tdraw(&col, &pg_fetch, 0, 0, 128, 72, (p_scissor){0, 0, 128, 72});
    ok = read_px(colt, px); in = 1; for (int y = 0; y < 144; y++) for (int x = 0; x < 256; x++) { const uint8_t *p = px + 4 * (y * 256 + x); in &= p[0] == (uint8_t)x && p[1] == y && p[2] == 7; }
    CHECK(ok && in, "a 1:1 texel fetch of a scaled texture in a scaled pass reads each pixel's own texel (negative scale)");
    bind710(); tdraw(&low, &pg_fetch, 0, 0, 128, 72, (p_scissor){0, 0, 128, 72});
    ok = read_px(lowt, px); in = 1; for (int y = 0; y < 72; y++) for (int x = 0; x < 128; x++) { const uint8_t *p = px + 4 * (y * 128 + x); in &= p[0] == (uint8_t)(2 * x) && p[1] == 2 * y; }
    CHECK(ok && in, "the same fetch in a pass at the game's size reads every second texel");
    bind710(); tdraw(&col, &pg_size, 0, 0, 128, 72, (p_scissor){0, 0, 128, 72});
    ok = read_px(colt, px); CHECK(ok && px[0] == 128 && px[1] == 72, "a size query of the scaled texture gives the game's size");
    // 4. copies
    fill(blkt, ^(int x, int y, uint8_t *p) { p[0] = (uint8_t)(x / 2); p[1] = (uint8_t)(y / 2); p[2] = 9; p[3] = 255; });   // the game's texel (x / 2, y / 2) at each scaled pixel
    { p_copy_t2t c = {.src = &blk, .dst = &low, .sr = {0, 0, 0, 128, 72, 1}, .dr = {0, 0, 0, 128, 72, 1}}; emit(OP_COPY_T2T, &c, sizeof c); submit(); }
    ok = read_px(lowt, px); in = 1; for (int y = 0; y < 72; y++) for (int x = 0; x < 128; x++) { const uint8_t *p = px + 4 * (y * 128 + x); in &= p[0] == x && p[1] == y && p[2] == 9; }
    CHECK(ok && in, "a scaled target copied into a texture of the game's size comes out at the game's size");
    { p_copy_t2t c = {.src = &blk, .dst = &col, .sr = {10, 5, 0, 20, 10, 1}, .dr = {30, 20, 0, 20, 10, 1}}; emit(OP_COPY_T2T, &c, sizeof c); submit(); }
    ok = read_px(colt, px); in = 1; for (int y = 40; y < 60; y++) for (int x = 60; x < 100; x++) { const uint8_t *p = px + 4 * (y * 256 + x); in &= p[0] == (x - 60 + 20) / 2 && p[1] == (y - 40 + 10) / 2 && p[2] == 9; }
    CHECK(ok && in, "a region copied between two scaled targets lands at the scaled position, pixel for pixel");
    void *host = NULL; if (posix_memalign(&host, (size_t)getpagesize(), 65536)) return 1; memset(host, 0xee, 65536); mtl_pool_add(host, 65536);
    { p_copy_b2t c = {.src = (uint64_t)host, .tex = &blk, .r = {0, 0, 0, 128, 72, 1}}; emit(OP_COPY_T2B, &c, sizeof c); submit(); }
    { const uint8_t *p = host; in = 1; for (int y = 0; y < 72; y++) for (int x = 0; x < 128; x++) in &= p[4 * (y * 128 + x)] == x && p[4 * (y * 128 + x) + 1] == y; }
    CHECK(in, "a texture-to-buffer copy of a scaled target gives the game's 128x72 texels");
    { uint8_t *p = host; for (int i = 0; i < 16 * 8; i++) { p[4 * i] = 40; p[4 * i + 1] = 50; p[4 * i + 2] = 60; p[4 * i + 3] = 255; } }
    { p_copy_b2t c = {.src = (uint64_t)host, .tex = &blk, .r = {8, 4, 0, 16, 8, 1}}; emit(OP_COPY_B2T, &c, sizeof c); submit(); }
    ok = read_px(blkt, px); in = 1; out = 1;
    for (int y = 0; y < 144; y++) for (int x = 0; x < 256; x++) { const uint8_t *p = px + 4 * (y * 256 + x); int hit = x >= 16 && x < 48 && y >= 8 && y < 24;
        if (hit) in &= p[0] == 40 && p[1] == 50 && p[2] == 60; else out &= p[2] == 9; }
    CHECK(ok && in && out, "a buffer-to-texture copy into a scaled target fills its scaled region and nothing else");
    // 5. a mixed pass
    tex_t dep = desc(997104, &gpu_pool, NVN_FORMAT_DEPTH32F, 128, 72, NVN_TEXTURE_FLAGS_COMPRESSIBLE), low2 = desc(997105, &cpu_pool, NVN_FORMAT_RGBA8, 128, 72, NVN_TEXTURE_FLAGS_COMPRESSIBLE);
    id<MTLTexture> dept = make(&dep), low2t = make(&low2);
    CHECK(dept.width == 256 && low2t.width == 128, "a scaled depth buffer, a colour target of the game's size");
    fill(dept, ^(int x, int y, uint8_t *p) { (void)y; float v = x < 128 ? 0.25f : 0.75f; memcpy(p, &v, 4); });
    clear_blue(&low2); uint64_t prox0 = g_rs_proxied;
    g_depth = &dep; g_ds = (ds_st){.dt = 1, .dw = 0, .df = NVN_DEPTH_FUNC_LESS}; tdraw(&low2, &pg_green, 0, 0, 128, 72, (p_scissor){0, 0, 128, 72});
    ok = read_px(low2t, px); in = out = 1; for (int y = 0; y < 72; y++) for (int x = 0; x < 128; x++) { const uint8_t *p = px + 4 * (y * 128 + x); int g_ = p[1] == 255 && !p[2]; if (x >= 64) in &= g_; else out &= !g_ && p[2] == 255; }
    CHECK(g_rs_proxied > prox0, "the mixed pass is drawn through a proxy");
    CHECK(ok && in && out, "the depth test of a mixed pass sees the whole scaled depth buffer (green on the right half only)");
    { static float dz[256 * 144]; ok = read_px(dept, (uint8_t *)dz); in = 1; for (int y = 0; y < 144; y++) for (int x = 0; x < 256; x++) in &= dz[y * 256 + x] == (x < 128 ? 0.25f : 0.75f);
      CHECK(ok && in, "a mixed pass that only tests the depth leaves the scaled depth buffer as it was (not drawn back)"); }
    g_ds = (ds_st){.dt = 1, .dw = 1, .df = NVN_DEPTH_FUNC_ALWAYS}; tdraw(&low2, &pg_green, 0, 0, 128, 72, (p_scissor){0, 0, 128, 72}); g_depth = NULL; g_ds = (ds_st){.df = NVN_DEPTH_FUNC_ALWAYS};
    { static float dz[256 * 144]; ok = read_px(dept, (uint8_t *)dz); in = 1; for (int i = 0; i < 256 * 144; i++) in &= dz[i] == 0.5f;
      CHECK(ok && in, "the depth a mixed pass writes is drawn back into the whole scaled depth buffer"); }
    // 6. the budget
    { tex_t a = desc(99800, &gpu_pool, NVN_FORMAT_RGBA8, 128, 72, NVN_TEXTURE_FLAGS_COMPRESSIBLE); uint64_t b0 = atomic_load(&g_rs_live_b), n0 = atomic_load(&g_rs_live_n), add = 0;
      @autoreleasepool { MTLTextureDescriptor *d = tex_desc(&a, 0); id<MTLTexture> x = d ? [g_dev newTextureWithDescriptor:d] : nil; rs_track(x, &a);
          add = atomic_load(&g_rs_live_b) - b0;
          CHECK(x && x.width == 256 && atomic_load(&g_rs_live_n) == n0 + 1 && add >= (uint64_t)x.allocatedSize * 3 / 4 - 1 && add <= (uint64_t)x.allocatedSize, "a scaled texture counts three quarters of its memory while it lives"); }
      CHECK(atomic_load(&g_rs_live_b) == b0 && atomic_load(&g_rs_live_n) == n0, "freed, it no longer counts");
      uint64_t keep = g_rs_budget; g_rs_budget = b0 + add / 2;   // room for half of one more
      tex_t over = desc(99801, &gpu_pool, NVN_FORMAT_RGBA8, 128, 72, NVN_TEXTURE_FLAGS_COMPRESSIBLE); MTLTextureDescriptor *d = tex_desc(&over, 0);
      CHECK(d && d.width == 128 && d.height == 72 && g_rs_refused[RS_WHY_BUDGET] >= 1, "past the budget a new target is made at the game's size");
      g_rs_budget = keep; d = tex_desc(&over, 0);
      CHECK(d && d.width == 128, "and stays so for every later descriptor of that texture, the budget raised or not");
      tex_t ok2 = desc(99802, &gpu_pool, NVN_FORMAT_RGBA8, 128, 72, NVN_TEXTURE_FLAGS_COMPRESSIBLE); d = tex_desc(&ok2, 0);
      CHECK(d && d.width == 256, "within the budget a new target is scaled");
      int mode = g_mr_mode; g_mr_mode = 1; atomic_store(&g_mr_short, 1);
      tex_t sh = desc(99803, &gpu_pool, NVN_FORMAT_RGBA8, 128, 72, NVN_TEXTURE_FLAGS_COMPRESSIBLE); d = tex_desc(&sh, 0);
      CHECK(d && d.width == 128 && g_rs_refused[RS_WHY_SHORT] >= 1, "while the memory relief finds the process short of memory a new target is made at the game's size");
      atomic_store(&g_mr_short, 0); g_mr_mode = mode; }
    // 7. an upscaler's rectangle at its input's scale
    { uint32_t v[4] = {32, 18, 63, 35}; NVNcopyRegion r = {0};   // 64x36 at 32,18 of the game's 128x72
      CHECK(up_rect_at(v, colt, 2.0f, &r) && r.xoffset == 64 && r.yoffset == 36 && r.width == 128 && r.height == 72, "an upscaler's input rectangle of a scaled texture in its pixels");
      CHECK(up_rect_at(v, lowt, 1.0f, &r) && r.xoffset == 32 && r.width == 64, "and of a texture at the game's size as given");
      uint32_t big[4] = {0, 0, 255, 143};
      CHECK(!up_rect_at(big, colt, 2.0f, &r), "a rectangle past the game's size is refused, as it was"); }
    CHECK(!mtl_last_commit_error(), "every submission completed");
    mtl_pool_del(host); free(host); mtl_pool_del(vertices); free(vertices);
    printf("resolution scale: %d checks, %d failed\n", checks, fails); return fails != 0;
} }
