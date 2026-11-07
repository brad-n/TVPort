// DM_NVN_BC_ASTC (nvn_mtl.m, dm/gfx/tex/nvn_astc_cache.m): on a GPU stored without BC, BC1/2/3/7 2D textures are uploaded as ASTC 4x4 / 6x6 LDR. Runs on the Mac GPU with DM_TEST_NO_BC=1:
// the texture's Metal format and size, what a shader samples against the CPU decode of the same blocks, the content-addressed cache (a second upload is all hits, from the cache directory alone),
// BC4/BC5 and 3D staying decoded, and ASTC off (unset) leaving every BC format as it was.
// Fixture and swizzling follow nxnative-tvos' t_bc_upload.m (MIT, yuchanns).
#include "../nvn/nvn_mtl.m"
#include <math.h>
#include <dirent.h>
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } } while (0)

static void fill_blocks(uint8_t *data, size_t size, uint32_t format, unsigned seed) {
    int bb = (format == 0x41 || format == 0x42 || format == 0x45 || format == 0x46 || format == 0x49 || format == 0x4a) ? 8 : 16;
    uint32_t state = seed + 1;
    for (size_t i = 0; i < size; i++) { state = state * 1664525u + 1013904223u; data[i] = state >> 24; }
    for (size_t i = 0; i < size; i += bb) {
        if (format == 0x4d || format == 0x4e) {   // BC7 mode 6 (one subset, 7-bit endpoints): the mode bit pattern is 0b1000000
            data[i] = (data[i] & ~0x7fu) | 0x40u;
        }
    }
}
static tex_t fixture(nvn_texdesc desc, void **allocation) {
    tex_t texture = {0}; texture.d = desc; nvn_tex_layout(&desc, &texture.L);
    size_t page = getpagesize(), bytes = (texture.L.size + page - 1) & ~(page - 1);
    if (posix_memalign(allocation, page, bytes)) abort();
    memset(*allocation, 0, bytes); mtl_pool_add(*allocation, bytes);
    texture.mem = *allocation; texture.serial = nvn_new_serial(); texture.has_layout = 1; texture.magic = MAGIC('T', 'E', 'X', 0);
    for (unsigned level = 0; level < desc.levels; level++) {
        uint32_t row, rows, depth, bpb; uint64_t base; unsigned th, td;
        if (nvn_deswizzle_geom(&desc, level, 0, &row, &rows, &depth, &base, &th, &td, &bpb)) abort();
        size_t size = (size_t)row * rows * depth; uint8_t *linear = malloc(size);
        for (unsigned layer = 0; layer < texture.L.layers; layer++) {
            fill_blocks(linear, size, desc.format, level + layer * 17);
            if (nvn_swizzle(&desc, level, layer, linear, row, texture.mem)) abort();
        }
        free(linear);
    }
    return texture;
}
static void release_fixture(void *allocation) { mtl_pool_del(allocation); mtl_drain(); free(allocation); }

static id<MTLComputePipelineState> sampler_pipeline(int array) {
    static id<MTLComputePipelineState> pipelines[2];
    if (pipelines[array]) return pipelines[array];
    NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
        "kernel void sample_array(texture2d_array<float> t [[texture(0)]], device float4 *out [[buffer(0)]], constant uint2 &sel [[buffer(1)]], uint2 gid [[thread_position_in_grid]]) {\n"
        "  uint w = t.get_width(sel.x); if (gid.x >= w || gid.y >= t.get_height(sel.x)) return;\n"
        "  out[gid.y * w + gid.x] = t.read(gid, sel.y, sel.x); }\n"
        "kernel void sample_2d(texture2d<float> t [[texture(0)]], device float4 *out [[buffer(0)]], constant uint2 &sel [[buffer(1)]], uint2 gid [[thread_position_in_grid]]) {\n"
        "  uint w = t.get_width(sel.x); if (gid.x >= w || gid.y >= t.get_height(sel.x)) return;\n"
        "  out[gid.y * w + gid.x] = t.read(gid, sel.x); }\n";
    NSError *error = nil; id<MTLLibrary> lib = [g_dev newLibraryWithSource:source options:nil error:&error];
    if (!lib) { fprintf(stderr, "no sampler library: %s\n", error.description.UTF8String); exit(1); }
    pipelines[array] = [g_dev newComputePipelineStateWithFunction:[lib newFunctionWithName:array ? @"sample_array" : @"sample_2d"] error:&error];
    return pipelines[array];
}
static float srgb_to_linear(float c) { return c <= 0.04045f ? c / 12.92f : powf((c + 0.055f) / 1.055f, 2.4f); }

// Mean and maximum absolute channel error of ASTC level `level` (as sampled) against the CPU decode of the same BC blocks; both in the sampled (linear for sRGB) space
static void compare_level(id<MTLTexture> mt, tex_t *texture, nvn_texdesc d, unsigned level, unsigned layer, double *mean, double *peak) {
    uint32_t row, rows, depth, bpb; uint64_t base; unsigned th, td;
    nvn_deswizzle_geom(&d, level, 0, &row, &rows, &depth, &base, &th, &td, &bpb);
    uint32_t w = MAX(d.width >> level, 1u), h = MAX(d.height >> level, 1u);
    uint8_t *linear = malloc((size_t)row * rows);
    fill_blocks(linear, (size_t)row * rows, d.format, level + layer * 17);
    uint32_t upf; int ubpp; nvn_bc_unpacked(d.format, &upf, &ubpp);
    uint8_t *expected = malloc((size_t)w * h * 4);
    CHECK(!nvn_bc_decode(d.format, linear, row, w, h, expected, (size_t)w * 4), "CPU decode of the fixture");
    id<MTLBuffer> out = [g_dev newBufferWithLength:(size_t)w * h * 16 options:MTLResourceStorageModeShared];
    uint32_t sel[2] = {level, layer};
    id<MTLCommandBuffer> cb = [g_q commandBuffer]; id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
    [e setComputePipelineState:sampler_pipeline(mt.textureType == MTLTextureType2DArray)]; [e setTexture:mt atIndex:0]; [e setBuffer:out offset:0 atIndex:0]; [e setBytes:sel length:sizeof sel atIndex:1];
    [e dispatchThreads:MTLSizeMake(w, h, 1) threadsPerThreadgroup:MTLSizeMake(MIN(w, 8u), MIN(h, 8u), 1)];
    [e endEncoding]; [cb commit]; [cb waitUntilCompleted];
    CHECK(cb.status == MTLCommandBufferStatusCompleted && !cb.error, "sampling kernel completes");
    int srgb = upf == MTLPixelFormatRGBA8Unorm_sRGB;
    const float *got = out.contents; double sum = 0, max = 0;
    for (size_t i = 0; i < (size_t)w * h * 4; i++) {
        float want = expected[i] / 255.0f;
        if (srgb && i % 4 < 3) want = srgb_to_linear(want);
        double err = fabs(got[i] - want); sum += err; if (err > max) max = err;
    }
    *mean = sum / ((double)w * h * 4); *peak = max;
    free(linear); free(expected);
}

static size_t cache_files(const char *dir) {
    size_t n = 0; DIR *d = opendir(dir); struct dirent *e;
    while (d && (e = readdir(d))) if (strstr(e->d_name, ".astc") && !strstr(e->d_name, ".astc.")) n++;
    if (d) closedir(d);
    return n;
}
static id<MTLTexture> upload(tex_t *t) {
    mtl_sub_begin(); id<MTLTexture> mt = pkg_upload(t, NULL, nil, 0);
    CHECK(mtl_wait(mtl_sub_commit(), 20000000000ull), "the upload's submission completes");
    return mt;
}

int main(int argc, char **argv) { @autoreleasepool {
    (void)argc; (void)argv;
    char dir[] = "/tmp/t_astc_upload.XXXXXX";
    if (!mkdtemp(dir)) { perror("mkdtemp"); return 1; }
    setenv("DM_TEST_NO_BC", "1", 1); const char *which = getenv("T_ASTC_BLOCK"); int six = which && atoi(which) == 6; setenv("DM_NVN_BC_ASTC", six ? "6" : "4", 1); setenv("DM_NVN_ASTC_CACHE", dir, 1); unsetenv("DM_NVN_ASTC_CACHE_RO");
    mtl_init();
    CHECK(astc_block() == (six ? 6u : 4u), "DM_NVN_BC_ASTC is on (with DM_TEST_NO_BC)");
    double slack = six ? 6.0 : 1.0;   // 6x6 holds 3.56 bits a texel against 8 for 4x4, and the fixture is noise at every 4x4 block: the bounds only catch a wrong layout (a run with T_ASTC_BLOCK=6)

    struct { uint32_t format; MTLPixelFormat expect; double mean_max; const char *name; } cases[] = {
        {0x42, MTLPixelFormatASTC_4x4_LDR, 0.02, "BC1"}, {0x46, MTLPixelFormatASTC_4x4_sRGB, 0.02, "BC1 sRGB"}, {0x43, MTLPixelFormatASTC_4x4_LDR, 0.04, "BC2"},
        {0x44, MTLPixelFormatASTC_4x4_LDR, 0.04, "BC3"}, {0x4d, MTLPixelFormatASTC_4x4_LDR, 0.04, "BC7"}, {0x4e, MTLPixelFormatASTC_4x4_sRGB, 0.04, "BC7 sRGB"},
    };
    for (size_t c = 0; c < sizeof cases / sizeof *cases; c++) {
        void *memory; nvn_texdesc d = {.target = NVN_TEXTURE_TARGET_2D, .format = cases[c].format, .width = 37, .height = 21, .depth = 1, .levels = 4, .samples = 1};
        tex_t t = fixture(d, &memory);
        id<MTLTexture> mt = upload(&t);
        MTLPixelFormat want_pf = cases[c].expect; if (six) want_pf = want_pf == MTLPixelFormatASTC_4x4_sRGB ? MTLPixelFormatASTC_6x6_sRGB : MTLPixelFormatASTC_6x6_LDR;
        CHECK(mt && mt.pixelFormat == want_pf, cases[c].name);
        CHECK(mt && mt.width == 37 && mt.height == 21 && mt.mipmapLevelCount == 4, "size and levels are the NVN texture's");
        for (unsigned level = 0; mt && level < 4; level++) {
            double mean, peak; compare_level(mt, &t, d, level, 0, &mean, &peak);
            printf("%-8s level %u: mean error %.4f, max %.4f\n", cases[c].name, level, mean, peak);
            CHECK(mean < cases[c].mean_max * slack, "ASTC samples close to the BC decode");
        }
        defer_obj_release(mt); release_fixture(memory);
    }
    size_t files = cache_files(dir);
    CHECK(files > 0, "uploads wrote cache entries");
    printf("cache entries after the first uploads: %zu\n", files);

    // The same textures again: all hits, nothing new in the cache directory. Then from the read-only directory alone (the prebuilt flow: the writable one is gone)
    {
        void *memory; nvn_texdesc d = {.target = NVN_TEXTURE_TARGET_2D, .format = 0x44, .width = 37, .height = 21, .depth = 1, .levels = 4, .samples = 1};
        tex_t t = fixture(d, &memory);
        id<MTLTexture> mt = upload(&t);
        CHECK(cache_files(dir) == files, "a repeated upload adds no cache entry");
        double mean, peak; compare_level(mt, &t, d, 0, 0, &mean, &peak); CHECK(mean < 0.04 * slack, "and samples the same");
        defer_obj_release(mt); release_fixture(memory);
    }

    // BC4 / BC5 stay decoded (R8 / RG8), a 3D BC texture too; a 2D array is ASTC per layer
    {
        void *memory; nvn_texdesc d = {.target = NVN_TEXTURE_TARGET_2D, .format = 0x49, .width = 16, .height = 16, .depth = 1, .levels = 1, .samples = 1};
        tex_t t = fixture(d, &memory); id<MTLTexture> mt = upload(&t);
        CHECK(mt && mt.pixelFormat == MTLPixelFormatR8Unorm, "BC4 stays R8"); defer_obj_release(mt); release_fixture(memory);
        d.format = 0x4b; t = fixture(d, &memory); mt = upload(&t);
        CHECK(mt && mt.pixelFormat == MTLPixelFormatRG8Unorm, "BC5 stays RG8"); defer_obj_release(mt); release_fixture(memory);
        d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_3D, .format = 0x44, .width = 8, .height = 8, .depth = 4, .levels = 1, .samples = 1};
        t = fixture(d, &memory); mt = upload(&t);
        CHECK(mt && mt.pixelFormat == MTLPixelFormatRGBA8Unorm && mt.textureType == MTLTextureType3D, "3D BC3 stays RGBA8"); defer_obj_release(mt); release_fixture(memory);
        d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D_ARRAY, .format = 0x44, .width = 16, .height = 16, .depth = 3, .levels = 2, .samples = 1};
        t = fixture(d, &memory); mt = upload(&t);
        CHECK(mt && mt.pixelFormat == (six ? MTLPixelFormatASTC_6x6_LDR : MTLPixelFormatASTC_4x4_LDR) && mt.arrayLength == 3, "a 2D array is ASTC");
        for (unsigned layer = 0; mt && layer < 3; layer++) { double mean, peak; compare_level(mt, &t, d, 1, layer, &mean, &peak); CHECK(mean < 0.04 * slack, "every layer samples like its BC decode"); }
        defer_obj_release(mt); release_fixture(memory);
    }
    // A buffer-to-texture copy of BC blocks into the ASTC texture (copy_b2t): a block-aligned region away from the origin lands there, the rest of the texture is untouched
    if (!six) {
        enum { SW = 32, RW = 16, RH = 12, OX = 8, OY = 4 };
        void *tmem; nvn_texdesc d = {.target = NVN_TEXTURE_TARGET_2D, .format = 0x44, .width = SW, .height = SW, .depth = 1, .levels = 1, .samples = 1};
        tex_t t = {.magic = MAGIC('T','E','X',0), .serial = nvn_new_serial(), .d = d}; nvn_tex_layout(&d, &t.L);
        if (posix_memalign(&tmem, getpagesize(), (t.L.size + 16383) & ~(size_t)16383)) abort();
        memset(tmem, 0, t.L.size); t.mem = tmem; mtl_pool_add(tmem, (t.L.size + 16383) & ~(size_t)16383);
        void *smem; size_t sbytes = 16384; if (posix_memalign(&smem, getpagesize(), sbytes)) abort(); mtl_pool_add(smem, sbytes);
        size_t row = RW / 4 * 16, rows = RH / 4; fill_blocks(smem, row * rows, 0x44, 99);
        mtl_tex_init(&t); mtl_sub_begin(); id<MTLTexture> mt = tex_mtl(&t);
        CHECK(mtl_wait(mtl_sub_commit(), 20000000000ull), "the new texture's zero fill completes");
        CHECK(mt && mt.pixelFormat == MTLPixelFormatASTC_4x4_LDR, "a texture made for copies is ASTC");
        p_copy_b2t c = {.src = (uint64_t)(uintptr_t)smem, .tex = &t, .r = {OX, OY, 0, RW, RH, 1}};
        mtl_sub_begin(); copy_b2t(&c, sizeof c); CHECK(mtl_wait(mtl_sub_commit(), 20000000000ull), "the copy's submission completes");
        uint8_t *expected = malloc((size_t)RW * RH * 4);
        CHECK(!nvn_bc_decode(0x44, smem, row, RW, RH, expected, (size_t)RW * 4), "CPU decode of the copy source");
        id<MTLBuffer> out = [g_dev newBufferWithLength:(size_t)SW * SW * 16 options:MTLResourceStorageModeShared];
        uint32_t sel[2] = {0, 0};
        id<MTLCommandBuffer> cb = [g_q commandBuffer]; id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
        [e setComputePipelineState:sampler_pipeline(0)]; [e setTexture:mt atIndex:0]; [e setBuffer:out offset:0 atIndex:0]; [e setBytes:sel length:sizeof sel atIndex:1];
        [e dispatchThreads:MTLSizeMake(SW, SW, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)]; [e endEncoding]; [cb commit]; [cb waitUntilCompleted];
        const float *got = out.contents; double inside = 0, outside = 0;
        for (unsigned y = 0; y < SW; y++) for (unsigned x = 0; x < SW; x++) for (unsigned ch = 0; ch < 4; ch++) {
            int in = x >= OX && x < OX + RW && y >= OY && y < OY + RH;
            double want = in ? expected[((y - OY) * RW + (x - OX)) * 4 + ch] / 255.0 : (ch == 3 ? 0.0 : 0.0);   // outside: the zero BC3 blocks decode to transparent black
            double err = fabs(got[((size_t)y * SW + x) * 4 + ch] - want);
            if (in) inside += err; else outside += err;
        }
        inside /= RW * RH * 4; outside /= (SW * SW - RW * RH) * 4.0;
        printf("copy_b2t into ASTC: mean error inside %.4f, outside %.4f\n", inside, outside);
        CHECK(inside < 0.04, "the copied region samples like its BC decode"); CHECK(outside < 0.001, "the rest of the texture is untouched");
        free(expected); defer_obj_release(mt); release_fixture(smem); release_fixture(tmem);
        // 6x6 would need grid-aligned regions; 4x4 has none to refuse
    }
    mtl_drain();
    { char cmd[128]; snprintf(cmd, sizeof cmd, "rm -rf %s", dir); system(cmd); }
    printf("ASTC upload: %d checks, %d failures\n", checks, failed);
    return failed ? 1 : 0;
} }
