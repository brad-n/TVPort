// DM_NVN_VIEW_KEEP: the view of a retired registration (a texture ID whose texture the game has finalized) lives for a transient epoch of whole frames, not one submission.
// Within the epoch the pool table keeps the view's entry without taking the ID again and no new view is made; the epoch ends at the end of the first submission a frame later,
// the view goes then (behind that submission's fence), and the next submission's table, stale now, takes the ID again before a draw can read it. A registration of the ID with
// another texture inside the epoch is taken at once. With the switch off a view lasts one submission, as before (t_pool_notes)
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
static uint8_t *pages(void) { uint8_t *m = mmap(NULL, LEN, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); if (m == MAP_FAILED) abort(); return m; }
// The 2D float texture table at base 0 in a submission of its own (frame f), as a draw that reads it would ask
static id<MTLBuffer> table(uint64_t f) {
    mtl_set_frame(f); mtl_sub_begin();
    __unsafe_unretained id<MTLBuffer> b = nil;
    os_unfair_lock_lock(&g_rmu); pool_gpu(0, MTLTextureType2D, NVN_DPF_FLOAT, 0, &b); os_unfair_lock_unlock(&g_rmu);
    id<MTLBuffer> held = b;
    CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull), "the submission completed");
    return held;
}
static pool_snap *snap(void) { for (int k = 0; k < POOL_SNAPS; k++) if (g_psnap[k].buf && !g_psnap[k].samp && g_psnap[k].dtt == MTLTextureType2D && g_psnap[k].dpf == NVN_DPF_FLOAT && !g_psnap[k].base) return &g_psnap[k]; return NULL; }
static uint64_t entry(id<MTLBuffer> b, int i) { return ((const uint64_t *)((const uint8_t *)b.contents + DMSH_POOL_HEAD))[i]; }
static uint64_t dummy_of(id<MTLBuffer> b) { return entry(b, (int)*(const uint32_t *)b.contents); }
// A CPU-written texture of its own (WriteTexels) on pool p at offset off, registered as ID id_
static void cpu_tex(NVNtexture *t, NVNtextureBuilder *tb, pool_t *p, ptrdiff_t off, int id_, uint8_t fill) {
    h_nvnTextureBuilderSetStorage(tb, (NVNmemoryPool *)p, off);
    CHECK(h_nvnTextureInitialize(t, tb), "texture initialized");
    uint8_t px[64]; memset(px, fill, sizeof px); NVNcopyRegion r = {0, 0, 0, 4, 4, 1}; h_nvnTextureWriteTexels(t, NULL, &r, px);
    mtl_reg_tex(id_, (const tex_t *)t, NULL);
}

int main(void) { @autoreleasepool {
    setenv("DM_NVN_VIEW_KEEP", "1", 1);
    mtl_init();
    CHECK(view_keep() == 1, "the switch is read");
    uint8_t *ma = pages();
    pool_t a = {0}; pool_builder_t pb = {.mem = ma, .size = LEN, .flags = NVN_MEMORY_POOL_FLAGS_CPU_CACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED};
    CHECK(h_nvnMemoryPoolInitialize((NVNmemoryPool *)&a, (const NVNmemoryPoolBuilder *)&pb), "pool initialized");
    NVNtextureBuilder tb = {0}; h_nvnTextureBuilderSetDefaults(&tb);
    h_nvnTextureBuilderSetWidth(&tb, 4); h_nvnTextureBuilderSetHeight(&tb, 4); h_nvnTextureBuilderSetFormat(&tb, NVN_FORMAT_RGBA8);
    // the swizzle makes the ID's entry a view of the texture (tex_by_id), as Ocarina of Time's are
    NVNtexture t3 = {0}; h_nvnTextureBuilderSetSwizzle(&tb, NVN_TEXTURE_SWIZZLE_B, NVN_TEXTURE_SWIZZLE_G, NVN_TEXTURE_SWIZZLE_R, NVN_TEXTURE_SWIZZLE_A);
    cpu_tex(&t3, &tb, &a, 0, 3, 0x40);
    id<MTLBuffer> b0 = table(100);
    CHECK(entry(b0, 3) != dummy_of(b0), "ID 3 holds its texture");

    // Finalized: the ID's view goes now (treg_retire_serial), and the next lookup makes a transient one
    h_nvnTextureFinalize(&t3);
    uint64_t views = g_xs[XS_VIEW], ep0 = g_trans_ep;
    id<MTLBuffer> b1 = table(100);
    CHECK(g_treg[3].retired && entry(b1, 3) != dummy_of(b1), "the finalized texture's ID resolves");
    CHECK(g_xs[XS_VIEW] == views + 1, "one view made for it");
    CHECK(g_treg[3].view && g_treg[3].transient_sub == ep0 && g_trans_ep == ep0, "its view outlives the submission: the epoch goes on in the same frame");
    CHECK(snap()->sub == ep0, "the table names the epoch");
    uint64_t rid = entry(b1, 3), schg = g_stat_pool_schg, builds = g_stat_pool_builds, drops = g_xs[XS_TRANS_DROP];

    // More submissions in the same frame: nothing to take again, no view made, the same buffer
    id<MTLBuffer> b2 = table(100), b3 = table(100);
    CHECK(b2 == b1 && b3 == b1 && entry(b3, 3) == rid, "the table stands with the same entry");
    CHECK(g_stat_pool_schg == schg && g_stat_pool_builds == builds && g_xs[XS_VIEW] == views + 1, "no ID taken again, no view made");
    CHECK(g_xs[XS_TRANS_DROP] == drops && g_treg[3].view, "the view is kept");

    // The next frame: its first submission still finds the view (the table is not stale) and ends the epoch, which drops the view behind its fence
    id<MTLBuffer> b4 = table(101);
    CHECK(b4 == b1 && entry(b4, 3) == rid && g_stat_pool_schg == schg, "the first submission of the next frame uses the kept view");
    CHECK(!g_treg[3].view && g_xs[XS_TRANS_DROP] == drops + 1 && g_trans_ep == ep0 + 1, "and ends the epoch: the view went");
    // The table names a view that went: the next submission takes the ID again before anything reads it
    id<MTLBuffer> b5 = table(101);
    CHECK(g_stat_pool_schg == schg + 1 && g_stat_pool_builds == builds, "the next submission takes the retired ID again without building the table");
    CHECK(entry(b5, 3) != dummy_of(b5) && g_treg[3].view && g_treg[3].view_rid == entry(b5, 3), "the entry is the ID's new view");
    CHECK(g_xs[XS_VIEW] == views + 2 && snap()->sub == ep0 + 1, "made once for the new epoch");

    // The ID registered with another texture inside the epoch: taken at once, from the registration's note
    NVNtexture t4 = {0}; h_nvnTextureBuilderSetSwizzle(&tb, NVN_TEXTURE_SWIZZLE_R, NVN_TEXTURE_SWIZZLE_R, NVN_TEXTURE_SWIZZLE_R, NVN_TEXTURE_SWIZZLE_ONE);
    cpu_tex(&t4, &tb, &a, 65536, 3, 0x80);
    id<MTLBuffer> b6 = table(101);
    CHECK(!g_treg[3].retired && entry(b6, 3) != dummy_of(b6) && entry(b6, 3) != entry(b5, 3), "the new texture replaces the kept view at once");
    CHECK(g_treg[3].view_rid == entry(b6, 3), "the entry is the new registration's view");

    // Submissions without a new frame (a load that presents nothing): the epoch still ends after 64 of them a frame of keep
    h_nvnTextureFinalize(&t4);
    table(150);   // a later frame: the epoch begun in frame 101 ends at this submission's end
    uint64_t ep1 = g_trans_ep; table(150);
    CHECK(g_treg[3].retired && g_treg[3].view && g_trans_ep == ep1, "a new epoch for the finalized texture's view");
    int subs = 1; while (g_trans_ep == ep1 && subs < 100) { table(150); subs++; }
    CHECK(g_trans_ep == ep1 + 1 && subs <= 65 && !g_treg[3].view, "without a new frame the epoch ends after 64 submissions");

    // Off: a view of a retired registration lasts one submission, as before
    g_view_keep = 0;
    id<MTLBuffer> b7 = table(102);
    CHECK(g_treg[3].retired && entry(b7, 3) != dummy_of(b7) && !g_treg[3].view, "switch off: the view goes at the submission's end");
    schg = g_stat_pool_schg;
    id<MTLBuffer> b8 = table(102);
    CHECK(g_stat_pool_schg == schg + 1 && entry(b8, 3) != dummy_of(b8), "and the next submission takes the ID again");

    mtl_reg_tex(3, NULL, NULL); table(103);
    h_nvnMemoryPoolFinalize((NVNmemoryPool *)&a);
    defer_drain(); munmap(ma, LEN);
    printf("t_view_keep: %d checks, %d failed\n", checks, failed); return failed != 0;
} }
