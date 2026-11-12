// Lossy render targets (nvn_mtl.m rl_apply, DM_NVN_RT_LOSSY; ported from Fasen24-AI/swordboiMacNative af07b1df5b): with the switch on, on a GPU of Metal family Apple8 or later, the game's
// own targets (COMPRESSIBLE in a GPU-only pool) of the listed colour formats are made with lossy compression, in their recycled placement heap at the lossy size; a freed one's heap is taken
// by the next. Everything else stays lossless without Metal aborting on it: formats Metal cannot compress (R11G11B10F, depth), integer, snorm and 32-bit formats, images (shader writes),
// multisample and 3D targets, small ones, CPU-visible pools, textures without COMPRESSIBLE. A lossy target that later needs shader writes is copied into a lossless one; its sRGB twin is a
// view of it. One the game carries across frames (read with an earlier frame's content and written again, over and over) becomes lossless, and so does its storage. Unset, or on a GPU
// without lossy compression (`nogpu`: the family check answers no), every target is lossless as before.
// ./t_rt_lossy [off|nogpu]
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } } while (0)

static tex_t target(pool_t *pool, uint64_t serial, uint64_t off, unsigned format, unsigned w, unsigned h) {
    tex_t t = {.magic = MAGIC('T','E','X',0), .serial = serial, .pool = pool, .mem = pool->mem + off, .off = (int64_t)off};
    t.d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = format, .flags = NVN_TEXTURE_FLAGS_COMPRESSIBLE, .width = w, .height = h, .depth = 1, .levels = 1, .samples = 1};
    nvn_tex_layout(&t.d, &t.L); return t;
}
static void settle(void) {   // the released textures' fences pass and the deferred releases run (as in t_rt_recycle)
    mtl_sub_commit(); mtl_drain(); mtl_sub_begin(); mtl_sub_commit(); mtl_drain();
    dispatch_sync(g_feedback_q, ^{}); defer_drain(); mtl_sub_begin();
}
static unsigned waiting(void) { os_unfair_lock_lock(&g_rh_lk); unsigned n = g_rh_n; os_unfair_lock_unlock(&g_rh_lk); return n; }
// Writes the bytes gen gives (one byte at i of a row-major copy) into level 0 of t, through the upload batch, as the host's fills go
static void fill(id<MTLTexture> t, unsigned bpp, uint8_t (^gen)(NSUInteger)) {
    NSUInteger row = t.width * bpp, bytes = row * t.height;
    id<MTLBuffer> b = [g_dev newBufferWithLength:bytes options:MTLResourceStorageModeShared]; uint8_t *p = b.contents; for (NSUInteger i = 0; i < bytes; i++) p[i] = gen(i); res_add(b);
    enc_b_copy_buffer_texture(blit(), b, 0, row, bytes, MTLSizeMake(t.width, t.height, 1), t, 0, 0, MTLOriginMake(0, 0, 0));
    mtl_sub_commit(); mtl_drain(); CHECK(!mtl_last_commit_error(), "the fill completes without GPU error"); res_remove(b); mtl_sub_begin();
}
static id<MTLBuffer> readback(id<MTLTexture> t, unsigned bpp) {
    NSUInteger row = t.width * bpp, bytes = row * t.height;
    id<MTLBuffer> b = [g_dev newBufferWithLength:bytes options:MTLResourceStorageModeShared]; res_add(b);
    enc_b_copy_texture_buffer(blit(), t, 0, 0, MTLOriginMake(0, 0, 0), MTLSizeMake(t.width, t.height, 1), b, 0, row, bytes);
    mtl_sub_commit(); mtl_drain(); CHECK(!mtl_last_commit_error(), "the read completes without GPU error"); res_remove(b); mtl_sub_begin();
    return b;
}
static int all_bytes(id<MTLTexture> t, unsigned bpp, uint8_t v) { id<MTLBuffer> b = readback(t, bpp); const uint8_t *p = b.contents; for (NSUInteger i = 0; i < b.length; i++) if (p[i] != v) return 0; return 1; }
static int lossy(id<MTLTexture> t) { return t && t.compressionType == MTLTextureCompressionTypeLossy; }

int main(int argc, char **argv) { @autoreleasepool {
    const char *mode = argc > 1 ? argv[1] : "on"; int nogpu = !strcmp(mode, "nogpu");
    if (strcmp(mode, "off")) setenv("DM_NVN_RT_LOSSY", "1", 1); else unsetenv("DM_NVN_RT_LOSSY");
    mtl_init();
    if (nogpu) g_rl_gpu = 0;   // a GPU without lossy compression (before Apple8: the M1, the A12 Apple TV 4K)
    int apple8 = [g_dev supportsFamily:MTLGPUFamilyApple8], want = strcmp(mode, "off") && !nogpu && apple8, rh = sw_on(rh_mode());
    if (!apple8 && !nogpu && strcmp(mode, "off")) puts("t_rt_lossy: this GPU has no lossy compression (Apple8): every target is expected lossless");
    void *mem = NULL; posix_memalign(&mem, 16384, 128 << 20); memset(mem, 0, 128 << 20);
    pool_t pool = {.magic = MAGIC('P','O','O','L'), .flags = NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS | NVN_MEMORY_POOL_FLAGS_GPU_CACHED | NVN_MEMORY_POOL_FLAGS_COMPRESSIBLE, .mem = mem, .size = 128 << 20};
    mtl_sub_begin();
    // the listed colour formats: lossy, placed in a recycled heap of the lossy size, and zeroed as a new target is
    struct { unsigned f, bpp; const char *name; } ok[] = {{NVN_FORMAT_RGBA8, 4, "RGBA8"}, {NVN_FORMAT_RGBA8_SRGB, 4, "RGBA8_SRGB"}, {NVN_FORMAT_BGRA8, 4, "BGRA8"}, {NVN_FORMAT_RGB10A2, 4, "RGB10A2"},
        {NVN_FORMAT_RGBA16F, 8, "RGBA16F"}, {NVN_FORMAT_RG16F, 4, "RG16F"}, {NVN_FORMAT_R16F, 2, "R16F"}, {NVN_FORMAT_RG8, 2, "RG8"}, {NVN_FORMAT_R8, 1, "R8"}};
    uint64_t made0 = g_rl_n[RL_LOSSY];
    for (unsigned i = 0; i < sizeof ok / sizeof *ok; i++) {
        tex_t t = target(&pool, 96001 + i, (uint64_t)i << 23, ok[i].f, 1280, 720); mtl_tex_init(&t);
        id<MTLTexture> mt = tex_mtl(&t); char label[160];
        snprintf(label, sizeof label, "%s 1280x720: %s", ok[i].name, want ? "lossy" : "lossless"); CHECK(mt && lossy(mt) == want, label);
        if (rh) { snprintf(label, sizeof label, "%s: in a recycled heap of its own", ok[i].name); CHECK(mt.heap != nil, label); }
        MTLTextureDescriptor *d = tex_desc(&t, 0); MTLSizeAndAlign full = [g_dev heapTextureSizeAndAlignWithDescriptor:d];
        if (want) { snprintf(label, sizeof label, "%s: its memory about half the lossless size (%lu of %lu bytes)", ok[i].name, (unsigned long)(rh ? mt.heap.size : mt.allocatedSize), (unsigned long)full.size);
            CHECK((rh ? mt.heap.size : mt.allocatedSize) < full.size * 3 / 4, label); }
        else { snprintf(label, sizeof label, "%s: its memory the lossless size", ok[i].name); CHECK((rh ? mt.heap.size : mt.allocatedSize) >= full.size, label); }
        snprintf(label, sizeof label, "%s: a new target reads zeros", ok[i].name); CHECK(all_bytes(mt, ok[i].bpp, 0), label);
        mt = nil; mtl_tex_release(&t);
    }
    CHECK(g_rl_n[RL_LOSSY] - made0 == (want ? sizeof ok / sizeof *ok : 0), "the decisions count the lossy targets");
    mtl_alias_drop_pool(&pool); settle();
    {   // what a lossy target holds: a constant comes back exact, a smooth gradient close; the same through the recycled heap it leaves
        tex_t a = target(&pool, 96101, 0, NVN_FORMAT_RGBA8, 1280, 720); mtl_tex_init(&a);
        id<MTLTexture> ta = tex_mtl(&a);
        fill(ta, 4, ^uint8_t(NSUInteger i) { (void)i; return 0x5a; });
        CHECK(all_bytes(ta, 4, 0x5a), "a constant fill comes back exact");
        fill(ta, 4, ^uint8_t(NSUInteger i) { NSUInteger px = i / 4, x = px % 1280, y = px / 1280; return (uint8_t)((i & 3) == 3 ? 255 : ((x + 2 * y + 60 * (i & 3)) / 8) & 0xff); });
        id<MTLBuffer> b = readback(ta, 4); const uint8_t *p = b.contents; unsigned worst = 0; double se = 0;
        for (NSUInteger i = 0; i < b.length; i++) { NSUInteger px = i / 4, x = px % 1280, y = px / 1280; int v = (i & 3) == 3 ? 255 : (int)(((x + 2 * y + 60 * (i & 3)) / 8) & 0xff), e = abs((int)p[i] - v); worst = MAX(worst, (unsigned)e); se += e * e; }
        double psnr = se ? 10 * log10(255.0 * 255.0 / (se / b.length)) : 99;
        printf("t_rt_lossy: a smooth RGBA8 gradient comes back with the largest error %u / 255, PSNR %.1f dB (%s)\n", worst, psnr, lossy(ta) ? "lossy" : "lossless");
        CHECK(want ? psnr >= 30 : worst == 0, "a smooth gradient comes back close (lossy) or exact (lossless)");
        __weak id<MTLHeap> h = ta.heap;
        ta = nil; mtl_tex_release(&a); mtl_alias_drop_pool(&pool); settle();
        if (rh) {
            CHECK(h && waiting() >= 1, "the freed lossy target's heap waits");
            os_unfair_lock_lock(&g_rh_lk); for (unsigned i = 0; i < g_rh_n; i++) if ((__bridge id)g_rh[i].heap != h) g_rh[i].t -= RH_IDLE_NS; os_unfair_lock_unlock(&g_rh_lk);
            mtl_sub_commit(); mtl_drain(); mtl_sub_begin();   // rh_trim: the format loop's heaps go, the freed target's stays
            CHECK(h && waiting() == 1, "the others waited too long and went");
            uint64_t re0 = g_rh_reused; tex_t c = target(&pool, 96102, 8 << 20, NVN_FORMAT_RGBA8, 1276, 718); mtl_tex_init(&c);
            id<MTLTexture> tc = tex_mtl(&c);
            CHECK(tc && tc.heap == h && g_rh_reused == re0 + 1 && lossy(tc) == want, "the next target that fits takes it, lossy as well");
            CHECK(all_bytes(tc, 4, 0), "and reads zeros, nothing of the old target");
            tc = nil; mtl_tex_release(&c); mtl_alias_drop_pool(&pool); settle();
        }
    }
    {   // left lossless, and Metal does not abort on any of them
        pool_t cpu = pool; cpu.flags = NVN_MEMORY_POOL_FLAGS_CPU_CACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED | NVN_MEMORY_POOL_FLAGS_COMPRESSIBLE;
        struct { tex_t t; const char *why; } no[13]; unsigned n = 0; uint64_t f0[RL_N]; for (int k = 0; k < RL_N; k++) f0[k] = g_rl_n[k];
        no[n].t = target(&pool, 96201, 0, NVN_FORMAT_R11G11B10F, 1280, 720); no[n++].why = "R11G11B10F (no lossy form in Metal)";
        no[n].t = target(&pool, 96202, 8 << 20, NVN_FORMAT_DEPTH32F, 1280, 720); no[n++].why = "Depth32F";
        no[n].t = target(&pool, 96203, 16 << 20, NVN_FORMAT_DEPTH24_STENCIL8, 1280, 720); no[n++].why = "Depth24Stencil8";
        no[n].t = target(&pool, 96204, 24 << 20, NVN_FORMAT_RGBA8UI, 1280, 720); no[n++].why = "RGBA8UI (integer)";
        no[n].t = target(&pool, 96205, 32 << 20, NVN_FORMAT_RGBA8SN, 1280, 720); no[n++].why = "RGBA8SN (snorm)";
        no[n].t = target(&pool, 96206, 40 << 20, NVN_FORMAT_R32F, 1280, 720); no[n++].why = "R32F (32-bit channels)";
        no[n].t = target(&pool, 96207, 48 << 20, NVN_FORMAT_RGBA16F, 1280, 720); no[n].t.d.flags |= NVN_TEXTURE_FLAGS_IMAGE; no[n++].why = "an image (shader writes)";
        no[n].t = target(&pool, 96208, 64 << 20, NVN_FORMAT_RGBA8, 1280, 720); no[n].t.d.target = NVN_TEXTURE_TARGET_2D_MULTISAMPLE; no[n].t.d.samples = 4; no[n++].why = "4x multisample";
        no[n].t = target(&pool, 96209, 80 << 20, NVN_FORMAT_RGBA8, 128, 128); no[n].t.d.target = NVN_TEXTURE_TARGET_3D; no[n].t.d.depth = 32; no[n++].why = "3D";
        no[n].t = target(&pool, 96210, 88 << 20, NVN_FORMAT_RGBA8, 128, 128); no[n++].why = "128x128 (under 256 KB)";
        no[n].t = target(&pool, 96211, 96 << 20, NVN_FORMAT_RGBA8, 1280, 720); no[n].t.d.flags = 0; no[n++].why = "without COMPRESSIBLE";
        no[n].t = target(&cpu, 96212, 0, NVN_FORMAT_RGBA8, 1280, 720); no[n++].why = "in a CPU-visible pool";
        no[n].t = target(&pool, 96213, 104 << 20, NVN_FORMAT_RGBA8, 1280, 720); no[n].t.d.flags |= NVN_TEXTURE_FLAGS_DISPLAY; no[n++].why = "a display texture";
        for (unsigned i = 0; i < n; i++) {
            nvn_tex_layout(&no[i].t.d, &no[i].t.L); mtl_tex_init(&no[i].t);
            id<MTLTexture> mt = tex_mtl(&no[i].t); char label[160]; snprintf(label, sizeof label, "%s stays lossless", no[i].why);
            CHECK(mt && !lossy(mt), label);
        }
        for (unsigned i = 0; i < n; i++) mtl_tex_release(&no[i].t);
        // R11G11B10F, Depth32F, RGBA8UI, RGBA8SN, R32F by format; Depth24Stencil8 (made with the format-view use, tex_desc) and the image by use; multisample and 3D by shape; one small.
        // Without COMPRESSIBLE, in a CPU-visible pool and the display texture are not the game's GPU-only targets (rh_target): no decision
        if (want) CHECK(g_rl_n[RL_FORMAT] - f0[RL_FORMAT] == 5 && g_rl_n[RL_USAGE] - f0[RL_USAGE] == 2 && g_rl_n[RL_SHAPE] - f0[RL_SHAPE] == 2 && g_rl_n[RL_SMALL] - f0[RL_SMALL] == 1 && g_rl_n[RL_LOSSY] == f0[RL_LOSSY],
                        "the decisions count each reason");
        mtl_alias_drop_pool(&cpu); mtl_alias_drop_pool(&pool); settle();
    }
    {   // a lossy target that needs shader writes later is copied into a lossless one, its pixels kept; its sRGB twin over the same storage is a view of it
        tex_t a = target(&pool, 96301, 0, NVN_FORMAT_RGBA8, 1280, 720); mtl_tex_init(&a);
        id<MTLTexture> ta = tex_mtl(&a); fill(ta, 4, ^uint8_t(NSUInteger i) { (void)i; return 0x3c; });
        tex_t s = a; s.serial = 96302; s.d.format = NVN_FORMAT_RGBA8_SRGB; nvn_tex_layout(&s.d, &s.L); mtl_tex_init(&s);
        id<MTLTexture> ts = tex_mtl(&s);
        CHECK(ts && ts.pixelFormat == MTLPixelFormatRGBA8Unorm_sRGB && (ts == ta || ts.parentTexture == ta), "the sRGB twin is a view of the target");
        CHECK(lossy(ta) == want, "the target is lossy where it applies");
        id<MTLTexture> up = tex_upgrade(&a, ta, MTLTextureUsageShaderWrite, MTLPixelFormatInvalid);
        mtl_sub_commit(); mtl_drain(); CHECK(!mtl_last_commit_error(), "the upgrade copy completes without GPU error"); mtl_sub_begin();
        CHECK(up && (up.usage & MTLTextureUsageShaderWrite) && !lossy(up), "a later shader write makes it a lossless copy");
        CHECK(all_bytes(up, 4, 0x3c), "with its pixels");
        CHECK(tex_mtl(&a) == up, "which its texture object names from then on");
        ta = nil; up = nil; ts = nil; mtl_tex_release(&s); mtl_tex_release(&a); mtl_alias_drop_pool(&pool); settle();
    }
    {   // a lossy target the game carries across frames (bound for reading with an earlier frame's content, then attached again, RL_FB frames each) is copied into a lossless one at
        // its next attachment, its pixels kept; a target written once and read for many frames (a text panel) stays lossy; a target made again in the carried one's storage is lossless
        tex_t h = target(&pool, 96501, 0, NVN_FORMAT_R8, 1920, 1080), u = target(&pool, 96502, 8 << 20, NVN_FORMAT_RGBA8, 1466, 282);
        mtl_tex_init(&h); mtl_tex_init(&u); mtl_reg_tex(951, &h, NULL); mtl_reg_tex(952, &u, NULL);
        id<MTLTexture> th = tex_mtl(&h), tu = tex_mtl(&u);
        CHECK(lossy(th) == want && lossy(tu) == want, "both start lossy where it applies");
        fill(th, 1, ^uint8_t(NSUInteger i) { (void)i; return 0x41; });
        uint64_t c0 = g_rl_n[RL_CARRIED], f0 = atomic_load(&g_cur_frame);
        MTLRenderPassColorAttachmentDescriptor *a = [MTLRenderPassColorAttachmentDescriptor new];
        atomic_store(&g_cur_frame, f0 + 1); attach(a, &u, NULL, 0);   // the panel: written once
        id<MTLTexture> at = nil;
        for (int f = 0; f <= RL_FB; f++) {
            atomic_store(&g_cur_frame, f0 + 2 + f);
            os_unfair_lock_lock(&g_rmu); tex_fast_rid(951, NULL); tex_fast_rid(952, NULL); os_unfair_lock_unlock(&g_rmu);   // read, with the frame before's content
            attach(a, &h, NULL, 0); at = a.texture;   // written again
            if (f == RL_FB - 2) CHECK(lossy(at) == want, "not yet: fewer than RL_FB frames each");
        }
        mtl_sub_commit(); mtl_drain(); CHECK(!mtl_last_commit_error(), "the copy completes without GPU error"); mtl_sub_begin();
        CHECK(at && !lossy(at) && !lossy(tex_mtl(&h)), "the carried target is lossless from its next attachment on, and its texture object names that one");
        CHECK(g_rl_n[RL_CARRIED] - c0 == (want ? 1u : 0u), "counted once");
        CHECK(all_bytes(tex_mtl(&h), 1, 0x41), "with its pixels");
        CHECK(lossy(tex_mtl(&u)) == want, "the panel written once and read in every frame stays lossy");
        th = nil; tu = nil; at = nil; a = nil; mtl_reg_tex_gone(951); mtl_reg_tex_gone(952); mtl_tex_release(&h); mtl_tex_release(&u); mtl_alias_drop_pool(&pool); settle();
        tex_t h2 = target(&pool, 96503, 0, NVN_FORMAT_R8, 1920, 1080); mtl_tex_init(&h2);
        id<MTLTexture> t2 = tex_mtl(&h2);
        CHECK(t2 && !lossy(t2), "a target made again in the carried one's storage is lossless");
        CHECK(g_rl_n[RL_CARRIED] - c0 == (want ? 2u : 0u), "and counted so");
        tex_t o2 = target(&pool, 96504, 8 << 20, NVN_FORMAT_R8, 1920, 1080); mtl_tex_init(&o2);
        CHECK(lossy(tex_mtl(&o2)) == want, "other storage is not affected");
        t2 = nil; mtl_tex_release(&h2); mtl_tex_release(&o2); mtl_alias_drop_pool(&pool); settle();
        atomic_store(&g_cur_frame, f0);
    }
    {   // the ledger's count of lossy targets alive follows them
        tex_t a = target(&pool, 96401, 0, NVN_FORMAT_RGBA16F, 1920, 1080); mtl_tex_init(&a);
        id<MTLTexture> ta = tex_mtl(&a);
        os_unfair_lock_lock(&g_rl_lk); int listed = g_rl_live && [g_rl_live objectForKey:ta] != nil; os_unfair_lock_unlock(&g_rl_lk);
        CHECK(listed == want, "a lossy target is listed for the ledger");
        ta = nil; mtl_tex_release(&a); mtl_alias_drop_pool(&pool); settle();
    }
    CHECK(!want ? g_rl_n[RL_LOSSY] == 0 : 1, "off, or on a GPU without it, nothing is made lossy");
    CHECK(!mtl_last_commit_error(), "no GPU errors");
    mtl_sub_commit(); mtl_drain(); free(mem);
    printf("t_rt_lossy (%s%s): %d checks, %d failed\n", mode, rh ? "" : ", recycling off", checks, failed); return failed != 0;
} }
