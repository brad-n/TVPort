// Engine-wide resolution scale (DM_RES_SCALE=<0.5..2.0>, 1.0 = off, the default; docs/reference/rendering.md, Engine-wide resolution scale). The game's own render targets that
// qualify (rs_apply) are made at that many times their size, and everything that addresses them in pixels follows: the viewports and scissors of their passes (draw, clr_scissor),
// copies to and from them (copy_t2t_enc scales the regions, copy_t2b and copy_b2t go through a texture of the game's size), texture clears, DrawTexture and CPU reads. Shaders
// address them through Ryujinx's resolution-scaling code (gl_FragCoord divided by the pass's scale, texel fetches and size queries rescaled per texture), which a library has
// only when it was built with shader_no_rescale 0; the per-draw values come from rs_support. A texture the rules refuse stays at the game's size, and a pass that mixes scaled and
// unscaled attachments is drawn at the game's size; both are logged with [res-scale]. nvn_mtl.m includes this file twice: before tex_desc (the size rules), and with NVN_RSCALE_LATE
// before encode_args_ (passes and shader values, which need the pass state and the shader objects).
#ifndef NVN_RSCALE_LATE
static float g_rs = 1.0f;   // the scale qualifying targets are made at (1 when off)
static int g_rs_on;         // 1: DM_RES_SCALE is not 1.0 and the game's shaders carry the rescale code
static int g_rs_screen_w = 1920, g_rs_screen_h = 1080;   // the shape targets must have (rs_apply): the game's window textures' once seen, 16:9 before that
enum { RS_WHY_TARGET, RS_WHY_IMAGE, RS_WHY_COMPRESSED, RS_WHY_LEVELS, RS_WHY_SMALL, RS_WHY_SHAPE, RS_WHY_LIMIT, RS_WHY_SPARSE, RS_WHY_BUDGET, RS_WHY_SHORT, RS_NWHY };
static const char *const g_rs_why[RS_NWHY] = {"not a 2D texture or array (3D, cube, 1D)", "shader-writable (image): a compute shader addresses it in the game's pixels",
    "a compressed format", "more than 3 levels (an asset, not a target)", "smaller than 64 pixels", "not the screen's shape", "past Metal's 16384 limit", "in a sparse pool (its tiles follow the game's mappings)",
    "over the memory budget of the scale (DM_RES_SCALE_BUDGET_MB)", "the process short of memory (the memory relief, DM_NVN_MEM_RELIEF)"};
static _Atomic uint64_t g_rs_made, g_rs_made_kb, g_rs_refused[RS_NWHY], g_rs_mixed, g_rs_proxied;
// The memory budget of the scale. What the scale adds (a scaled texture's memory less what it takes at the game's size) is counted for every scaled texture alive (rs_track: an owner object
// on the Metal texture, released with it, so retired, taken-over and finalized targets leave the count when their memory goes); a new target that would take the count past the budget, or
// that comes while the memory relief finds the process short of memory (mr_active), stays at the game's size. The budget is a share of what the process may use: on iOS and tvOS a tenth of
// its limit (os_proc_available_memory plus its footprint when the first target asks; the Apple TV 4K ends an app at about 2,100 MB, so about 210 MB), on a Mac a quarter of Metal's
// recommended working set (the M2 Pro's 32 GB: about 5.3 GB). DM_RES_SCALE_BUDGET_MB=<n> sets it, 0 no budget. A scale below 1 adds nothing and is never refused
static uint64_t g_rs_budget; static _Atomic uint64_t g_rs_live_b, g_rs_live_n, g_rs_peak_b;
// The sizes scaled targets were made at (the game's): a game whose count keeps growing makes targets of new sizes, as a dynamic resolution does under GPU load, each made scaled
static CFMutableSetRef g_rs_sizes; static _Atomic uint64_t g_rs_nsizes;
static void rs_init(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *e = getenv("DM_RES_SCALE"); float v = e && *e ? strtof(e, NULL) : 1.0f;
        if (!(v >= 0.5f && v <= 2.0f)) { MLOG("[res-scale] DM_RES_SCALE=%s is outside 0.5 to 2.0: off", e); v = 1.0f; }
        v = roundf(v * 20.0f) / 20.0f;   // steps of 0.05, as the launcher offers them
        if (v == 1.0f) return;
        if (DM_GAME_SHADER_NO_RESCALE) {   // the shaders read gl_FragCoord and texel coordinates as they are: a scaled target would come out zoomed into its corner
            MLOG("[res-scale] off: DM_RES_SCALE=%.2f, but this game's shaders were built without the resolution-scaling code (profile key shader_no_rescale 1); a library built with shader_no_rescale 0 is needed", v);
            return;
        }
        g_rs = v; g_rs_on = 1;
        MLOG("[res-scale] on: the game's render targets at %.2fx their size (%.2fx the memory each), viewports, scissors, copies and shader coordinates scaled to match", v, v * v);
    });
}
static inline int rs_on(void) { rs_init(); return g_rs_on; }
static inline NSUInteger rs_dim(NSUInteger g) { long v = lroundf((float)g * g_rs); return v > 0 ? (NSUInteger)v : 1; }
static inline long rs_c(long x, float s) { return s == 1.0f ? x : lroundf((float)x * s); }   // a pixel edge at scale s (both edges round the same way, so abutting rectangles stay abutting)
// The game's window textures give the screen's shape (nvnWindowBuilderSetTextures, hle_nvn.c); 16:9 until then
static void rs_screen(const tex_t *t) { if (t && t->d.width >= 64 && t->d.height >= 64) { g_rs_screen_w = (int)t->d.width; g_rs_screen_h = (int)t->d.height; } }
static os_unfair_lock g_rs_lk = OS_UNFAIR_LOCK_INIT; static CFMutableDictionaryRef g_rs_dec;
enum { RS_DEC_NONE, RS_DEC_UNSCALED, RS_DEC_SCALED };
// What was decided for a texture serial (RS_DEC_*): tex_desc runs for a texture again (its twin, its family's other members, a remake after retirement or an upgrade), and all of them
// must agree, budget or not; counted and logged once
static int rs_dec(uint64_t ser, int set) {
    os_unfair_lock_lock(&g_rs_lk);
    if (!g_rs_dec) g_rs_dec = CFDictionaryCreateMutable(NULL, 0, NULL, NULL);
    const void *v = NULL; int had = CFDictionaryGetValueIfPresent(g_rs_dec, (const void *)(uintptr_t)ser, &v) ? (int)(uintptr_t)v : RS_DEC_NONE;
    if (!had && set) CFDictionarySetValue(g_rs_dec, (const void *)(uintptr_t)ser, (const void *)(uintptr_t)set);
    os_unfair_lock_unlock(&g_rs_lk); return had ? had : set;
}
static uint64_t rs_budget(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *e = getenv("DM_RES_SCALE_BUDGET_MB"); const char *how;
        if (e && *e) { long long v = atoll(e); g_rs_budget = v > 0 ? (uint64_t)v << 20 : 0; how = "DM_RES_SCALE_BUDGET_MB"; }
        else {
#if TARGET_OS_IPHONE
            task_vm_info_data_t vi; mach_msg_type_number_t n = TASK_VM_INFO_COUNT; uint64_t fp = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vi, &n) == KERN_SUCCESS ? vi.phys_footprint : 0;
            g_rs_budget = ((uint64_t)os_proc_available_memory() + fp) / 10; how = "a tenth of the process limit";
#else
            g_rs_budget = (uint64_t)g_dev.recommendedMaxWorkingSetSize / 4; how = "a quarter of the recommended working set";
#endif
        }
        if (g_rs_budget) MLOG("[res-scale] memory budget: the scale may add %llu MB to the targets alive (%s); past it, or while the process is short of memory, new targets stay at the game's size", (unsigned long long)(g_rs_budget >> 20), how);
        else MLOG("[res-scale] memory budget: none (DM_RES_SCALE_BUDGET_MB=0)");
    });
    return g_rs_budget;
}
@interface NvRsTrack : NSObject { @public uint64_t added; } @end
@implementation NvRsTrack
- (void)dealloc { atomic_fetch_sub(&g_rs_live_b, added); atomic_fetch_sub(&g_rs_live_n, 1); }
@end
static char g_rs_track_key;
// A Metal texture made for a guest texture (tex_mtl_, tex_upgrade): when it holds the texture at the scale, what the scale adds is counted while it lives
static void rs_track(id<MTLTexture> mt, const tex_t *t);
// tex_desc's GPU path: the descriptor of one of the game's render targets is scaled when it qualifies. Called for every descriptor of the texture (its sRGB twin, its image family),
// so all of them agree; logged once per texture
static void rs_apply(const tex_t *t, MTLTextureDescriptor *d) {
    if (!rs_on()) return;
    if (t->d.flags & NVN_TEXTURE_FLAGS_DISPLAY) { rs_screen(t); return; }
    if (!rh_target(t)) return;   // assets, CPU-visible, display (the window textures), video, linear and sparse textures keep their size, unlogged
    int why = -1; uint32_t w = t->d.width, h = t->d.height;
    // 2D arrays too, each layer at the scale: Mario Kart 8 Deluxe draws its race's 1920x1080 RG11B10F colour as a one-layer 2D array beside a 2D depth buffer, and refused,
    // that pass mixed a scaled depth with an unscaled colour
    if (t->d.target != NVN_TEXTURE_TARGET_2D && t->d.target != NVN_TEXTURE_TARGET_2D_MULTISAMPLE && t->d.target != NVN_TEXTURE_TARGET_RECTANGLE
        && t->d.target != NVN_TEXTURE_TARGET_2D_ARRAY && t->d.target != NVN_TEXTURE_TARGET_2D_MULTISAMPLE_ARRAY) why = RS_WHY_TARGET;
    else if (t->d.flags & NVN_TEXTURE_FLAGS_IMAGE) why = RS_WHY_IMAGE;
    else if (fmt_compressed(t->d.format)) why = RS_WHY_COMPRESSED;
    else if (t->d.levels > 3) why = RS_WHY_LEVELS;
    else if (w < 64 || h < 64) why = RS_WHY_SMALL;
    else if (fabs((double)w * g_rs_screen_h / ((double)h * g_rs_screen_w) - 1.0) > 0.04) why = RS_WHY_SHAPE;   // a shadow map, an atlas, a lookup table, a cube face
    else if (rs_dim(w) > 16384 || rs_dim(h) > 16384) why = RS_WHY_LIMIT;
    else if (t->pool && nvn_sparse_pool(t->pool)) why = RS_WHY_SPARSE;
    int dec = rs_dec(t->serial, 0), say = dec == RS_DEC_NONE;
    if (why >= 0) {
        if (say) rs_dec(t->serial, RS_DEC_UNSCALED);
        if (say && atomic_fetch_add(&g_rs_refused[why], 1) < 6)
            MLOG("[res-scale] refused ser=%llu %ux%u format %#x target %d levels %u flags %#x: %s", (unsigned long long)t->serial, w, h, t->d.format, t->d.target, t->d.levels, t->d.flags, g_rs_why[why]);
        return;
    }
    if (dec == RS_DEC_UNSCALED) return;   // refused once by the budget: its twin, family members and remakes stay at the game's size too
    NSUInteger w0 = d.width, h0 = d.height, l0 = d.mipmapLevelCount;
    d.width = rs_dim(d.width); d.height = rs_dim(d.height);
    NSUInteger big = MAX(d.width, d.height), fit = 1; while (big >> fit) fit++;
    if (d.mipmapLevelCount > fit) d.mipmapLevelCount = fit;   // a 0.5 scale holds one level fewer
    if (say) {   // the budget, once per texture: what the scale adds to it against what the scaled targets alive add
        uint64_t sz = (uint64_t)[g_dev heapTextureSizeAndAlignWithDescriptor:d].size, add = g_rs > 1.0f ? sz - (uint64_t)((double)sz / ((double)g_rs * g_rs)) : 0, b = rs_budget();
        int over = add && b && atomic_load(&g_rs_live_b) + add > b, shortm = add && mr_active();
        if (over || shortm) {
            rs_dec(t->serial, RS_DEC_UNSCALED); d.width = w0; d.height = h0; d.mipmapLevelCount = l0;
            if (atomic_fetch_add(&g_rs_refused[shortm ? RS_WHY_SHORT : RS_WHY_BUDGET], 1) < 6)
                MLOG("[res-scale] refused ser=%llu %ux%u format %#x: %s (the scale adds %llu MB in %llu targets alive, %llu MB more for this one, budget %llu MB): it stays at the game's size",
                     (unsigned long long)t->serial, w, h, t->d.format, g_rs_why[shortm ? RS_WHY_SHORT : RS_WHY_BUDGET], (unsigned long long)(atomic_load(&g_rs_live_b) >> 20),
                     (unsigned long long)atomic_load(&g_rs_live_n), (unsigned long long)(add >> 20), (unsigned long long)(b >> 20));
            return;
        }
        rs_dec(t->serial, RS_DEC_SCALED);
    }
    if (say) { uint64_t key = (uint64_t)w << 32 | h, ns = 0; int fresh;
        os_unfair_lock_lock(&g_rs_lk); if (!g_rs_sizes) g_rs_sizes = CFSetCreateMutable(NULL, 0, NULL);
        fresh = !CFSetContainsValue(g_rs_sizes, (const void *)(uintptr_t)key); if (fresh) { CFSetAddValue(g_rs_sizes, (const void *)(uintptr_t)key); ns = (uint64_t)CFSetGetCount(g_rs_sizes); } os_unfair_lock_unlock(&g_rs_lk);
        if (fresh) { atomic_store(&g_rs_nsizes, ns); if (ns > 24 && ns <= 64) MLOG("[res-scale] a scaled target of a new size %ux%u (%llu sizes so far): the game makes targets of new sizes, as a dynamic resolution does", w, h, (unsigned long long)ns); } }
    if (say) { uint64_t n = atomic_fetch_add(&g_rs_made, 1); atomic_fetch_add(&g_rs_made_kb, (uint64_t)([g_dev heapTextureSizeAndAlignWithDescriptor:d].size >> 10));
        if (n < 24) MLOG("[res-scale] scaled ser=%llu %ux%u → %lux%lu format %#x target %d levels %u", (unsigned long long)t->serial, w, h, (unsigned long)d.width, (unsigned long)d.height, t->d.format, t->d.target, t->d.levels); }
}
// A summary with the memory readout (mtl_mem_stat, every 300 frames at most): the targets made scaled and their memory at the scale, what was refused by rule, the mixed passes.
// A count that keeps growing is a game making new targets (its dynamic resolution's sizes, a target per frame)
static void rs_summary(unsigned long long frame) {
    static uint64_t last_made, last_mixed; static int lines;
    if (!g_rs_on || lines >= 60) return;
    uint64_t made = atomic_load(&g_rs_made), mixed = atomic_load(&g_rs_mixed); if (made == last_made && mixed == last_mixed) return;
    last_made = made; last_mixed = mixed; lines++;
    char why[512]; size_t o = 0; why[0] = 0;
    for (int i = 0; i < RS_NWHY; i++) { uint64_t n = atomic_load(&g_rs_refused[i]); if (n && o < sizeof why) o += (size_t)snprintf(why + o, sizeof why - o, "%s%llu %s", o ? ", " : "", (unsigned long long)n, g_rs_why[i]); }
    MLOG("[res-scale] up to frame %llu: %llu targets made at %.2fx (%llu MB at that size in all, %llu sizes); alive %llu, the scale adding %llu MB (peak %llu MB, budget %llu MB); %llu mixed passes drawn through proxies, %llu drawn unscaled; refused: %s",
         frame, (unsigned long long)made, g_rs, (unsigned long long)(atomic_load(&g_rs_made_kb) >> 10), (unsigned long long)atomic_load(&g_rs_nsizes), (unsigned long long)atomic_load(&g_rs_live_n), (unsigned long long)(atomic_load(&g_rs_live_b) >> 20),
         (unsigned long long)(atomic_load(&g_rs_peak_b) >> 20), (unsigned long long)(g_rs_budget >> 20), (unsigned long long)atomic_load(&g_rs_proxied), (unsigned long long)mixed, o ? why : "none");
}
// The scale a Metal texture holds a guest texture at: g_rs when rs_apply made it so, else 1 (a view reports its base texture's; a snapshot or a copy of one has its size, so its own)
static inline float rs_of(id<MTLTexture> mt, const tex_t *t) {
    if (!g_rs_on || !mt || !t || !rh_target(t)) return 1.0f;
    id<MTLTexture> b = mt; while (b.parentTexture) b = b.parentTexture;
    NSUInteger gw = t->d.width ? t->d.width : 1;
    return b.width != gw && b.width == rs_dim(gw) ? g_rs : 1.0f;
}
static void rs_track(id<MTLTexture> mt, const tex_t *t) {
    if (!g_rs_on || g_rs <= 1.0f || !mt || mt.parentTexture || rs_of(mt, t) == 1.0f || objc_getAssociatedObject(mt, &g_rs_track_key)) return;
    NvRsTrack *k = [NvRsTrack new]; uint64_t sz = (uint64_t)mt.allocatedSize; k->added = sz - (uint64_t)((double)sz / ((double)g_rs * g_rs));
    objc_setAssociatedObject(mt, &g_rs_track_key, k, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    uint64_t now = atomic_fetch_add(&g_rs_live_b, k->added) + k->added, pk = atomic_load(&g_rs_peak_b); atomic_fetch_add(&g_rs_live_n, 1);
    while (now > pk && !atomic_compare_exchange_weak(&g_rs_peak_b, &pk, now)) {}
}
// A copy region of a guest texture's level, in the Metal texture's pixels at scale s, within that level (lw x lh)
static NVNcopyRegion rs_region(const NVNcopyRegion *r, float s, NSUInteger lw, NSUInteger lh) {
    NVNcopyRegion o = *r; if (s == 1.0f) return o;
    long x0 = rs_c(r->xoffset, s), y0 = rs_c(r->yoffset, s), x1 = rs_c((long)r->xoffset + r->width, s), y1 = rs_c((long)r->yoffset + r->height, s);
    if (x1 > (long)lw) x1 = (long)lw; if (y1 > (long)lh) y1 = (long)lh; if (x0 > x1 - 1) x0 = MAX(x1 - 1, 0); if (y0 > y1 - 1) y0 = MAX(y1 - 1, 0);
    o.xoffset = (int)x0; o.yoffset = (int)y0; o.width = (int)MAX(x1 - x0, 1); o.height = (int)MAX(y1 - y0, 1);
    return o;
}
#else
// What a pass's attachments were made at (rp_begin_ex_): g_rs when all are scaled, 1 when none is. A pass that mixes them is drawn at the game's size, which leaves the scaled ones
// drawn in their top-left part: logged (the first 8 cases) and counted. Phase 1 has no way to bring a target to the other scale
static float rs_pass(MTL4RenderPassDescriptor *pd) {
    if (!g_rs_on) return 1.0f;
    int sc = 0, un = 0; const tex_t *ss = NULL, *us = NULL;
    for (int i = 0; i < R.rt.n && i < 8; i++) { id<MTLTexture> t = pd.colorAttachments[i].texture; if (!t || !R.rt.color[i]) continue;
        if (rs_of(t, R.rt.color[i]) != 1.0f) { sc++; ss = R.rt.color[i]; } else { un++; us = R.rt.color[i]; } }
    id<MTLTexture> dt = pd.depthAttachment.texture ?: pd.stencilAttachment.texture;
    if (dt && R.rt.depth) { if (rs_of(dt, R.rt.depth) != 1.0f) { sc++; ss = R.rt.depth; } else { un++; us = R.rt.depth; } }
    if (sc && un) {   // what rs_proxy_begin could not draw down
        if (atomic_fetch_add(&g_rs_mixed, 1) < 8) MLOG("[res-scale] pass %llu mixes scaled (ser=%llu %ux%u format %#x) and unscaled (ser=%llu %ux%u format %#x target %d levels %u flags %#x, pool flags %#x) attachments: drawn at the game's size, so the scaled ones get the top-left part",
            (unsigned long long)g_stat_pass + 1, (unsigned long long)ss->serial, ss->d.width, ss->d.height, ss->d.format, (unsigned long long)us->serial, us->d.width, us->d.height, us->d.format, us->d.target, us->d.levels, us->d.flags, us->pool ? us->pool->flags : 0u);
        return 1.0f;
    }
    return sc ? g_rs : 1.0f;
}
// R.rt's scale before its pass is open (the render-area choice, clear_rect_zero, DrawTexture): its first colour target's, else its depth's
static float rs_rt(void) {
    if (!g_rs_on) return 1.0f;
    for (int i = 0; i < R.rt.n && i < 8; i++) if (R.rt.color[i]) return rs_of(tex_mtl(R.rt.color[i]), R.rt.color[i]);
    return R.rt.depth ? rs_of(tex_mtl(R.rt.depth), R.rt.depth) : 1.0f;
}
// The support buffer of a shader with the rescale code (encode_args_), the layout support_buf has: alpha test, BGRA flags, viewport fields and the fragment scale count 0 (so a vertex
// shader's texture i reads render_scale[1 + i], as a fragment or compute shader's does), render_scale[0] the pass's scale (gl_FragCoord.xy / it in a pixel shader), then 1.0 for each
// texture and image until rs_bound sets the scaled ones. Returns the GPU address; *sc points at render_scale[0].x, a float4 apart
enum { RS_SUP_SCALE = 192, RS_SUP_MAX = 73 };
static uint64_t rs_support(const NvShader *sh, int nvn_stage, float **sc) {
    int n = 1 + sh->rf.nrsi; if (n > RS_SUP_MAX) n = RS_SUP_MAX;
    id<MTLBuffer> b; size_t o = arena_alloc(RS_SUP_SCALE + 16 * (size_t)n, &b);
    uint8_t *p = g_cur_arena->cpu + o; memset(p, 0, RS_SUP_SCALE);
    float *f = (float *)(void *)(p + RS_SUP_SCALE);
    for (int i = 0; i < n; i++) { f[4 * i] = 1.0f; f[4 * i + 1] = f[4 * i + 2] = f[4 * i + 3] = 0.0f; }
    if (nvn_stage == 1) f[0] = g_pass.rs;   // the pixel shader's gl_FragCoord.xy is divided by it (InstEmitAttribute.EmitIpa)
    *sc = f; return g_cur_arena->gpu + o;
}
// One texture binding's scale for the rescale helpers (Ryujinx's TexelFetchScale / TextureSizeUnscale). In a pixel shader of a scaled pass a scaled texture's scale is given
// negative, which makes the helper place a fetch at the pixel's own sub-texel position (TexelFetchScale's fragment branch): a 1:1 fetch of a scaled target lands on its own pixel
static inline void rs_bound(float *sc, const nvn_rbind *b, id<MTLTexture> t, int tid, int nvn_stage) {
    if (!sc || !b->rsi || b->rsi >= RS_SUP_MAX) return;
    const tex_t *gt = tid > 0 && tid < g_ntreg && g_treg[tid].ok ? &g_treg[tid].t : NULL;
    float s = rs_of(t, gt);
    if (s != 1.0f && nvn_stage == 1 && g_pass.rs != 1.0f) s = -s;
    sc[4 * b->rsi] = s;
}
// A scaled texture's region at the game's size, for what must see the game's pixels (copy_t2b; copy_b2t the other way, rs_scale_into): a 2D texture of the region's size, drawn into
// from the scaled region with a bilinear filter (depth nearest), released after this submission. nil where the scaling draw cannot take the format (integer and stencil-only
// formats, multisample): then the caller copies as before, at the scaled size, and it is logged
static int fmt_int_or_ds(MTLPixelFormat f);
static int copy_t2t_draw(id<MTLTexture> s, id<MTLTexture> d, unsigned sl, unsigned ss, unsigned dl, unsigned ds, const NVNcopyRegion *sr, const NVNcopyRegion *dr, int linear, int mirror);
static id<MTLTexture> rs_temp(MTLPixelFormat pf, int w, int h) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pf width:(NSUInteger)MAX(w, 1) height:(NSUInteger)MAX(h, 1) mipmapped:NO];
    d.storageMode = MTLStorageModePrivate; d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | (pf == MTLPixelFormatDepth32Float_Stencil8 ? MTLTextureUsagePixelFormatView : 0);
    id<MTLTexture> t = [g_dev newTextureWithDescriptor:d]; if (!t) return nil;
    res_add(t); defer_obj_release(t);   // resident for this submission, released once it has run
    return t;
}
static void rs_cannot(const char *what, id<MTLTexture> t, uint64_t ser) {
    static _Atomic int n; if (atomic_fetch_add(&n, 1) < 8) MLOG("[res-scale] %s of scaled ser=%llu (Metal format %lu, %lu samples): the scaling draw cannot take it, so it goes at the scaled size", what, (unsigned long long)ser, (unsigned long)t.pixelFormat, (unsigned long)t.sampleCount);
}
static id<MTLTexture> rs_unscaled(id<MTLTexture> s, unsigned lv, unsigned sl, const NVNcopyRegion *r, float sc, uint64_t ser, const char *what) {
    if (s.sampleCount > 1 || fmt_int_or_ds(s.pixelFormat) != (s.pixelFormat == MTLPixelFormatDepth32Float || s.pixelFormat == MTLPixelFormatDepth16Unorm || s.pixelFormat == MTLPixelFormatDepth32Float_Stencil8)) { rs_cannot(what, s, ser); return nil; }
    id<MTLTexture> u = rs_temp(s.pixelFormat, r->width, r->height); if (!u) return nil;
    NVNcopyRegion sr = rs_region(r, sc, MAX(s.width >> lv, 1ul), MAX(s.height >> lv, 1ul)), dr = {0, 0, 0, r->width, r->height, 1};
    if (!copy_t2t_draw(s, u, lv, sl, 0, 0, &sr, &dr, 1, 0)) { rs_cannot(what, s, ser); return nil; }
    return u;
}
// The other way: what a copy wrote at the game's size (u, its region at 0, 0) drawn into the scaled texture's region. 0 when the format cannot be drawn
static int rs_scale_into(id<MTLTexture> u, id<MTLTexture> t, unsigned lv, unsigned sl, const NVNcopyRegion *r, float sc) {
    NVNcopyRegion sr = {0, 0, 0, r->width, r->height, 1}, dr = rs_region(r, sc, MAX(t.width >> lv, 1ul), MAX(t.height >> lv, 1ul));
    return copy_t2t_draw(u, t, 0, 0, lv, sl, &sr, &dr, 1, 0);
}
// A pass that mixes scaled and unscaled attachments is drawn at the game's size through proxies (rs_proxy_begin, rp_begin_ex_): each scaled attachment's level is drawn down
// into a texture of the game's size (when the pass loads it), that texture is attached in its place, and when the pass ends it is drawn back up into the scaled level (when
// the pass stores it; rs_proxy_flush, rp_end). Ocarina of Time draws effects into a 1536x864 RGBA8 target agl makes shader-writable (IMAGE, so it stays at the game's size)
// with the scene's scaled depth buffer: attached as they were, the pass covered the depth's top-left part and the depth test put the effects in the wrong places.
// The copies cost GPU time, and what such a pass draws into the scaled target is at the game's resolution. Multisample attachments cannot be drawn down: logged, drawn as before
static __strong id<MTLTexture> g_rs_pdst[9], g_rs_ptmp[9]; static __strong MTLRenderPassAttachmentDescriptor *g_rs_patt[9]; static NSUInteger g_rs_plv[9], g_rs_psl[9]; static int g_rs_nprox;
static uint8_t g_rs_pds[9], g_rs_pclr[9];   // the proxy is the depth-stencil one; its pass clears it. A depth-stencil proxy goes back only when the pass cleared or wrote it (g_rs_ds_wrote, set by draw):
                                            // a depth buffer drawn down and up again for a pass that only tests it would come back at the game's resolution
static void rs_proxy_flush(void) {
    int n = g_rs_nprox; g_rs_nprox = 0;   // copy_t2t_draw ends the pass in progress (none here) through rp_end, which would come back here
    for (int i = 0; i < n; i++) {
        id<MTLTexture> d = g_rs_pdst[i], u = g_rs_ptmp[i]; MTLRenderPassAttachmentDescriptor *a = g_rs_patt[i];
        if (a.storeAction != MTLStoreActionDontCare && (!g_rs_pds[i] || g_rs_pclr[i] || g_rs_ds_wrote)) {
            NVNcopyRegion sr = {0, 0, 0, (int)u.width, (int)u.height, 1}, dr = {0, 0, 0, (int)MAX(d.width >> g_rs_plv[i], 1ul), (int)MAX(d.height >> g_rs_plv[i], 1ul), 1};
            if (!copy_t2t_draw(u, d, 0, 0, (unsigned)g_rs_plv[i], (unsigned)g_rs_psl[i], &sr, &dr, 1, 0)) rs_cannot("a mixed pass's proxy drawn back", d, 0);
        }
        g_rs_pdst[i] = nil; g_rs_ptmp[i] = nil; g_rs_patt[i] = nil;
    }
}
static int rs_proxy_one(MTLRenderPassAttachmentDescriptor *a, MTLRenderPassAttachmentDescriptor *also, const tex_t *t) {
    id<MTLTexture> d = a.texture; NSUInteger lv = a.level, sl = a.slice;
    if (!d || d.sampleCount > 1 || d.textureType == MTLTextureType3D || g_rs_nprox >= 9) return 0;
    int gw = (int)MAX(t->d.width >> lv, 1u), gh = (int)MAX(t->d.height >> lv, 1u);
    id<MTLTexture> u = rs_temp(d.pixelFormat, gw, gh); if (!u) return 0;
    if (a.loadAction == MTLLoadActionLoad) {
        NVNcopyRegion sr = {0, 0, 0, (int)MAX(d.width >> lv, 1ul), (int)MAX(d.height >> lv, 1ul), 1}, dr = {0, 0, 0, gw, gh, 1};
        if (!copy_t2t_draw(d, u, (unsigned)lv, (unsigned)sl, 0, 0, &sr, &dr, 1, 0)) return 0;
    }
    g_rs_pds[g_rs_nprox] = mtl_fmt_depth(d.pixelFormat) || d.pixelFormat == MTLPixelFormatStencil8 || d.pixelFormat == MTLPixelFormatX32_Stencil8;
    g_rs_pclr[g_rs_nprox] = a.loadAction == MTLLoadActionClear || (also && also.texture == d && also.loadAction == MTLLoadActionClear);
    a.texture = u; a.level = 0; a.slice = 0;
    if (also && also.texture == d) { also.texture = u; also.level = 0; also.slice = 0; }   // the stencil plane of the same depth-stencil texture
    g_rs_pdst[g_rs_nprox] = d; g_rs_ptmp[g_rs_nprox] = u; g_rs_patt[g_rs_nprox] = a; g_rs_plv[g_rs_nprox] = lv; g_rs_psl[g_rs_nprox] = sl; g_rs_nprox++;
    return 1;
}
static void rs_proxy_begin(MTL4RenderPassDescriptor *pd) {
    if (!g_rs_on) return;
    int sc = 0, un = 0; const tex_t *ss = NULL, *us = NULL;
    for (int i = 0; i < R.rt.n && i < 8; i++) { id<MTLTexture> t = pd.colorAttachments[i].texture; if (!t || !R.rt.color[i]) continue;
        if (rs_of(t, R.rt.color[i]) != 1.0f) { sc++; ss = R.rt.color[i]; } else { un++; us = R.rt.color[i]; } }
    id<MTLTexture> dt = pd.depthAttachment.texture ?: pd.stencilAttachment.texture;
    if (dt && R.rt.depth) { if (rs_of(dt, R.rt.depth) != 1.0f) { sc++; ss = R.rt.depth; } else { un++; us = R.rt.depth; } }
    if (!sc || !un) return;
    int ok = 1; g_rs_ds_wrote = 0;
    for (int i = 0; i < R.rt.n && i < 8; i++) { MTLRenderPassColorAttachmentDescriptor *c = pd.colorAttachments[i];
        if (c.texture && R.rt.color[i] && rs_of(c.texture, R.rt.color[i]) != 1.0f) ok &= rs_proxy_one(c, nil, R.rt.color[i]); }
    if (dt && R.rt.depth && rs_of(dt, R.rt.depth) != 1.0f) {
        if (pd.depthAttachment.texture) ok &= rs_proxy_one(pd.depthAttachment, pd.stencilAttachment, R.rt.depth);
        else ok &= rs_proxy_one(pd.stencilAttachment, nil, R.rt.depth);
    }
    uint64_t n = atomic_fetch_add(&g_rs_proxied, 1);
    if (n < 8 || !ok) MLOG("[res-scale] pass %llu mixes scaled (ser=%llu %ux%u format %#x) and unscaled (ser=%llu %ux%u format %#x target %d flags %#x) attachments: %s", (unsigned long long)g_stat_pass + 1,
        (unsigned long long)ss->serial, ss->d.width, ss->d.height, ss->d.format, (unsigned long long)us->serial, us->d.width, us->d.height, us->d.format, us->d.target, us->d.flags,
        ok ? "drawn at the game's size through proxies of the scaled ones" : "a scaled one could not be drawn down (multisample, or a format the scaling draw lacks): drawn at the game's size into its top-left part");
}
#endif
