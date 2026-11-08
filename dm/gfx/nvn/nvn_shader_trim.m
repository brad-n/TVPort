// See nvn_shader_trim.h
#import "nvn_shader_trim.h"
#include <stdatomic.h>
#include <pthread.h>
#include <string.h>
#include "../../third_party/zstd/zstd.h"

@interface TrimShader : NSObject { @public int state; NSMutableDictionary<NSString *, id<MTLLibrary>> *libs; NSMutableSet<NSString *> *layer; int skip_logged; } @end
@implementation TrimShader @end

static NSCondition *g_cv;   // guards everything below but the counters
static NSMutableDictionary<NSString *, TrimShader *> *g_sh;
static NSMutableSet<NSString *> *g_src;
static NSMutableArray<NSString *> *g_q;
static id<MTLDevice> g_dev; static trim_read_fn g_rd; static trim_log_fn g_log; static int g_workers;
static _Atomic uint64_t c_compiled, c_failed, c_ns, c_libs, c_skip, c_skip_sh, c_inflated;
static ZSTD_DDict *g_dd[2]; static pthread_mutex_t g_dd_lock = PTHREAD_MUTEX_INITIALIZER;
static __thread ZSTD_DCtx *t_dctx;
#define LOG(...) do { if (g_log) g_log([NSString stringWithFormat:__VA_ARGS__]); } while (0)

static ZSTD_DDict *dict_of(int json) {
    pthread_mutex_lock(&g_dd_lock);
    if (!g_dd[json]) { NSData *d = g_rd ? g_rd(json ? @"trim_json.dict" : @"trim.dict") : nil; if (d.length) g_dd[json] = ZSTD_createDDict(d.bytes, d.length); }
    ZSTD_DDict *r = g_dd[json]; pthread_mutex_unlock(&g_dd_lock); return r;
}
NSData *trim_inflate(NSData *frame, int json) {
    ZSTD_DDict *dd = dict_of(json ? 1 : 0);
    unsigned long long n = ZSTD_getFrameContentSize(frame.bytes, frame.length);
    if (!dd || n == ZSTD_CONTENTSIZE_ERROR || n == ZSTD_CONTENTSIZE_UNKNOWN || n > (256ull << 20)) return nil;
    if (!t_dctx) t_dctx = ZSTD_createDCtx();
    NSMutableData *o = [NSMutableData dataWithLength:(NSUInteger)n];
    size_t r = ZSTD_decompress_usingDDict(t_dctx, o.mutableBytes, (size_t)n, frame.bytes, frame.length, dd);
    if (ZSTD_isError(r) || r != n) return nil;
    atomic_fetch_add(&c_inflated, n);
    return o;
}

MTLCompileOptions *trim_compile_options(void) {
    // The build compiles with -O1 -fmetal-math-mode=relaxed -fpreserve-invariance -fbracket-depth=1024 -mios-version-min=18.0. MTLCompileOptions has the math mode, the invariance switch and the
    // language version (iOS 18 = MSL 3.2), but no -O1 (its optimization levels are Default and Size) and no bracket depth (the front end keeps its limit of 256 nested brackets)
    MTLCompileOptions *o = [MTLCompileOptions new];
    o.preserveInvariance = YES;
    if (@available(macOS 15.0, iOS 18.0, tvOS 18.0, *)) { o.mathMode = MTLMathModeRelaxed; o.languageVersion = MTLLanguageVersion3_2; }
    // an older system keeps the default (fast math)
    return o;
}

static NSString *const kSuf[] = {@"_b", @"_bp", @"_bv", @"_bu"};

static void compile_key(NSString *key) {
    uint64_t t0 = clock_gettime_nsec_np(CLOCK_MONOTONIC);
    TrimShader *s; [g_cv lock]; s = g_sh[key]; [g_cv unlock];
    NSMutableDictionary *libs = [NSMutableDictionary dictionary]; NSMutableSet *layer = [NSMutableSet set]; int ok = 1; NSString *why = nil;
    MTLCompileOptions *opts = trim_compile_options();
    for (int i = 0; i < 4 && ok; i++) {
        NSData *fr = g_rd([NSString stringWithFormat:@"%@%@.msl", key, kSuf[i]]);
        if (!fr) { if (i == 0) { ok = 0; why = @"no source in the image"; } continue; }
        NSData *txt = trim_inflate(fr, 0);
        if (!txt) { ok = 0; why = [NSString stringWithFormat:@"%@%@.msl does not inflate", key, kSuf[i]]; break; }
        NSString *src = [[NSString alloc] initWithData:txt encoding:NSUTF8StringEncoding];
        NSError *e = nil; id<MTLLibrary> lib = src ? [g_dev newLibraryWithSource:src options:opts error:&e] : nil;
        if (!lib) { if (i == 0) { ok = 0; why = [NSString stringWithFormat:@"%@: %@", kSuf[i], e.localizedDescription ?: @"bad text"]; }
                    else LOG(@"[RED] shader trim: %@%@ does not compile on the device (%@): the shader goes without it", key, kSuf[i], [e.localizedDescription substringToIndex:MIN(e.localizedDescription.length, 160)]);
                    continue; }
        libs[kSuf[i]] = lib; atomic_fetch_add(&c_libs, 1);
        if (memmem(txt.bytes, txt.length, "render_target_array_index", 25)) [layer addObject:kSuf[i]];
    }
    uint64_t dt = clock_gettime_nsec_np(CLOCK_MONOTONIC) - t0;
    [g_cv lock];
    s->libs = libs; s->layer = layer; s->state = ok ? TRIM_READY : TRIM_FAILED;
    [g_cv broadcast]; [g_cv unlock];
    atomic_fetch_add(&c_ns, dt);
    if (ok) { uint64_t n = atomic_fetch_add(&c_compiled, 1) + 1; if (n <= 3 || !(n & (n - 1))) LOG(@"shader trim: %llu shaders compiled from source on the device (this one %@, %.0f ms, %lu libraries)", n, key, dt / 1e6, (unsigned long)libs.count); }
    else { uint64_t n = atomic_fetch_add(&c_failed, 1) + 1; if (n <= 8) LOG(@"[RED] shader trim: %@ failed to compile from source: %@", key, why); }
}
static void *worker(void *arg) {
    (void)arg; pthread_setname_np("shader-trim"); pthread_set_qos_class_self_np(QOS_CLASS_UTILITY, 0);
    for (;;) {
        @autoreleasepool {
            [g_cv lock]; while (!g_q.count) [g_cv wait];
            NSString *key = g_q.firstObject; [g_q removeObjectAtIndex:0]; [g_cv unlock];
            compile_key(key);
        }
    }
    return NULL;
}

void trim_configure(id<MTLDevice> dev, trim_read_fn rd, trim_log_fn log, int workers) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g_cv = [NSCondition new]; g_sh = [NSMutableDictionary dictionary]; g_src = [NSMutableSet set]; g_q = [NSMutableArray array];
        g_dev = dev; g_rd = [rd copy]; g_log = [log copy]; g_workers = workers < 1 ? 1 : workers > 8 ? 8 : workers;
        for (int i = 0; i < g_workers; i++) { pthread_t t; pthread_create(&t, NULL, worker, NULL); pthread_detach(t); }
    });
}
void trim_add_source_key(NSString *key) { [g_cv lock]; [g_src addObject:key]; [g_cv unlock]; }
int trim_active(void) { [g_cv lock]; int r = g_src.count != 0; [g_cv unlock]; return r; }
int trim_is_source(NSString *key) { if (!g_cv) return 0; [g_cv lock]; int r = [g_src containsObject:key]; [g_cv unlock]; return r; }
int trim_state(NSString *key) {
    if (!g_cv) return TRIM_NONE;
    [g_cv lock]; int r = ![g_src containsObject:key] ? TRIM_NONE : g_sh[key] ? g_sh[key]->state : TRIM_PENDING; [g_cv unlock]; return r;
}
int trim_ensure(NSString *key, int wait) {
    if (!g_cv) return TRIM_NONE;
    [g_cv lock];
    if (![g_src containsObject:key]) { [g_cv unlock]; return TRIM_NONE; }
    TrimShader *s = g_sh[key];
    if (!s) { s = [TrimShader new]; s->state = TRIM_PENDING; g_sh[key] = s; if (wait) [g_q insertObject:key atIndex:0]; else [g_q addObject:key]; [g_cv broadcast]; }
    while (wait && s->state == TRIM_PENDING) [g_cv wait];
    int r = s->state; [g_cv unlock]; return r;
}
id<MTLLibrary> trim_library(NSString *name, int *layer) {
    if (name.length < 18 || !g_cv) return nil;
    NSString *key = [name substringToIndex:16], *suf = [name substringFromIndex:16];
    if ([suf isEqual:@"_bx"] || [suf isEqual:@"_bf"]) suf = @"_bu";
    [g_cv lock]; TrimShader *s = g_sh[key]; id<MTLLibrary> lib = s && s->state == TRIM_READY ? s->libs[suf] : nil; int l = lib && [s->layer containsObject:suf]; [g_cv unlock];
    if (layer) *layer = l;
    return lib;
}
NSData *trim_json(NSString *key) {
    NSData *fr = g_rd ? g_rd([key stringByAppendingString:@"_b.jsonz"]) : nil;
    return fr ? trim_inflate(fr, 1) : nil;
}
void trim_note_skip(NSString *key) {
    atomic_fetch_add(&c_skip, 1);
    [g_cv lock]; TrimShader *s = g_sh[key]; int first = s && !s->skip_logged; if (first) s->skip_logged = 1; [g_cv unlock];
    if (!first) return;
    uint64_t n = atomic_fetch_add(&c_skip_sh, 1) + 1;
    if (n <= 200) LOG(@"shader trim: a draw is skipped while %@ compiles from source (shader %llu of this run)", key, n);
}
trim_stats_t trim_stats(void) {
    trim_stats_t t = {atomic_load(&c_compiled), atomic_load(&c_failed), atomic_load(&c_ns), atomic_load(&c_libs), atomic_load(&c_skip), atomic_load(&c_skip_sh), atomic_load(&c_inflated), 0};
    if (g_cv) { [g_cv lock]; t.source_keys = g_src.count; [g_cv unlock]; }
    return t;
}
