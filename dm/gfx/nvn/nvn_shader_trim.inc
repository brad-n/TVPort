// Shader trimming at run time (dm/gfx/tools/shader_trim.py; docs/reference/tv-size.md, "Cut 2 as built: shader trimming"). A trimmed library keeps the shaders the game has used as plain entries and
// packs each other vertex and pixel shader into one zstd frame, <key>.trim, of its build output byte for byte: its libraries (AIR, as dmsh_build.py compiled them) and its reflection. The first
// time anything reads a file of a packed shader (msl_data, lib_from_file), the shader's whole frame is inflated into a cache folder and its files are read from there as from a library folder:
// a regular file, mapped and handed to Metal like the image's own entries (clean pages, which the system can drop, not malloc'd ones), and kept for the next start. Nothing is compiled from
// source and nothing is skipped: the cost of a packed shader is the inflate, about a millisecond, on the thread that asks first (another thread asking meanwhile waits for it), then the same
// pipeline builds as for any library the device has not met. The cache folder is <root>/<the trimmed image's id>: an install of another trimmed image leaves its own folder, and the others
// are removed at the first use; a folder over DM_SHADER_TRIM_CACHE_MB (1024 by default) is emptied at the start, before anything maps its files.
// Root: DM_SHADER_TRIM_CACHE, else the app's Library/Caches/shader-trim on iOS and tvOS, else shader-trim beside the save folder (as pso_user.tsv) on the Mac, else the temporary folder.
// The pipeline prebuild, which walks every shader pair the profile knows (pso_prebuild), never inflates (t_trim_quiet): a packed shader counts there as a file the app does not carry until
// something has drawn with it (pre_lib_absent). Nor does the prefetch at program creation (trim_prefetch_skip): the draws do, with the submission's other new shaders in parallel.
// Included into nvn_mtl.m after msl_image_file (it reads the same image) and before msl_data
#include <dirent.h>
#include "../../third_party/zstd/zstd.h"   // decoder only (dm/host/Makefile ZSTD)

enum { TRIM_NONE, TRIM_BUSY, TRIM_READY, TRIM_FAILED };
typedef struct { char key[17]; _Atomic uint8_t state; char *files; } trim_ent;   // files: the packed file names without the key, comma separated (trim.tsv)
static struct {
    _Atomic int state;   // 0 not looked at yet, 1 this library packs nothing, 2 open
    romfs_img *img; trim_ent *e; size_t n; ZSTD_DDict *dd; char dir[1024], id[24];
    pthread_mutex_t mu; pthread_cond_t cv;
    _Atomic uint64_t inflated, files, bytes, ns, max_ns, waits, cached, failed, deferred, sub_n, sub_ns, sub_waits;
} g_trim = {.mu = PTHREAD_MUTEX_INITIALIZER, .cv = PTHREAD_COND_INITIALIZER};
static __thread int t_trim_quiet;   // this thread does not inflate: a packed shader that is not in the cache yet is absent for it (the pipeline prebuild)

static NSString *trim_cache_root(void) {
    const char *e = getenv("DM_SHADER_TRIM_CACHE");
    if (e && *e) return @(e);
#if TARGET_OS_IPHONE
    NSString *c = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    if (c) return [c stringByAppendingPathComponent:@"shader-trim"];
#endif
    const char *save = getenv("DM_SAVE");
    if (save && *save) return [[@(save) stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"shader-trim"];
    return [NSTemporaryDirectory() stringByAppendingPathComponent:@"nxnative-shader-trim"];
}
static uint64_t trim_dir_bytes(const char *dir, int remove) {   // the files' bytes in a flat folder, removing them when remove (and the folder itself when remove == 2)
    DIR *d = opendir(dir); if (!d) return 0;
    uint64_t total = 0; struct dirent *de; char p[1300]; struct stat st;
    while ((de = readdir(d))) {
        if (de->d_name[0] == '.' && (!de->d_name[1] || (de->d_name[1] == '.' && !de->d_name[2]))) continue;
        snprintf(p, sizeof p, "%s/%s", dir, de->d_name);
        if (!stat(p, &st) && S_ISREG(st.st_mode)) total += (uint64_t)st.st_size;
        if (remove) unlink(p);
    }
    closedir(d);
    if (remove == 2) rmdir(dir);
    return total;
}
static void trim_bench_start(void);
static int trim_cmp(const void *a, const void *b) { return memcmp(((const trim_ent *)a)->key, ((const trim_ent *)b)->key, 16); }
// Reads the image's trim.tsv and trim.dict once. Not an error when the library packs nothing (every library before this, and a trimmed one of a game whose lists name every shader)
static void trim_open(void) {
    if (!g_msl_dir) return;   // no library yet (shmap_read names it): asked again later
    static dispatch_once_t once;
    dispatch_once(&once, ^{ @autoreleasepool {
        romfs_img *m = NULL; const img_ent *ix = g_msl_dir ? msl_image_file([g_msl_dir stringByAppendingPathComponent:@"trim.tsv"], &m) : NULL;
        if (!ix || !m || ix->b > (256u << 20)) { atomic_store(&g_trim.state, 1); return; }
        char *txt = malloc((size_t)ix->b + 1);
        if (!txt || !romfs_image_read(m, txt, (size_t)ix->b, ix->a)) { free(txt); MLOG("[RED] shader trimming: cannot read the library's trim.tsv: the packed shaders do not load"); atomic_store(&g_trim.state, 1); return; }
        txt[ix->b] = 0;
        char *save = NULL, *ln = strtok_r(txt, "\n", &save);
        if (!ln || strncmp(ln, "# shader_trim 1\t", 16) || strlen(ln + 16) >= sizeof g_trim.id) { MLOG("[RED] shader trimming: the library's trim.tsv is not version 1 (%.40s): the packed shaders do not load", ln ? ln : ""); free(txt); atomic_store(&g_trim.state, 1); return; }
        strlcpy(g_trim.id, ln + 16, sizeof g_trim.id);
        size_t cap = 1024, n = 0; trim_ent *e = calloc(cap, sizeof *e);
        while ((ln = strtok_r(NULL, "\n", &save))) {
            if (ln[0] == '#') continue;
            char *t1 = strchr(ln, '\t'), *t2 = t1 ? strchr(t1 + 1, '\t') : NULL;
            if (!t1 || !t2 || t1 - ln != 16) continue;
            if (n == cap) { cap *= 2; e = realloc(e, cap * sizeof *e); memset(e + n, 0, (cap - n) * sizeof *e); }
            memcpy(e[n].key, ln, 16); e[n].key[16] = 0; e[n].files = strdup(t2 + 1); n++;
        }
        free(txt);
        qsort(e, n, sizeof *e, trim_cmp);
        const img_ent *dx = msl_image_file([g_msl_dir stringByAppendingPathComponent:@"trim.dict"], &m);
        if (dx && dx->b && dx->b < (64u << 20)) {
            void *d = malloc((size_t)dx->b);
            if (d && romfs_image_read(m, d, (size_t)dx->b, dx->a)) g_trim.dd = ZSTD_createDDict(d, (size_t)dx->b);
            free(d);
            if (!g_trim.dd) MLOG("[RED] shader trimming: the library's trim.dict does not load: the packed shaders will fail to inflate");
        }
        NSString *root = trim_cache_root(), *dir = [root stringByAppendingPathComponent:@(g_trim.id)];
        [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
        for (NSString *other in [NSFileManager.defaultManager contentsOfDirectoryAtPath:root error:NULL])   // another trimmed image's folder (an earlier install): not read again
            if (![other isEqualToString:@(g_trim.id)]) trim_dir_bytes([root stringByAppendingPathComponent:other].fileSystemRepresentation, 2);
        strlcpy(g_trim.dir, dir.fileSystemRepresentation, sizeof g_trim.dir);
        const char *capmb = getenv("DM_SHADER_TRIM_CACHE_MB");
        uint64_t have = trim_dir_bytes(g_trim.dir, 0), limit = (uint64_t)(capmb && *capmb ? strtoull(capmb, NULL, 10) : 1024) << 20;
        if (limit && have > limit) { trim_dir_bytes(g_trim.dir, 1); MLOG("shader trimming: the cache folder held %.0f MB, over DM_SHADER_TRIM_CACHE_MB (%llu): emptied, what this run needs is inflated again", have / 1048576.0, (unsigned long long)(limit >> 20)); have = 0; }
        g_trim.img = m; g_trim.e = e; g_trim.n = n;
        atomic_store(&g_trim.state, 2);
        MLOG("shader trimming: %zu vertex and pixel shaders of this library are packed (trim.tsv %s, %s), inflated at first use into %s (%.1f MB there from earlier runs)",
             n, g_trim.id, g_trim.dd ? "with its dictionary" : "no dictionary", g_trim.dir, have / 1048576.0);
        trim_bench_start();
    } });
}
// The packed shader a library file name belongs to, NULL when the library packs no such file
static trim_ent *trim_find(const char *name) {
    if (atomic_load_explicit(&g_trim.state, memory_order_acquire) != 2) { if (atomic_load(&g_trim.state)) return NULL; trim_open(); if (atomic_load(&g_trim.state) != 2) return NULL; }
    size_t len = strlen(name); if (len <= 16) return NULL;
    trim_ent want; memcpy(want.key, name, 16);
    trim_ent *t = bsearch(&want, g_trim.e, g_trim.n, sizeof *g_trim.e, trim_cmp); if (!t) return NULL;
    const char *suf = name + 16; size_t sl = len - 16;
    for (const char *p = t->files; *p; ) {
        const char *c = strchr(p, ','); size_t l = c ? (size_t)(c - p) : strlen(p);
        if (l == sl && !memcmp(p, suf, sl)) return t;
        if (!c) break; p = c + 1;
    }
    return NULL;
}
static int trim_cached_in(const trim_ent *t, const char *dir) {   // every file of the shader is in the folder (inflated by an earlier run)
    char p[1300]; struct stat st;
    for (const char *f = t->files; *f; ) {
        const char *c = strchr(f, ','); int l = c ? (int)(c - f) : (int)strlen(f);
        snprintf(p, sizeof p, "%s/%s%.*s", dir, t->key, l, f);
        if (stat(p, &st) || !S_ISREG(st.st_mode)) return 0;
        if (!c) break; f = c + 1;
    }
    return 1;
}
static int trim_cached(const trim_ent *t) { return trim_cached_in(t, g_trim.dir); }
static int trim_write(const char *path, const uint8_t *p, size_t n) {   // a file whole or not at all: written beside it, then renamed
    char tmp[1400]; snprintf(tmp, sizeof tmp, "%s.%d.%llx.part", path, getpid(), (unsigned long long)(uintptr_t)pthread_self());
    int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0644); if (fd < 0) return 0;
    for (size_t o = 0; o < n; ) { ssize_t w = write(fd, p + o, n - o); if (w <= 0) { close(fd); unlink(tmp); return 0; } o += (size_t)w; }
    if (close(fd) || rename(tmp, path)) { unlink(tmp); return 0; }
    return 1;
}
// Inflates the shader's frame into dir (the cache folder). tm, when given: {ns reading the frame and inflating it, ns writing the files}. → NULL, or why not
static const char *trim_inflate(const trim_ent *t, const char *dir, uint64_t *out_bytes, int *out_files, uint64_t tm[2]) {
    uint64_t t_start = bp_now(), t_write = 0;
    char name[32]; snprintf(name, sizeof name, "%s.trim", t->key);
    const img_ent *x = msl_image_find(g_trim.img, name);
    if (!x || !x->b) return "its frame is not in the library";
    uint8_t *in = malloc((size_t)x->b); if (!in) return "out of memory";
    const char *why = NULL; uint8_t *out = NULL;
    if (!romfs_image_read(g_trim.img, in, (size_t)x->b, x->a)) { why = "the library cannot be read"; goto done; }
    unsigned long long n = ZSTD_getFrameContentSize(in, (size_t)x->b);
    if (n == ZSTD_CONTENTSIZE_ERROR || n == ZSTD_CONTENTSIZE_UNKNOWN || n < 8 || n > (512ull << 20)) { why = "not a zstd frame of a known size"; goto done; }
    if (!(out = malloc((size_t)n))) { why = "out of memory"; goto done; }
    ZSTD_DCtx *dc = ZSTD_createDCtx();
    size_t r = !dc ? 0 : g_trim.dd ? ZSTD_decompress_usingDDict(dc, out, (size_t)n, in, (size_t)x->b, g_trim.dd) : ZSTD_decompressDCtx(dc, out, (size_t)n, in, (size_t)x->b);
    ZSTD_freeDCtx(dc);
    if (!dc || ZSTD_isError(r) || r != n) { why = dc && ZSTD_isError(r) ? ZSTD_getErrorName(r) : "the frame inflates to the wrong size"; goto done; }
    if (memcmp(out, "DMT1", 4)) { why = "not a shader_trim frame"; goto done; }
    if (tm) tm[0] = bp_now() - t_start;
    uint32_t count; memcpy(&count, out + 4, 4); size_t at = 8; int files = 0;
    for (uint32_t i = 0; i < count; i++) {
        uint16_t nl; uint32_t sz;
        if (at + 6 > n) { why = "the frame ends inside a file"; goto done; }
        memcpy(&nl, out + at, 2); memcpy(&sz, out + at + 2, 4); at += 6;
        if (at + nl + (uint64_t)sz > n || nl < 17 || nl > 200 || memcmp(out + at, t->key, 16)) { why = "a file of another shader, or the frame ends inside one"; goto done; }
        char fn[256], path[1300]; memcpy(fn, out + at, nl); fn[nl] = 0; at += nl;
        snprintf(path, sizeof path, "%s/%s", dir, fn);
        uint64_t w0 = bp_now(); int wrote = trim_write(path, out + at, sz); t_write += bp_now() - w0;
        if (!wrote) { why = "the cache folder cannot be written (a full disk?)"; goto done; }
        at += sz; files++;
    }
    if (at != n) why = "bytes after the last file";
    else if (!trim_cached_in(t, dir)) why = "the frame lacks a file its index names";
    if (tm) tm[1] = t_write;
    *out_bytes = n; *out_files = files;
done:
    free(in); free(out);
    return why;
}
// The path in the cache folder of a packed shader's file, the shader's frame inflated there first when it is not yet. 0: the library packs no such file (path untouched); 1: path is the
// file; -1: packed and not inflated, and this thread does not inflate (t_trim_quiet); -2: packed, and its frame does not inflate
static int trim_path(const char *name, char *path, size_t pn) {
    trim_ent *t = trim_find(name); if (!t) return 0;
    snprintf(path, pn, "%s/%s", g_trim.dir, name);
    for (;;) {
        uint8_t s = atomic_load(&t->state);
        if (s == TRIM_READY) return 1;
        if (s == TRIM_FAILED) return -2;
        if (s == TRIM_NONE && trim_cached(t)) { uint8_t z = TRIM_NONE; if (atomic_compare_exchange_strong(&t->state, &z, TRIM_READY)) atomic_fetch_add(&g_trim.cached, 1); continue; }
        if (t_trim_quiet) { atomic_fetch_add(&g_trim.deferred, 1); return -1; }
        uint8_t z = TRIM_NONE;
        if (s == TRIM_NONE && atomic_compare_exchange_strong(&t->state, &z, TRIM_BUSY)) {
            char tn[64] = ""; pthread_getname_np(pthread_self(), tn, sizeof tn);
            uint64_t t0 = bp_now(), bytes = 0; int files = 0, sub = on_sub_thread() || (tn[0] && strncmp(tn, "com.apple.", 10));   // sub: a thread a frame waits on (the submit thread, a game thread), not a worker
            const char *why = trim_inflate(t, g_trim.dir, &bytes, &files, NULL);
            uint64_t dt = bp_now() - t0;
            pthread_mutex_lock(&g_trim.mu); atomic_store(&t->state, why ? TRIM_FAILED : TRIM_READY); pthread_cond_broadcast(&g_trim.cv); pthread_mutex_unlock(&g_trim.mu);
            if (why) { uint64_t f = atomic_fetch_add(&g_trim.failed, 1) + 1; if (f <= 16) MLOG("[RED] shader trimming: shader %s cannot be inflated (%s): it does not load, its draws go without it", t->key, why); return -2; }
            uint64_t k = atomic_fetch_add(&g_trim.inflated, 1) + 1; atomic_fetch_add(&g_trim.files, (uint64_t)files); atomic_fetch_add(&g_trim.bytes, bytes); atomic_fetch_add(&g_trim.ns, dt);
            for (uint64_t m = atomic_load(&g_trim.max_ns); dt > m && !atomic_compare_exchange_weak(&g_trim.max_ns, &m, dt); ) {}
            if (sub) { atomic_fetch_add(&g_trim.sub_n, 1); atomic_fetch_add(&g_trim.sub_ns, dt); }
            if (k <= 8 || !(k & (k - 1)))
                MLOG("shader trimming: shader %s inflated from the library (%d files, %.0f KB, %.2f ms, on %s), %llu so far", t->key, files, bytes / 1024.0, dt / 1e6, on_sub_thread() ? "the submit thread" : tn[0] ? tn : "a worker thread", (unsigned long long)k);
            return 1;
        }
        pthread_mutex_lock(&g_trim.mu);   // another thread is inflating it
        { char tn[64] = ""; pthread_getname_np(pthread_self(), tn, sizeof tn); atomic_fetch_add(&g_trim.waits, 1); if (on_sub_thread() || (tn[0] && strncmp(tn, "com.apple.", 10))) atomic_fetch_add(&g_trim.sub_waits, 1); }
        while (atomic_load(&t->state) == TRIM_BUSY) pthread_cond_wait(&g_trim.cv, &g_trim.mu);
        pthread_mutex_unlock(&g_trim.mu);
    }
}
static int trim_in_lib(NSString *path) { return g_trim.state != 1 && g_msl_dir && path.length > g_msl_dir.length && [path hasPrefix:g_msl_dir]; }   // a file of the library (not another folder's)
static int trim_path_ns(NSString *path, char *out, size_t n) { return trim_in_lib(path) ? trim_path(path.lastPathComponent.UTF8String, out, n) : 0; }
// Whether the cache folder holds a packed file now (without inflating): what msl_has answers for one
static int trim_have(NSString *path) {
    if (!trim_in_lib(path)) return 0;
    trim_ent *t = trim_find(path.lastPathComponent.UTF8String);
    return t && (atomic_load(&t->state) == TRIM_READY || (atomic_load(&t->state) == TRIM_NONE && trim_cached(t)));
}
// The prefetch at program creation (mtl_prog_prefetch) leaves a packed shader that is not inflated yet to the draws, which load the shaders a submission binds in parallel
// (shader_prefetch_rest): a game makes programs for far more shaders than it draws (Ocarina of Time's balcony route on the Mac with every shader packed: 7,061 inflated at program
// creation, 1.28 GB in the cache folder, against 752 drawn), and each would take its room in the cache folder. DM_SHADER_TRIM_PREFETCH=1 inflates them there too
static int trim_prefetch_skip(NSString *pc) {
    static int on = -1; if (on < 0) { const char *e = getenv("DM_SHADER_TRIM_PREFETCH"); on = e && *e == '1'; }
    if (on || g_trim.state == 1) return 0;
    trim_ent *t = trim_find([pc stringByAppendingString:@".json"].UTF8String);   // pc: <key>_b
    if (!t || atomic_load(&t->state) != TRIM_NONE || trim_cached(t)) return 0;
    atomic_fetch_add(&g_trim.deferred, 1); return 1;
}
// DM_SHADER_TRIM_BENCH=<n>: what a first use of a packed shader costs on this device, measured and logged at launch (nothing here touches the cache folder). n packed shaders, spread through the
// library, are inflated into a scratch folder, and each of their libraries is loaded as Metal library as the first draw would (lib_from_file: mapped, newLibraryWithData); the times of each (the frame read
// and inflated, the files written, the libraries loaded) and their totals are logged, and the scratch folder is removed. Metal may keep a library it has met before, so a repeat on one device loads faster
static id<MTLLibrary> lib_from_file(NSString *path, NSError **err);
static void trim_bench(int want) {
    char scratch[1400]; snprintf(scratch, sizeof scratch, "%s/nxnative-trim-bench-%d", NSTemporaryDirectory().fileSystemRepresentation, getpid());
    mkdir(scratch, 0755);
    size_t n = g_trim.n, take = (size_t)want < n ? (size_t)want : n, done = 0, failed = 0, libs = 0; uint64_t sum[3] = {0, 0, 0}, bytes_total = 0, t_all = bp_now();
    for (size_t i = 0; i < take; i++) {
        const trim_ent *t = &g_trim.e[i * n / take];
        uint64_t bytes = 0, tm[2] = {0, 0}; int files = 0;
        const char *why = trim_inflate(t, scratch, &bytes, &files, tm);
        if (why) { failed++; MLOG("shader trim bench: shader %s cannot be inflated (%s)", t->key, why); continue; }
        uint64_t lib_ns = 0; int loaded = 0, bad = 0;
        for (const char *f = t->files; *f; ) {
            const char *c = strchr(f, ','); int l = c ? (int)(c - f) : (int)strlen(f);
            if (l > 9 && !strncmp(f + l - 9, ".metallib", 9)) {
                @autoreleasepool {
                    NSError *e = nil; uint64_t l0 = bp_now();
                    id<MTLLibrary> lib = lib_from_file([NSString stringWithFormat:@"%s/%s%.*s", scratch, t->key, l, f], &e);
                    lib_ns += bp_now() - l0; if (lib) loaded++; else bad++;
                }
            }
            if (!c) break; f = c + 1;
        }
        sum[0] += tm[0]; sum[1] += tm[1]; sum[2] += lib_ns; bytes_total += bytes; libs += (size_t)loaded; done++; failed += bad ? 1 : 0;
        MLOG("shader trim bench: shader %s (%d files, %.0f KB inflated): decompress %.3f ms, write %.3f ms, library load %.3f ms (%d libraries%s)", t->key, files, bytes / 1024.0, tm[0] / 1e6, tm[1] / 1e6, lib_ns / 1e6, loaded, bad ? ", some failed" : "");
    }
    trim_dir_bytes(scratch, 2);
    double d = done ? done : 1;
    MLOG("shader trim bench: %zu shaders measured, %zu failed (of %zu asked for, %zu packed), %zu libraries, %.1f KB inflated; totals: decompress %.2f ms, write %.2f ms, library load %.2f ms; per shader: %.3f + %.3f + %.3f = %.3f ms; %.1f ms in all; scratch folder removed",
         done, failed, (size_t)want, n, libs, bytes_total / 1024.0, sum[0] / 1e6, sum[1] / 1e6, sum[2] / 1e6, sum[0] / 1e6 / d, sum[1] / 1e6 / d, sum[2] / 1e6 / d, (sum[0] + sum[1] + sum[2]) / 1e6 / d, (bp_now() - t_all) / 1e6);
}
static void trim_bench_start(void) {   // from trim_open, once the index is read: on a thread of its own, once the Metal device exists
    const char *e = getenv("DM_SHADER_TRIM_BENCH"); int want = e && *e ? atoi(e) : 0;
    if (want <= 0 || !g_trim.n) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        for (int i = 0; !g_dev && i < 600; i++) usleep(100000);
        if (g_dev) trim_bench(want); else MLOG("shader trim bench: no Metal device after 60 s");
    });
}
static void trim_log_stats(const char *when) {
    if (atomic_load(&g_trim.state) != 2) return;
    static _Atomic uint64_t last = UINT64_MAX; uint64_t now = g_trim.inflated + g_trim.cached + g_trim.failed + g_trim.waits;
    if (!strcmp(when, "so far") && atomic_exchange(&last, now) == now) return;   // the periodic line only when something changed
    MLOG("shader trimming %s: %llu of %zu packed shaders inflated (%llu files, %.1f MB, %.1f ms, longest %.2f ms; %llu on a thread a frame waits on, the submit thread or a game thread, %.1f ms; %llu waits for another thread's, %llu on such a thread), "
         "%llu taken from the cache folder, %llu left to a later load (the pipeline prebuild, the prefetch at program creation), %llu failed", when, (unsigned long long)g_trim.inflated, g_trim.n, (unsigned long long)g_trim.files,
         g_trim.bytes / 1048576.0, g_trim.ns / 1e6, g_trim.max_ns / 1e6, (unsigned long long)g_trim.sub_n, g_trim.sub_ns / 1e6, (unsigned long long)g_trim.waits, (unsigned long long)g_trim.sub_waits,
         (unsigned long long)g_trim.cached, (unsigned long long)g_trim.deferred, (unsigned long long)g_trim.failed);
}
