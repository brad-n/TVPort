// DM_NVN_BC_ASTC (nvn_mtl.m, dm/gfx/tex/nvn_astc_cache.m): on a GPU stored without BC, BC1/2/3/7 2D textures are uploaded as ASTC 4x4 / 6x6 LDR. Runs on the Mac GPU with DM_TEST_NO_BC=1:
// the texture's Metal format and size, what a shader samples against the CPU decode of the same blocks, the content-addressed cache (a second upload is all hits, from the cache directory alone),
// BC4/BC5 and 3D staying decoded, and ASTC off (unset) leaving every BC format as it was.
// Fixture and swizzling follow nxnative-tvos' t_bc_upload.m (MIT, yuchanns).
#include "../nvn/nvn_mtl.m"
#include <math.h>
#include <dirent.h>
#include <sys/stat.h>
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } } while (0)

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
static void compare_level(id<MTLTexture> mt, tex_t *texture, nvn_texdesc d, unsigned level, unsigned layer, double *mean, double *peak) {
    uint32_t row, rows, depth, bpb; uint64_t base; unsigned th, td;
    nvn_deswizzle_geom(&d, level, 0, &row, &rows, &depth, &base, &th, &td, &bpb);
    uint32_t w = MAX(d.width >> level, 1u), h = MAX(d.height >> level, 1u);
    uint8_t *linear = malloc((size_t)row * rows);
    fill_blocks(linear, (size_t)row * rows, d.format, level + layer * 17 + g_seed_base);
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

int main(int argc, char **argv) { @autoreleasepool {
    (void)argc; (void)argv;
    char dir[] = "/tmp/t_astc_upload.XXXXXX";
    if (!mkdtemp(dir)) { perror("mkdtemp"); return 1; }
    setenv("DM_TEST_NO_BC", "1", 1); const char *mode = getenv("T_ASTC_MODE"); int background = mode && !strcmp(mode, "background"); setenv("DM_NVN_ASTC_MISS", background ? "background" : "sync", 1); const char *which = getenv("T_ASTC_BLOCK"); int six = which && atoi(which) == 6; setenv("DM_NVN_BC_ASTC", six ? "6" : "4", 1); setenv("DM_NVN_ASTC_CACHE", dir, 1); unsetenv("DM_NVN_ASTC_CACHE_RO");
    mtl_init();
    CHECK(astc_block() == (six ? 6u : 4u), "DM_NVN_BC_ASTC is on (with DM_TEST_NO_BC)");
    if (background) {
        run_background(dir, six);
        mtl_drain();
        { char cmd[128]; snprintf(cmd, sizeof cmd, "rm -rf %s", dir); system(cmd); }
        printf("ASTC upload (background, %s): %d checks, %d failures\n", six ? "6x6" : "4x4", checks, failed);
        return failed ? 1 : 0;
    }
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
