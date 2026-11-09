// The movie library's enhancement network replaced by a plain scale (DM_MOVIE_NETWORK=bypass; nvn_mtl.m up_movie_step): Ocarina of Time's per-frame chain is 49dff010 (Y and UV planes into an RGBA8 picture),
// a dozen layer shaders on storage buffers, and the NDSR stage 4f41ccf2 (the layers' result into the 2560x1440 RGBA8 image the game draws from). With the bypass the YUV stage runs, the layers do not, and the NDSR
// stage's dispatch becomes a bilinear scale of the picture into its image, with no MetalFX anywhere. The shader roles are checked against the profile's 22 movie keys when it has them.
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s\n", label); } } while (0)
static tex_t texture(uint64_t serial, unsigned w, unsigned h, int format) {
    tex_t t = {.magic = MAGIC('T','E','X',0), .serial = serial, .off = serial << 24};
    t.d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = format, .width = w, .height = h, .depth = 1, .levels = 1, .samples = 1};
    nvn_tex_layout(&t.d, &t.L); mtl_tex_init(&t); return t;
}
static void fill(id<MTLTexture> t, MTLClearColor c) {
    id<MTLCommandBuffer> cb = q_cb(); MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = t; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore; rp.colorAttachments[0].clearColor = c;
    [[cb renderCommandEncoderWithDescriptor:rp] endEncoding]; [cb commit]; [cb waitUntilCompleted];
}
// left half red, right half blue (RGBA8), by a copy from a buffer
static void fill_halves(id<MTLTexture> t) {
    NSUInteger w = t.width, h = t.height; id<MTLBuffer> b = [g_dev newBufferWithLength:w * h * 4 options:MTLResourceStorageModeShared]; uint8_t *p = b.contents;
    for (NSUInteger y = 0; y < h; y++) for (NSUInteger x = 0; x < w; x++) { uint8_t *q = p + 4 * (y * w + x); q[0] = x < w / 2 ? 255 : 0; q[1] = 0; q[2] = x < w / 2 ? 0 : 255; q[3] = 255; }
    id<MTLCommandBuffer> cb = q_cb(); id<MTLBlitCommandEncoder> e = [cb blitCommandEncoder];
    [e copyFromBuffer:b sourceOffset:0 sourceBytesPerRow:w * 4 sourceBytesPerImage:w * h * 4 sourceSize:MTLSizeMake(w, h, 1) toTexture:t destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
    [e endEncoding]; [cb commit]; [cb waitUntilCompleted];
}
static uint8_t *read_rgba8(id<MTLTexture> t, id<MTLBuffer> *keep) {
    NSUInteger w = t.width, h = t.height; *keep = [g_dev newBufferWithLength:w * h * 4 options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb = q_cb(); id<MTLBlitCommandEncoder> e = [cb blitCommandEncoder];
    [e copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, h, 1) toBuffer:*keep destinationOffset:0 destinationBytesPerRow:w * 4 destinationBytesPerImage:w * h * 4];
    [e endEncoding]; [cb commit]; [cb waitUntilCompleted]; return (*keep).contents;
}
static NvShader *shader(const char *key, int ntex, const int *texreg, int nimg, const int *imgreg) {
    NvShader *s = [NvShader new]; snprintf(s->key, sizeof s->key, "%s_b", key); int n = 0;
    for (int i = 0; i < ntex; i++) s->rf.b[n++] = (nvn_rbind){.kind = NVN_RB_TEX, .dtt = MTLTextureType2D, .dpf = NVN_DPF_FLOAT, .reg = texreg[i]};
    for (int i = 0; i < nimg; i++) s->rf.b[n++] = (nvn_rbind){.kind = NVN_RB_IMG, .dtt = MTLTextureType2D, .dpf = NVN_DPF_FLOAT, .reg = imgreg[i], .rw = 1};
    s->rf.nb = n; return s;
}
int main(void) { @autoreleasepool {
    mtl_init();
    const char *sw = getenv("DM_MOVIE_NETWORK"); int on = sw && !strcmp(sw, "bypass");
    // the roles of the library's shaders (every key of the profile's list; a profile without a movie network checks none)
    int roles[5] = {0}, listed = 0;
    for (const char *k = DM_GAME_MOVIE_KEYS; *k; k += k[16] == ',' ? 17 : 16) { listed++; roles[up_movie_role(k)]++; }
    if (DM_GAME_MOVIE_N) {
        CHECK(listed == DM_GAME_MOVIE_N, "the profile lists as many movie keys as it counts");
        CHECK(roles[MV_YUV] == 1 && roles[MV_RGB] == 1 && roles[MV_OUT] == 2 && roles[MV_LAYER] == listed - 4, "of the movie shaders one is the YUV stage, one the RGB entry, two the NDSR stage, the rest layers");
        CHECK(up_movie_role("49dff010b9832251_b") == MV_YUV && up_movie_role("4f41ccf24f163e0d_b") == MV_OUT && up_movie_role("a8b4fb48fee0ccf8_b") == MV_LAYER, "named keys have their roles");
    }
    // one frame of the chain on synthetic textures
    tex_t y = texture(901, 1920, 1080, NVN_FORMAT_R8), uv = texture(902, 960, 540, NVN_FORMAT_RG8), pic = texture(903, 1920, 1080, NVN_FORMAT_RGBA8), res = texture(904, 1920, 1080, NVN_FORMAT_RGB10A2), out = texture(905, 2560, 1440, NVN_FORMAT_RGBA8);
    pic.d.flags |= NVN_TEXTURE_FLAGS_IMAGE; out.d.flags |= NVN_TEXTURE_FLAGS_IMAGE; res.d.flags |= NVN_TEXTURE_FLAGS_IMAGE;
    mtl_reg_tex(911, &y, NULL); mtl_reg_tex(912, &uv, NULL); mtl_reg_image(913, &pic, NULL); mtl_reg_image(914, &res, NULL); mtl_reg_image(915, &out, NULL);
    fill_halves(tex_mtl(&pic)); fill(tex_mtl(&out), MTLClearColorMake(0, 1, 0, 1)); fill(tex_mtl(&res), MTLClearColorMake(0, 0, 0, 0));
    const int yuv_t[2] = {1, 2}, yuv_i[1] = {0}, lay_t[1] = {1}, ndsr_t[2] = {0, 3}, ndsr_i[1] = {1};
    NvShader *yuv = shader("49dff010b9832251", 2, yuv_t, 1, yuv_i), *layer = shader("a8b4fb48fee0ccf8", 0, NULL, 0, NULL), *first = shader("ba079f68ae288dba", 1, lay_t, 0, NULL), *ndsr = shader("4f41ccf24f163e0d", 2, ndsr_t, 1, ndsr_i);
    memset(&S, 0, sizeof S); S.tex[5][1] = 911; S.tex[5][2] = 912; S.img[5][0] = 913; S.img[5][1] = 915;
    p_dispatch dp = {.x = 60, .y = 270, .z = 1};
    uint64_t skipped0 = g_movie_skipped, scaled0 = g_movie_scaled;
    mtl_sub_begin();
    int r_yuv = on ? up_movie_step(yuv, up_movie_role(yuv->key)) : -1, r_first = on ? up_movie_step(first, up_movie_role(first->key)) : -1, r_layer = on ? up_movie_step(layer, up_movie_role(layer->key)) : -1;
    int r_out = on ? up_movie_step(ndsr, up_movie_role(ndsr->key)) : -1;
    if (on) {
        CHECK(r_yuv == 0, "the YUV stage runs: it makes the picture");
        CHECK(g_movie_src_tid == 913, "the picture is the image the YUV stage wrote");
        CHECK(r_first == 1 && r_layer == 1 && g_movie_skipped == skipped0 + 2, "the layers are skipped");
        CHECK(r_out == 1 && g_movie_scaled == scaled0 + 1, "the NDSR stage is drawn as the plain scale");
    }
    CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull) && !mtl_last_commit_error(), "the submission completes");
    os_unfair_lock_lock(&g_rmu); id<MTLTexture> written = tex_by_id(915); os_unfair_lock_unlock(&g_rmu);
    id<MTLBuffer> keep; const uint8_t *px = read_rgba8(written, &keep);
    #define PX(x, y) (px + 4 * ((size_t)(y) * 2560 + (x)))
    if (on) {
        CHECK(PX(100, 100)[0] > 250 && PX(100, 100)[2] < 5 && PX(100, 100)[1] < 5, "the left of the output is the picture's red");
        CHECK(PX(2400, 1300)[2] > 250 && PX(2400, 1300)[0] < 5, "the right of the output is the picture's blue");
        CHECK(PX(5, 1435)[0] > 250 && PX(2554, 3)[2] > 250, "the corners keep their sides: the picture fills the whole output, unflipped");
        int seam = 0; for (int x = 0; x < 2560; x++) if (PX(x, 700)[0] > 128) seam = x;
        CHECK(seam >= 1275 && seam <= 1285, "the seam of the picture is at the middle of the output");
        CHECK(PX(10, 10)[1] < 5, "no texel keeps the old fill");
        // a second frame of another colour overwrites the first
        fill(tex_mtl(&pic), MTLClearColorMake(0.2, 0.4, 0.6, 1));
        mtl_sub_begin(); up_movie_step(yuv, MV_YUV); int again = up_movie_step(ndsr, MV_OUT); CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull) && !mtl_last_commit_error(), "the second submission completes");
        px = read_rgba8(written, &keep);
        CHECK(again == 1 && abs(PX(1280, 720)[0] - 51) <= 2 && abs(PX(1280, 720)[1] - 102) <= 2 && abs(PX(1280, 720)[2] - 153) <= 2, "the next frame's picture is scaled over the last");
        // no picture to scale: the dispatch is skipped and the output is left alone
        g_movie_src_tid = 0; uint64_t none = g_movie_nosrc; mtl_sub_begin(); int r = up_movie_step(ndsr, MV_OUT); mtl_wait(mtl_sub_commit(), 5000000000ull);
        CHECK(r == 1 && g_movie_nosrc == none + 1, "with no picture the stage is skipped and counted");
    } else {
        CHECK(PX(100, 100)[1] > 250 && PX(100, 100)[0] < 5, "without the switch the output is untouched");
        if (DM_GAME_MOVIE_N) CHECK(!up_movie(layer, &dp) && !up_movie(ndsr, &dp), "without the switch no dispatch is taken");
    }
    if (on && DM_GAME_MOVIE_N) {   // through the dispatch hook: only a profile's own keys count
        NvShader *l = shader(DM_GAME_MOVIE_KEYS, 0, NULL, 0, NULL); l->key[16] = 0; strcat(l->key, "_b");
        CHECK(up_movie(l, &dp) == up_movie_named(l) && up_movie_named(l), "a shader the profile lists is taken by the hook");
        NvShader *other = shader("0123456789abcdef", 0, NULL, 0, NULL); CHECK(!up_movie(other, &dp), "a shader the profile does not list runs");
    }
    printf("t_movie_bypass (%s): %d checks, %d failed\n", on ? "bypass" : "off", checks, failed);
    return failed != 0;
}}
