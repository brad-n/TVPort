// BC6H on a GPU without BC formats (DM_TEST_NO_BC=1): unsigned BC6H (NVN 0x50, BPTC_UFLOAT) is stored as RG11B10Float, 4 bytes a pixel and no alpha, instead of RGBA16Float (8 bytes); signed BC6H
// (0x4f) has negative texels and stays RGBA16Float. DM_BC6H_R11G11B10=0 (nvn_bc6h_r11g11b10_set(0)) restores RGBA16Float for both. Checks: the formats, the CPU decode against the RGBA16Float decode
// of the same blocks (within RG11B10Float's 6 / 5 mantissa bits), the engine's upload and a buffer-to-texture copy (Metal format, size, sampled colour, sampled alpha 1).
#include "../nvn/nvn_mtl.m"
#include <math.h>
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } } while (0)

static void fill_blocks(uint8_t *data, size_t size, unsigned seed) {
    uint32_t state = seed + 1;
    for (size_t i = 0; i < size; i++) { state = state * 1664525u + 1013904223u; data[i] = state >> 24; }
}
static float half_f(uint16_t h) {
    int e = (h >> 10) & 31, m = h & 1023; float s = h & 0x8000 ? -1.f : 1.f;
    return e == 0 ? s * ldexpf((float)m, -24) : e == 31 ? (m ? NAN : s * INFINITY) : s * ldexpf((float)(m | 1024), e - 25);
}
static float uf_f(uint32_t v, int mbits) {   // an unsigned float with 5 exponent bits and mbits mantissa bits
    int e = v >> mbits, m = v & ((1 << mbits) - 1);
    return e == 0 ? ldexpf((float)m, -14 - mbits) : ldexpf((float)(m | (1 << mbits)), e - 15 - mbits);
}
static void fill_storage(tex_t *tp, nvn_texdesc desc, unsigned seed) {
    for (unsigned level = 0; level < desc.levels; level++) {
        uint32_t row, rows, depth, bpb; uint64_t base; unsigned th, td;
        if (nvn_deswizzle_geom(&desc, level, 0, &row, &rows, &depth, &base, &th, &td, &bpb)) abort();
        size_t size = (size_t)row * rows * depth; uint8_t *linear = malloc(size);
        fill_blocks(linear, size, seed + level);
        if (nvn_swizzle(&desc, level, 0, linear, row, tp->mem)) abort();
        free(linear);
    }
}
static tex_t fixture(nvn_texdesc desc, void **allocation, unsigned seed) {
    tex_t texture = {0}; texture.d = desc; nvn_tex_layout(&desc, &texture.L);
    size_t page = getpagesize(), bytes = (texture.L.size + page - 1) & ~(page - 1);
    if (posix_memalign(allocation, page, bytes)) abort();
    memset(*allocation, 0, bytes); mtl_pool_add(*allocation, bytes);
    texture.mem = *allocation; texture.serial = nvn_new_serial(); texture.has_layout = 1; texture.magic = MAGIC('T', 'E', 'X', 0);
    fill_storage(&texture, desc, seed);
    return texture;
}
static void release_fixture(void *allocation) { mtl_pool_del(allocation); mtl_drain(); free(allocation); }

// Expected float value of decoded pixel i (4 channels) of a w*h region, from the RGBA16Float decode of the same blocks (the switch off)
static void reference(uint32_t fmt, const uint8_t *blocks, size_t pitch, uint32_t w, uint32_t h, float *out) {
    nvn_bc6h_r11g11b10_set(0);
    uint16_t *px = malloc((size_t)w * h * 8);
    CHECK(!nvn_bc_decode(fmt, blocks, pitch, w, h, (uint8_t *)px, (size_t)w * 8), "RGBA16Float decode");
    for (size_t i = 0; i < (size_t)w * h * 4; i++) out[i] = half_f(px[i]);
    free(px);
    nvn_bc6h_r11g11b10_set(1);
}
// Tolerance for one channel: its own mantissa rounding (half an ulp of a (mbits)-bit mantissa, relative) plus the smallest value the format holds; a reference past the format's largest value is clamped to it
static int close_channel(float got, float want, int mbits) {
    float max = ldexpf(2.f - ldexpf(1.f, -mbits), 15);
    if (isnan(want) || isinf(want) || want > max) want = max;
    if (want < 0) want = 0;
    return fabsf(got - want) <= want * ldexpf(1.f, -mbits - 1) * 1.001f + ldexpf(1.f, -14 - mbits);
}

static id<MTLComputePipelineState> sampler_pipeline(void) {
    static id<MTLComputePipelineState> ps;
    if (ps) return ps;
    NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
        "kernel void sample_2d(texture2d<float> t [[texture(0)]], device float4 *out [[buffer(0)]], constant uint &level [[buffer(1)]], uint2 gid [[thread_position_in_grid]]) {\n"
        "  uint w = t.get_width(level); if (gid.x >= w || gid.y >= t.get_height(level)) return;\n"
        "  out[gid.y * w + gid.x] = t.read(gid, level); }\n";
    NSError *error = nil; id<MTLLibrary> lib = [g_dev newLibraryWithSource:source options:nil error:&error];
    if (!lib) { fprintf(stderr, "no sampler library: %s\n", error.description.UTF8String); exit(1); }
    ps = [g_dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"sample_2d"] error:&error];
    return ps;
}
static void sample_level(id<MTLTexture> mt, unsigned level, float *out4) {   // the texture as a shader reads it: float4 per pixel
    uint32_t w = MAX(mt.width >> level, 1u), h = MAX(mt.height >> level, 1u);
    id<MTLBuffer> out = [g_dev newBufferWithLength:(size_t)w * h * 16 options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb = [g_q commandBuffer]; id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
    [e setComputePipelineState:sampler_pipeline()]; [e setTexture:mt atIndex:0]; [e setBuffer:out offset:0 atIndex:0]; [e setBytes:&level length:sizeof level atIndex:1];
    [e dispatchThreads:MTLSizeMake(w, h, 1) threadsPerThreadgroup:MTLSizeMake(MIN(w, 8u), MIN(h, 8u), 1)]; [e endEncoding]; [cb commit]; [cb waitUntilCompleted];
    CHECK(cb.status == MTLCommandBufferStatusCompleted && !cb.error, "sampling kernel completes");
    memcpy(out4, out.contents, (size_t)w * h * 16);
}

static void test_cpu_decode(void) {
    uint32_t pf; int bpp;
    nvn_bc6h_r11g11b10_set(1);
    CHECK(nvn_bc_unpacked(0x50, &pf, &bpp) && pf == MTLPixelFormatRG11B10Float && bpp == 4, "unsigned BC6H decodes to RG11B10Float, 4 bytes");
    CHECK(nvn_bc_unpacked(0x4f, &pf, &bpp) && pf == MTLPixelFormatRGBA16Float && bpp == 8, "signed BC6H stays RGBA16Float, 8 bytes");
    CHECK(!nvn_bc_astc_format(0x50, 4, NULL) && !nvn_bc_astc_format(0x4f, 4, NULL) && nvn_bc_astc_format(0x4d, 4, NULL), "BC6H (4 bytes now) is still not an ASTC format; BC7 is");
    nvn_bc6h_r11g11b10_set(0);
    CHECK(nvn_bc_unpacked(0x50, &pf, &bpp) && pf == MTLPixelFormatRGBA16Float && bpp == 8, "with the switch off unsigned BC6H is RGBA16Float again");
    nvn_bc6h_r11g11b10_set(1);
    // 61x37 (edge blocks included) of random blocks, a few sets, against the RGBA16Float decode
    enum { W = 61, H = 37 };
    size_t pitch = ((W + 3) / 4) * 16, nrows = (H + 3) / 4;
    uint8_t *blocks = malloc(pitch * nrows); float *want = malloc((size_t)W * H * 16); uint32_t *got = malloc((size_t)W * H * 4);
    unsigned bad = 0, total = 0, big = 0;
    for (unsigned seed = 0; seed < 8; seed++) {
        fill_blocks(blocks, pitch * nrows, 100 + seed);
        reference(0x50, blocks, pitch, W, H, want);
        CHECK(!nvn_bc_decode(0x50, blocks, pitch, W, H, (uint8_t *)got, (size_t)W * 4), "RG11B10Float decode");
        for (size_t i = 0; i < (size_t)W * H; i++) {
            float r = uf_f(got[i] & 2047, 6), g = uf_f(got[i] >> 11 & 2047, 6), b = uf_f(got[i] >> 22, 5);
            total++; if (want[i * 4] > 64512.f) big++;
            if (!close_channel(r, want[i * 4], 6) || !close_channel(g, want[i * 4 + 1], 6) || !close_channel(b, want[i * 4 + 2], 5)) bad++;
        }
    }
    printf("CPU decode: %u pixels, %u outside RG11B10Float precision (%u red values past its range)\n", total, bad, big);
    CHECK(total > 0 && bad == 0, "RG11B10Float decode is the RGBA16Float decode within the format's precision");
    // an all-zero block
    memset(blocks, 0, 16); CHECK(!nvn_bc_decode(0x50, blocks, 16, 4, 4, (uint8_t *)got, 16), "zero block"); reference(0x50, blocks, 16, 4, 4, want);
    CHECK(got[0] == 0 || close_channel(uf_f(got[0] & 2047, 6), want[0], 6), "a zero block decodes to a value the RGBA16Float decode has");
    // signed: unchanged (the RGBA16Float path with alpha 1.0)
    uint16_t sg[16 * 4]; fill_blocks(blocks, 16, 7);
    CHECK(!nvn_bc_decode(0x4f, blocks, 16, 4, 4, (uint8_t *)sg, 32), "signed decode");
    int alpha_one = 1; for (int i = 0; i < 16; i++) alpha_one &= sg[i * 4 + 3] == 0x3c00;
    CHECK(alpha_one, "signed BC6H keeps alpha 1.0");
    free(blocks); free(want); free(got);
}

static void test_engine(void) {
    nvn_bc6h_r11g11b10_set(1);
    nvn_texdesc d = {.target = NVN_TEXTURE_TARGET_2D, .format = 0x50, .width = 64, .height = 36, .depth = 1, .levels = 3, .samples = 1};
    void *mem; tex_t t = fixture(d, &mem, 5);
    mtl_sub_begin(); id<MTLTexture> mt = pkg_upload(&t, NULL, nil, 0); CHECK(mtl_wait(mtl_sub_commit(), 20000000000ull), "the upload completes");
    CHECK(mt && mt.pixelFormat == MTLPixelFormatRG11B10Float && mt.width == 64 && mt.height == 36 && mt.mipmapLevelCount == 3, "unsigned BC6H texture: RG11B10Float, same size and levels");
    unsigned bad = 0, n = 0, alpha_bad = 0;
    for (unsigned l = 0; mt && l < 3; l++) {
        uint32_t w = MAX(64u >> l, 1u), h = MAX(36u >> l, 1u), row, rows, depth, bpb; uint64_t base; unsigned th, td;
        nvn_deswizzle_geom(&d, l, 0, &row, &rows, &depth, &base, &th, &td, &bpb);
        uint8_t *linear = malloc((size_t)row * rows); fill_blocks(linear, (size_t)row * rows, 5 + l);
        float *want = malloc((size_t)w * h * 16), *got = malloc((size_t)w * h * 16);
        reference(0x50, linear, row, w, h, want); sample_level(mt, l, got);
        for (size_t i = 0; i < (size_t)w * h; i++) {
            n++; alpha_bad += got[i * 4 + 3] != 1.0f;
            if (!close_channel(got[i * 4], want[i * 4], 6) || !close_channel(got[i * 4 + 1], want[i * 4 + 1], 6) || !close_channel(got[i * 4 + 2], want[i * 4 + 2], 5)) bad++;
        }
        free(linear); free(want); free(got);
    }
    printf("engine upload: %u pixels sampled, %u outside the precision, %u with alpha != 1\n", n, bad, alpha_bad);
    CHECK(n && bad == 0, "the sampled texture is the BC6H decode within RG11B10Float precision");
    CHECK(n && alpha_bad == 0, "a sampled alpha reads 1.0");
    defer_obj_release(mt); release_fixture(mem);

    // a buffer-to-texture copy (the CPU decode of the source) into an empty unsigned BC6H texture
    {
        enum { SW = 32, RW = 16, RH = 12, OX = 8, OY = 4 };
        nvn_texdesc cd = {.target = NVN_TEXTURE_TARGET_2D, .format = 0x50, .width = SW, .height = SW, .depth = 1, .levels = 1, .samples = 1};
        void *smem; if (posix_memalign(&smem, getpagesize(), 16384)) abort(); mtl_pool_add(smem, 16384);
        size_t row = RW / 4 * 16, rows = RH / 4; fill_blocks(smem, row * rows, 33);
        float *want = malloc((size_t)RW * RH * 16); reference(0x50, smem, row, RW, RH, want);
        tex_t ct = {.magic = MAGIC('T','E','X',0), .serial = nvn_new_serial(), .d = cd}; nvn_tex_layout(&cd, &ct.L);
        void *tmem; size_t bytes = (ct.L.size + 16383) & ~(size_t)16383; if (posix_memalign(&tmem, getpagesize(), bytes)) abort();
        memset(tmem, 0, ct.L.size); ct.mem = tmem; mtl_pool_add(tmem, bytes);
        mtl_tex_init(&ct); mtl_sub_begin(); id<MTLTexture> cm = tex_mtl(&ct); CHECK(mtl_wait(mtl_sub_commit(), 20000000000ull), "the new texture completes");
        CHECK(cm && cm.pixelFormat == MTLPixelFormatRG11B10Float, "a texture made for copies is RG11B10Float");
        p_copy_b2t c = {.src = (uint64_t)(uintptr_t)smem, .tex = &ct, .r = {OX, OY, 0, RW, RH, 1}};
        mtl_sub_begin(); copy_b2t(&c, sizeof c); CHECK(mtl_wait(mtl_sub_commit(), 20000000000ull), "the copy completes");
        float *got = malloc((size_t)SW * SW * 16); sample_level(cm, 0, got);
        unsigned cbad = 0, calpha = 0;
        for (unsigned y = OY; y < OY + RH; y++) for (unsigned x = OX; x < OX + RW; x++) {
            const float *g = got + ((size_t)y * SW + x) * 4, *w = want + ((size_t)(y - OY) * RW + (x - OX)) * 4;
            calpha += g[3] != 1.0f; cbad += !close_channel(g[0], w[0], 6) || !close_channel(g[1], w[1], 6) || !close_channel(g[2], w[2], 5);
        }
        printf("copy_b2t: %u of %d pixels outside the precision, %u with alpha != 1\n", cbad, RW * RH, calpha);
        CHECK(cbad == 0 && calpha == 0, "a copy into an unsigned BC6H texture is the decode, alpha 1");
        defer_obj_release(cm); release_fixture(tmem); release_fixture(smem); free(want); free(got);
    }

    // signed stays RGBA16Float
    nvn_texdesc sd = d; sd.format = 0x4f; void *smem2; tex_t st = fixture(sd, &smem2, 9);
    mtl_sub_begin(); id<MTLTexture> sm = pkg_upload(&st, NULL, nil, 0); CHECK(mtl_wait(mtl_sub_commit(), 20000000000ull), "the signed upload completes");
    CHECK(sm && sm.pixelFormat == MTLPixelFormatRGBA16Float, "signed BC6H texture stays RGBA16Float");
    defer_obj_release(sm); release_fixture(smem2);
    // with the switch off unsigned is RGBA16Float
    nvn_bc6h_r11g11b10_set(0);
    void *umem; tex_t ut = fixture(d, &umem, 5);
    mtl_sub_begin(); id<MTLTexture> um = pkg_upload(&ut, NULL, nil, 0); CHECK(mtl_wait(mtl_sub_commit(), 20000000000ull), "the upload completes");
    CHECK(um && um.pixelFormat == MTLPixelFormatRGBA16Float, "DM_BC6H_R11G11B10=0: unsigned BC6H is RGBA16Float");
    defer_obj_release(um); release_fixture(umem);
    nvn_bc6h_r11g11b10_set(1);
}

int main(void) { @autoreleasepool {
    setenv("DM_TEST_NO_BC", "1", 1);
    mtl_init();
    test_cpu_decode();
    test_engine();
    mtl_drain();
    printf("BC6H RG11B10Float: %d checks, %d failures\n", checks, failed);
    return failed ? 1 : 0;
} }
