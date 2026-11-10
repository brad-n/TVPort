// A packaged texture's re-upload spare (NvPkg spare: the texture its last re-upload replaced) goes once DM_NVN_PKG_SPARE_FRAMES frames (default 120) pass with no re-upload taking it:
// the texture's next clean lookup releases it, and the next rewrite makes a new texture; a rewrite within the window still takes the spare (a texture rewritten every frame keeps
// alternating between two); with DM_NVN_PKG_SPARE_FRAMES=0 a spare stays for good, as before. Every round reads back what the CPU wrote
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } } while (0)
static void finish(void) { CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull), "the submission completes"); }
enum { W = 64, H = 64 };
static tex_t g_t; static pool_t g_pool; static void *g_mem;
static void write_round(unsigned round) {   // the CPU rewrites the texture's storage (dirty pages), as a streamed texture is
    dm_guest_write_prepare(g_mem, g_pool.size);
    uint32_t px[W * H]; for (unsigned i = 0; i < W * H; i++) px[i] = 0x01020304u * (round + 1) + i;
    CHECK(!nvn_swizzle(&g_t.d, 0, 0, px, W * 4, g_t.mem), "the reference swizzle succeeds");
}
static id<MTLTexture> look(uint64_t frame) { atomic_store(&g_cur_frame, frame); mtl_sub_begin(); id<MTLTexture> m = tex_mtl(&g_t); finish(); return m; }
static int reads(id<MTLTexture> m, unsigned round) {
    id<MTLBuffer> rb = [g_dev newBufferWithLength:W * H * 4 options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb = q_cb(); id<MTLBlitCommandEncoder> ce = [cb blitCommandEncoder];
    [ce copyFromTexture:m sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(W, H, 1) toBuffer:rb destinationOffset:0 destinationBytesPerRow:W * 4 destinationBytesPerImage:W * H * 4];
    [ce endEncoding]; [cb commit]; [cb waitUntilCompleted];
    const uint32_t *p = rb.contents; for (unsigned i = 0; i < W * H; i++) if (p[i] != 0x01020304u * (round + 1) + i) return 0;
    return 1;
}
static NvPkg *pkg(void) { id o = tex_get(g_t.serial); return [o isKindOfClass:[NvPkg class]] ? o : nil; }
int main(void) { @autoreleasepool {
    mtl_init();
    const char *e = getenv("DM_NVN_PKG_SPARE_FRAMES"); int keep_all = e && !strcmp(e, "0");
    CHECK(spare_frames() == (keep_all ? 0 : 120), "the switch: 120 frames unless DM_NVN_PKG_SPARE_FRAMES says otherwise");
    g_t = (tex_t){.magic = MAGIC('T', 'E', 'X', 0), .has_layout = 1, .serial = 77100};
    g_t.d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = NVN_FORMAT_RGBA8, .width = W, .height = H, .depth = 1, .levels = 1, .samples = 1}; nvn_tex_layout(&g_t.d, &g_t.L);
    size_t size = (g_t.L.size + getpagesize() - 1) & ~(size_t)(getpagesize() - 1);
    if (posix_memalign(&g_mem, getpagesize(), size)) abort(); memset(g_mem, 0, size);
    g_pool = (pool_t){.magic = MAGIC('P', 'O', 'O', 'L'), .mem = g_mem, .size = size, .flags = NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED};
    g_t.pool = &g_pool; g_t.mem = g_mem; mtl_pool_add(g_mem, size); nvn_dirty_add_range(g_mem, size);
    write_round(0); id<MTLTexture> first = look(1000);
    CHECK(first && reads(first, 0) && pkg() && !pkg()->spare, "uploaded once: no spare");
    write_round(1); id<MTLTexture> second = look(1001);
    CHECK(second && second != first && reads(second, 1), "a rewrite is re-uploaded into another texture");
    CHECK(pkg() && pkg()->spare == first, "the one it replaced is kept as the spare");
    write_round(2); id<MTLTexture> third = look(1002);
    CHECK(third == first && reads(third, 2), "a rewrite soon after takes the spare");
    CHECK(pkg() && pkg()->spare == second, "and the one it replaced is the spare now");
    CHECK(look(1002 + 60) == third && pkg()->spare == second, "a clean lookup within the window keeps the spare");
    uint64_t drops = atomic_load(&g_spare_drops);
    CHECK(look(1002 + 200) == third && reads(third, 2), "a clean lookup after the window still draws the texture");
    if (keep_all) CHECK(pkg()->spare == second && atomic_load(&g_spare_drops) == drops, "with DM_NVN_PKG_SPARE_FRAMES=0 the spare stays");
    else CHECK(pkg()->spare == nil && atomic_load(&g_spare_drops) == drops + 1, "after the window the spare is released");
    write_round(3); id<MTLTexture> fourth = look(1003 + 200);
    CHECK(fourth && fourth != third && reads(fourth, 3), "the next rewrite goes into another texture");
    if (keep_all) CHECK(fourth == second, "the kept spare, with DM_NVN_PKG_SPARE_FRAMES=0");
    else CHECK(fourth != second, "a new one once the spare went");
    CHECK(pkg()->spare == third, "the texture it replaced is the spare again");
    mtl_tex_release(&g_t); mtl_drain(); mtl_alias_drop_pool(&g_pool); nvn_dirty_remove_range(g_mem); mtl_pool_del(g_mem); mtl_drain(); free(g_mem);
    printf("t_pkg_spare (%s): %d checks, %d failed\n", keep_all ? "DM_NVN_PKG_SPARE_FRAMES=0" : "default", checks, failed);
    return failed != 0;
} }
