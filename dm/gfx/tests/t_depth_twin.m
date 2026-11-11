// Depth / colour twins (nvn_mtl.m depth_twin): an R32F (R16) texture over the storage of a live GPU-only DEPTH32F (DEPTH16) texture of the same size and layout reads the depth texture's
// bytes through its texture ID, with no Metal texture of its own, whichever of the two was made first; a write path (tex_mtl) still makes it a texture of its own, which its ID then reads;
// IMAGE, CPU-visible, differently sized or differently laid out colour textures keep their own texture
#include "../nvn/nvn_mtl.m"
uint64_t g_t0_ns;
int dm_guest_as_contains(uintptr_t address) { (void)address; return 0; }
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, fails;
#define CHECK(c, msg) do { checks++; if (!(c)) { fails++; fprintf(stderr, "FAIL: %s\n", msg); } } while (0)
static void clear_depth(id<MTLTexture> depth, double value) {
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.depthAttachment.texture = depth; pass.depthAttachment.loadAction = MTLLoadActionClear; pass.depthAttachment.storeAction = MTLStoreActionStore; pass.depthAttachment.clearDepth = value;
    id<MTLCommandBuffer> command = q_cb(); [[command renderCommandEncoderWithDescriptor:pass] endEncoding]; [command commit]; [command waitUntilCompleted];
    CHECK(command.status == MTLCommandBufferStatusCompleted, "depth cleared");
}
static void clear_colour(id<MTLTexture> t, double value) {
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = t; pass.colorAttachments[0].loadAction = MTLLoadActionClear; pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(value, 0, 0, 1);
    id<MTLCommandBuffer> command = q_cb(); [[command renderCommandEncoderWithDescriptor:pass] endEncoding]; [command commit]; [command waitUntilCompleted];
    CHECK(command.status == MTLCommandBufferStatusCompleted, "colour cleared");
}
// What a shader reads through the texture: texel (1, 1) by read and by a nearest sample, both as float4
static void read_texel(id<MTLTexture> t, float out[8]) {
    static id<MTLComputePipelineState> p;
    if (!p) { NSError *e = nil; id<MTLLibrary> l = [g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
            "kernel void rd(texture2d<float> t [[texture(0)]], device float4 *out [[buffer(0)]], uint i [[thread_position_in_grid]]) {"
            " out[i] = i == 0 ? t.read(uint2(1, 1)) : t.sample(sampler(coord::pixel, filter::nearest), float2(1.5f, 1.5f)); }" options:nil error:&e];
        p = [g_dev newComputePipelineStateWithFunction:[l newFunctionWithName:@"rd"] error:&e]; CHECK(p != nil, "reader pipeline"); }
    id<MTLBuffer> b = [g_dev newBufferWithLength:32 options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> command = q_cb(); id<MTLComputeCommandEncoder> en = [command computeCommandEncoder];
    [en setComputePipelineState:p]; [en setTexture:t atIndex:0]; [en setBuffer:b offset:0 atIndex:0];
    [en dispatchThreads:MTLSizeMake(2, 1, 1) threadsPerThreadgroup:MTLSizeMake(2, 1, 1)]; [en endEncoding]; [command commit]; [command waitUntilCompleted];
    memcpy(out, b.contents, 32);
}
static void expect_red(id<MTLTexture> t, float red, float tol, const char *what) {
    float v[8]; read_texel(t, v); int ok = 1;
    for (int i = 0; i < 2; i++) ok &= fabsf(v[4 * i] - red) <= tol && v[4 * i + 1] == 0 && v[4 * i + 2] == 0 && v[4 * i + 3] == 1;
    if (!ok) fprintf(stderr, "%s: read %g,%g,%g,%g sample %g,%g,%g,%g, want %g,0,0,1\n", what, v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7], red);
    CHECK(ok, what);
}
static uint8_t *g_mem; static pool_t g_pool, g_cpu_pool;
static tex_t tex(pool_t *pool, uint64_t serial, int format, unsigned w, unsigned h, int flags, uint64_t off) {
    tex_t t = {.magic=MAGIC('T','E','X',0), .serial=serial, .pool=pool, .off=(int64_t)off, .mem=pool->mem + off};
    t.d = (nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D, .format=format, .flags=flags, .width=w, .height=h, .depth=1, .levels=1, .samples=1};
    nvn_tex_layout(&t.d, &t.L); return t;
}
static id<MTLTexture> by_id(int tid) { os_unfair_lock_lock(&g_rmu); id<MTLTexture> v = tex_by_id(tid); os_unfair_lock_unlock(&g_rmu); return v; }
static int own(const tex_t *t) { alias_key k = tex_alias_key(t); if (tex_get(t->serial)) return 1; pthread_mutex_lock(&g_smu); int r = hm_get_id(&g_alias, &k) != nil; pthread_mutex_unlock(&g_smu); return r; }
static id<MTLTexture> root(id<MTLTexture> t) { while (t.parentTexture) t = t.parentTexture; return t; }
int main(void) { @autoreleasepool {
    mtl_init();
    g_mem = calloc(1, 64 << 20);
    g_pool = (pool_t){.magic=MAGIC('P','O','O','L'), .flags=NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS|NVN_MEMORY_POOL_FLAGS_GPU_CACHED|NVN_MEMORY_POOL_FLAGS_COMPRESSIBLE, .mem=g_mem, .size=48 << 20};
    g_cpu_pool = (pool_t){.magic=MAGIC('P','O','O','L'), .flags=NVN_MEMORY_POOL_FLAGS_CPU_CACHED|NVN_MEMORY_POOL_FLAGS_GPU_CACHED, .mem=g_mem + (48 << 20), .size=16 << 20};
    const int C = NVN_TEXTURE_FLAGS_COMPRESSIBLE;
    // 1. Depth made first, then the colour texture read through its ID: the depth texture through a red view, no second texture, the depth's later writes read too
    tex_t d1 = tex(&g_pool, 97001, NVN_FORMAT_DEPTH32F, 64, 32, C, 0), c1 = tex(&g_pool, 97002, NVN_FORMAT_R32F, 64, 32, 0, 0);
    mtl_tex_init(&d1); mtl_tex_init(&c1);
    id<MTLTexture> dm = tex_mtl(&d1); CHECK(dm.pixelFormat == MTLPixelFormatDepth32Float, "depth texture made");
    clear_depth(dm, 0.375);
    mtl_reg_tex(701, &c1, NULL);
    id<MTLTexture> v1 = by_id(701);
    CHECK(v1 && root(v1) == dm, "R32F over Depth32F storage reads the depth texture");
    CHECK(!own(&c1), "the R32F texture has no Metal texture of its own");
    expect_red(v1, 0.375f, 0, "R32F twin reads the depth as (d, 0, 0, 1)");
    clear_depth(dm, 0.625); expect_red(by_id(701), 0.625f, 0, "R32F twin reads the depth's later writes");
    CHECK(by_id(701) == v1, "the twin's view is cached");
    // 2. Colour texture read first: the depth texture is made for it, and the depth's own lookup finds the same texture
    tex_t d2 = tex(&g_pool, 97011, NVN_FORMAT_DEPTH32F, 128, 64, C, 8 << 20), c2 = tex(&g_pool, 97012, NVN_FORMAT_R32F, 128, 64, 0, 8 << 20);
    mtl_tex_init(&d2); mtl_tex_init(&c2); mtl_reg_tex(702, &c2, NULL);
    id<MTLTexture> v2 = by_id(702); id<MTLTexture> dm2 = tex_mtl(&d2);
    CHECK(v2 && dm2 && root(v2) == dm2 && dm2.pixelFormat == MTLPixelFormatDepth32Float, "colour read first: the depth texture made for it is the depth's own");
    clear_depth(dm2, 0.25); expect_red(by_id(702), 0.25f, 0, "colour read first: reads the depth");
    // 3. A write path (an attachment, a copy, a clear: tex_mtl) makes the colour texture its own; its ID then reads that one, not the depth
    id<MTLTexture> w = tex_mtl(&c1);
    CHECK(w && w.pixelFormat == MTLPixelFormatR32Float && w != dm, "a write path makes the R32F texture its own");
    clear_colour(w, 0.5);
    id<MTLTexture> v1b = by_id(701);
    CHECK(v1b && root(v1b) == w, "after the write path the ID reads the colour texture's own storage");
    expect_red(v1b, 0.5f, 0, "the ID reads what was written into the colour texture");
    // 4. R16 over DEPTH16 likewise (unorm)
    tex_t d4 = tex(&g_pool, 97041, NVN_FORMAT_DEPTH16, 64, 64, C, 16 << 20), c4 = tex(&g_pool, 97042, NVN_FORMAT_R16, 64, 64, 0, 16 << 20);
    mtl_tex_init(&d4); mtl_tex_init(&c4); id<MTLTexture> dm4 = tex_mtl(&d4); clear_depth(dm4, 0.75); mtl_reg_tex(704, &c4, NULL);
    id<MTLTexture> v4 = by_id(704);
    CHECK(v4 && root(v4) == dm4 && !own(&c4), "R16 over Depth16 storage reads the depth texture");
    expect_red(v4, 0.75f, 1.0f / 65535, "R16 twin reads the depth");
    // 5. Not twins: an IMAGE colour texture, a CPU-visible pool, another size, another offset: each its own texture
    tex_t d5 = tex(&g_pool, 97051, NVN_FORMAT_DEPTH32F, 64, 32, C, 24 << 20); mtl_tex_init(&d5); tex_mtl(&d5);
    tex_t img = tex(&g_pool, 97052, NVN_FORMAT_R32F, 64, 32, NVN_TEXTURE_FLAGS_IMAGE, 24 << 20), big = tex(&g_pool, 97053, NVN_FORMAT_R32F, 128, 32, 0, 24 << 20),
          off = tex(&g_pool, 97054, NVN_FORMAT_R32F, 64, 32, 0, (24 << 20) + 65536);
    tex_t dc = tex(&g_cpu_pool, 97055, NVN_FORMAT_DEPTH32F, 64, 32, C, 0), cc = tex(&g_cpu_pool, 97056, NVN_FORMAT_R32F, 64, 32, 0, 0);
    tex_t *no[] = {&img, &big, &off, &cc}; const char *why[] = {"an IMAGE colour texture keeps its own texture", "a colour texture of another size keeps its own texture",
                                                               "a colour texture at another offset keeps its own texture", "a CPU-visible pool's colour texture keeps its own texture"};
    mtl_tex_init(&dc); tex_mtl(&dc);
    for (int i = 0; i < 4; i++) { mtl_tex_init(no[i]); mtl_reg_tex(710 + i, no[i], NULL); id<MTLTexture> v = by_id(710 + i);
        CHECK(v && root(v).pixelFormat == MTLPixelFormatR32Float, why[i]); }
    // an ID whose view names another format (R32UI) reads the colour texture's own storage
    tex_t vf = tex(&g_pool, 97057, NVN_FORMAT_R32F, 64, 32, 0, 24 << 20); mtl_tex_init(&vf);
    view_t other = {.set_format = 1, .format = NVN_FORMAT_R32UI}; mtl_reg_tex(714, &vf, &other);
    id<MTLTexture> vv = by_id(714);
    CHECK(vv && root(vv) != tex_mtl(&d5) && root(vv).pixelFormat != MTLPixelFormatDepth32Float, "an ID with a view of another format keeps the colour texture's own storage");
    CHECK(g_dtwin_n >= 3, "the twins read are counted");
    printf("depth twins: %d checks, %d failed\n", checks, fails);
    return fails != 0;
} }
