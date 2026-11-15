// The anisotropic filtering override (DM_ANISO, nvn_mtl.m aniso_for / aniso_override): the game's samplers that filter minification and magnification linearly through mips get at least the
// asked anisotropy, the production sampler registry's samplers (mtl_reg_samp, samp_by_id) and, on the GPU, a footprint stretched eight to one reads the mip level that anisotropy implies;
// nearest, mipless, comparison and reduction samplers, and a game's own larger value, are left alone. Run under Metal validation (MTL_DEBUG_LAYER=1)
#include "../nvn/nvn_mtl.m"
uint64_t g_t0_ns;
int dm_guest_as_contains(uintptr_t address) { (void)address; return 0; }
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, fails;
#define CHECK(c, ...) do { checks++; if (!(c)) { fails++; fprintf(stderr, "FAIL: "); fprintf(stderr, __VA_ARGS__); fprintf(stderr, "\n"); } } while (0)

enum { N = 64, LEVELS = 7 };   // 64x64 with 7 levels, level k solid with red k / 7
static id<MTLTexture> g_tex; static id<MTLComputePipelineState> g_pipe;
static samp_par par(int minf, int magf, float aniso) { samp_par p = {0}; p.minf = minf; p.magf = magf; p.ws = p.wt = p.wr = 0; p.lod_min = 0; p.lod_max = 15; p.aniso = aniso; return p; }

// The mip level a sampler of that state reads for a footprint eight texels long and one wide: the level whose colour comes back, -1 when the sampler was not made
static int level_of(int sid, samp_par p) {
    mtl_reg_samp(sid, &p);
    os_unfair_lock_lock(&g_rmu); id<MTLSamplerState> s = samp_by_id(sid); uint64_t rid = g_srid[sid]; os_unfair_lock_unlock(&g_rmu);
    if (!s) return -1;
    id<MTLBuffer> args = [g_dev newBufferWithLength:16 options:MTLResourceStorageModeShared]; uint64_t a[2] = { g_tex.gpuResourceID._impl, rid }; memcpy(args.contents, a, 16);
    id<MTLBuffer> out = [g_dev newBufferWithLength:16 options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb = q_cb(); id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
    [e setComputePipelineState:g_pipe]; [e setBuffer:args offset:0 atIndex:0]; [e setBuffer:out offset:0 atIndex:1]; [e useResource:g_tex usage:MTLResourceUsageRead];
    [e dispatchThreads:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)]; [e endEncoding]; [cb commit]; [cb waitUntilCompleted];
    CHECK(cb.status == MTLCommandBufferStatusCompleted, "sampler %d: GPU work completed", sid);
    return (int)lroundf(((const float *)out.contents)[0] * LEVELS);
}
static int level_with(int over, int sid, samp_par p) { g_aniso_ovr = over; return level_of(sid, p); }
static void expect(const char *what, int got, int want) { CHECK(got == want, "%s: level %d, expected %d", what, got, want); }

int main(void) { @autoreleasepool {
    // the pure rule
    CHECK(aniso_for(&(samp_par){ .minf = 5, .magf = 1, .lod_max = 15, .aniso = 1 }, 0) == 1, "off: the game's own");
    CHECK(aniso_for(&(samp_par){ .minf = 5, .magf = 1, .lod_max = 15, .aniso = 0 }, 0) == 1, "off: a zero is one");
    CHECK(aniso_for(&(samp_par){ .minf = 3, .magf = 1, .lod_max = 15, .aniso = 1 }, 16) == 16, "linear / nearest mip: 16");
    CHECK(aniso_for(&(samp_par){ .minf = 5, .magf = 1, .lod_max = 15, .aniso = 1 }, 4) == 4, "linear mips: 4");
    CHECK(aniso_for(&(samp_par){ .minf = 5, .magf = 1, .lod_max = 15, .aniso = 8 }, 4) == 8, "the game's larger value stays");
    CHECK(aniso_for(&(samp_par){ .minf = 5, .magf = 1, .lod_max = 15, .aniso = 64 }, 2) == 16, "the game's value is clamped to 16 as before");
    CHECK(aniso_for(&(samp_par){ .minf = 2, .magf = 1, .lod_max = 15, .aniso = 1 }, 16) == 1, "nearest minification");
    CHECK(aniso_for(&(samp_par){ .minf = 4, .magf = 1, .lod_max = 15, .aniso = 1 }, 16) == 1, "nearest minification, linear mips");
    CHECK(aniso_for(&(samp_par){ .minf = 1, .magf = 1, .lod_max = 15, .aniso = 1 }, 16) == 1, "no mips");
    CHECK(aniso_for(&(samp_par){ .minf = 0, .magf = 0, .lod_max = 15, .aniso = 1 }, 16) == 1, "point");
    CHECK(aniso_for(&(samp_par){ .minf = 5, .magf = 0, .lod_max = 15, .aniso = 1 }, 16) == 1, "nearest magnification");
    CHECK(aniso_for(&(samp_par){ .minf = 5, .magf = 1, .lod_max = 0, .aniso = 1 }, 16) == 1, "mip range of level 0 only");
    CHECK(aniso_for(&(samp_par){ .minf = 5, .magf = 1, .lod_max = 15, .aniso = 1, .cmp_mode = 1, .cmp_func = 2 }, 16) == 1, "comparison (shadow)");
    CHECK(aniso_for(&(samp_par){ .minf = 5, .magf = 1, .lod_max = 15, .aniso = 1, .reduction = 1 }, 16) == 1, "min reduction (depth pyramid)");
    CHECK(aniso_for(&(samp_par){ .minf = 5, .magf = 1, .lod_max = 15, .aniso = 1, .reduction = 2 }, 16) == 1, "max reduction");
    // the switch
    const char *cases[][2] = { {"", "0"}, {"0", "0"}, {"2", "2"}, {"4", "4"}, {"8", "8"}, {"16", "16"}, {"3", "0"}, {"32", "0"}, {"junk", "0"}, {"-4", "0"} };
    for (size_t i = 0; i < sizeof cases / sizeof *cases; i++) { setenv("DM_ANISO", cases[i][0], 1); g_aniso_ovr = -1; CHECK(aniso_override() == atoi(cases[i][1]), "DM_ANISO=%s reads as %d, got %d", cases[i][0], atoi(cases[i][1]), aniso_override()); }
    unsetenv("DM_ANISO"); g_aniso_ovr = -1; CHECK(aniso_override() == 0, "unset: off");

    mtl_init();
    // a texture of solid levels, and a kernel that samples it with a footprint of 8 x 1 texels
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:N height:N mipmapped:YES]; d.storageMode = MTLStorageModeShared;
    g_tex = [g_dev newTextureWithDescriptor:d]; CHECK(g_tex.mipmapLevelCount == LEVELS, "%d levels", (int)g_tex.mipmapLevelCount);
    for (int l = 0; l < LEVELS; l++) { int n = N >> l; uint8_t *px = malloc((size_t)n * n * 4); for (int i = 0; i < n * n; i++) { px[4 * i] = (uint8_t)lroundf(255.f * l / LEVELS); px[4 * i + 1] = px[4 * i + 2] = 0; px[4 * i + 3] = 255; }
        [g_tex replaceRegion:MTLRegionMake2D(0, 0, n, n) mipmapLevel:l withBytes:px bytesPerRow:4 * n]; free(px); }
    NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\nstruct A { texture2d<float> t; sampler s; };\n"
        "kernel void k(constant A &a [[buffer(0)]], device float4 *o [[buffer(1)]]) { o[0] = a.t.sample(a.s, float2(0.5), gradient2d(float2(8.0 / 64, 0), float2(0, 1.0 / 64))); }\n";
    NSError *err = nil; MTLCompileOptions *co = [MTLCompileOptions new]; co.languageVersion = MTLLanguageVersion3_0;
    id<MTLLibrary> lib = [g_dev newLibraryWithSource:src options:co error:&err];
    g_pipe = lib ? [g_dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&err] : nil;
    CHECK(g_pipe != nil, "the probe kernel compiles: %s", err.localizedDescription.UTF8String);
    if (g_pipe) {
        // game's own value: 1 reads level 3 (the long axis, 8 texels), 8 reads level 0
        int own1 = level_with(0, 21, par(3, 1, 1)), own2 = level_with(0, 22, par(3, 1, 2)), own4 = level_with(0, 23, par(3, 1, 4)), own8 = level_with(0, 24, par(3, 1, 8)), own16 = level_with(0, 25, par(3, 1, 16));
        expect("the game's own 1x", own1, 3); expect("the game's own 8x", own8, 0); CHECK(own2 > own4 && own4 > own8 && own2 < own1 && own16 == own8, "the levels fall with the anisotropy: %d %d %d %d %d", own1, own2, own4, own8, own16);
        // the override makes the game's samplers what a game asking for it directly gets
        int ref[17] = {0}; ref[2] = own2; ref[4] = own4; ref[8] = own8; ref[16] = own16;
        for (int o = 2; o <= 16; o *= 2) { char w[96];
            snprintf(w, sizeof w, "override %d on a linear / nearest-mip sampler", o); expect(w, level_with(o, 30 + o, par(3, 1, 1)), ref[o]);
            snprintf(w, sizeof w, "override %d on a trilinear sampler", o); int t = level_with(o, 50 + o, par(5, 1, 1)), tref = level_with(0, 70 + o, par(5, 1, (float)o)); expect(w, t, tref);
            snprintf(w, sizeof w, "override %d: nearest minification keeps the game's", o); expect(w, level_with(o, 90 + o, par(2, 1, 1)), own1);
            snprintf(w, sizeof w, "override %d: nearest minification, linear mips", o); expect(w, level_with(o, 110 + o, par(4, 1, 1)), level_with(0, 130 + o, par(4, 1, 1)));
            snprintf(w, sizeof w, "override %d: nearest magnification keeps the game's", o); expect(w, level_with(o, 150 + o, par(3, 0, 1)), own1);
            snprintf(w, sizeof w, "override %d: lod_max 0 keeps the game's", o); samp_par z = par(3, 1, 1); z.lod_max = 0; expect(w, level_with(o, 170 + o, z), 0);
            snprintf(w, sizeof w, "override %d: the game's 16x stays", o); expect(w, level_with(o, 230 + o, par(3, 1, 16)), own16);
            snprintf(w, sizeof w, "override %d: a game's larger value than the override", o); if (o < 16) expect(w, level_with(o, 250 + o, par(3, 1, 16)), own16);
        }
        // the sampler cache: the same game sampler under one override is one state, and a slot registered again under another picks up that override
        g_aniso_ovr = 4; mtl_reg_samp(300, &(samp_par){ .minf = 3, .magf = 1, .lod_max = 15, .aniso = 1 }); mtl_reg_samp(301, &(samp_par){ .minf = 3, .magf = 1, .lod_max = 15, .aniso = 1 });
        CHECK(mtl_samp_pin(300) == mtl_samp_pin(301) || !spin_on(), "equal game samplers share a pin: %llu %llu", mtl_samp_pin(300), mtl_samp_pin(301));
        os_unfair_lock_lock(&g_rmu); samp_pin *pn = spin_get((int)mtl_samp_pin(300)); int pinned = pn != NULL; os_unfair_lock_unlock(&g_rmu);
        CHECK(pinned || !spin_on(), "the pinned sampler is made");
        expect("slot 300 under 4", level_of(300, par(3, 1, 1)), own4);
        expect("slot 300 under 16, registered again", level_with(16, 300, par(3, 1, 1)), own16);
        // the border twin gets the override too: a clamp-to-border sampler with a colour Metal lacks
        samp_par b = par(3, 1, 1); b.ws = b.wt = b.wr = 5; b.border[0] = b.border[1] = b.border[2] = b.border[3] = 0.5f; g_aniso_ovr = 8; mtl_reg_samp(310, &b);
        os_unfair_lock_lock(&g_rmu); id<MTLSamplerState> bs = samp_by_id(310); int twin = g_sview_w[310] != NULL; os_unfair_lock_unlock(&g_rmu); CHECK(bs != nil, "a bordered sampler is made");
        CHECK(twin || !DM_GAME_SHADER_BORDER_EMU, "its twin is made");
    }
    printf("t_aniso: %d checks, %d failed\n", checks, fails);
    return fails != 0;
} }
