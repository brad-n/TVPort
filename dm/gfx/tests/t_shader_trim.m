// Shader trimming at run time (dm/gfx/nvn/nvn_shader_trim.inc): a trimmed library from test_shader_trim.py --fixture (real Mac libraries; v_src, f_src, v_src2, f_src2 and f_bad packed, f_bad's
// frame damaged). Checks which files the image packs, that a packed file is absent for the pipeline prebuild and the prefetch at program creation until something loads it (msl_has,
// t_trim_quiet, trim_prefetch_skip), that shader_get loads a packed shader by inflating its frame once into the cache folder (its other libraries then come from there), that threads asking for the same shader at once inflate it once, that a damaged frame
// fails once with a red line and no crash, that a program of two packed shaders draws, and that the shaders it loaded are recorded in pso_user.tsv. Run again with `again` (a second start
// over the same cache folder): the shaders come from the cache folder, none is inflated.
// make GAME=<id> check_t_shader_trim (./t_shader_trim <fixture dir> [again])
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #c); } } while (0)
static NSMutableDictionary<NSString *, NSString *> *K;
static NvProg *g_trim_test_prog;
static NSString *F(NSString *name, NSString *suffix) { return [NSString stringWithFormat:@"%@/%@%@", g_msl_dir, K[name], suffix]; }
static NSString *B(NSString *name) { return [K[name] stringByAppendingString:@"_b"]; }
static int cached_files(NSString *name) {   // the packed shader's files in the cache folder
    int n = 0; for (NSString *f in [NSFileManager.defaultManager contentsOfDirectoryAtPath:@(g_trim.dir) error:NULL]) n += [f hasPrefix:K[name]] && ![f hasSuffix:@".part"]; return n;
}
static void draw_check(void) {   // a program of two packed shaders: its pipeline is built from the inflated libraries and the triangle covers the target in the fragment shader's red
    NvProg *pr = [NvProg new]; pr->sh[0] = shader_get(B(@"v_src2"), 0); pr->sh[1] = shader_get(B(@"f_src2"), 1);
    CHECK(pr->sh[0] && pr->sh[1] && pr->sh[0]->fn && pr->sh[1]->fn);
    if (!pr->sh[0] || !pr->sh[1]) return;
    static prog_t program; program.serial = 97001; serial_put(program.serial, pr);
    g_trim_test_prog = pr;   // serial_put holds it unretained
    tex_t target = {.magic = MAGIC('T', 'E', 'X', 0), .serial = 97101};
    target.d = (nvn_texdesc){.width = 8, .height = 8, .depth = 1, .samples = 1, .levels = 1, .target = NVN_TEXTURE_TARGET_2D, .format = NVN_FORMAT_RGBA8};
    uint8_t *commands; if (posix_memalign((void **)&commands, getpagesize(), 65536)) abort(); memset(commands, 0, 65536); mtl_pool_add(commands, 65536);
    size_t used = 0;
    #define EMIT(OP, X) do { size_t z = (8 + sizeof(X) + 7) & ~7ull; op_hdr h = {OP, (uint32_t)z}; memcpy(commands + used, &h, 8); memcpy(commands + used + 8, &(X), sizeof(X)); used += z; } while (0)
    p_set_rt rt = {.n = 1}; rt.color[0] = &target; EMIT(OP_SET_RT, rt);
    p_viewports vp = {.n = 1}; vp.v[0][2] = 8; vp.v[0][3] = 8; EMIT(OP_VIEWPORTS, vp);
    p_clear_color cl = {.index = 0, .mask = 15, .rgba = {0, 0, 1, 1}}; EMIT(OP_CLEAR_COLOR, cl);
    p_bind_program bp = {&program, 3}; EMIT(OP_BIND_PROGRAM, bp);
    p_scissor sc = {0, 0, 8, 8}; EMIT(OP_SCISSOR, sc);
    p_draw dr = {.prim = 4, .count = 3, .instances = 1}; EMIT(OP_DRAW, dr);
    op_hdr end = {OP_END, 8}; memcpy(commands + used, &end, 8);
    #undef EMIT
    state_reset(); memset(&R, 0, sizeof R); mtl_sub_begin(); mtl_exec(commands);
    id<MTLBuffer> pixels = [g_dev newBufferWithLength:256 * 8 options:MTLResourceStorageModeShared];
    [blit() copyFromTexture:tex_mtl(&target) sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(8, 8, 1) toBuffer:pixels destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:256 * 8];
    CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull)); CHECK(!mtl_last_commit_error());
    const uint8_t *px = pixels.contents; int red = 0;
    for (int y = 0; y < 8; y++) for (int x = 0; x < 8; x++) red += px[y * 256 + x * 4] > 200 && px[y * 256 + x * 4 + 2] < 50;
    CHECK(red == 64);
    mtl_pool_del(commands); mtl_drain(); free(commands);
}
int main(int argc, char **argv) { @autoreleasepool {
    if (argc < 2) return 2;
    int again = argc > 2 && !strcmp(argv[2], "again");
    NSString *dir = @(argv[1]), *cache = [dir stringByAppendingPathComponent:@"cache"], *user = [dir stringByAppendingPathComponent:@"pso_user.tsv"];
    K = [NSMutableDictionary dictionary];
    for (NSString *l in [[NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:@"keys.tsv"] encoding:NSUTF8StringEncoding error:nil] componentsSeparatedByString:@"\n"]) {
        NSArray *c = [l componentsSeparatedByString:@"\t"]; if (c.count == 2) K[c[0]] = c[1]; }
    if (!again) { [NSFileManager.defaultManager removeItemAtPath:cache error:NULL]; unlink(user.fileSystemRepresentation);
                  [NSFileManager.defaultManager createDirectoryAtPath:[cache stringByAppendingPathComponent:@"0123456789abcdef"] withIntermediateDirectories:YES attributes:nil error:NULL];
                  [@"stale" writeToFile:[cache stringByAppendingPathComponent:@"0123456789abcdef/x_b.metallib"] atomically:NO encoding:NSUTF8StringEncoding error:NULL]; }
    setenv("DM_SHADER_TRIM_CACHE", cache.fileSystemRepresentation, 1); setenv("DM_PSO_USER", user.fileSystemRepresentation, 1);
    unsetenv("DM_SHADER_TRIM_CACHE_MB");
    mtl_init(); g_msl_dir = [NSString stringWithFormat:@"%@/msl/b-%s", dir, DMSH_CHAIN];

    // what the image packs
    CHECK(trim_find([K[@"v_src"] stringByAppendingString:@"_b.metallib"].UTF8String) && trim_find([K[@"v_src"] stringByAppendingString:@"_bp.metallib"].UTF8String) && trim_find([K[@"f_src"] stringByAppendingString:@"_bx.metallib"].UTF8String));
    CHECK(!trim_find([K[@"v_used"] stringByAppendingString:@"_b.metallib"].UTF8String) && !trim_find([K[@"v_src"] stringByAppendingString:@"_bx.metallib"].UTF8String) && !trim_find("trim.tsv"));
    CHECK(g_trim.state == 2 && g_trim.n == 5);
    CHECK(![NSFileManager.defaultManager fileExistsAtPath:[cache stringByAppendingPathComponent:@"0123456789abcdef"]]);   // another trimmed image's folder is removed
    CHECK(msl_has(F(@"v_used", @"_b.metallib")) && msl_has(F(@"c_unused", @"_b.metallib")));
    if (!again) {
        // not inflated yet: absent for the prebuild, and a quiet thread does not inflate
        CHECK(!msl_has(F(@"v_src", @"_b.metallib")) && !msl_has(F(@"v_src", @"_b.json")));
        t_trim_quiet = 1; CHECK(msl_data(F(@"v_src", @"_b.json")) == nil); NSError *e = nil; CHECK(lib_from_file(F(@"v_src", @"_b.metallib"), &e) == nil && [e.localizedDescription containsString:@"not inflated yet"]); t_trim_quiet = 0;
        CHECK(g_trim.deferred == 2 && g_trim.inflated == 0 && cached_files(@"v_src") == 0);
        CHECK(trim_prefetch_skip(B(@"f_src2")) && !trim_prefetch_skip(B(@"v_used")) && g_trim.inflated == 0);   // the prefetch at program creation leaves it to the draw
    }
    // a packed shader loads: its frame inflated once, every file of it into the cache folder
    NvShader *vs = shader_get(B(@"v_src"), 0);
    CHECK(vs && vs->fn && vs->has_pull);
    CHECK(cached_files(@"v_src") == 3 && msl_has(F(@"v_src", @"_bp.metallib")));
    NSError *e = nil; id<MTLLibrary> bp = lib_from_file(F(@"v_src", @"_bp.metallib"), &e);
    CHECK(bp && [bp newFunctionWithName:@"main0"]);
    NvShader *fs = shader_get(B(@"f_src"), 1); id<MTLLibrary> bx = lib_from_file(F(@"f_src", @"_bx.metallib"), &e);
    CHECK(fs && fs->fn && fs->has_alpha && bx && [bx newFunctionWithName:@"main0_a"]);
    if (!again) CHECK(g_trim.inflated == 2 && g_trim.cached == 0);
    else CHECK(g_trim.inflated == 0 && g_trim.cached == 2);   // a second start: from the cache folder
    // threads asking for one shader at once: one inflates, the others wait for it
    uint64_t before = g_trim.inflated;
    __block _Atomic int got = 0;
    dispatch_apply(8, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t i) { (void)i; if (msl_data(F(@"v_src2", @"_b.json")).length) atomic_fetch_add(&got, 1); });
    CHECK(got == 8 && g_trim.inflated - before == (again ? 0u : 1u));
    // a damaged frame: fails once, with a red line, and is not tried again
    uint64_t f0 = g_trim.failed;
    CHECK(shader_get(B(@"f_bad"), 1) == nil && shader_get(B(@"f_bad"), 1) == nil && g_trim.failed - f0 == 1 && cached_files(@"f_bad") == 0);
    CHECK(shader_get(B(@"v_used"), 0) != nil);   // a shader the lists named loads from the image, nothing inflated for it
    draw_check();
    NSString *rec = [NSString stringWithContentsOfFile:user encoding:NSUTF8StringEncoding error:nil];
    NSString *row_v = [NSString stringWithFormat:@"S\t%@\t0\n", B(@"v_src")], *row_f = [NSString stringWithFormat:@"S\t%@\t1\n", B(@"f_src2")];
    CHECK([rec containsString:row_v] && [rec containsString:row_f]);
    CHECK(!trim_prefetch_skip(B(@"f_src2")));   // inflated (or from the cache folder): the prefetch takes it as any library
    trim_log_stats("at the end");
    CHECK(g_trim.max_ns > 0 || again);
    printf("shader trimming%s: %d checks, %d failed\n", again ? " (second start)" : "", checks, failed);
    return failed != 0;
} }
