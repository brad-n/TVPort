// DM_NVN_TEX_PURGE (nvn_mtl.m, "Purgeable reloadable textures"): a packaged texture nothing has used for a while leaves the residency set and becomes Volatile / Empty, and comes back byte-exact
// when it is used. Runs on the Mac GPU with DM_TEST_NO_BC=1 and the ASTC cache of t_astc_upload (BC textures are ASTC here, as on the Apple TV), so a restore goes through the upload path
// of the ASTC pack and cache. Memory pressure is faked (DM_NVN_TEX_PURGE_FAKE_AVAIL_MB: the Mac has no os_proc_available_memory).
#define main t_astc_upload_main
#include "t_astc_upload.m"
#undef main
#include "../nvn/nvn_dirty.h"
static tex_t tfixture(nvn_texdesc d, void **mem) { tex_t t = fixture(d, mem); nvn_dirty_add_range(*mem, (t.L.size + getpagesize() - 1) & ~(size_t)(getpagesize() - 1)); return t; }   // the pool tracked by dirty pages, as the game's are
static void tfree(void *mem) { nvn_dirty_remove_range(mem); pthread_mutex_lock(&g_gws_mu); g_ngws = 0; pthread_mutex_unlock(&g_gws_mu); release_fixture(mem); }
static NvPkg *pkg_of(const tex_t *t) { id o = tex_get(t->serial); return [o isKindOfClass:[NvPkg class]] ? o : nil; }
static int in_set(id<MTLTexture> t) { pthread_mutex_lock(&g_res_mu); int r = [g_res_objects containsObject:t]; pthread_mutex_unlock(&g_res_mu); return r; }
static id<MTLTexture> resolve(tex_t *t) {   // a direct bind: tex_mtl_ outside a table walk
    mtl_sub_begin(); id<MTLTexture> mt = tex_mtl(t);
    CHECK(mtl_wait(mtl_sub_commit(), 20000000000ull), "the submission completes");
    return mt;
}
static void step(uint64_t frame) {   // one submission's sweep at that frame
    atomic_store(&g_cur_frame, frame); pu_step();
}
static void settle(void) { mtl_sub_begin(); mtl_wait(mtl_sub_commit(), 20000000000ull); }   // g_done catches up with g_fence
typedef struct { float *lv[8]; uint32_t w[8], h[8]; unsigned n; } snapshot;
static snapshot snap(id<MTLTexture> mt) {
    snapshot s = {.n = (unsigned)mt.mipmapLevelCount};
    for (unsigned l = 0; l < s.n; l++) { s.w[l] = MAX((uint32_t)mt.width >> l, 1u); s.h[l] = MAX((uint32_t)mt.height >> l, 1u); s.lv[l] = read_level(mt, l, s.w[l], s.h[l]); }
    return s;
}
static int same(const snapshot *a, const snapshot *b) {
    if (a->n != b->n) return 0;
    for (unsigned l = 0; l < a->n; l++) if (memcmp(a->lv[l], b->lv[l], (size_t)a->w[l] * a->h[l] * 16)) return 0;
    return 1;
}
static void snap_free(snapshot *s) { for (unsigned l = 0; l < s->n; l++) free(s->lv[l]); }
static void case_one(uint32_t format, const char *name, unsigned seed) {
    printf("-- %s\n", name);
    void *mem; nvn_texdesc d = {.target = NVN_TEXTURE_TARGET_2D, .format = format, .width = 1024, .height = 512, .depth = 1, .levels = 5, .samples = 1};
    g_seed_base = seed; tex_t t = tfixture(d, &mem);
    uint64_t f = 1000 + seed * 100;
    atomic_store(&g_cur_frame, f);
    id<MTLTexture> mt = resolve(&t); NvPkg *pk = pkg_of(&t);
    CHECK(mt && pk && pk->pu, "%s: a packaged texture with a purge record", name); if (!mt || !pk || !pk->pu) { tfree(mem); return; }
    NvPurge *p = (NvPurge *)pk->pu;
    CHECK(pk->span != NULL && pu_eligible(pk, p), "%s: reloadable (dirty-tracked, not GPU-written)", name);
    snapshot before = snap(mt);
    g_pu.idle = 3; g_pu.idle_empty = 4; g_pu.keep = 0; g_pu.min_bytes = 0;
    g_pu_fake_mb = 100;   // short of memory
    // used a moment ago: nothing happens
    step(f + 1); step(f + 2);
    CHECK(p->state == PU_LIVE && in_set(mt), "%s: not idle yet, it stays", name);
    // idle: pending first (the tables show the dummy), then empty
    uint64_t base_reload = g_pu_reload_n, base_back = g_pu_back_n;
    step(f + 10);
    CHECK(p->state == PU_PENDING && in_set(mt), "%s: idle -> pending, still resident", name);
    settle(); step(f + 11);
    CHECK(p->state == PU_EMPTY && !in_set(mt), "%s: then empty and out of the residency set", name);
    { unsigned long ps = (unsigned long)[mt setPurgeableState:MTLPurgeableStateKeepCurrent]; CHECK(ps == MTLPurgeableStateEmpty, "%s: Metal agrees it is empty (state %lu, alloc %lu)", name, ps, (unsigned long)mt.allocatedSize); }
    // a table walk is not a use
    g_pu_walk = 1; id<MTLTexture> w = tex_mtl(&t); g_pu_walk = 0;
    CHECK(w == nil && p->state == PU_EMPTY, "%s: a pool table walk reads the dummy and leaves it purged", name);
    // a direct bind brings it back, filled again from the guest's bytes / the ASTC cache, in the same texture
    atomic_store(&g_cur_frame, f + 20);
    id<MTLTexture> mt2 = resolve(&t);
    CHECK(mt2 == mt && p->state == PU_LIVE && in_set(mt2), "%s: used again: the same texture, live, resident", name);
    CHECK([mt2 setPurgeableState:MTLPurgeableStateKeepCurrent] == MTLPurgeableStateNonVolatile, "%s: non-volatile", name);
    CHECK(g_pu_reload_n == base_reload + 1 && g_pu_back_n == base_back + 1, "%s: one re-upload", name);
    snapshot after = snap(mt2);
    CHECK(same(&before, &after), "%s: every level is byte-exact after the restore", name);
    snap_free(&after);
    // volatile only (no empty): contents intact, no re-upload
    g_pu.idle_empty = 0;
    step(f + 30); settle(); step(f + 31);
    CHECK(p->state == PU_VOLATILE && !in_set(mt), "%s: volatile and out of the set", name);
    base_reload = g_pu_reload_n;
    atomic_store(&g_cur_frame, f + 40);
    mt2 = resolve(&t);
    CHECK(mt2 == mt && p->state == PU_LIVE && in_set(mt2), "%s: volatile -> used again", name);
    after = snap(mt2);
    CHECK(same(&before, &after), "%s: byte-exact after volatile (%s)", name, g_pu_reload_n == base_reload ? "contents kept" : "the system had taken them: re-uploaded");
    snap_free(&after);
    // used while pending: cancelled, no state change but live
    step(f + 50); CHECK(p->state == PU_PENDING, "%s: pending again", name);
    uint64_t c0 = g_pu_cancel_n; atomic_store(&g_cur_frame, f + 51); mt2 = tex_mtl(&t);   /* no new submission in between: it would finish the pending purge */
    CHECK(mt2 == mt && p->state == PU_LIVE && g_pu_cancel_n == c0 + 1 && in_set(mt), "%s: a use while pending cancels it (state %d cancels %llu/%llu)", name, p->state, (unsigned long long)g_pu_cancel_n, (unsigned long long)c0);
    // the most recent that fit the keep budget stay
    g_pu.keep = 1ull << 30; p->uframe = f + 56; step(f + 60);
    CHECK(p->state == PU_LIVE, "%s: kept as recent within the budget", name);
    g_pu.keep = 0; p->uframe = f + 51;
    // the GPU wrote this storage: not the content, never purged
    pthread_mutex_lock(&g_gws_mu); gws_set(p->lo, p->hi); pthread_mutex_unlock(&g_gws_mu);
    CHECK(!pu_eligible(pk, p), "%s: GPU-written storage is not eligible", name);
    step(f + 70); step(f + 71);
    CHECK(p->state == PU_LIVE && in_set(mt), "%s: and stays", name);
    snap_free(&before);
    defer_obj_release(mt); tfree(mem);
}
int main(void) { @autoreleasepool {
    char dir[] = "/tmp/t_tex_purge.XXXXXX"; if (!mkdtemp(dir)) { perror("mkdtemp"); return 1; }
    const char *mode = getenv("T_PURGE_MODE");
    setenv("DM_TEST_NO_BC", "1", 1); setenv("DM_NVN_ASTC_MISS", "sync", 1); setenv("DM_NVN_BC_ASTC", "4", 1); setenv("DM_NVN_ASTC_CACHE", dir, 1); unsetenv("DM_NVN_ASTC_CACHE_RO");
    setenv("DM_NVN_TEX_PURGE", "1", 1);
    if (mode && !strcmp(mode, "release")) {   // the anonymous guest given back: nothing to rebuild a texture from
        setenv("DM_TEX_RELEASE", "2", 1); mtl_init();
        CHECK(!pu_on(), "DM_TEX_RELEASE with the anonymous guest turns the purge off");
        printf("tex purge (release): %d checks, %d failures\n", checks, failed); return failed ? 1 : 0;
    }
    if (mode && !strcmp(mode, "off")) {
        unsetenv("DM_NVN_TEX_PURGE"); mtl_init();
        void *mem; nvn_texdesc d = {.target = NVN_TEXTURE_TARGET_2D, .format = 0x44, .width = 64, .height = 48, .depth = 1, .levels = 1, .samples = 1};
        tex_t t = tfixture(d, &mem); id<MTLTexture> mt = resolve(&t); NvPkg *pk = pkg_of(&t);
        CHECK(!pu_on() && mt && pk && !pk->pu, "off by default: no purge record");
        defer_obj_release(mt); tfree(mem);
        printf("tex purge (off): %d checks, %d failures\n", checks, failed); return failed ? 1 : 0;
    }
    setenv("DM_NVN_TEX_PURGE_EVERY", "1", 1);
    mtl_init();
    CHECK(pu_on(), "DM_NVN_TEX_PURGE=1 turns it on");
    case_one(0x44, "BC3 (ASTC 4x4)", 1);
    case_one(0x4e, "BC7 sRGB (ASTC 4x4)", 2);
    case_one(0x42, "BC1 (ASTC 4x4)", 3);
    case_one(0x79, "native ASTC 4x4", 4);
    {   // hysteresis: below LOW the purge starts, between LOW and HIGH it goes on, at HIGH it stops
        void *mem; nvn_texdesc d = {.target = NVN_TEXTURE_TARGET_2D, .format = 0x44, .width = 1024, .height = 512, .depth = 1, .levels = 2, .samples = 1};
        g_seed_base = 9; tex_t t = tfixture(d, &mem); uint64_t f = 5000; atomic_store(&g_cur_frame, f);
        id<MTLTexture> mt = resolve(&t); NvPurge *p = (NvPurge *)pkg_of(&t)->pu;
        g_pu.idle = 3; g_pu.keep = 0; g_pu.min_bytes = 0; g_pu.idle_empty = 0;
        g_pu_pressure = 0; g_pu_fake_mb = 950; step(f + 10);
        CHECK(!g_pu_pressure && p->state == PU_LIVE, "950 MB available, not short before: no purge");
        g_pu_fake_mb = 800; step(f + 11);
        CHECK(g_pu_pressure && p->state == PU_PENDING, "800 MB available (< 896): the purge starts");
        settle(); g_pu_fake_mb = 950; step(f + 12);
        CHECK(g_pu_pressure && p->state == PU_VOLATILE, "950 MB (between 896 and 1024): the purge goes on");
        g_pu_fake_mb = 1100; step(f + 13);
        CHECK(!g_pu_pressure, "1100 MB (>= 1024): it stops");
        defer_obj_release(mt); tfree(mem);
    }
    mtl_drain();
    { char cmd[128]; snprintf(cmd, sizeof cmd, "rm -rf %s", dir); system(cmd); }
    printf("tex purge: %d checks, %d failures\n", checks, failed);
    return failed ? 1 : 0;
}}
