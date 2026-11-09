// DM_NVN_ARGS_CACHE: an argument block serves again while the bindings it was made from are exactly those bound: across a program switch and across the passes of its submission.
// Two synthetic fragment shaders read a uniform buffer and a texture (out = u[0] * texel). Each draw renders into a 4x4 target of its own, so the GPU shows which block it read:
// the block of an earlier pass serves the next pass when nothing changed, and a uniform buffer bound between passes, a texture ID registered again, a new submission, a shader that
// reads a handle from memory or a pass of another sample count each get a new block whose contents and picture are the current ones. Without the switch a program switch and a new
// pass both encode again, as before
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } } while (0)

enum { LEN = 1 << 20 };
static id<MTLTexture> make_tex(tex_t *t, uint64_t serial, const uint8_t rgba[4], int rt) {
    *t = (tex_t){.magic = MAGIC('T','E','X',0), .serial = serial};
    t->d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = NVN_FORMAT_RGBA8, .width = 4, .height = 4, .depth = 1, .levels = 1, .samples = 1};
    MTLTextureDescriptor *d = tex_desc(t, 0); d.storageMode = MTLStorageModeShared; if (rt) d.usage |= MTLTextureUsageRenderTarget;
    id<MTLTexture> x = [g_dev newTextureWithDescriptor:d];
    CHECK(x != nil, "texture created");
    uint8_t px[64]; for (int i = 0; i < 16; i++) memcpy(px + 4 * i, rgba, 4);
    [x replaceRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0 withBytes:px bytesPerRow:16];
    res_add(x); mtl_tex_init(t); serial_put(serial, x);
    return x;
}
static id<MTLRenderPipelineState> g_ps;
static uint8_t *g_mem;
static uint64_t ubo(int k) { return (uint64_t)(uintptr_t)(g_mem + 256 * k); }
static void bind_ubo(int k) { p_bind_buf b = {1, 0, ubo(k), 256}; state_op(OP_BIND_UBO, &b); }
static void bind_tex(int tid) { p_bind_handles h = {.stage = 1, .first = 0, .n = 1}; h.h[0] = (uint64_t)tid; state_op(OP_BIND_TEX, &h); }
// One draw of shader sh into target out (a pass of its own unless keep is set), its block's address and the slots it holds
static uint64_t draw_into(NvShader *sh, tex_t *out, int open, int close, uint64_t slots[2]) {
    if (open) { R.has_rt = 1; R.rt.n = 1; R.rt.color[0] = out; R.clear_c[0] = 1; R.cc[0] = MTLClearColorMake(0, 0, 0, 0); CHECK(rp_begin() != nil, "pass opens"); }
    enc_r_pso(g_enc, g_ps); enc_r_viewport(g_enc, (MTLViewport){0, 0, 4, 4, 0, 1});
    CHECK(encode_args((id<MTLCommandEncoder>)g_enc, sh, 1, 0), "arguments encoded");
    enc_r_draw(g_enc, MTLPrimitiveTypeTriangle, 0, 3);
    if (slots) memcpy(slots, (const uint8_t *)sh->ab_buf.contents + sh->ab_off, 16);
    if (close) rp_end();
    return sh->ab_gpu;
}
static void pixel(id<MTLTexture> t, const uint8_t want[4], const char *label) {
    uint8_t got[4]; [t getBytes:got bytesPerRow:16 fromRegion:MTLRegionMake2D(1, 1, 1, 1) mipmapLevel:0];
    CHECK(!memcmp(got, want, 4), label);
    if (memcmp(got, want, 4)) fprintf(stderr, "  got %d %d %d %d, want %d %d %d %d\n", got[0], got[1], got[2], got[3], want[0], want[1], want[2], want[3]);
}

int main(void) { @autoreleasepool {
    setenv("DM_NVN_TBDR", "0", 1); setenv("DM_NVN_ARGS_CACHE", "1", 1);
    mtl_init(); NSError *error = nil;
    id<MTLLibrary> lib = [g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
        "vertex float4 v(uint i[[vertex_id]]) { return float4(i == 1 ? 3.0 : -1.0, i == 2 ? 3.0 : -1.0, 0, 1); }\n"
        "struct A { constant float4 *u [[id(0)]]; texture2d<float, access::read> t [[id(1)]]; };\n"
        "fragment float4 f(constant A &a [[buffer(0)]]) { return a.u[0] * a.t.read(uint2(0, 0)); }\n"
        "fragment float4 g(constant A &a [[buffer(0)]]) { return a.u[0] * a.t.read(uint2(0, 0)); }\n"
        options:nil error:&error];
    CHECK(lib != nil, "synthetic shaders compile");
    if (!lib) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 1; }
    NvShader *sa = [NvShader new], *sc = [NvShader new];
    NSString *names[2] = {@"f", @"g"}; NvShader *both[2] = {sa, sc};
    for (int i = 0; i < 2; i++) { NvShader *s = both[i]; s->stage = 1; snprintf(s->key, sizeof s->key, "00000000000000a%d", i); s->fn = [lib newFunctionWithName:names[i]];
        s->ae = [s->fn newArgumentEncoderWithBufferIndex:0]; s->arg_len = s->ae.encodedLength; s->rf.nb = 2;
        s->rf.b[0] = (nvn_rbind){.kind = NVN_RB_CBUF, .reg = 0, .aid = 0}; s->rf.b[1] = (nvn_rbind){.kind = NVN_RB_TEX, .reg = 0, .aid = 1, .dtt = MTLTextureType2D}; }
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [lib newFunctionWithName:@"v"]; d.fragmentFunction = sa->fn; d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    g_ps = [g_dev newRenderPipelineStateWithDescriptor:d error:&error];
    CHECK(g_ps != nil, "pipeline compiles");
    if (!g_ps) return 1;
    // Uniform buffers 0..3 in a pool the host maps: red, green, blue, white (u[0] scales the white or grey texture)
    g_mem = mmap(NULL, LEN, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); mtl_pool_add(g_mem, LEN);
    const float col[4][4] = {{1, 0, 0, 1}, {0, 1, 0, 1}, {0, 0, 1, 1}, {1, 1, 1, 1}};
    for (int k = 0; k < 4; k++) memcpy(g_mem + 256 * k, col[k], 16);
    tex_t white, grey, out[16]; id<MTLTexture> outs[16];
    make_tex(&white, 98000, (const uint8_t[]){255, 255, 255, 255}, 0); id<MTLTexture> greyt = make_tex(&grey, 98001, (const uint8_t[]){128, 128, 128, 255}, 0);
    for (int i = 0; i < 16; i++) outs[i] = make_tex(&out[i], 98100 + i, (const uint8_t[]){9, 9, 9, 9}, 1);
    mtl_reg_tex(700, &white, NULL);
    CHECK(args_cache_on(), "the switch is read");

    state_reset(); memset(&R, 0, sizeof R); mtl_sub_begin();
    bind_ubo(0); bind_tex(700);
    uint64_t s0[2], s1[2], s2[2], s3[2], s4[2];
    uint64_t enc = g_stat_args_enc, xhit = g_xs[XS_AB_XHIT];
    uint64_t a0 = draw_into(sa, &out[0], 1, 0, s0);                     // pass 1: shader A
    draw_into(sc, NULL, 0, 0, NULL);                                    // a program switch to C, same pass
    uint64_t a1 = draw_into(sa, NULL, 0, 1, NULL);                      // back to A: nothing it reads changed
    CHECK(a1 == a0 && g_stat_args_enc == enc + 2 && g_xs[XS_AB_XHIT] == xhit + 1, "a program switch alone keeps A's block");
    uint64_t a2 = draw_into(sa, &out[1], 1, 1, s1);                     // pass 2, same bindings
    CHECK(a2 == a0 && g_xs[XS_AB_XHIT] == xhit + 2 && !memcmp(s0, s1, 16), "the next pass of the submission reuses the block");
    bind_ubo(1);                                                         // a uniform buffer bound between passes
    uint64_t a3 = draw_into(sa, &out[2], 1, 1, s2);
    CHECK(a3 != a0 && s2[0] != s0[0] && s2[1] == s0[1], "a binding changed between passes: a new block with the new buffer");
    uint64_t gpu1 = 0; void *mb; uint64_t mo; CHECK(mtl_gpu_addr(ubo(1), 256, &mb, &mo, &gpu1) && s2[0] == gpu1, "the block holds the bound buffer's address");
    mtl_reg_tex(700, &grey, NULL);                                       // the ID registered with another texture (a generation)
    uint64_t a4 = draw_into(sa, &out[3], 1, 1, s3);
    CHECK(a4 != a3 && s3[1] != s2[1] && s3[1] == greyt.gpuResourceID._impl, "a registration change: a new block with the new texture");
    CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull) && !mtl_last_commit_error(), "first submission completed");
    pixel(outs[0], (const uint8_t[]){255, 0, 0, 255}, "pass 1: red uniform, white texture");
    pixel(outs[1], (const uint8_t[]){255, 0, 0, 255}, "pass 2 (reused block): the same");
    pixel(outs[2], (const uint8_t[]){0, 255, 0, 255}, "pass 3: the green uniform bound between passes");
    pixel(outs[3], (const uint8_t[]){0, 128, 0, 255}, "pass 4: the grey texture registered since");

    // A new submission: the earlier submission's block is not taken (its arena goes with that submission's fence)
    mtl_sub_begin();
    uint64_t a5 = draw_into(sa, &out[4], 1, 1, s4);
    CHECK(a5 != a4 && sa->ab_sub == g_sub_serial && !memcmp(s4, s3, 16), "a new submission encodes again, the same contents");
    // A pass of another sample count: c0's sample positions differ, so a block that might read them is not taken (a stand-in: the pass's count changed)
    uint32_t samples = g_pass.samples; uint64_t a5b = sa->ab_gpu;
    R.has_rt = 1; R.rt.n = 1; R.rt.color[0] = &out[5]; R.clear_c[0] = 1; CHECK(rp_begin() != nil, "pass opens");
    g_pass.samples = samples + 3;
    enc_r_pso(g_enc, g_ps); enc_r_viewport(g_enc, (MTLViewport){0, 0, 4, 4, 0, 1}); encode_args((id<MTLCommandEncoder>)g_enc, sa, 1, 0);
    CHECK(sa->ab_gpu != a5b, "another sample count: a new block");
    g_pass.samples = samples; enc_r_draw(g_enc, MTLPrimitiveTypeTriangle, 0, 3); rp_end();
    // A shader that reads a handle from memory: its block stays in its pass
    sc->rf.b[1] = (nvn_rbind){.kind = NVN_RB_TEXU, .reg = 0, .off = 16, .aid = 1, .dtt = MTLTextureType2D}; sc->ab_xpk = 0;
    uint32_t h = 700; memcpy(g_mem + 256 + 16, &h, 4);   // in the bound uniform buffer (1), after its colour
    uint64_t c0 = draw_into(sc, &out[6], 1, 1, NULL), c1 = draw_into(sc, &out[7], 1, 1, NULL);
    CHECK(c1 != c0 && !sc->ab_xp, "a block that read a handle from memory is not taken by the next pass");
    CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull) && !mtl_last_commit_error(), "second submission completed");
    pixel(outs[4], (const uint8_t[]){0, 128, 0, 255}, "new submission: the same picture");
    pixel(outs[6], (const uint8_t[]){0, 128, 0, 255}, "the handle read from memory: the grey texture");

    // Off: a program switch and a new pass encode again, as before
    g_args_cache = 0; sc->rf.b[1] = sa->rf.b[1]; sc->ab_xpk = 0;
    mtl_sub_begin(); enc = g_stat_args_enc;
    uint64_t b0 = draw_into(sa, &out[8], 1, 0, NULL); args_dirty_all(); draw_into(sc, NULL, 0, 0, NULL); args_dirty_all();   // OP_BIND_PROGRAM's dirtying without the switch
    uint64_t b1 = draw_into(sa, NULL, 0, 1, NULL), b2 = draw_into(sa, &out[9], 1, 1, NULL);
    CHECK(b1 != b0 && b2 != b1 && g_stat_args_enc == enc + 4, "switch off: the program switch and the next pass encode again");
    CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull) && !mtl_last_commit_error(), "third submission completed");
    pixel(outs[9], (const uint8_t[]){0, 128, 0, 255}, "switch off: the same picture");
    mtl_reg_tex(700, NULL, NULL);
    printf("t_args_cache: %d checks, %d failed\n", checks, failed); return failed != 0;
} }
