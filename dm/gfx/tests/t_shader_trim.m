// Shader trimming at run time (dm/gfx/nvn/nvn_shader_trim.m, nvn_mtl.m): a fixture image made by dm/gfx/tests/test_shader_trim.py (shader_trim.py split) holds some shaders as compiled libraries and
// the others as zstd MSL. Checks the shader map's form column, the reflection json and libraries read from source entries, a source shader compiled with newLibraryWithSource through lib_from_file
// and shader_load (pending first, then ready), a program with a pending shader (kept apart from the serial table, completed when the shaders are ready), a draw skipped while it compiles and counted,
// the S row recorded in pso_user.tsv once the shader has loaded, and the compiled shaders of the same image still loading as they did.
// Usage: t_shader_trim <fixture dir with shader_map.tsv and msl/b-<chain>.img> <pso_user.tsv to write>
#include "../nvn/nvn_mtl.m"
#include <stdlib.h>
#include <unistd.h>

void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
int dm_guest_as_contains(uintptr_t address) { (void)address; return 0; }

static int g_checks, g_failed;
#define CHECK(name, ...) do { int ok_ = !!(__VA_ARGS__); g_checks++; printf("%s %s\n", name, ok_ ? "OK" : "FAIL"); g_failed += !ok_; } while (0)

// Tags 1..6 name six shaders: a program's key is sha256 of its 0x880-byte control section (hle_nvn.c keys_hash), which here is zero but for the tag at +0x800, so the fixture (test_shader_trim.py) knows the keys
enum { T_VUSED = 1, T_VSRC, T_FSRC, T_FUSED, T_VSRC2, T_FSRC2 };
static NSString *K[8];
static void set_ctl(prog_t *p, unsigned st, int tag) {
    static uint8_t ctl[8][0x880]; memset(ctl[tag], 0, sizeof ctl[tag]); ctl[tag][0x800] = (uint8_t)tag; p->sd[st].control = ctl[tag];
}
static NSString *key_of_tag(int tag) {
    static uint8_t ctl[0x880]; memset(ctl, 0, sizeof ctl); ctl[0x800] = (uint8_t)tag; uint8_t md[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(ctl, sizeof ctl, md);
    return [NSString stringWithFormat:@"%02x%02x%02x%02x%02x%02x%02x%02x", md[0], md[1], md[2], md[3], md[4], md[5], md[6], md[7]];
}
#define NAME(tag, suffix) [K[tag] stringByAppendingString:@suffix]
static int wait_ready(NSString *key) {
    trim_ensure(key, 0);   // starts it when nothing has asked yet
    for (int i = 0; i < 20000; i++) { if (trim_state(key) != TRIM_PENDING) return trim_state(key); usleep(1000); }
    return TRIM_PENDING;
}

int main(int argc, char **argv) { @autoreleasepool {
    if (argc < 3) { fprintf(stderr, "usage: t_shader_trim <fixture dir> <pso_user.tsv>\n"); return 2; }
    NSString *dir = @(argv[1]);
    setenv("DM_NVN_SHMAP", [dir stringByAppendingPathComponent:@"shader_map.tsv"].UTF8String, 1);
    setenv("DM_MSL_DIR", [dir stringByAppendingPathComponent:@"msl"].UTF8String, 1);
    setenv("DM_PSO_USER", argv[2], 1);
    unlink(argv[2]);
    unsetenv("DM_PSO_MANIFEST"); unsetenv("DM_SAVE"); unsetenv("DM_PSO_PREBUILD"); unsetenv("DM_PSO_HYBRID");
    mtl_init();
    for (int t = T_VUSED; t <= T_FSRC2; t++) K[t] = key_of_tag(t);
    shmap_read_once();

    CHECK("the map's form column marks source shaders", g_trim_any && trim_is_source(K[T_VSRC]) && trim_is_source(K[T_FSRC]) && trim_is_source(K[T_VSRC2]) && trim_is_source(K[T_FSRC2]));
    CHECK("compiled shaders are not source", !trim_is_source(K[T_VUSED]) && !trim_is_source(K[T_FUSED]));
    CHECK("all six keys are in the map", g_shmap.count >= 6 && g_shmap[K[T_VSRC]] && g_shmap[K[T_FUSED]]);

    // compiled shaders load as before
    NvShader *vu = shader_get(NAME(T_VUSED, "_b"), 0), *fu = shader_get(NAME(T_FUSED, "_b"), 1);
    CHECK("a compiled vertex shader loads from the image", vu && vu->fn);
    CHECK("a compiled fragment shader loads from the image", fu && fu->fn);

    // the reflection of a source shader comes out of its zstd entry
    NSData *jd = msl_data([NSString stringWithFormat:@"%@/%@_b.json", g_msl_dir, K[T_VSRC]]);
    NSDictionary *j = jd ? [NSJSONSerialization JSONObjectWithData:jd options:0 error:nil] : nil;
    CHECK("the reflection json of a source shader is inflated from <key>_b.jsonz", j && [j[@"entry"] isEqual:@"main0"] && j[@"pull"]);

    // not ready: shader_load answers pending (nil, no error), the library is not made on this thread
    trim_test_hold(1);
    t_trim_pending = 0; NvShader *p0 = shader_get(NAME(T_VSRC, "_b"), 0);
    CHECK("a source shader is pending while its compile is queued", !p0 && t_trim_pending && trim_state(K[T_VSRC]) == TRIM_PENDING);
    NSError *e = nil; t_trim_pending = 0;
    id<MTLLibrary> l0 = lib_from_file([NSString stringWithFormat:@"%@/%@_b.metallib", g_msl_dir, K[T_VSRC]], &e);
    CHECK("lib_from_file gives no library yet, and says why", !l0 && t_trim_pending && [e.localizedDescription containsString:@"compiling"]);
    CHECK("nothing was recorded for a shader that has not loaded", ![[NSString stringWithContentsOfFile:@(argv[2]) encoding:NSUTF8StringEncoding error:nil] containsString:K[T_VSRC]]);

    // a program with one pending shader: kept apart, its draws skipped
    prog_t pg = {.nstage = 2, .serial = 777001}; set_ctl(&pg, 0, T_VSRC2); set_ctl(&pg, 1, T_FSRC2);
    NvProg *pr = prog_get(&pg);
    CHECK("a program whose shaders are compiling is returned incomplete and flagged", pr && pr->trim_pending && !pr->sh[0] && !pr->sh[1] && pr->trim_keys.count == 2);
    CHECK("it is not put in the serial table", serial_get(pg.serial) == nil);
    CHECK("asking again gives the same object while the shaders are pending", prog_get(&pg) == pr);

    // a draw with it is skipped and counted
    trim_stats_t s0 = trim_stats();
    tex_t t = {.magic = MAGIC('T','E','X',0), .serial = 810001, .off = (int64_t)810001 << 20};
    t.d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = NVN_FORMAT_RGBA8, .width = 8, .height = 8, .depth = 1, .levels = 1, .samples = 1}; nvn_tex_layout(&t.d, &t.L);
    static uint8_t buf[4096]; size_t n = 0;
    #define EMIT(OP, ARG) do { size_t sz_ = (8 + sizeof(ARG) + 7) & ~7ull; op_hdr h_ = {OP, (uint32_t)sz_}; memcpy(buf + n, &h_, 8); memcpy(buf + n + 8, &(ARG), sizeof(ARG)); n += sz_; } while (0)
    p_set_rt rt = {.n = 1}; rt.color[0] = &t; EMIT(OP_SET_RT, rt);
    p_bind_program bp = {&pg, 3}; EMIT(OP_BIND_PROGRAM, bp);
    p_draw dw = {.prim = NVN_DRAW_PRIMITIVE_TRIANGLES, .count = 3, .instances = 1}; EMIT(OP_DRAW, dw);
    { op_hdr h_ = {OP_END, 8}; memcpy(buf + n, &h_, 8); n += 8; }
    state_reset(); memset(&R, 0, sizeof R);
    mtl_sub_begin(); mtl_exec(buf); uint64_t f = mtl_sub_commit(); int done = mtl_wait(f, 2000000000ull); mtl_drain();
    trim_stats_t s1 = trim_stats();
    CHECK("the submission with the skipped draw completes", done && !mtl_last_commit_error());
    CHECK("the draw was skipped and counted", s1.skipped_draws > s0.skipped_draws && s1.skipped_shaders >= s0.skipped_shaders + 1);

    // release the compile threads: everything becomes ready
    trim_test_hold(0);
    CHECK("the vertex source compiles", wait_ready(K[T_VSRC]) == TRIM_READY);
    CHECK("the fragment source compiles", wait_ready(K[T_FSRC]) == TRIM_READY);
    CHECK("the second pair compiles", wait_ready(K[T_VSRC2]) == TRIM_READY && wait_ready(K[T_FSRC2]) == TRIM_READY);
    int layer = 7; id<MTLLibrary> lb = trim_library(NAME(T_VSRC, "_b"), &layer), lp = trim_library(NAME(T_VSRC, "_bp"), NULL);
    CHECK("the base library has the shader's entry point", lb && [lb newFunctionWithName:@"main0"] && layer == 0);
    CHECK("the pulling library (a vertex variant) was compiled from its own source", lp && [lp newFunctionWithName:@"main0"]);
    CHECK("the pixel shader has no vertex variants", trim_library(NAME(T_FSRC, "_bp"), NULL) == nil && trim_library(NAME(T_FSRC, "_b"), NULL) != nil);
    CHECK("the unit serves _bx and _bf", trim_library(NAME(T_FSRC, "_bx"), NULL) != nil && trim_library(NAME(T_FSRC, "_bx"), NULL) == trim_library(NAME(T_FSRC, "_bf"), NULL) && [trim_library(NAME(T_FSRC, "_bx"), NULL) newFunctionWithName:@"main0_a"]);

    // the program now completes and is cached
    pr = prog_get(&pg);
    CHECK("the program is complete once its shaders are ready", pr && !pr->trim_pending && pr->sh[0] && pr->sh[1] && pr->sh[0]->fn && pr->sh[1]->fn);
    CHECK("and it is in the serial table", serial_get(pg.serial) == pr);
    s0 = trim_stats();
    state_reset(); memset(&R, 0, sizeof R);
    mtl_sub_begin(); mtl_exec(buf); f = mtl_sub_commit(); done = mtl_wait(f, 2000000000ull); mtl_drain();
    s1 = trim_stats();
    CHECK("the same draw is no longer skipped", done && !mtl_last_commit_error() && s1.skipped_draws == s0.skipped_draws);

    // loading a ready source shader: like a compiled one, and recorded
    t_trim_pending = 0; NvShader *vs = shader_get(NAME(T_VSRC, "_b"), 0), *fs = shader_get(NAME(T_FSRC, "_b"), 1);
    CHECK("a ready source shader loads like a compiled one", vs && fs && vs->fn && fs->fn && !t_trim_pending && vs->has_pull);
    NSString *rec = [NSString stringWithContentsOfFile:@(argv[2]) encoding:NSUTF8StringEncoding error:nil];
    CHECK("it is recorded in pso_user.tsv (S row), the compiled ones too", [rec containsString:[NSString stringWithFormat:@"S\t%@_b\t0\n", K[T_VSRC]]] && [rec containsString:[NSString stringWithFormat:@"S\t%@_b\t1\n", K[T_FSRC]]] && [rec containsString:[NSString stringWithFormat:@"S\t%@_b\t0\n", K[T_VUSED]]]);
    trim_stats_t st = trim_stats();
    CHECK("counters: compiled on the device, time, libraries, no failures", st.compiled >= 4 && st.libs >= 7 && st.compile_ns > 0 && st.failed == 0 && st.source_keys == 4 && st.inflated_bytes > 0);

    // the prewarm waits (t_trim_sync) instead of answering pending
    t_trim_sync = 1; t_trim_pending = 0; NvShader *w = shader_load(NAME(T_VSRC, "_b"), 0, 0); t_trim_sync = 0;
    CHECK("a waiting caller gets the shader", w && !t_trim_pending);

    printf("%d checks, %d failed\n", g_checks, g_failed);
    return g_failed != 0;
} }
