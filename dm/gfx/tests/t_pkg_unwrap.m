// A packaged texture's serial holds its NvPkg (the uploaded texture and its storage record), not a Metal texture. Resolved again while tex_from_storage says no (packaged 0), tex_mtl_ handed
// that NvPkg out as the texture, and the view code called texture methods on it: "-[NvPkg buffer]: unrecognized selector" in tex_by_id (Ocarina of Time, learning a song on the ocarina;
// reported by a community fork, ninboy-hat-for-macos). One way there: nvnMemoryPoolFinalize drops the pool's CPU-written classifications (cpu_tex_drop_pool) while the pool's magic is
// still set, and the replay thread resolves a texture of that pool in between. Here that state is made directly: a CPU-written texture resolved once (an NvPkg), its classification
// dropped. Every exit must give the uploaded Metal texture: tex_mtl, tex_made, treg_tex, and tex_by_id's view of it, also for a retired ID whose kept view (DM_NVN_VIEW_KEEP) is checked again
#define nvn_game_fps nvn_game_fps_mtl_default
#include "../nvn/nvn_mtl.m"
#undef nvn_game_fps
#define g_ft g_ft_hle
#include "../nvn/hle_nvn.c"
#undef g_ft
uint64_t g_t0_ns;
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } } while (0)

enum { LEN = 1 << 20 };
static int is_tex(id o) { return o && ![o isKindOfClass:[NvPkg class]] && [o conformsToProtocol:@protocol(MTLTexture)]; }

int main(void) { @autoreleasepool {
    mtl_init();
    uint8_t *ma = mmap(NULL, LEN, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    pool_t a = {0}; pool_builder_t pb = {.mem = ma, .size = LEN, .flags = NVN_MEMORY_POOL_FLAGS_CPU_CACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED};
    CHECK(h_nvnMemoryPoolInitialize((NVNmemoryPool *)&a, (const NVNmemoryPoolBuilder *)&pb), "pool initialized");
    NVNtextureBuilder tb = {0}; h_nvnTextureBuilderSetDefaults(&tb);
    h_nvnTextureBuilderSetWidth(&tb, 4); h_nvnTextureBuilderSetHeight(&tb, 4); h_nvnTextureBuilderSetFormat(&tb, NVN_FORMAT_RGBA8);
    h_nvnTextureBuilderSetSwizzle(&tb, NVN_TEXTURE_SWIZZLE_B, NVN_TEXTURE_SWIZZLE_G, NVN_TEXTURE_SWIZZLE_R, NVN_TEXTURE_SWIZZLE_A);   // the ID's entry is a view (tex_by_id)
    h_nvnTextureBuilderSetStorage(&tb, (NVNmemoryPool *)&a, 0);
    NVNtexture tx = {0}; CHECK(h_nvnTextureInitialize(&tx, &tb), "texture initialized");
    uint8_t px[64]; memset(px, 0x5a, sizeof px); NVNcopyRegion r = {0, 0, 0, 4, 4, 1}; h_nvnTextureWriteTexels(&tx, NULL, &r, px);   // CPU-written: packaged
    const tex_t *t = (const tex_t *)&tx; mtl_reg_tex(5, t, NULL);

    mtl_sub_begin();
    os_unfair_lock_lock(&g_rmu); id<MTLTexture> first = tex_mtl(t), v0 = tex_by_id(5); os_unfair_lock_unlock(&g_rmu);
    NvPkg *pk = [tex_get(t->serial) isKindOfClass:[NvPkg class]] ? tex_get(t->serial) : nil;
    CHECK(pk && is_tex(first) && first == (pk->view ? pk->view : pk->tex), "a CPU-written texture resolves through its NvPkg to the uploaded texture");
    CHECK(is_tex(v0) && v0.parentTexture == first, "its ID's entry is a view of it");
    CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull), "the upload completed");

    // The window inside nvnMemoryPoolFinalize: the classification gone, the pool's magic still set
    cpu_tex_drop_pool(&a);
    CHECK(!tex_from_storage(t) && a.magic == MAGIC('P', 'O', 'O', 'L'), "no longer CPU-written, its pool still there");
    mtl_sub_begin();
    os_unfair_lock_lock(&g_rmu);
    id<MTLTexture> again = tex_mtl(t), made = tex_made(t);
    CHECK(is_tex(again) && again == first, "tex_mtl gives the uploaded texture, not the NvPkg");
    CHECK(is_tex(made) && made == first, "tex_made too");
    if (is_tex(again)) {   // the crash itself: the ID's view made again on what tex_mtl gives (base.buffer, base.pixelFormat, newTextureView...)
        g_treg[5].view_ser = 0;
        id<MTLTexture> base = treg_tex(&g_treg[5]), v1 = tex_by_id(5);
        CHECK(is_tex(base) && base == first, "treg_tex gives the uploaded texture");
        CHECK(is_tex(v1) && v1.parentTexture == first, "tex_by_id makes the ID's view on it");
    }
    os_unfair_lock_unlock(&g_rmu);
    CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull), "the submission completed");

    // A retired ID (the texture finalized, its descriptor still registered) whose view DM_NVN_VIEW_KEEP keeps, checked again in the same window
    h_nvnTextureFinalize(&tx);
    mtl_sub_begin(); os_unfair_lock_lock(&g_rmu); id<MTLTexture> v2 = tex_by_id(5); os_unfair_lock_unlock(&g_rmu);
    CHECK(g_treg[5].retired && is_tex(v2), "the retired ID resolves");
    CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull), "submission completed");
    cpu_tex_drop_pool(&a);
    mtl_sub_begin(); os_unfair_lock_lock(&g_rmu);
    if (g_treg[5].view) g_treg[5].view_ser = 0;   // a serial note sends it down the slow path
    id<MTLTexture> v3 = is_tex(tex_mtl(&g_treg[5].t)) ? tex_by_id(5) : nil;   // the registration's snapshot: the finalized object itself is no longer valid
    os_unfair_lock_unlock(&g_rmu);
    CHECK(is_tex(v3), "its kept view checked again gives a texture");
    CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull), "submission completed");

    mtl_reg_tex(5, NULL, NULL);
    h_nvnMemoryPoolFinalize((NVNmemoryPool *)&a); defer_drain(); munmap(ma, LEN);
    printf("t_pkg_unwrap: %d checks, %d failed\n", checks, failed); return failed != 0;
} }
