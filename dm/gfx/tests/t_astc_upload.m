// DM_NVN_BC_ASTC (nvn_mtl.m, dm/gfx/tex/nvn_astc_cache.m): on a GPU stored without BC, BC1/2/3/7 2D textures are uploaded as ASTC 4x4 / 6x6 LDR. Runs on the Mac GPU with DM_TEST_NO_BC=1:
// the texture's Metal format and size, what a shader samples against the CPU decode of the same blocks, the content-addressed cache (a second upload is all hits, from the cache directory alone),
// BC4/BC5 and 3D staying decoded, and ASTC off (unset) leaving every BC format as it was.
// Fixture and swizzling follow nxnative-tvos' t_bc_upload.m (MIT, yuchanns).
#include "../nvn/nvn_mtl.m"
#include "../../host/tests/romfs_sparse_fixture.h"
#include <math.h>
#include <dirent.h>
#include <sys/stat.h>
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, ...) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: "); fprintf(stderr, __VA_ARGS__); fprintf(stderr, " (line %d)\n", __LINE__); } } while (0)

// The ASTC block each format is stored at (DM_NVN_BC_ASTC for BC2/3/7, DM_NVN_BC1_ASTC for BC1): T_ASTC_BLOCK and T_ASTC_BC1_BLOCK
static unsigned g_blk = 4, g_bc1_blk = 4;
static int is_bc1(uint32_t f) { return f == 0x41 || f == 0x42 || f == 0x45 || f == 0x46; }
static int is_srgb_fmt(uint32_t f) { return f == 0x45 || f == 0x46 || f == 0x47 || f == 0x48 || f == 0x4e; }
static unsigned blk_for(uint32_t f) { return is_bc1(f) ? g_bc1_blk : g_blk; }
static MTLPixelFormat astc_pf_of(unsigned blk, int srgb) {
    return blk == 4 ? (srgb ? MTLPixelFormatASTC_4x4_sRGB : MTLPixelFormatASTC_4x4_LDR) : blk == 5 ? (srgb ? MTLPixelFormatASTC_5x5_sRGB : MTLPixelFormatASTC_5x5_LDR) : (srgb ? MTLPixelFormatASTC_6x6_sRGB : MTLPixelFormatASTC_6x6_LDR);
}
static double slack_of(unsigned blk) { return blk == 6 ? 6.0 : blk == 5 ? 4.0 : 1.0; }   // a bigger block holds fewer bits a texel and the fixture is noise at every 4x4 block: the bounds only catch a wrong layout
static unsigned g_seed_base;   // added to every fixture seed: another set of bytes for the same texture
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
static void fill_storage(tex_t *tp, nvn_texdesc desc) {
    tex_t texture = *tp;
    for (unsigned level = 0; level < desc.levels; level++) {
        uint32_t row, rows, depth, bpb; uint64_t base; unsigned th, td;
        if (nvn_deswizzle_geom(&desc, level, 0, &row, &rows, &depth, &base, &th, &td, &bpb)) abort();
        size_t size = (size_t)row * rows * depth; uint8_t *linear = malloc(size);
        for (unsigned layer = 0; layer < texture.L.layers; layer++) {
            fill_blocks(linear, size, desc.format, level + layer * 17 + g_seed_base);
            if (nvn_swizzle(&desc, level, layer, linear, row, texture.mem)) abort();
        }
        free(linear);
    }
}
static tex_t fixture(nvn_texdesc desc, void **allocation) {
    tex_t texture = {0}; texture.d = desc; nvn_tex_layout(&desc, &texture.L);
    size_t page = getpagesize(), bytes = (texture.L.size + page - 1) & ~(page - 1);
    if (posix_memalign(allocation, page, bytes)) abort();
    memset(*allocation, 0, bytes); mtl_pool_add(*allocation, bytes);
    texture.mem = *allocation; texture.serial = nvn_new_serial(); texture.has_layout = 1; texture.magic = MAGIC('T', 'E', 'X', 0);
    fill_storage(&texture, desc);
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
static void compare_level_sk(id<MTLTexture> mt, tex_t *texture, nvn_texdesc d, unsigned level, unsigned layer, double *mean, double *peak, unsigned skip) {   // level: the NVN level; the Metal texture starts at NVN level `skip`
    uint32_t row, rows, depth, bpb; uint64_t base; unsigned th, td;
    nvn_deswizzle_geom(&d, level, 0, &row, &rows, &depth, &base, &th, &td, &bpb);
    uint32_t w = MAX(d.width >> level, 1u), h = MAX(d.height >> level, 1u);
    uint8_t *linear = malloc((size_t)row * rows);
    fill_blocks(linear, (size_t)row * rows, d.format, level + layer * 17 + g_seed_base);
    uint32_t upf; int ubpp; nvn_bc_unpacked(d.format, &upf, &ubpp);
    uint8_t *expected = malloc((size_t)w * h * 4);
    CHECK(!nvn_bc_decode(d.format, linear, row, w, h, expected, (size_t)w * 4), "CPU decode of the fixture");
    id<MTLBuffer> out = [g_dev newBufferWithLength:(size_t)w * h * 16 options:MTLResourceStorageModeShared];
    uint32_t sel[2] = {level - skip, layer};
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

#define compare_level(mt, texture, d, level, layer, mean, peak) compare_level_sk(mt, texture, d, level, layer, mean, peak, 0)

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


// ---- DM_NVN_ASTC_MISS=background (T_ASTC_MODE=background): a miss uploads decoded and is encoded off the calling thread; the next texture of the same bytes is ASTC ----
static void configure(const char *rw, size_t queue_cap, uint64_t cache_max, uint64_t min_free, unsigned threads) {
    nvn_astc_bg_config c = {.cache = rw, .readonly = NULL, .queue_cap = queue_cap, .cache_max = cache_max, .min_free = min_free, .threads = threads};
    nvn_bc_astc_bg_configure(&c);
}
static nvn_astc_bg_stats stats(void) { nvn_astc_bg_stats s; nvn_bc_astc_bg_stats(&s); return s; }
static void subdir(char *out, size_t n, const char *dir, const char *name) { snprintf(out, n, "%s/%s", dir, name); mkdir(out, 0755); }
// A pack (the layout of nvn_astc_cache.m, what bntx_astc.py writes) of the entries in a cache directory
static void pack_dir(const char *dir, const char *pack_path) {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSString *f in [NSFileManager.defaultManager contentsOfDirectoryAtPath:@(dir) error:NULL]) if (f.length == 69 && [f hasSuffix:@".astc"]) [names addObject:f];
    [names sortUsingSelector:@selector(compare:)];
    NSMutableData *file = [NSMutableData dataWithLength:80], *index = [NSMutableData data];
    for (NSString *f in names) {
        NSData *e = [NSData dataWithContentsOfFile:[@(dir) stringByAppendingPathComponent:f]];
        uint8_t key[32]; for (int i = 0; i < 32; i++) { unsigned v; sscanf([f substringWithRange:NSMakeRange(2 * i, 2)].UTF8String, "%2x", &v); key[i] = (uint8_t)v; }
        uint64_t off = file.length, len = e.length; [file appendData:e]; [file increaseLengthBy:-file.length & 15];
        [index appendBytes:key length:32]; [index appendBytes:&off length:8]; [index appendBytes:&len length:8];
    }
    uint64_t ioff = file.length, count = names.count; [file appendData:index]; uint64_t total = file.length; uint32_t one = 1, esz = 48;
    uint8_t *b = file.mutableBytes; memcpy(b, "NXASTCPK", 8); memcpy(b + 8, &one, 4); memcpy(b + 12, &esz, 4); memcpy(b + 16, &count, 8); memcpy(b + 24, &ioff, 8); memcpy(b + 32, &total, 8);
    [file writeToFile:@(pack_path) atomically:NO];
}
// DM_BC_MAX_DIM=64 with ASTC (T_ASTC_MODE=maxdim): the finest levels left out are neither requested from the cache nor stored, and the Metal texture made for the kept ones is ASTC of the right size
static void run_maxdim(const char *dir) {
    char rw[512]; subdir(rw, sizeof rw, dir, "rw");
    configure(rw, 64u << 20, 1ull << 30, 0, 2);
    nvn_texdesc d = {.target = NVN_TEXTURE_TARGET_2D, .format = 0x4d, .width = 256, .height = 128, .depth = 1, .levels = 6, .samples = 1};   // 256x128 .. 8x4; the cap of 64 keeps NVN levels 2..5
    void *m1, *m2; tex_t t1 = fixture(d, &m1);
    unsigned sk = bc_skip(&t1);
    CHECK(sk == 2, "DM_BC_MAX_DIM=64 leaves out the two finest levels of a 256x128 texture");
    CHECK(nvn_bc_skip_levels(&d, 64) == 2 && nvn_bc_skip_levels(&d, 0) == 0 && nvn_bc_skip_levels(&d, 4) == 5, "nvn_bc_skip_levels: cap 64 -> 2, no cap -> 0, a cap nothing fits keeps the last level");
    nvn_texdesc one = d; one.levels = 1; CHECK(nvn_bc_skip_levels(&one, 64) == 0, "a texture without a mip chain keeps its only level");
    nvn_texdesc cube = d; cube.target = NVN_TEXTURE_TARGET_3D; CHECK(nvn_bc_skip_levels(&cube, 64) == 0, "a 3D texture is not cut");
    id<MTLTexture> mt1 = upload(&t1);
    CHECK(mt1 && mt1.pixelFormat == MTLPixelFormatRGBA8Unorm && mt1.width == 64 && mt1.height == 32 && mt1.mipmapLevelCount == 4, "a miss: decoded, 64x32 with four levels");
    CHECK(nvn_bc_astc_bg_wait(120), "the queue drains");
    nvn_astc_bg_stats s = stats();
    CHECK(s.misses == 4 && s.queued == 4 && cache_files(rw) == 4, "the runtime looked up and queued only the four kept planes, not six");
    tex_t t2 = fixture(d, &m2);
    id<MTLTexture> mt2 = upload(&t2);
    CHECK(mt2 && mt2.pixelFormat == MTLPixelFormatASTC_4x4_LDR && mt2.width == 64 && mt2.height == 32 && mt2.mipmapLevelCount == 4, "the texture made when all kept planes are cached is ASTC 64x32 with four levels");
    CHECK(mt2 && mt2.textureType == MTLTextureType2D, "and 2D");
    for (unsigned l = sk; mt2 && l < d.levels; l++) { double mean, peak; compare_level_sk(mt2, &t2, d, l, 0, &mean, &peak, sk); printf("maxdim ASTC NVN level %u: mean error %.4f\n", l, mean); CHECK(mean < 0.04, "ASTC level samples like the BC decode of the NVN level it came from"); }
    defer_obj_release(mt1); defer_obj_release(mt2); release_fixture(m1); release_fixture(m2);
}
// ---- Tagged planes (T_ASTC_MODE=tagged; docs/texture_once.md sections 2 and 3): a stripped plane is the first 8 bytes of its pack key and zeros. The pack is embedded in a DMSPARS1 image ----
typedef struct { uint8_t key[8][32]; unsigned n; } tag_keys;
static int tag_collect(void *ctx, unsigned level, unsigned layer, uint32_t w, uint32_t h, const void *bc, size_t size) {
    (void)layer; tag_keys *k = ctx; nvn_astc_cache_key key; nvn_bc_astc_plane_key(0x4d, w, h, 4, bc, size, &key);
    for (int i = 0; i < 32; i++) { unsigned v; sscanf(key.hex + 2 * i, "%2x", &v); k->key[level][i] = (uint8_t)v; }
    k->n = level + 1; return 0;
}
static void strip_plane(tex_t *t, unsigned level, const uint8_t *prefix8) {   // docs/texture_once.md section 2: the plane's stored bytes become the prefix and zeros
    uint64_t off, len; CHECK(!nvn_astc_plane_storage(&t->d, level, 0, &off, &len) && off + len <= t->L.size && len >= 16, "plane storage of level %u", level);
    memset((uint8_t *)t->mem + off, 0, len); memcpy((uint8_t *)t->mem + off, prefix8, 8);
}
static float *read_level(id<MTLTexture> mt, unsigned level, uint32_t w, uint32_t h) {
    id<MTLBuffer> out = [g_dev newBufferWithLength:(size_t)w * h * 16 options:MTLResourceStorageModeShared]; uint32_t sel[2] = {level, 0};
    id<MTLCommandBuffer> cb = [g_q commandBuffer]; id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
    [e setComputePipelineState:sampler_pipeline(0)]; [e setTexture:mt atIndex:0]; [e setBuffer:out offset:0 atIndex:0]; [e setBytes:sel length:sizeof sel atIndex:1];
    [e dispatchThreads:MTLSizeMake(w, h, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)]; [e endEncoding]; [cb commit]; [cb waitUntilCompleted];
    float *r = malloc((size_t)w * h * 16); memcpy(r, out.contents, (size_t)w * h * 16); return r;
}
static double mean_err_vs_decode(id<MTLTexture> mt, unsigned level, uint32_t format, const uint8_t *tight, size_t pitch, uint32_t w, uint32_t h) {
    uint8_t *want = malloc((size_t)w * h * 4); CHECK(!nvn_bc_decode(format, tight, pitch, w, h, want, (size_t)w * 4), "CPU decode");
    float *got = read_level(mt, level, w, h); double sum = 0; for (size_t i = 0; i < (size_t)w * h * 4; i++) sum += fabs(got[i] - want[i] / 255.0);
    free(got); free(want); return sum / ((double)w * h * 4);
}
static void tag_counts(uint64_t *hit, uint64_t *unres, uint64_t *dec) { nvn_bc_astc_tag_stats(hit, unres, dec); }
static tex_t empty_texture(nvn_texdesc d, void **mem, unsigned serial_off) {
    tex_t t = {.magic = MAGIC('T','E','X',0), .serial = nvn_new_serial(), .d = d}; nvn_tex_layout(&d, &t.L);
    if (posix_memalign(mem, getpagesize(), (t.L.size + 16383) & ~(size_t)16383)) abort();
    memset(*mem, 0, t.L.size); t.mem = *mem; t.off = 0x10000u * serial_off; mtl_pool_add(*mem, (t.L.size + 16383) & ~(size_t)16383);
    return t;
}
// nvn_astc_plane_storage: the bytes a plane's data lands in lie inside [offset, offset + length), planes do not overlap, and the walker's raw hook handles / passes / stops as documented
typedef struct { unsigned raw_calls, fn_calls, handle_every, stop_at; } walk_probe;
static int walk_raw(void *ctx, unsigned level, unsigned layer, uint32_t w, uint32_t h, const void *st, size_t len) {
    (void)level; (void)layer; (void)w; (void)h; (void)st; (void)len; walk_probe *p = ctx; unsigned n = p->raw_calls++;
    if (p->stop_at && n + 1 == p->stop_at) return -7;
    return p->handle_every && n % p->handle_every == 0;
}
static int walk_fn(void *ctx, unsigned level, unsigned layer, uint32_t w, uint32_t h, const void *bc, size_t size) { (void)level; (void)layer; (void)w; (void)h; (void)bc; (void)size; ((walk_probe *)ctx)->fn_calls++; return 0; }
static void check_plane_storage(nvn_texdesc d, const char *name) {
    nvn_texlayout L; nvn_tex_layout(&d, &L); uint8_t *mem = calloc(1, L.size + 64);
    unsigned levels = d.levels ? d.levels : 1, layers = nvn_astc_layers(&d); uint64_t prev_end = 0; int ok = 1;
    for (unsigned y = 0; y < layers; y++) for (unsigned l = 0; l < levels; l++) {
        uint32_t row, rows, slices, bpb; uint64_t base; unsigned th, td; if (nvn_deswizzle_geom(&d, l, y, &row, &rows, &slices, &base, &th, &td, &bpb)) abort();
        uint8_t *lin = malloc((size_t)row * rows); memset(lin, 0xFF, (size_t)row * rows); if (nvn_swizzle(&d, l, y, lin, row, mem)) abort(); free(lin);
        uint64_t off, len; if (nvn_astc_plane_storage(&d, l, y, &off, &len)) abort();
        uint64_t first = UINT64_MAX, last = 0, count = 0; for (uint64_t i = 0; i < L.size; i++) if (mem[i]) { if (first == UINT64_MAX) first = i; last = i; count++; mem[i] = 0; }
        if (count != (uint64_t)row * rows || first < off || last >= off + len || off + len > L.size || off < prev_end * 0) ok = 0;
        if (y == 0 && l && off < prev_end) ok = 0;   // within a layer, levels follow each other
        if (y == 0) prev_end = off + len;
    }
    CHECK(ok, "plane storage of %s: written bytes inside [offset, offset + length), levels in order", name);
    walk_probe p = {0, 0, 0, 0}; int r = nvn_astc_walk_planes_raw(&d, mem, 0, walk_raw, walk_fn, &p);
    CHECK(r == 0 && p.raw_calls == levels * layers && p.fn_calls == levels * layers, "%s: raw returning 0 goes on to every plane", name);
    p = (walk_probe){0, 0, 1, 0}; r = nvn_astc_walk_planes_raw(&d, mem, 0, walk_raw, walk_fn, &p);
    CHECK(r == 0 && p.raw_calls == levels * layers && p.fn_calls == 0, "%s: raw returning 1 handles the plane", name);
    p = (walk_probe){0, 0, 0, 2}; r = nvn_astc_walk_planes_raw(&d, mem, 0, walk_raw, walk_fn, &p);
    CHECK(levels * layers < 2 || (r == -7 && p.raw_calls == 2 && p.fn_calls == 1), "%s: raw returning < 0 stops the walk with that value", name);
    p = (walk_probe){0, 0, 0, 0}; r = nvn_astc_walk_planes(&d, mem, levels > 1 ? 1 : 0, walk_fn, &p); CHECK(r == 0 && p.fn_calls == (levels > 1 ? levels - 1 : levels) * layers, "%s: the plain walk is unchanged", name);
    free(mem);
}
static void run_tagged(const char *dir) {
    const unsigned blk = 4;
    check_plane_storage((nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = 0x4d, .width = 64, .height = 64, .depth = 1, .levels = 4, .samples = 1}, "BC7 64x64 x4");
    check_plane_storage((nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = 0x44, .width = 37, .height = 21, .depth = 1, .levels = 6, .samples = 1}, "BC3 37x21 x6");
    check_plane_storage((nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = 0x42, .width = 1024, .height = 512, .depth = 1, .levels = 11, .samples = 1}, "BC1 1024x512 x11");
    check_plane_storage((nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D_ARRAY, .format = 0x44, .width = 128, .height = 128, .depth = 3, .levels = 4, .samples = 1}, "BC3 array of 3");
    check_plane_storage((nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = 0x4d, .width = 4, .height = 4, .depth = 1, .levels = 1, .samples = 1}, "BC7 4x4");
    // the refusal rule for a stripped image
    CHECK(!stripped_refusal(0, 0, 0) && !stripped_refusal(0, 1, 4) && stripped_refusal(1, 0, 4) && strstr(stripped_refusal(1, 0, 4), "native BC") && stripped_refusal(1, 1, 0) && strstr(stripped_refusal(1, 1, 0), "DM_NVN_BC_ASTC") && !stripped_refusal(1, 1, 4), "stripped_refusal: native BC and ASTC off refuse, the ASTC path on a BC-less GPU accepts");
    // 1. seed the writable directory with every plane the scenarios below need, by the hashed path, then pack it
    char rw[512]; subdir(rw, sizeof rw, dir, "rw"); configure(rw, 64u << 20, 1ull << 30, 0, 2);
    nvn_texdesc d = {.target = NVN_TEXTURE_TARGET_2D, .format = 0x4d, .width = 64, .height = 64, .depth = 1, .levels = 4, .samples = 1};
    void *m1; tex_t t1 = fixture(d, &m1);
    tag_keys keys = {{{0}}, 0}; CHECK(nvn_astc_walk_planes(&t1.d, t1.mem, 0, tag_collect, &keys) == 0 && keys.n == 4, "the four plane keys");
    id<MTLTexture> mt1 = upload(&t1); CHECK(nvn_bc_astc_bg_wait(120), "seed drains"); CHECK(cache_files(rw) == 4, "four entries from the first texture");
    // two 16x16 BC7 textures whose stored bytes look tagged (8 bytes, then zeros) but are genuine content: one with a prefix no entry has, one with the prefix of a bigger entry
    nvn_texdesc d5 = {.target = NVN_TEXTURE_TARGET_2D, .format = 0x4d, .width = 16, .height = 16, .depth = 1, .levels = 1, .samples = 1};
    void *m5[2]; tex_t t5[2]; uint8_t tight[2][256]; size_t pitch5 = 4 * 16;
    for (int v = 0; v < 2; v++) {
        t5[v] = empty_texture(d5, &m5[v], 0); uint8_t head[8]; for (int i = 0; i < 8; i++) head[i] = v ? keys.key[0][i] : (uint8_t)(0xe0 + i);
        memcpy(t5[v].mem, head, 8);   // a BC7 block's first 8 bytes in an otherwise empty plane
        CHECK(!nvn_deswizzle(&d5, 0, 0, t5[v].mem, tight[v], pitch5) && nvn_bc_astc_looks_tagged(t5[v].mem, 512), "the genuine plane looks tagged");
        uint8_t out[256]; int hit; CHECK(!nvn_bc_astc_encode(0x4d, tight[v], 256, 16, 16, blk, out, 256, rw, NULL, &hit), "encode the genuine plane into the writable directory");
    }
    // a copy source: one BC3 plane, cached
    enum { N = 16 }; size_t crow = N / 4 * 16, crows = N / 4;
    void *smem; if (posix_memalign(&smem, getpagesize(), 16384)) abort(); mtl_pool_add(smem, 16384); fill_blocks(smem, crow * crows, 0x44, 321);
    nvn_astc_cache_key ck; CHECK(nvn_bc_astc_learn(0x44, smem, crow * crows, N, N, blk, &ck) == 0, "the copy plane is queued"); CHECK(nvn_bc_astc_bg_wait(120), "and encoded");
    uint8_t ckey[32]; for (int i = 0; i < 32; i++) { unsigned v; sscanf(ck.hex + 2 * i, "%2x", &v); ckey[i] = (uint8_t)v; }
    char pk[600]; snprintf(pk, sizeof pk, "%s/seed.pack", dir); pack_dir(rw, pk);
    // 2. the pack goes into a DMSPARS1 image (logical image: bytes with holes), which DM_ROMFS would name: the embedded pack becomes the read-only cache
    NSData *pkd = [NSData dataWithContentsOfFile:@(pk)]; uint8_t logical[20000]; for (int i = 0; i < 20000; i++) logical[i] = (uint8_t)(i * 31 + 1);
    memset(logical + 3000, 0, 9000);
    uint8_t *wrapped; size_t wn; CHECK(fx_write_sparse(NULL, logical, sizeof logical, 4096, 0, pkd.bytes, pkd.length, &wrapped, &wn) >= 2, "the image");
    char img[600]; snprintf(img, sizeof img, "%s/romfs.img", dir); { FILE *f = fopen(img, "wb"); fwrite(wrapped, 1, wn, f); fclose(f); } free(wrapped);
    char plain[600]; snprintf(plain, sizeof plain, "%s/plain.img", dir); { FILE *f = fopen(plain, "wb"); fwrite(logical, 1, sizeof logical, f); fclose(f); }
    CHECK(embedded_pack_setup(plain) == 0 && !g_embedded, "a plain file is not a stripped image");
    setenv("DM_NVN_ASTC_CACHE_RO", "/nonexistent-ro", 1);
    CHECK(embedded_pack_setup(img) == 1 && g_embedded, "a DMSPARS1 with a pack is a stripped image");
    CHECK(!strcmp(getenv("DM_NVN_ASTC_CACHE_RO"), NVN_ASTC_EMBEDDED_ROOT), "its pack takes precedence over DM_NVN_ASTC_CACHE_RO");
    uint64_t entries, bytes; CHECK(nvn_bc_astc_pack_info(NVN_ASTC_EMBEDDED_ROOT, &entries, &bytes, NULL) && entries == 7 && bytes == pkd.length, "seven entries (4 + 2 genuine + 1 copy)");
    char rw2[512]; subdir(rw2, sizeof rw2, dir, "rw2");
    nvn_astc_bg_config c = {.cache = rw2, .readonly = NVN_ASTC_EMBEDDED_ROOT, .queue_cap = 64u << 20, .cache_max = 1ull << 30, .min_free = 0, .threads = 1};
    nvn_bc_astc_bg_configure(&c);
    // 3. the hashed path from the embedded pack (a texture with the original bytes), and the tagged one: the same ASTC blocks
    void *m3; tex_t t3 = fixture(d, &m3); id<MTLTexture> mt3 = upload(&t3);
    CHECK(mt3 && mt3.pixelFormat == MTLPixelFormatASTC_4x4_LDR, "the hashed path resolves from the embedded pack");
    float *ref[4]; for (unsigned l = 0; l < 4; l++) ref[l] = read_level(mt3, l, 64 >> l, 64 >> l);
    nvn_astc_bg_stats before = stats(); uint64_t h0, u0, d0; tag_counts(&h0, &u0, &d0);
    void *m2; tex_t t2 = fixture(d, &m2); for (unsigned l = 0; l < 4; l++) strip_plane(&t2, l, keys.key[l]);
    CHECK(nvn_bc_astc_looks_tagged(t2.mem, 16) && !memcmp(t2.mem, keys.key[0], 8), "level 0 of the stripped texture is the tag");
    id<MTLTexture> mt2 = upload(&t2);
    CHECK(mt2 && mt2.pixelFormat == MTLPixelFormatASTC_4x4_LDR && mt2.mipmapLevelCount == 4, "a stripped texture is ASTC");
    uint64_t h1, u1, d1; tag_counts(&h1, &u1, &d1); nvn_astc_bg_stats after = stats();
    CHECK(h1 - h0 == 4 && u1 == u0 && d1 == d0, "four tagged hits, nothing unresolved or decoded (%llu / %llu / %llu)", (unsigned long long)(h1 - h0), (unsigned long long)(u1 - u0), (unsigned long long)(d1 - d0));
    CHECK(after.hits == before.hits && after.misses == before.misses && after.fetch_misses == before.fetch_misses && after.queued == before.queued, "no hashed lookup was made for a tagged plane");
    for (unsigned l = 0; l < 4; l++) { float *got = read_level(mt2, l, 64 >> l, 64 >> l); CHECK(!memcmp(got, ref[l], (size_t)(64 >> l) * (64 >> l) * 16), "level %u: the tagged plane is the same ASTC blocks as the hashed path's", l); free(got); }
    for (unsigned l = 0; l < 4; l++) { double mean, peak; compare_level(mt2, &t2, d, l, 0, &mean, &peak); CHECK(mean < 0.04, "level %u of the stripped texture samples like the original BC decode (%.4f)", l, mean); }
    // 4. planes that merely look tagged resolve by hash, with no red line or count
    for (int v = 0; v < 2; v++) {
        tag_counts(&h0, &u0, &d0); before = stats();
        id<MTLTexture> mt = upload(&t5[v]);
        CHECK(mt && mt.pixelFormat == MTLPixelFormatASTC_4x4_LDR, "a genuine plane that looks tagged (%s) is ASTC through the hash", v ? "its prefix names a bigger entry" : "unknown prefix");
        tag_counts(&h1, &u1, &d1); after = stats();
        CHECK(h1 == h0 && u1 == u0 && d1 == d0, "and counts nothing as tagged");
        CHECK(after.hits >= before.hits + 1 && after.misses == before.misses, "it was found by the hash");
        CHECK(mt && mean_err_vs_decode(mt, 0, 0x4d, tight[v], pitch5, 16, 16) < 0.04, "and samples like its BC decode");
        defer_obj_release(mt);
    }
    // 5. a tag no entry has, and a hash no entry has: the texture is decoded, every plane unresolved (and, decoded from its zeros, counted as decoded), nothing queued, one red line each
    {
        tag_counts(&h0, &u0, &d0); before = stats();
        void *m6; tex_t t6 = fixture(d, &m6); uint8_t junk[8] = {0x5a, 0x5b, 0x5c, 0x5d, 0x5e, 0x5f, 0x60, 0x61};
        for (unsigned l = 0; l < 4; l++) strip_plane(&t6, l, junk);
        id<MTLTexture> mt = upload(&t6);
        CHECK(mt && mt.pixelFormat == MTLPixelFormatRGBA8Unorm, "a stripped texture with no entries is decoded");
        tag_counts(&h1, &u1, &d1); after = stats();
        CHECK(u1 - u0 == 4 && h1 == h0, "four unresolved planes (%llu)", (unsigned long long)(u1 - u0));
        CHECK(d1 - d0 == 4, "four decoded planes (%llu)", (unsigned long long)(d1 - d0));
        CHECK(after.queued == before.queued && after.misses == before.misses, "nothing was queued for the encoder: the bytes are zeros");
        pthread_mutex_lock(&g_astc_mu); astc_dec *e = astc_slot(t6.serial, 0); int flags = e ? e->flags : 0; pthread_mutex_unlock(&g_astc_mu);
        CHECK((flags & 8) && (flags & 16), "each red line is logged once per texture (flags %#x)", flags);
        defer_obj_release(mt); release_fixture(m6);
    }
    // 6. copies: a whole-level stripped source whose entry exists makes the texture ASTC at its first copy and is read by tag; an unknown tag, and a piece of a level, are decoded and counted
    {
        nvn_texdesc cd = {.target = NVN_TEXTURE_TARGET_2D, .format = 0x44, .width = N, .height = N, .depth = 1, .levels = 1, .samples = 1};
        uint8_t *expected = malloc((size_t)N * N * 4); CHECK(!nvn_bc_decode(0x44, smem, crow, N, N, expected, (size_t)N * 4), "CPU decode of the copy source");
        void *src[3], *tm[3]; uint8_t bad[8] = {0x71, 0x72, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78};
        for (int v = 0; v < 3; v++) {   // 0: tag of the cached plane; 1: unknown tag; 2: tag of the cached plane, but a piece of the level is copied
            if (posix_memalign(&src[v], getpagesize(), 16384)) abort(); mtl_pool_add(src[v], 16384); memset(src[v], 0, 16384); memcpy(src[v], v == 1 ? bad : ckey, 8);
            tag_counts(&h0, &u0, &d0); uint64_t part0 = atomic_load(&g_astc_copy_partial);
            void *tmem; tex_t t = empty_texture(cd, &tmem, v + 1); tm[v] = tmem; mtl_tex_init(&t);
            p_copy_b2t cp = {.src = (uint64_t)(uintptr_t)src[v], .tex = &t, .r = {0, 0, 0, v == 2 ? 8 : N, v == 2 ? 8 : N, 1}};
            mtl_sub_begin(); copy_b2t(&cp, sizeof cp); CHECK(mtl_wait(mtl_sub_commit(), 20000000000ull), "the copy completes");
            id<MTLTexture> mt = tex_mtl(&t); tag_counts(&h1, &u1, &d1);
            if (v == 0) {
                CHECK(mt && mt.pixelFormat == MTLPixelFormatASTC_4x4_LDR, "a stripped whole-level copy source makes the texture ASTC");
                CHECK(h1 - h0 == 1 && u1 == u0 && d1 == d0, "one tagged hit (%llu/%llu/%llu)", (unsigned long long)(h1 - h0), (unsigned long long)(u1 - u0), (unsigned long long)(d1 - d0));
                CHECK(mt && mean_err_vs_decode(mt, 0, 0x44, smem, crow, N, N) < 0.04, "and samples like the original plane");
            } else {
                CHECK(mt && mt.pixelFormat == MTLPixelFormatRGBA8Unorm, "an unknown tag, or a piece of a level, leaves the texture decoded");
                CHECK(d1 - d0 == 1, "the decode of the tag's bytes is counted (%llu)", (unsigned long long)(d1 - d0));
                if (v == 1) CHECK(u1 - u0 == 1, "an unknown tag at a whole level is unresolved too"); else CHECK(atomic_load(&g_astc_copy_partial) - part0 == 1 && u1 == u0, "a piece of a level is not an unresolved lookup");
            }
            defer_obj_release(mt);
        }
        for (int v = 0; v < 3; v++) { release_fixture(src[v]); release_fixture(tm[v]); }
        free(expected);
    }
    g_embedded = 0;
    defer_obj_release(mt1); defer_obj_release(mt2); defer_obj_release(mt3);
    release_fixture(m1); release_fixture(m2); release_fixture(m3); release_fixture(smem); for (int v = 0; v < 2; v++) release_fixture(m5[v]);
    for (int i = 0; i < 4; i++) free(ref[i]);
    CHECK(nvn_bc_astc_bg_wait(120), "drains");
}
static void run_background(const char *dir, int six) {
    unsigned blk = six ? 6 : 4;
    MTLPixelFormat astc_pf = six ? MTLPixelFormatASTC_6x6_LDR : MTLPixelFormatASTC_4x4_LDR;
    char rw[512]; subdir(rw, sizeof rw, dir, "rw");
    configure(rw, 64u << 20, 1ull << 30, 0, 2);
    CHECK(!astc_sync(), "background is the mode");
    nvn_texdesc d = {.target = NVN_TEXTURE_TARGET_2D, .format = 0x4d, .width = 64, .height = 64, .depth = 1, .levels = 4, .samples = 1};
    // 1. a miss: the texture is decoded (RGBA8, as without ASTC), exact, and its four planes are queued, encoded, written
    void *m1, *m2; tex_t t1 = fixture(d, &m1);
    id<MTLTexture> mt1 = upload(&t1);
    CHECK(mt1 && mt1.pixelFormat == MTLPixelFormatRGBA8Unorm, "a cache miss uploads the decoded format");
    for (unsigned l = 0; mt1 && l < 4; l++) { double mean, peak; compare_level(mt1, &t1, d, l, 0, &mean, &peak); CHECK(mean < 0.0005, "decoded upload is the BC decode"); }
    CHECK(nvn_bc_astc_bg_wait(120), "the queue drains");
    nvn_astc_bg_stats s = stats();
    printf("after the miss: %llu misses, %llu queued, %llu encoded, %llu written\n", (unsigned long long)s.misses, (unsigned long long)s.queued, (unsigned long long)s.encoded, (unsigned long long)s.written);
    CHECK(s.misses == 4 && s.queued == 4 && s.encoded == 4 && s.written == 4 && s.dropped == 0, "four planes missed, were queued, encoded and written");
    CHECK(cache_files(rw) == 4, "four cache files");
    // the decision is kept: the same texture uploaded again (now every plane is cached) stays decoded
    id<MTLTexture> mt1b = pkg_upload(&t1, NULL, mt1, 0); mtl_drain();
    CHECK(mt1b && mt1b.pixelFormat == MTLPixelFormatRGBA8Unorm, "a decoded texture stays decoded on re-upload, though its planes are cached now");
    // 2. a new texture of the same bytes: every plane hits, ASTC
    tex_t t2 = fixture(d, &m2);
    id<MTLTexture> mt2 = upload(&t2);
    CHECK(mt2 && mt2.pixelFormat == astc_pf, "a texture whose planes are all cached is ASTC");
    for (unsigned l = 0; mt2 && l < 4; l++) { double mean, peak; compare_level(mt2, &t2, d, l, 0, &mean, &peak); CHECK(mean < 0.04 * (six ? 6.0 : 1.0), "ASTC samples close to the BC decode"); }
    s = stats(); CHECK(s.hits >= 4 && s.fetch_misses == 0, "the ASTC upload was four cache hits");
    // 3. an ASTC texture stays ASTC when its storage gets other bytes: the planes without an entry are void blocks, queued, never encoded on this thread
    g_seed_base = 1000; fill_storage(&t2, d);
    double before = s.encode_ns; (void)before;
    id<MTLTexture> mt2b = pkg_upload(&t2, NULL, mt2, 0); mtl_drain();
    CHECK(mt2b && mt2b.pixelFormat == astc_pf, "an ASTC texture stays ASTC when its content changes to uncached bytes");
    s = stats(); CHECK(s.fetch_misses == 4 && s.queued == 8, "its four new planes were queued");
    CHECK(nvn_bc_astc_bg_wait(120), "and drain");
    id<MTLTexture> mt2c = pkg_upload(&t2, NULL, mt2b, 0); mtl_drain();
    CHECK(mt2c && mt2c.pixelFormat == astc_pf, "still ASTC");
    for (unsigned l = 0; mt2c && l < 4; l++) { double mean, peak; compare_level(mt2c, &t2, d, l, 0, &mean, &peak); CHECK(mean < 0.04 * (six ? 6.0 : 1.0), "after the background encode the next upload shows the new bytes"); }
    g_seed_base = 0;
    defer_obj_release(mt1); defer_obj_release(mt2); release_fixture(m1); release_fixture(m2);

    // 4. buffer-to-texture copies follow the texture's own format. A texture made for copies has no bytes yet: decoded
    if (!six) {
        enum { SW = 32, RW = 16, RH = 12, OX = 8, OY = 4 };
        nvn_texdesc cd = {.target = NVN_TEXTURE_TARGET_2D, .format = 0x44, .width = SW, .height = SW, .depth = 1, .levels = 1, .samples = 1};
        void *smem; if (posix_memalign(&smem, getpagesize(), 16384)) abort(); mtl_pool_add(smem, 16384);
        size_t row = RW / 4 * 16, rows = RH / 4; fill_blocks(smem, row * rows, 0x44, 99);
        uint8_t *expected = malloc((size_t)RW * RH * 4); CHECK(!nvn_bc_decode(0x44, smem, row, RW, RH, expected, (size_t)RW * 4), "CPU decode of the copy source");
        for (int into_astc = 0; into_astc < 2; into_astc++) {
            void *tmem = NULL; tex_t t;
            if (into_astc) {   // bytes in the storage, all planes cached (a first texture of them was uploaded decoded and encoded): ASTC at creation
                tex_t seed = fixture(cd, &tmem); id<MTLTexture> sm = upload(&seed); defer_obj_release(sm); CHECK(nvn_bc_astc_bg_wait(120), "seed drains");
                release_fixture(tmem); t = fixture(cd, &tmem);
            } else {
                t = (tex_t){.magic = MAGIC('T','E','X',0), .serial = nvn_new_serial(), .d = cd}; nvn_tex_layout(&cd, &t.L);
                if (posix_memalign(&tmem, getpagesize(), (t.L.size + 16383) & ~(size_t)16383)) abort();
                memset(tmem, 0, t.L.size); t.mem = tmem; mtl_pool_add(tmem, (t.L.size + 16383) & ~(size_t)16383);
            }
            mtl_tex_init(&t); mtl_sub_begin(); id<MTLTexture> mt = tex_mtl(&t);
            CHECK(mtl_wait(mtl_sub_commit(), 20000000000ull), "the new texture completes");
            CHECK(mt && mt.pixelFormat == (into_astc ? MTLPixelFormatASTC_4x4_LDR : MTLPixelFormatRGBA8Unorm), into_astc ? "a texture with cached bytes is ASTC" : "a texture with no bytes yet is decoded");
            for (int pass = 0; pass < (into_astc ? 2 : 1); pass++) {   // into ASTC: the first copy's source is not in the cache (void blocks, queued), the second is
                p_copy_b2t c = {.src = (uint64_t)(uintptr_t)smem, .tex = &t, .r = {OX, OY, 0, RW, RH, 1}};
                mtl_sub_begin(); copy_b2t(&c, sizeof c); CHECK(mtl_wait(mtl_sub_commit(), 20000000000ull), "the copy completes");
                id<MTLBuffer> out = [g_dev newBufferWithLength:(size_t)SW * SW * 16 options:MTLResourceStorageModeShared];
                uint32_t sel[2] = {0, 0};
                id<MTLCommandBuffer> cb = [g_q commandBuffer]; id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
                [e setComputePipelineState:sampler_pipeline(0)]; [e setTexture:mt atIndex:0]; [e setBuffer:out offset:0 atIndex:0]; [e setBytes:sel length:sizeof sel atIndex:1];
                [e dispatchThreads:MTLSizeMake(SW, SW, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)]; [e endEncoding]; [cb commit]; [cb waitUntilCompleted];
                const float *got = out.contents; double inside = 0;
                for (unsigned y = OY; y < OY + RH; y++) for (unsigned x = OX; x < OX + RW; x++) for (unsigned ch = 0; ch < 4; ch++)
                    inside += fabs(got[((size_t)y * SW + x) * 4 + ch] - expected[((y - OY) * RW + (x - OX)) * 4 + ch] / 255.0);
                inside /= RW * RH * 4;
                printf("copy_b2t into %s, pass %d: mean error inside %.4f\n", into_astc ? "ASTC" : "decoded", pass, inside);
                if (!into_astc) CHECK(inside < 0.001, "a copy into a decoded texture is the BC decode");
                else if (pass == 0) { nvn_astc_bg_stats cs = stats(); CHECK(cs.fetch_misses >= 1, "the uncached copy source was queued, not encoded here"); CHECK(nvn_bc_astc_bg_wait(120), "and drains"); }
                else CHECK(inside < 0.04, "once encoded, the copy into the ASTC texture is the BC decode");
            }
            CHECK(mt.pixelFormat == (into_astc ? MTLPixelFormatASTC_4x4_LDR : MTLPixelFormatRGBA8Unorm), "the copies did not change the texture's format");
            defer_obj_release(mt); release_fixture(tmem);
        }
        free(expected); release_fixture(smem);
    }

    // 5. queue cap: 256x256 BC7 planes of 65,536 bytes, a cap of two and a half of them; the rest is dropped and counted
    {
        char q[512]; subdir(q, sizeof q, dir, "queue");
        size_t bytes = 256 * 256;   // 64x64 blocks of 16 bytes
        configure(q, 2 * bytes + bytes / 2, 1ull << 30, 0, 1);
        uint8_t *buf = malloc(bytes);
        for (unsigned i = 0; i < 8; i++) { fill_blocks(buf, bytes, 0x4d, 500 + i); CHECK(nvn_bc_astc_learn(0x4d, buf, bytes, 256, 256, blk, NULL) == 0, "a fresh plane misses"); }
        s = stats();
        printf("queue cap: %llu queued, %llu dropped (%.1f MB), %llu pending-duplicates\n", (unsigned long long)s.queued, (unsigned long long)s.dropped, s.dropped_bytes / 1048576.0, (unsigned long long)s.duplicates);
        CHECK(s.queued + s.dropped + s.duplicates == 8 && s.dropped >= 1 && s.queued >= 2, "every miss is queued or counted as dropped");
        CHECK(s.queued_bytes_now <= 2 * bytes + bytes / 2, "the queue never holds more than its cap");
        CHECK(nvn_bc_astc_bg_wait(120), "drains"); s = stats(); CHECK(s.encoded == s.queued && s.written == s.queued, "everything queued was encoded and written");
        // a dropped plane is not remembered: it can be queued again
        fill_blocks(buf, bytes, 0x4d, 507); int again = nvn_bc_astc_learn(0x4d, buf, bytes, 256, 256, blk, NULL); CHECK(again == 0 || again == 1, "a later look-up of a dropped plane is valid");
        CHECK(nvn_bc_astc_bg_wait(120), "drains again");
        free(buf);
    }
    // 5b. the read-only cache as one pack file: the planes the first texture left in the writable directory are packed, the writable directory is replaced by an empty one, and a new texture of the same
    // bytes is ASTC from the pack alone. A pack that does not hold together is ignored (the texture is decoded)
    {
        char pk[600]; snprintf(pk, sizeof pk, "%s/astc-ro.pack", dir); pack_dir(rw, pk);
        char rw2[512]; subdir(rw2, sizeof rw2, dir, "rw2");
        nvn_astc_bg_config c = {.cache = rw2, .readonly = pk, .queue_cap = 64u << 20, .cache_max = 1ull << 30, .min_free = 0, .threads = 1};
        nvn_bc_astc_bg_configure(&c);
        void *m3; tex_t t3 = fixture(d, &m3);
        id<MTLTexture> mt3 = upload(&t3);
        CHECK(mt3 && mt3.pixelFormat == astc_pf, "a texture whose planes are in the read-only pack is ASTC");
        for (unsigned l = 0; mt3 && l < 4; l++) { double mean, peak; compare_level(mt3, &t3, d, l, 0, &mean, &peak); CHECK(mean < 0.04 * (six ? 6.0 : 1.0), "ASTC from the pack samples close to the BC decode"); }
        nvn_astc_bg_stats ps = stats(); CHECK(ps.hits >= 4 && ps.misses == 0 && ps.fetch_misses == 0 && cache_files(rw2) == 0, "four hits in the pack, nothing missed or written");
        defer_obj_release(mt3); release_fixture(m3);
        FILE *f = fopen(pk, "r+b"); fseek(f, 0, SEEK_END); long n = ftell(f); fclose(f); CHECK(!truncate(pk, n - 20), "cut the index short");   // the whole pack is then ignored
        char pk2[600]; snprintf(pk2, sizeof pk2, "%s/astc-ro-cut.pack", dir); rename(pk, pk2); c.readonly = pk2;
        nvn_bc_astc_bg_configure(&c);
        void *m4; tex_t t4 = fixture(d, &m4);
        id<MTLTexture> mt4 = upload(&t4);
        CHECK(mt4 && mt4.pixelFormat == MTLPixelFormatRGBA8Unorm, "a truncated pack is ignored: the texture stays decoded");
        defer_obj_release(mt4); release_fixture(m4);
        CHECK(nvn_bc_astc_bg_wait(120), "its planes drain into the writable directory");
    }
    // 5c. a texture created empty and filled by a copy: with a read-only cache the format is decided at its first copy. A whole-level copy whose plane is in the pack makes it ASTC; one that is not, or a piece of a level, leaves it decoded
    {
        enum { N = 16 };
        nvn_texdesc cd = {.target = NVN_TEXTURE_TARGET_2D, .format = 0x44, .width = N, .height = N, .depth = 1, .levels = 1, .samples = 1};
        void *smem; if (posix_memalign(&smem, getpagesize(), 16384)) abort(); mtl_pool_add(smem, 16384);
        size_t row = N / 4 * 16, rows = N / 4; fill_blocks(smem, row * rows, 0x44, 321);
        char c1[512]; subdir(c1, sizeof c1, dir, "copy-warm");
        configure(c1, 64u << 20, 1ull << 30, 0, 1);
        nvn_astc_cache_key kk; CHECK(nvn_bc_astc_learn(0x44, smem, row * rows, N, N, blk, &kk) == 0, "the copy's plane is queued"); CHECK(nvn_bc_astc_bg_wait(120), "and encoded");
        char pk[600]; snprintf(pk, sizeof pk, "%s/copy.pack", dir); pack_dir(c1, pk);
        char c2[512]; subdir(c2, sizeof c2, dir, "copy-new");
        nvn_astc_bg_config rc = {.cache = c2, .readonly = pk, .queue_cap = 64u << 20, .cache_max = 1ull << 30, .min_free = 0, .threads = 1};
        nvn_bc_astc_bg_configure(&rc);
        uint8_t *expected = malloc((size_t)N * N * 4); CHECK(!nvn_bc_decode(0x44, smem, row, N, N, expected, (size_t)N * 4), "CPU decode of the copy source");
        uint64_t first0 = atomic_load(&g_astc_copy_first), astc0 = atomic_load(&g_astc_copy_astc), part0 = atomic_load(&g_astc_copy_partial);
        void *keep[6] = {0};   // storage stays allocated until the end: a new texture at the address of an earlier one would be aliased to its Metal texture
        for (int variant = 0; variant < 3; variant++) {   // 0: the whole level, cached; 1: the whole level, not cached; 2: a piece of a level
            tex_t t = {.magic = MAGIC('T','E','X',0), .serial = nvn_new_serial(), .d = cd}; nvn_tex_layout(&cd, &t.L);
            void *tmem; if (posix_memalign(&tmem, getpagesize(), (t.L.size + 16383) & ~(size_t)16383)) abort();
            memset(tmem, 0, t.L.size); t.mem = tmem; t.off = 0x10000u * (variant + 1); mtl_pool_add(tmem, (t.L.size + 16383) & ~(size_t)16383);   // another offset: textures of one description and offset share a Metal texture
            mtl_tex_init(&t);
            void *other = NULL; uint64_t src = (uint64_t)(uintptr_t)smem;
            if (variant == 1) { if (posix_memalign(&other, getpagesize(), 16384)) abort(); mtl_pool_add(other, 16384); fill_blocks(other, row * rows, 0x44, 999); src = (uint64_t)(uintptr_t)other; }
            p_copy_b2t cp = {.src = src, .tex = &t, .r = {0, 0, 0, variant == 2 ? 8 : N, variant == 2 ? 8 : N, 1}};
            mtl_sub_begin(); copy_b2t(&cp, sizeof cp); CHECK(mtl_wait(mtl_sub_commit(), 20000000000ull), "the copy completes");
            id<MTLTexture> mt = tex_mtl(&t);
            CHECK(mt && mt.pixelFormat == (variant == 0 ? astc_pf : MTLPixelFormatRGBA8Unorm), variant == 0 ? "an empty texture whose first copy is a cached whole level is made ASTC" : "an uncached or partial first copy leaves it decoded");
            if (variant == 0 && mt) {
                id<MTLBuffer> out = [g_dev newBufferWithLength:(size_t)N * N * 16 options:MTLResourceStorageModeShared]; uint32_t sel[2] = {0, 0};
                id<MTLCommandBuffer> cb = [g_q commandBuffer]; id<MTL4ComputeCommandEncoder> unused = nil; (void)unused;
                id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
                [e setComputePipelineState:sampler_pipeline(0)]; [e setTexture:mt atIndex:0]; [e setBuffer:out offset:0 atIndex:0]; [e setBytes:sel length:sizeof sel atIndex:1];
                [e dispatchThreads:MTLSizeMake(N, N, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)]; [e endEncoding]; [cb commit]; [cb waitUntilCompleted];
                const float *got = out.contents; double err = 0; for (unsigned i = 0; i < N * N * 4; i++) err += fabs(got[i] - expected[i] / 255.0); err /= N * N * 4;
                CHECK(err < 0.04 * (six ? 6.0 : 1.0), "the copy into the ASTC texture is the BC decode");
            }
            defer_obj_release(mt); keep[variant] = tmem; keep[3 + variant] = other;
        }
        for (int i = 0; i < 6; i++) if (keep[i]) release_fixture(keep[i]);
        CHECK(atomic_load(&g_astc_copy_first) - first0 == 3 && atomic_load(&g_astc_copy_astc) - astc0 == 1 && atomic_load(&g_astc_copy_partial) - part0 == 1, "three first copies seen: one ASTC via the pack, one piece of a level");
        CHECK(nvn_bc_astc_bg_wait(120), "the uncached plane drains into the writable directory"); CHECK(cache_files(c2) >= 1, "and is encoded for the next run");
        free(expected); release_fixture(smem);
    }
    // 6. cache size cap: room for two entries, four planes encoded, two written
    {
        char c[512]; subdir(c, sizeof c, dir, "capped");
        size_t bytes = 128 * 128;
        size_t astc_bytes = (size_t)((128 + blk - 1) / blk) * ((128 + blk - 1) / blk) * 16;
        configure(c, 64u << 20, 2 * (astc_bytes + 40) + 10, 0, 1);
        uint8_t *buf = malloc(bytes);
        for (unsigned i = 0; i < 4; i++) { fill_blocks(buf, bytes, 0x4d, 700 + i); nvn_bc_astc_learn(0x4d, buf, bytes, 128, 128, blk, NULL); }
        CHECK(nvn_bc_astc_bg_wait(120), "drains"); s = stats();
        printf("cache cap: %llu encoded, %llu written, %llu not written for the cap, %llu bytes\n", (unsigned long long)s.encoded, (unsigned long long)s.written, (unsigned long long)s.skipped_cap, (unsigned long long)s.cache_bytes);
        CHECK(s.encoded == 4 && s.written == 2 && s.skipped_cap == 2 && cache_files(c) == 2 && s.cache_bytes <= 2 * (astc_bytes + 40) + 10, "the cache stops at its cap");
        free(buf);
    }
    // 7. low free disk: nothing is written
    {
        char c[512]; subdir(c, sizeof c, dir, "lowdisk");
        configure(c, 64u << 20, 1ull << 30, 1ull << 60, 1);
        size_t bytes = 128 * 128; uint8_t *buf = malloc(bytes); fill_blocks(buf, bytes, 0x4d, 800); nvn_bc_astc_learn(0x4d, buf, bytes, 128, 128, blk, NULL);
        CHECK(nvn_bc_astc_bg_wait(120), "drains"); s = stats(); CHECK(s.encoded == 1 && s.written == 0 && s.skipped_lowdisk == 1 && cache_files(c) == 0, "writes stop when the disk is low");
        free(buf);
    }
    // 8. corrupt and short entries are ignored, and replaced by the background encode
    {
        char c[512]; subdir(c, sizeof c, dir, "corrupt");
        configure(c, 64u << 20, 1ull << 30, 0, 1);
        size_t bytes = 128 * 128; uint8_t *buf = malloc(bytes), *out = malloc(bytes);
        size_t astc_bytes = (size_t)((128 + blk - 1) / blk) * ((128 + blk - 1) / blk) * 16;
        fill_blocks(buf, bytes, 0x4d, 900); nvn_astc_cache_key key; CHECK(nvn_bc_astc_learn(0x4d, buf, bytes, 128, 128, blk, &key) == 0, "miss");
        CHECK(nvn_bc_astc_bg_wait(120), "drains");
        CHECK(nvn_bc_astc_fetch(0x4d, buf, bytes, 128, 128, blk, out, astc_bytes) == 1, "now a hit");
        char path[1024]; snprintf(path, sizeof path, "%s/%s.astc", c, key.hex);
        FILE *f = fopen(path, "r+b"); fseek(f, 100, SEEK_SET); int ch = fgetc(f); fseek(f, 100, SEEK_SET); fputc(ch ^ 0x55, f); fclose(f);
        CHECK(nvn_bc_astc_fetch(0x4d, buf, bytes, 128, 128, blk, out, astc_bytes) == 0, "a flipped byte fails the payload hash: a miss");
        CHECK(nvn_bc_astc_bg_wait(120), "the entry is rewritten");
        CHECK(nvn_bc_astc_fetch(0x4d, buf, bytes, 128, 128, blk, out, astc_bytes) == 1, "and hits again");
        truncate(path, 60);
        CHECK(nvn_bc_astc_learn(0x4d, buf, bytes, 128, 128, blk, NULL) == 0, "a short file is a miss");
        CHECK(nvn_bc_astc_bg_wait(120), "rewritten"); CHECK(nvn_bc_astc_fetch(0x4d, buf, bytes, 128, 128, blk, out, astc_bytes) == 1, "hits");
        free(buf); free(out);
    }
}


// ---- BC1 and the other formats at different blocks in one run (T_ASTC_BC1_BLOCK=5|6 with T_ASTC_BLOCK=4): sync mode ----
// A buffer-to-texture copy of BC blocks into a texture of `fmt`: when the region lines up with the ASTC blocks of that format's block it lands, otherwise it is skipped (RED_ONCE 158) and the texture keeps its zero fill
static void mixed_copy_case(uint32_t fmt, unsigned SW, unsigned OX, unsigned OY, unsigned RW, unsigned RH) {
    unsigned blk = blk_for(fmt); int bb = is_bc1(fmt) ? 8 : 16;
    int aligned = !(OX % blk || OY % blk || ((RW % blk) && OX + RW != SW) || ((RH % blk) && OY + RH != SW));
    void *tmem; nvn_texdesc d = {.target = NVN_TEXTURE_TARGET_2D, .format = fmt, .width = SW, .height = SW, .depth = 1, .levels = 1, .samples = 1};
    tex_t t = {.magic = MAGIC('T','E','X',0), .serial = nvn_new_serial(), .d = d}; nvn_tex_layout(&d, &t.L);
    if (posix_memalign(&tmem, getpagesize(), (t.L.size + 16383) & ~(size_t)16383)) abort();
    static unsigned seq; t.off = 0x10000u * (100 + ++seq);   // a guest address of its own
    memset(tmem, 0, t.L.size); t.mem = tmem; mtl_pool_add(tmem, (t.L.size + 16383) & ~(size_t)16383);
    void *smem; if (posix_memalign(&smem, getpagesize(), 16384)) abort(); mtl_pool_add(smem, 16384);
    size_t row = RW / 4 * bb, rows = RH / 4; fill_blocks(smem, row * rows, fmt, 99);
    mtl_tex_init(&t); mtl_sub_begin(); id<MTLTexture> mt = tex_mtl(&t);
    CHECK(mtl_wait(mtl_sub_commit(), 20000000000ull), "the new texture's zero fill completes");
    CHECK(mt && mt.pixelFormat == astc_pf_of(blk, is_srgb_fmt(fmt)), "format %#x made for copies is ASTC %ux%u", fmt, blk, blk);
    p_copy_b2t c = {.src = (uint64_t)(uintptr_t)smem, .tex = &t, .r = {(int)OX, (int)OY, 0, (int)RW, (int)RH, 1}};
    mtl_sub_begin(); copy_b2t(&c, sizeof c); up_flush();   // a skipped copy leaves the zero fill queued; the next draw would flush it
    CHECK(mtl_wait(mtl_sub_commit(), 20000000000ull), "the copy's submission completes");
    uint8_t *expected = malloc((size_t)RW * RH * 4); uint8_t zero_bc[16] = {0}, zero_px[4 * 4 * 4];
    CHECK(!nvn_bc_decode(fmt, smem, row, RW, RH, expected, (size_t)RW * 4) && !nvn_bc_decode(fmt, zero_bc, 16, 4, 4, zero_px, 16), "CPU decode of the copy source");
    id<MTLBuffer> out = [g_dev newBufferWithLength:(size_t)SW * SW * 16 options:MTLResourceStorageModeShared]; uint32_t sel[2] = {0, 0};
    id<MTLCommandBuffer> cb = [g_q commandBuffer]; id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
    [e setComputePipelineState:sampler_pipeline(0)]; [e setTexture:mt atIndex:0]; [e setBuffer:out offset:0 atIndex:0]; [e setBytes:sel length:sizeof sel atIndex:1];
    [e dispatchThreads:MTLSizeMake(SW, SW, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)]; [e endEncoding]; [cb commit]; [cb waitUntilCompleted];
    const float *got = out.contents; double inside = 0, outside = 0; size_t nin = 0, nout = 0;
    for (unsigned y = 0; y < SW; y++) for (unsigned x = 0; x < SW; x++) for (unsigned ch = 0; ch < 4; ch++) {
        int in = x >= OX && x < OX + RW && y >= OY && y < OY + RH;
        double want = in && aligned ? expected[((y - OY) * RW + (x - OX)) * 4 + ch] / 255.0 : zero_px[ch] / 255.0;   // not copied: the zero blocks' colour
        double err = fabs(got[((size_t)y * SW + x) * 4 + ch] - want);
        if (in) { inside += err; nin++; } else { outside += err; nout++; }
    }
    inside /= nin; outside /= nout;
    if (getenv("T_DEBUG")) for (unsigned y = 0; y < SW; y += 6) { for (unsigned x = 0; x < SW; x += 6) printf("%.2f/%.2f ", got[((size_t)y * SW + x) * 4], got[((size_t)y * SW + x) * 4 + 3]); printf("\n"); }
    printf("copy_b2t format %#x ASTC %ux%u, region %u,%u %ux%u of %u (%s): mean error inside %.4f, outside %.4f\n", fmt, blk, blk, OX, OY, RW, RH, SW, aligned ? "lines up" : "does not line up, skipped", inside, outside);
    CHECK(inside < 0.04 * slack_of(blk), "the region %s", aligned ? "samples like its BC decode" : "is untouched");
    CHECK(outside < 0.001, "the rest of the texture is untouched");
    free(expected); defer_obj_release(mt); release_fixture(smem); release_fixture(tmem);
}
// A view with another BC format of the same family takes the base texture's ASTC block, not the block of the view's format (Metal cannot change the block in a view)
static void mixed_view_case(uint32_t base_fmt, uint32_t view_fmt, int tid) {
    void *mem; nvn_texdesc d = {.target = NVN_TEXTURE_TARGET_2D, .format = base_fmt, .width = 32, .height = 32, .depth = 1, .levels = 2, .samples = 1};
    tex_t t = fixture(d, &mem); id<MTLTexture> mt = upload(&t);
    CHECK(mt && mt.pixelFormat == astc_pf_of(blk_for(base_fmt), is_srgb_fmt(base_fmt)), "view base %#x is ASTC %ux%u", base_fmt, blk_for(base_fmt), blk_for(base_fmt));
    view_t v = {0}; v.set_format = 1; v.format = view_fmt;
    mtl_reg_tex(tid, &t, &v);
    os_unfair_lock_lock(&g_rmu); id<MTLTexture> view = tex_by_id(tid); os_unfair_lock_unlock(&g_rmu);
    CHECK(view && view.pixelFormat == astc_pf_of(blk_for(base_fmt), is_srgb_fmt(view_fmt)), "a %#x view of the %#x texture has the base's block %u (got pixel format %lu)", view_fmt, base_fmt, blk_for(base_fmt), view ? (unsigned long)view.pixelFormat : 0ul);
    CHECK(view && view.width == 32, "and its size");
    defer_obj_release(mt); release_fixture(mem);
}
static void run_mixed_sync(const char *dir) {
    (void)dir;
    // the two textures in one run, each at its own block
    {
        void *m1, *m7; nvn_texdesc d1 = {.target = NVN_TEXTURE_TARGET_2D, .format = 0x42, .width = 64, .height = 48, .depth = 1, .levels = 5, .samples = 1}, d7 = d1; d7.format = 0x4d;
        tex_t t1 = fixture(d1, &m1), t7 = fixture(d7, &m7); id<MTLTexture> mt1 = upload(&t1), mt7 = upload(&t7);
        CHECK(mt1 && mt1.pixelFormat == astc_pf_of(g_bc1_blk, 0) && mt7 && mt7.pixelFormat == astc_pf_of(g_blk, 0), "BC1 at %ux%u and BC7 at %ux%u in the same run", g_bc1_blk, g_bc1_blk, g_blk, g_blk);
        for (unsigned l = 0; l < 5; l++) {
            double m, p; if (mt1) { compare_level(mt1, &t1, d1, l, 0, &m, &p); CHECK(m < 0.02 * slack_of(g_bc1_blk), "BC1 level %u samples like its decode (%.4f)", l, m); }
            if (mt7) { compare_level(mt7, &t7, d7, l, 0, &m, &p); CHECK(m < 0.04 * slack_of(g_blk), "BC7 level %u samples like its decode (%.4f)", l, m); }
        }
        defer_obj_release(mt1); defer_obj_release(mt7); release_fixture(m1); release_fixture(m7);
    }
    // 2D array of BC1
    {
        void *mem; nvn_texdesc d = {.target = NVN_TEXTURE_TARGET_2D_ARRAY, .format = 0x42, .width = 24, .height = 24, .depth = 3, .levels = 2, .samples = 1};
        tex_t t = fixture(d, &mem); id<MTLTexture> mt = upload(&t);
        CHECK(mt && mt.pixelFormat == astc_pf_of(g_bc1_blk, 0) && mt.arrayLength == 3, "a BC1 2D array is ASTC at the BC1 block");
        for (unsigned layer = 0; mt && layer < 3; layer++) { double m, p; compare_level(mt, &t, d, 1, layer, &m, &p); CHECK(m < 0.02 * slack_of(g_bc1_blk), "BC1 layer %u samples like its decode", layer); }
        defer_obj_release(mt); release_fixture(mem);
    }
    mixed_view_case(0x42, 0x46, 97001); mixed_view_case(0x46, 0x42, 97002); mixed_view_case(0x44, 0x48, 97003); mixed_view_case(0x4d, 0x4e, 97004);
    // copies (block-aligned for each block; for 5x5 and 6x6 the aligned region starts on a multiple of 20 / 12 so both the BC and ASTC grids line up)
    unsigned b1 = g_bc1_blk; unsigned al = b1 == 6 ? 12 : b1 == 5 ? 20 : 4;
    mixed_copy_case(0x42, al * 4, al, al, al * 2, al * 2);      // lines up
    mixed_copy_case(0x42, al * 4, 4, 4, 8, 8);                  // 4,4 8x8: only a 4x4 block lines up
    if (b1 != 4) mixed_copy_case(0x42, al * 4, al, 4, al, 8);   // starts on the grid in x only
    mixed_copy_case(0x44, 32, 8, 4, 16, 12);                    // BC3 at its own block
    mixed_copy_case(0x4d, 24, 12, 12, 12, 12);
}
// ---- the same, DM_NVN_ASTC_MISS=background ----
static void run_background_mixed(const char *dir) {
    char rw[512]; subdir(rw, sizeof rw, dir, "mixed_rw"); configure(rw, 64u << 20, 1ull << 30, 0, 2);
    nvn_texdesc d1 = {.target = NVN_TEXTURE_TARGET_2D, .format = 0x42, .width = 64, .height = 64, .depth = 1, .levels = 4, .samples = 1}, d7 = d1; d7.format = 0x4d;
    nvn_astc_bg_stats s0 = stats();
    void *m1, *m7, *n1, *n7; tex_t t1 = fixture(d1, &m1), t7 = fixture(d7, &m7);
    id<MTLTexture> mt1 = upload(&t1), mt7 = upload(&t7);
    CHECK(mt1 && mt1.pixelFormat == MTLPixelFormatRGBA8Unorm && mt7 && mt7.pixelFormat == MTLPixelFormatRGBA8Unorm, "misses upload decoded");
    CHECK(nvn_bc_astc_bg_wait(120), "the queue drains");
    nvn_astc_bg_stats s = stats(); CHECK(s.misses - s0.misses == 8 && s.written - s0.written == 8 && cache_files(rw) == 8, "eight planes (4 BC1, 4 BC7) were missed and written");
    // each plane was stored at its format's block: a look-up at the other block finds nothing, at its own it is found
    {
        uint32_t row, rows, depth, bpb; uint64_t base; unsigned th, td; nvn_deswizzle_geom(&d1, 0, 0, &row, &rows, &depth, &base, &th, &td, &bpb);
        uint8_t *lin = malloc((size_t)row * rows); fill_blocks(lin, (size_t)row * rows, 0x42, 0 + g_seed_base);
        CHECK(nvn_bc_astc_has_plane(0x42, lin, (size_t)row * rows, 64, 64, g_bc1_blk) == 1, "the BC1 plane is in the cache at the BC1 block");
        if (g_bc1_blk != g_blk) CHECK(nvn_bc_astc_has_plane(0x42, lin, (size_t)row * rows, 64, 64, g_blk) == 0, "and not at the other block");
        free(lin);
    }
    tex_t u1 = fixture(d1, &n1), u7 = fixture(d7, &n7); id<MTLTexture> nt1 = upload(&u1), nt7 = upload(&u7);
    CHECK(nt1 && nt1.pixelFormat == astc_pf_of(g_bc1_blk, 0), "a BC1 texture whose planes are cached is ASTC %ux%u", g_bc1_blk, g_bc1_blk);
    CHECK(nt7 && nt7.pixelFormat == astc_pf_of(g_blk, 0), "a BC7 texture whose planes are cached is ASTC %ux%u", g_blk, g_blk);
    for (unsigned l = 0; l < 4; l++) { double m, p;
        if (nt1) { compare_level(nt1, &u1, d1, l, 0, &m, &p); CHECK(m < 0.03 * slack_of(g_bc1_blk), "BC1 level %u samples like its decode (%.4f)", l, m); }
        if (nt7) { compare_level(nt7, &u7, d7, l, 0, &m, &p); CHECK(m < 0.04 * slack_of(g_blk), "BC7 level %u samples like its decode (%.4f)", l, m); } }
    s = stats(); CHECK(s.hits - s0.hits >= 8 && s.fetch_misses == s0.fetch_misses, "the ASTC uploads were eight cache hits");
    defer_obj_release(mt1); defer_obj_release(mt7); defer_obj_release(nt1); defer_obj_release(nt7); release_fixture(m1); release_fixture(m7); release_fixture(n1); release_fixture(n7);
}
// ---- the same, stripped planes read by tag from an embedded pack ----
typedef struct { uint32_t format; unsigned block; uint8_t key[8][32]; unsigned n; } mtag_keys;
static int mtag_collect(void *ctx, unsigned level, unsigned layer, uint32_t w, uint32_t h, const void *bc, size_t size) {
    (void)layer; mtag_keys *k = ctx; nvn_astc_cache_key key; nvn_bc_astc_plane_key(k->format, w, h, k->block, bc, size, &key);
    for (int i = 0; i < 32; i++) { unsigned v; sscanf(key.hex + 2 * i, "%2x", &v); k->key[level][i] = (uint8_t)v; }
    k->n = level + 1; return 0;
}
static void run_tagged_mixed(const char *dir) {
    char rw[512]; subdir(rw, sizeof rw, dir, "mtag_rw"); configure(rw, 64u << 20, 1ull << 30, 0, 2);
    nvn_texdesc d1 = {.target = NVN_TEXTURE_TARGET_2D, .format = 0x42, .width = 64, .height = 64, .depth = 1, .levels = 4, .samples = 1}, d7 = d1; d7.format = 0x4d;
    void *m1, *m7; tex_t t1 = fixture(d1, &m1), t7 = fixture(d7, &m7);
    mtag_keys k1 = {0x42, blk_for(0x42), {{0}}, 0}, k7 = {0x4d, blk_for(0x4d), {{0}}, 0};
    CHECK(nvn_astc_walk_planes(&t1.d, t1.mem, 0, mtag_collect, &k1) == 0 && k1.n == 4 && nvn_astc_walk_planes(&t7.d, t7.mem, 0, mtag_collect, &k7) == 0 && k7.n == 4, "the plane keys, each at its format's block");
    id<MTLTexture> mt1 = upload(&t1), mt7 = upload(&t7); CHECK(nvn_bc_astc_bg_wait(120), "seed drains"); CHECK(cache_files(rw) == 8, "eight entries");
    char pk[600]; snprintf(pk, sizeof pk, "%s/mixed.pack", dir); pack_dir(rw, pk);
    NSData *pkd = [NSData dataWithContentsOfFile:@(pk)]; uint8_t logical[20000]; for (int i = 0; i < 20000; i++) logical[i] = (uint8_t)(i * 31 + 1);
    memset(logical + 3000, 0, 9000);
    uint8_t *wrapped; size_t wn; CHECK(fx_write_sparse(NULL, logical, sizeof logical, 4096, 0, pkd.bytes, pkd.length, &wrapped, &wn) >= 2, "the image");
    char img[600]; snprintf(img, sizeof img, "%s/mixed_romfs.img", dir); { FILE *f = fopen(img, "wb"); fwrite(wrapped, 1, wn, f); fclose(f); } free(wrapped);
    CHECK(embedded_pack_setup(img) == 1 && g_embedded, "a DMSPARS1 with a pack is a stripped image");
    uint64_t entries, bytes; CHECK(nvn_bc_astc_pack_info(NVN_ASTC_EMBEDDED_ROOT, &entries, &bytes, NULL) && entries == 8, "eight entries in the pack (%llu)", (unsigned long long)entries);
    char rw2[512]; subdir(rw2, sizeof rw2, dir, "mtag_rw2");
    nvn_astc_bg_config c = {.cache = rw2, .readonly = NVN_ASTC_EMBEDDED_ROOT, .queue_cap = 64u << 20, .cache_max = 1ull << 30, .min_free = 0, .threads = 1};
    nvn_bc_astc_bg_configure(&c);
    void *r1, *r7; tex_t h1 = fixture(d1, &r1), h7 = fixture(d7, &r7); id<MTLTexture> hm1 = upload(&h1), hm7 = upload(&h7);   // the hashed path
    CHECK(hm1 && hm1.pixelFormat == astc_pf_of(g_bc1_blk, 0) && hm7 && hm7.pixelFormat == astc_pf_of(g_blk, 0), "the hashed path resolves each from the pack at its block");
    float *ref1[4], *ref7[4]; for (unsigned l = 0; l < 4; l++) { ref1[l] = read_level(hm1, l, 64 >> l, 64 >> l); ref7[l] = read_level(hm7, l, 64 >> l, 64 >> l); }
    nvn_astc_bg_stats before = stats(); uint64_t th0, tu0, td0; tag_counts(&th0, &tu0, &td0);
    void *s1, *s7; tex_t x1 = fixture(d1, &s1), x7 = fixture(d7, &s7);
    for (unsigned l = 0; l < 4; l++) { strip_plane(&x1, l, k1.key[l]); strip_plane(&x7, l, k7.key[l]); }
    id<MTLTexture> xm1 = upload(&x1), xm7 = upload(&x7);
    CHECK(xm1 && xm1.pixelFormat == astc_pf_of(g_bc1_blk, 0), "a stripped BC1 texture is ASTC %ux%u", g_bc1_blk, g_bc1_blk);
    CHECK(xm7 && xm7.pixelFormat == astc_pf_of(g_blk, 0), "a stripped BC7 texture is ASTC %ux%u", g_blk, g_blk);
    uint64_t th1, tu1, td1; tag_counts(&th1, &tu1, &td1); nvn_astc_bg_stats after = stats();
    CHECK(th1 - th0 == 8 && tu1 == tu0 && td1 == td0, "eight tagged hits, nothing unresolved or decoded (%llu/%llu/%llu)", (unsigned long long)(th1 - th0), (unsigned long long)(tu1 - tu0), (unsigned long long)(td1 - td0));
    CHECK(after.hits == before.hits && after.misses == before.misses && after.queued == before.queued, "no hashed lookup for a tagged plane");
    for (unsigned l = 0; l < 4; l++) {
        float *g1 = xm1 ? read_level(xm1, l, 64 >> l, 64 >> l) : NULL, *g7 = xm7 ? read_level(xm7, l, 64 >> l, 64 >> l) : NULL;
        CHECK(g1 && !memcmp(g1, ref1[l], (size_t)(64 >> l) * (64 >> l) * 16), "BC1 level %u: the tagged plane is the hashed path's blocks", l);
        CHECK(g7 && !memcmp(g7, ref7[l], (size_t)(64 >> l) * (64 >> l) * 16), "BC7 level %u: the tagged plane is the hashed path's blocks", l);
        free(g1); free(g7);
        double m, p; if (xm1) { compare_level(xm1, &x1, d1, l, 0, &m, &p); CHECK(m < 0.03 * slack_of(g_bc1_blk), "stripped BC1 level %u samples like the original (%.4f)", l, m); }
    }
    g_embedded = 0;
    defer_obj_release(mt1); defer_obj_release(mt7); defer_obj_release(hm1); defer_obj_release(hm7); defer_obj_release(xm1); defer_obj_release(xm7);
    release_fixture(m1); release_fixture(m7); release_fixture(r1); release_fixture(r7); release_fixture(s1); release_fixture(s7);
    for (int i = 0; i < 4; i++) { free(ref1[i]); free(ref7[i]); }
    CHECK(nvn_bc_astc_bg_wait(120), "drains");
}
int main(int argc, char **argv) { @autoreleasepool {
    (void)argc; (void)argv;
    char dir[] = "/tmp/t_astc_upload.XXXXXX";
    if (!mkdtemp(dir)) { perror("mkdtemp"); return 1; }
    setenv("DM_TEST_NO_BC", "1", 1); const char *mode = getenv("T_ASTC_MODE"); int maxdim = mode && !strcmp(mode, "maxdim"), tagged = mode && (!strcmp(mode, "tagged") || !strcmp(mode, "tagged_mixed")), background = (mode && !strcmp(mode, "background")) || maxdim || tagged; if (maxdim) setenv("DM_BC_MAX_DIM", "64", 1); setenv("DM_NVN_ASTC_MISS", background ? "background" : "sync", 1); const char *which = getenv("T_ASTC_BLOCK"); int six = which && atoi(which) == 6; setenv("DM_NVN_BC_ASTC", six ? "6" : "4", 1); g_blk = six ? 6 : 4; { const char *b1 = getenv("T_ASTC_BC1_BLOCK"); g_bc1_blk = b1 && *b1 ? (unsigned)atoi(b1) : g_blk; if (b1 && *b1) setenv("DM_NVN_BC1_ASTC", b1, 1); else unsetenv("DM_NVN_BC1_ASTC"); } setenv("DM_NVN_ASTC_CACHE", dir, 1); unsetenv("DM_NVN_ASTC_CACHE_RO");
    mtl_init();
    CHECK(astc_block() == (six ? 6u : 4u), "DM_NVN_BC_ASTC is on (with DM_TEST_NO_BC)");
    CHECK(astc_block_for(0x42) == g_bc1_blk && astc_block_for(0x46) == g_bc1_blk && astc_block_for(0x41) == g_bc1_blk && astc_block_for(0x45) == g_bc1_blk, "BC1 (and sRGB) uses DM_NVN_BC1_ASTC");
    CHECK(astc_block_for(0x43) == g_blk && astc_block_for(0x44) == g_blk && astc_block_for(0x4d) == g_blk && astc_block_for(0x4e) == g_blk, "BC2/3/7 use DM_NVN_BC_ASTC");
    if (maxdim) {
        run_maxdim(dir);
        mtl_drain();
        { char cmd[128]; snprintf(cmd, sizeof cmd, "rm -rf %s", dir); system(cmd); }
        printf("ASTC upload (DM_BC_MAX_DIM=64): %d checks, %d failures\n", checks, failed);
        return failed ? 1 : 0;
    }
    if (tagged) {
        if (getenv("T_ASTC_MODE") && !strcmp(getenv("T_ASTC_MODE"), "tagged_mixed")) run_tagged_mixed(dir); else run_tagged(dir);   // the embedded pack registers once per process
        mtl_drain();
        { char cmd[128]; snprintf(cmd, sizeof cmd, "rm -rf %s", dir); system(cmd); }
        printf("ASTC upload (tagged planes): %d checks, %d failures\n", checks, failed);
        return failed ? 1 : 0;
    }
    if (background) {
        run_background(dir, six);
        run_background_mixed(dir);
        mtl_drain();
        { char cmd[128]; snprintf(cmd, sizeof cmd, "rm -rf %s", dir); system(cmd); }
        printf("ASTC upload (background, %s): %d checks, %d failures\n", six ? "6x6" : "4x4", checks, failed);
        return failed ? 1 : 0;
    }
    double slack = slack_of(g_blk);   // (a run with T_ASTC_BLOCK=6)

    struct { uint32_t format; MTLPixelFormat expect; double mean_max; const char *name; } cases[] = {
        {0x42, MTLPixelFormatASTC_4x4_LDR, 0.02, "BC1"}, {0x46, MTLPixelFormatASTC_4x4_sRGB, 0.02, "BC1 sRGB"}, {0x43, MTLPixelFormatASTC_4x4_LDR, 0.04, "BC2"},
        {0x44, MTLPixelFormatASTC_4x4_LDR, 0.04, "BC3"}, {0x4d, MTLPixelFormatASTC_4x4_LDR, 0.04, "BC7"}, {0x4e, MTLPixelFormatASTC_4x4_sRGB, 0.04, "BC7 sRGB"},
    };
    for (size_t c = 0; c < sizeof cases / sizeof *cases; c++) {
        void *memory; nvn_texdesc d = {.target = NVN_TEXTURE_TARGET_2D, .format = cases[c].format, .width = 37, .height = 21, .depth = 1, .levels = 4, .samples = 1};
        tex_t t = fixture(d, &memory);
        id<MTLTexture> mt = upload(&t);
        MTLPixelFormat want_pf = astc_pf_of(blk_for(cases[c].format), is_srgb_fmt(cases[c].format)); double slack = slack_of(blk_for(cases[c].format));
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
    run_mixed_sync(dir);
    mtl_drain();
    { char cmd[128]; snprintf(cmd, sizeof cmd, "rm -rf %s", dir); system(cmd); }
    printf("ASTC upload: %d checks, %d failures\n", checks, failed);
    return failed ? 1 : 0;
} }
