// CPU-only cache tests: no Metal device, guest, or emulator is started.
#include <unistd.h>
#include <errno.h>
#include <stdatomic.h>
static _Atomic int read_fault;
static _Atomic unsigned read_calls;
static _Atomic size_t largest_read;
static ssize_t test_pread(int fd, void *output, size_t size, off_t offset) {
    unsigned call = atomic_fetch_add(&read_calls, 1);
    size_t largest = atomic_load(&largest_read);
    while (size > largest && !atomic_compare_exchange_weak(&largest_read, &largest, size)) {}
    int fault = atomic_load(&read_fault);
    if (fault == 1 && !call) { errno = EINTR; return -1; }
    if (fault == 4 || (fault == 3 && call)) { errno = EIO; return -1; }
    if (fault == 5) return 0;
    if ((fault == 2 || fault == 3) && size > 113) size = 113;
    return pread(fd, output, size, offset);
}
#define pread test_pread
#include "../tex/nvn_astc_cache.m"
#undef pread
#include <assert.h>
#include <sys/mman.h>

static unsigned checks, failures;
#define CHECK(condition) do { checks++; if (!(condition)) { failures++; fprintf(stderr, "line %d: %s\n", __LINE__, #condition); } } while (0)

static NSString *fixture(NSString *root, unsigned key, size_t size) {
    NSString *path = [root stringByAppendingPathComponent:[NSString stringWithFormat:@"%064x.astc", key]];
    uint8_t *bytes = malloc(size);
    memset(bytes, (uint8_t)key, size);
    cache_write(path, bytes, size);
    free(bytes);
    return path;
}
static uint8_t stream_byte(size_t index) { return (uint8_t)(index ^ (index >> 7) ^ (index >> 15)); }

// ---- background miss policy: learn / fetch, the bounded queue, the size cap, the free-disk floor, corrupt entries ----
static void bg_configure(NSString *dir, size_t queue_cap, uint64_t cache_max, uint64_t min_free, unsigned threads) {
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    nvn_astc_bg_config c = {.cache = dir.fileSystemRepresentation, .readonly = NULL, .queue_cap = queue_cap, .cache_max = cache_max, .min_free = min_free, .threads = threads};
    nvn_bc_astc_bg_configure(&c);
}
static void bc7_plane(uint8_t *data, size_t size, unsigned seed) {   // BC7 mode 6 blocks of noise
    uint32_t state = seed * 2654435761u + 1;
    for (size_t i = 0; i < size; i++) { state = state * 1664525u + 1013904223u; data[i] = state >> 24; }
    for (size_t i = 0; i < size; i += 16) data[i] = (data[i] & ~0x7fu) | 0x40u;
}
static size_t count_entries(NSString *dir) {
    size_t n = 0; for (NSString *f in [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:NULL]) if (f.length == 69 && [f hasSuffix:@".astc"]) n++;
    return n;
}
static void background_contract(NSString *root) {
    const unsigned W = 128, H = 128; const size_t bytes = (size_t)W * H;   // BC7: 16 bytes a 4x4 block
    const size_t astc_bytes = (size_t)((W + 3) / 4) * ((H + 3) / 4) * 16;
    uint8_t *plane = malloc(bytes), *fetched = malloc(astc_bytes), *direct = malloc(astc_bytes);
    // miss -> queued -> encoded by a worker -> hit; the entry is the one the synchronous encoder makes
    NSString *a = [root stringByAppendingPathComponent:@"bg-a"];
    bg_configure(a, 64u << 20, 1ull << 30, 0, 2);
    bc7_plane(plane, bytes, 1);
    nvn_astc_cache_key key;
    CHECK(nvn_bc_astc_learn(0x4d, plane, bytes, W, H, 4, &key) == 0);
    CHECK(nvn_bc_astc_fetch(0x4d, plane, bytes, W, H, 4, fetched, astc_bytes) >= 0);   // may or may not be there yet; either way never an error
    CHECK(nvn_bc_astc_bg_wait(120));
    nvn_astc_bg_stats s; nvn_bc_astc_bg_stats(&s);
    CHECK(s.encoded == 1 && s.written == 1 && s.duplicates + s.queued >= 1 && count_entries(a) == 1);
    CHECK(nvn_bc_astc_learn(0x4d, plane, bytes, W, H, 4, NULL) == 1);
    CHECK(nvn_bc_astc_fetch(0x4d, plane, bytes, W, H, 4, fetched, astc_bytes) == 1);
    NSString *b = [root stringByAppendingPathComponent:@"bg-sync"];
    int hit; CHECK(!nvn_bc_astc_encode(0x4d, plane, bytes, W, H, 4, direct, astc_bytes, b.fileSystemRepresentation, NULL, &hit) && !hit);
    CHECK(!memcmp(fetched, direct, astc_bytes));   // background and synchronous encodes are the same bytes
    CHECK(nvn_bc_astc_learn(0x4d, plane, bytes, 64, 64, 4, NULL) == -1);   // wrong size for the format: invalid, not queued
    CHECK(nvn_bc_astc_learn(0x49, plane, bytes, W, H, 4, NULL) == -1);    // BC4 has no ASTC form
    // a plane already pending is not queued twice
    NSString *d = [root stringByAppendingPathComponent:@"bg-dup"];
    bg_configure(d, 64u << 20, 1ull << 30, 0, 1);
    bc7_plane(plane, bytes, 2);
    for (int i = 0; i < 5; i++) nvn_bc_astc_learn(0x4d, plane, bytes, W, H, 4, NULL);
    CHECK(nvn_bc_astc_bg_wait(120)); nvn_bc_astc_bg_stats(&s);
    CHECK(s.queued + s.duplicates + s.hits == 5 && s.queued >= 1 && s.encoded == s.queued);
    // queue cap: a cap of a plane and a half holds one, the rest is dropped (counted); nothing over the cap is ever queued
    NSString *q = [root stringByAppendingPathComponent:@"bg-queue"];
    bg_configure(q, bytes + bytes / 2, 1ull << 30, 0, 1);
    for (unsigned i = 0; i < 12; i++) { bc7_plane(plane, bytes, 100 + i); nvn_bc_astc_learn(0x4d, plane, bytes, W, H, 4, NULL); nvn_bc_astc_bg_stats(&s); CHECK(s.queued_bytes_now <= bytes + bytes / 2); }
    nvn_bc_astc_bg_stats(&s);
    CHECK(s.queued + s.dropped == 12 && s.dropped > 0 && s.dropped_bytes == s.dropped * bytes);
    CHECK(nvn_bc_astc_bg_wait(120)); nvn_bc_astc_bg_stats(&s); CHECK(s.encoded == s.queued && s.queued_bytes_now == 0);
    bg_configure(q, 0, 1ull << 30, 0, 1);   // no room at all: everything is dropped
    bc7_plane(plane, bytes, 300); CHECK(nvn_bc_astc_learn(0x4d, plane, bytes, W, H, 4, NULL) == 0); nvn_bc_astc_bg_stats(&s); CHECK(s.dropped == 1 && s.queued == 0);
    // two workers encode many planes: all are written, once each
    NSString *m = [root stringByAppendingPathComponent:@"bg-many"];
    bg_configure(m, 64u << 20, 1ull << 30, 0, 2);
    for (unsigned i = 0; i < 24; i++) { bc7_plane(plane, bytes, 400 + i); nvn_bc_astc_learn(0x4d, plane, bytes, W, H, 4, NULL); }
    CHECK(nvn_bc_astc_bg_wait(120)); nvn_bc_astc_bg_stats(&s);
    CHECK(s.queued == 24 && s.written == 24 && count_entries(m) == 24 && s.cache_entries == 24);
    // cache size cap: room for two entries
    NSString *c = [root stringByAppendingPathComponent:@"bg-cap"];
    bg_configure(c, 64u << 20, 2 * (astc_bytes + 40) + 10, 0, 1);
    for (unsigned i = 0; i < 5; i++) { bc7_plane(plane, bytes, 500 + i); nvn_bc_astc_learn(0x4d, plane, bytes, W, H, 4, NULL); }
    CHECK(nvn_bc_astc_bg_wait(120)); nvn_bc_astc_bg_stats(&s);
    CHECK(s.encoded == 5 && s.written == 2 && s.skipped_cap == 3 && count_entries(c) == 2 && s.cache_bytes == 2 * (astc_bytes + 40));
    // a restart counts what is already in the directory (the cap holds across launches), and stale temporaries of a crashed write are removed, nothing else
    NSString *stale = [c stringByAppendingPathComponent:[NSString stringWithFormat:@"%064x.astc.AbCdEf", 7]], *other = [c stringByAppendingPathComponent:@"keep-me.txt"];
    [NSData.data writeToFile:stale atomically:NO]; [NSData.data writeToFile:other atomically:NO];
    struct timeval old[2] = {{time(NULL) - 7200, 0}, {time(NULL) - 7200, 0}}; utimes(stale.fileSystemRepresentation, old);
    bg_configure(c, 64u << 20, 2 * (astc_bytes + 40) + 10, 0, 1);
    nvn_bc_astc_bg_stats(&s); CHECK(s.cache_entries == 2 && s.cache_bytes == 2 * (astc_bytes + 40));
    CHECK(![NSFileManager.defaultManager fileExistsAtPath:stale] && [NSFileManager.defaultManager fileExistsAtPath:other]);
    bc7_plane(plane, bytes, 600); nvn_bc_astc_learn(0x4d, plane, bytes, W, H, 4, NULL);
    CHECK(nvn_bc_astc_bg_wait(120)); nvn_bc_astc_bg_stats(&s); CHECK(s.written == 0 && s.skipped_cap == 1);
    // free-disk floor
    NSString *l = [root stringByAppendingPathComponent:@"bg-low"];
    bg_configure(l, 64u << 20, 1ull << 30, 1ull << 60, 1);
    bc7_plane(plane, bytes, 700); nvn_bc_astc_learn(0x4d, plane, bytes, W, H, 4, NULL);
    CHECK(nvn_bc_astc_bg_wait(120)); nvn_bc_astc_bg_stats(&s); CHECK(s.encoded == 1 && s.written == 0 && s.skipped_lowdisk == 1 && count_entries(l) == 0);
    // corrupt (same size, wrong payload) and short entries: not used, queued again, and the rewrite repairs them
    NSString *r = [root stringByAppendingPathComponent:@"bg-corrupt"];
    bg_configure(r, 64u << 20, 1ull << 30, 0, 1);
    bc7_plane(plane, bytes, 800); CHECK(nvn_bc_astc_learn(0x4d, plane, bytes, W, H, 4, &key) == 0); CHECK(nvn_bc_astc_bg_wait(120));
    NSString *path = [r stringByAppendingPathComponent:[NSString stringWithFormat:@"%s.astc", key.hex]];
    FILE *f = fopen(path.fileSystemRepresentation, "r+b"); fseek(f, 200, SEEK_SET); int byte = fgetc(f); fseek(f, 200, SEEK_SET); fputc(byte ^ 0x5a, f); fclose(f);
    CHECK(nvn_bc_astc_fetch(0x4d, plane, bytes, W, H, 4, fetched, astc_bytes) == 0);   // the payload hash fails
    CHECK(nvn_bc_astc_bg_wait(120)); CHECK(nvn_bc_astc_fetch(0x4d, plane, bytes, W, H, 4, fetched, astc_bytes) == 1);
    truncate(path.fileSystemRepresentation, 100);
    CHECK(nvn_bc_astc_learn(0x4d, plane, bytes, W, H, 4, NULL) == 0);   // the size no longer matches
    CHECK(nvn_bc_astc_bg_wait(120)); CHECK(nvn_bc_astc_learn(0x4d, plane, bytes, W, H, 4, NULL) == 1);
    // no writable cache: a miss is counted, nothing is queued
    nvn_astc_bg_config none = {.cache = NULL, .readonly = NULL, .queue_cap = 1u << 20, .cache_max = 1ull << 30, .min_free = 0, .threads = 1};
    nvn_bc_astc_bg_configure(&none);
    bc7_plane(plane, bytes, 900); CHECK(nvn_bc_astc_learn(0x4d, plane, bytes, W, H, 4, NULL) == 0); nvn_bc_astc_bg_stats(&s); CHECK(s.misses == 1 && s.queued == 0 && s.dropped == 0);
    free(plane); free(fetched); free(direct);
}

static void diagnostic_contract(NSString *root) {
    NSString *directory = [root stringByAppendingPathComponent:@"diagnostics"];
    const char *cache = directory.fileSystemRepresentation;
    uint8_t source[32] = {0}, expected[64], output[64]; int hit;
    nvn_astc_cache_report report;
    CHECK(!nvn_bc_astc_encode_report(66, source, sizeof source, 8, 8, 4,
        expected, sizeof expected, cache, cache, &hit, NULL, &report));
    CHECK(!hit && strlen(report.key.hex) == 64);
    CHECK(report.readonly_status == NVN_ASTC_CACHE_MISSING && report.writable_status == NVN_ASTC_CACHE_MISSING);
    CHECK(report.write_attempted && !report.write_error);
    nvn_astc_cache_key key = report.key;
    NSString *path = cache_path(cache, key.hex);
    CHECK(!nvn_bc_astc_encode_report(66, source, sizeof source, 8, 8, 4,
        output, sizeof output, cache, cache, &hit, NULL, &report));
    CHECK(hit && !report.write_attempted && !memcmp(expected, output, sizeof output));
    CHECK(report.readonly_status == NVN_ASTC_CACHE_HIT && report.writable_status == NVN_ASTC_CACHE_UNCHECKED);
    NSData *valid = [NSData dataWithContentsOfFile:path];
    for (unsigned fault = 0; fault < 4; fault++) {
        NSMutableData *broken = [valid mutableCopy];
        nvn_astc_cache_status status;
        if (fault == 0) { ((uint8_t *)broken.mutableBytes)[0] ^= 1; status = NVN_ASTC_CACHE_HEADER; }
        else if (fault == 1) { broken.length--; status = NVN_ASTC_CACHE_SIZE; }
        else if (fault == 2) { broken.length++; status = NVN_ASTC_CACHE_SIZE; }
        else { ((uint8_t *)broken.mutableBytes)[40] ^= 1; status = NVN_ASTC_CACHE_HASH; }
        CHECK([broken writeToFile:path atomically:YES]);
        CHECK(!nvn_bc_astc_encode_report(66, source, sizeof source, 8, 8, 4,
            output, sizeof output, cache, cache, &hit, NULL, &report));
        CHECK(!hit && report.readonly_status == status && report.writable_status == status);
        CHECK(!report.write_error && !memcmp(&key, &report.key, sizeof key));
        CHECK(!memcmp(expected, output, sizeof output));
    }
    // A valid writable entry still serves a corrupt read-only entry.
    NSString *ro = [root stringByAppendingPathComponent:@"readonly"];
    CHECK(!cache_write(cache_path(ro.fileSystemRepresentation, key.hex), expected, sizeof expected));
    CHECK(!truncate(cache_path(ro.fileSystemRepresentation, key.hex).fileSystemRepresentation, 3));
    CHECK(!nvn_bc_astc_encode_report(66, source, sizeof source, 8, 8, 4,
        output, sizeof output, cache, ro.fileSystemRepresentation, &hit, NULL, &report));
    CHECK(hit && report.readonly_status == NVN_ASTC_CACHE_SIZE && report.writable_status == NVN_ASTC_CACHE_HIT);
    CHECK(cache_read_disk_status(root, output, sizeof output) == NVN_ASTC_CACHE_IO);
    // A directory at the final filename lets encoding succeed but rejects rename.
    CHECK(!unlink(path.fileSystemRepresentation));
    CHECK([NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:NO attributes:nil error:NULL]);
    CHECK(!nvn_bc_astc_encode_report(66, source, sizeof source, 8, 8, 4,
        output, sizeof output, cache, NULL, &hit, NULL, &report));
    CHECK(!hit && report.readonly_status == NVN_ASTC_CACHE_DISABLED && report.writable_status == NVN_ASTC_CACHE_IO);
    CHECK(report.write_attempted && report.write_error && !memcmp(expected, output, sizeof output));
    CHECK(!memcmp(&key, &report.key, sizeof key));
    CHECK(!nvn_bc_astc_encode_report(66, source, sizeof source, 8, 8, 4,
        output, sizeof output, NULL, NULL, &hit, NULL, &report));
    CHECK(!hit && !report.write_attempted && !report.write_error);
    CHECK(report.readonly_status == NVN_ASTC_CACHE_DISABLED && report.writable_status == NVN_ASTC_CACHE_DISABLED);
    CHECK(!strcmp(nvn_bc_astc_cache_status_name(NVN_ASTC_CACHE_HASH), "hash"));
    CHECK(nvn_bc_astc_encode_report(66, source, 31, 8, 8, 4,
        output, sizeof output, cache, cache, &hit, NULL, &report) != 0);
    CHECK(!report.key.hex[0] && !report.write_attempted);
    CHECK([NSFileManager.defaultManager removeItemAtPath:directory error:NULL]);
    CHECK([NSFileManager.defaultManager removeItemAtPath:ro error:NULL]);
}

static void restore_contract(NSString *root) {
    NSString *directory = [root stringByAppendingPathComponent:@"restore"];
    const char *cache = directory.fileSystemRepresentation;
    size_t page = (size_t)getpagesize();
    uint8_t *source = mmap(NULL, page, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    CHECK(source != MAP_FAILED);
    if (source == MAP_FAILED) return;
    uint8_t expected[64], actual[65]; int hit;
    nvn_astc_cache_key original, changed, invalid = {0};
    CHECK(!nvn_bc_astc_encode_key(0x42, source, 32, 8, 8, 4,
        expected, sizeof expected, cache, NULL, &hit, &original)); CHECK(!hit);
    CHECK(strlen(original.hex) == 64);
    // A direct restore remains valid even when the guest source cannot be read.
    CHECK(!mprotect(source, page, PROT_NONE));
    memset(actual, 0xa5, sizeof actual);
    CHECK(nvn_bc_astc_cache_read(&original, actual, 64, NULL, cache));
    CHECK(!memcmp(expected, actual, 64) && actual[64] == 0xa5);
    CHECK(!nvn_bc_astc_cache_read(&original, actual, 63, cache, NULL));
    CHECK(!nvn_bc_astc_cache_read(&invalid, actual, 64, cache, NULL));
    invalid = original; invalid.hex[0] = '/';
    CHECK(!nvn_bc_astc_cache_read(&invalid, actual, 64, cache, NULL));
    invalid = original; invalid.hex[64] = '0';
    CHECK(!nvn_bc_astc_cache_read(&invalid, actual, 64, cache, NULL));
    NSString *path = cache_path(cache, original.hex);
    FILE *file = fopen(path.fileSystemRepresentation, "r+b"); CHECK(file != NULL);
    if (file) {
        CHECK(!fseek(file, 40, SEEK_SET)); CHECK(fputc(expected[0] ^ 0xff, file) != EOF); fclose(file);
    }
    CHECK(!nvn_bc_astc_cache_read(&original, actual, 64, cache, NULL));
    CHECK(!mprotect(source, page, PROT_READ | PROT_WRITE));
    CHECK(!nvn_bc_astc_encode_key(0x42, source, 32, 8, 8, 4,
        actual, 64, cache, NULL, &hit, &changed)); CHECK(!hit);
    CHECK(!memcmp(&changed, &original, sizeof original) && !memcmp(expected, actual, 64));
    CHECK(!unlink(path.fileSystemRepresentation));
    CHECK(!nvn_bc_astc_cache_read(&original, actual, 64, cache, NULL));
    CHECK(!nvn_bc_astc_encode_key(0x42, source, 32, 8, 8, 4,
        actual, 64, cache, NULL, &hit, &changed)); CHECK(!hit);
    memset(source, 0xff, 32);
    CHECK(!nvn_bc_astc_encode_key(0x42, source, 32, 8, 8, 4,
        actual, 64, cache, NULL, &hit, &changed)); CHECK(!hit);
    CHECK(memcmp(&changed, &original, sizeof original));
    CHECK(nvn_bc_astc_cache_read(&original, actual, 64, cache, NULL));
    CHECK(!memcmp(expected, actual, 64));
    CHECK(nvn_bc_astc_encode_key(0x42, source, 31, 8, 8, 4,
        actual, 64, cache, NULL, &hit, &changed) != 0);
    CHECK(!changed.hex[0]);
    CHECK(!munmap(source, page));
}

int main(int argc, char **argv) { @autoreleasepool {
    size_t budget = argc > 1 && !strcmp(argv[1], "budget") ? 128 : 1u << 20;
    int mapped_mode = argc > 1 && (!strcmp(argv[1], "mapped") || !strcmp(argv[1], "mapped-memcpy"));
    int bulk_mode = mapped_mode && !strcmp(argv[1], "mapped");
    CHECK(!setenv("DM_NVN_ASTC_SNAPSHOT_PREAD", bulk_mode ? "1" : "0", 1));
    size_t mapped_budget = mapped_mode ? 2u << 20 : 0;
    char directory[] = "/tmp/dm-astc-cache.XXXXXX";
    CHECK(mkdtemp(directory) != NULL);
    NSString *root = @(directory);
    diagnostic_contract(root);
    restore_contract(root);
    NSString *small = fixture(root, 1, 16);
    fixture(root, 2, 32); fixture(root, 3, 48);
    fixture(root, 4, 64); fixture(root, 5, 65536);
    NSString *large = fixture(root, 6, 65537);
    NSString *corrupt = fixture(root, 7, 80);
    NSString *truncated = fixture(root, 8, 96);
    NSString *mapped_corrupt = mapped_mode ? fixture(root, 9, 128u << 10) : nil;
    NSString *unmapped_large = mapped_mode ? fixture(root, 10, 2u << 20) : nil;
    NSString *streamed = mapped_mode ? fixture(root, 11, 700001) : nil;
    const size_t boundary_size = (1u << 20) + 257;
    NSString *boundary = mapped_mode ? fixture(root, 12, boundary_size) : nil;
    FILE *file = fopen(corrupt.fileSystemRepresentation, "r+b"); CHECK(file != NULL);
    CHECK(fseek(file, 40, SEEK_SET) == 0); CHECK(fputc(0xff, file) != EOF); fclose(file);
    CHECK(truncate(truncated.fileSystemRepresentation, 41) == 0);
    if (mapped_mode) {
        uint8_t *bytes = malloc(700001);
        for (size_t i = 0; i < 700001; i++) bytes[i] = stream_byte(i);
        cache_write(streamed, bytes, 700001); free(bytes);
        bytes = malloc(boundary_size);
        for (size_t i = 0; i < boundary_size; i++) bytes[i] = stream_byte(i);
        cache_write(boundary, bytes, boundary_size); free(bytes);
        FILE *bad = fopen(mapped_corrupt.fileSystemRepresentation, "r+b"); CHECK(bad != NULL);
        if (bad) { CHECK(!fseek(bad, 40, SEEK_SET)); CHECK(fputc(0xff, bad) != EOF); fclose(bad); }
        uint8_t scratch[17];
        CHECK(cache_snapshot_copy(large, -1, 0, 65537, scratch, sizeof scratch) == -1);
    }
    uint8_t source[32] = {0}, encoded[64], result[64]; int hit;
    CHECK(!nvn_bc_astc_encode(0x42, source, sizeof source, 8, 8, 4,
                            encoded, sizeof encoded, directory, NULL, &hit)); CHECK(!hit);
    CHECK(!nvn_bc_astc_encode(0x42, source, sizeof source, 8, 8, 4,
                            result, sizeof result, directory, NULL, &hit)); CHECK(hit);
    CHECK(!memcmp(encoded, result, sizeof result));

    nvn_bc_astc_cache_prepare(directory, directory, 0, 0);
    CHECK(!atomic_load(&g_cache_small_ready));
    __block _Atomic unsigned concurrent_errors = 0;
    dispatch_group_t readers = dispatch_group_create();
    for (unsigned thread = 0; thread < 4; thread++) dispatch_group_async(readers,
        dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
            uint8_t *large_bytes = mapped_mode ? malloc(65537) : NULL;
            for (unsigned i = 0; i < 1000; i++) { @autoreleasepool {
                uint8_t bytes[16];
                if (!cache_read(small, bytes, sizeof bytes) || bytes[0] != 1 || bytes[15] != 1)
                    atomic_fetch_add(&concurrent_errors, 1);
                if (large_bytes && i % 16 == 0 &&
                    (!cache_read(large, large_bytes, 65537) || large_bytes[0] != 6 || large_bytes[65536] != 6))
                    atomic_fetch_add(&concurrent_errors, 1);
            } }
            free(large_bytes);
        });
    nvn_bc_astc_cache_prepare(directory, directory, budget, mapped_budget);
    dispatch_group_wait(readers, DISPATCH_TIME_FOREVER);
    CHECK(atomic_load(&concurrent_errors) == 0);
    CHECK(atomic_load(&g_cache_small_ready));
    size_t used = 0;
    for (NSData *data in g_cache_small.allValues) used += data.length;
    CHECK(used <= budget);
    CHECK(g_cache_small[small] != nil);
    CHECK(g_cache_small[large] == nil);
    CHECK(g_cache_small[corrupt] == nil);
    CHECK(g_cache_small[truncated] == nil);
    if (budget == 128) { CHECK(used == 96); CHECK(g_cache_small.count == 3); }
    else { CHECK(g_cache_small.count == 6); CHECK(used == 65760); }
    CHECK(unlink(small.fileSystemRepresentation) == 0);
    CHECK(cache_read(small, result, 16)); CHECK(result[0] == 1 && result[15] == 1);
    CHECK(!cache_read(small, result, 15));
    CHECK(!cache_read(corrupt, result, 64));
    CHECK(!cache_read(truncated, result, 64));
    uint8_t *large_result = malloc(65537);
    CHECK(cache_read(large, large_result, 65537));
    CHECK(large_result[0] == 6 && large_result[65536] == 6);
    if (mapped_mode) {
        CHECK(g_cache_mapped[large].length == 65537);
        CHECK(g_cache_mapped[mapped_corrupt] == nil && g_cache_mapped[unmapped_large] == nil);
        CHECK(g_cache_mapped_base != NULL && g_cache_mapped_size > 65537 && g_cache_mapped_size <= mapped_budget);
        // The verified snapshot owns different storage from the mutable cache.
        // Deleting or truncating the originals cannot invalidate this snapshot.
        CHECK(!truncate(large.fileSystemRepresentation, 0));
        CHECK(cache_read(large, large_result, 65537));
        CHECK(large_result[0] == 6 && large_result[65536] == 6);
        CHECK(!unlink(large.fileSystemRepresentation));
        CHECK(!madvise(g_cache_mapped_base, g_cache_mapped_size, MADV_DONTNEED));
        CHECK(cache_read(large, large_result, 65537));
        CHECK(large_result[0] == 6 && large_result[65536] == 6);
        CHECK(!cache_read(large, large_result, 65536));
        uint8_t *fallback = malloc(2u << 20);
        CHECK(g_cache_mapped[streamed].length == 700001);
        CHECK(!unlink(streamed.fileSystemRepresentation));
        CHECK(cache_read(streamed, fallback, 700001));
        int intact = 1;
        for (size_t i = 0; i < 700001; i++) intact &= fallback[i] == stream_byte(i);
        CHECK(intact);
        CHECK(cache_read(unmapped_large, fallback, 2u << 20));
        CHECK(fallback[0] == 10 && fallback[(2u << 20) - 1] == 10);
        CHECK(!cache_read(mapped_corrupt, fallback, 128u << 10));
        fixture(root, 9, 128u << 10);
        CHECK(cache_read(mapped_corrupt, fallback, 128u << 10));
        CHECK(fallback[0] == 9 && fallback[(128u << 10) - 1] == 9);
        CHECK((g_cache_snapshot_fd >= 0) == bulk_mode);
        if (bulk_mode) {
            CHECK(fcntl(g_cache_snapshot_fd, F_GETFD) & FD_CLOEXEC);
            off_t position = lseek(g_cache_snapshot_fd, 0, SEEK_CUR);
            const void *mapped = g_cache_mapped[boundary].bytes;
            CHECK(mapped && g_cache_mapped[boundary].length == boundary_size);
            CHECK(!cache_snapshot_read(NULL, mapped, boundary_size));
            CHECK(!cache_snapshot_read(fallback, mapped, SIZE_MAX));
            CHECK(!cache_snapshot_read(fallback, (uint8_t *)g_cache_mapped_base + g_cache_mapped_size, 1));
            // Positional reads must not fault on the source mapping at all.
            CHECK(!mprotect(g_cache_mapped_base, g_cache_mapped_size, PROT_NONE));
            CHECK(cache_snapshot_read(fallback, mapped, boundary_size));
            CHECK(!mprotect(g_cache_mapped_base, g_cache_mapped_size, PROT_READ));
            CHECK(lseek(g_cache_snapshot_fd, 0, SEEK_CUR) == position);
            for (int fault = 0; fault <= 5; fault++) {
                memset(fallback, 0xa5, boundary_size + 1);
                atomic_store(&read_calls, 0); atomic_store(&read_fault, fault);
                CHECK(cache_read(boundary, fallback, boundary_size));
                unsigned calls = atomic_load(&read_calls);
                atomic_store(&read_fault, 0);
                intact = fallback[boundary_size] == 0xa5;
                for (size_t i = 0; i < boundary_size; i++) intact &= fallback[i] == stream_byte(i);
                CHECK(intact);
                CHECK(fault >= 4 ? calls == 1 : calls >= 2);
            }
            CHECK(atomic_load(&largest_read) == 1u << 20);
            // Different offsets can share the descriptor without racing a seek.
            for (unsigned thread = 0; thread < 4; thread++) dispatch_group_async(readers,
                dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                    uint8_t *bytes = malloc(boundary_size);
                    for (unsigned i = 0; i < 16; i++) { @autoreleasepool {
                        NSString *path = (i + thread) % 2 ? streamed : boundary;
                        size_t count = path == streamed ? 700001 : boundary_size;
                        int valid = cache_read(path, bytes, count);
                        for (size_t j = 0; valid && j < count; j++) valid = bytes[j] == stream_byte(j);
                        if (!valid) atomic_fetch_add(&concurrent_errors, 1);
                    } }
                    free(bytes);
                });
            dispatch_group_wait(readers, DISPATCH_TIME_FOREVER);
            CHECK(atomic_load(&concurrent_errors) == 0);
        }
        free(fallback);
    }
    free(large_result);
    fixture(root, 7, 80);
    uint8_t repaired[80]; CHECK(cache_read(corrupt, repaired, sizeof repaired));
    CHECK(repaired[0] == 7 && repaired[79] == 7);
    CHECK(!nvn_bc_astc_encode(0x42, source, sizeof source, 8, 8, 4,
                            result, sizeof result, directory, directory, &hit)); CHECK(hit);
    CHECK(!memcmp(encoded, result, sizeof result));
    uint64_t memory_hits, disk_hits, mapped_hits;
    nvn_bc_astc_cache_stats(&memory_hits, &disk_hits, &mapped_hits);
    CHECK(memory_hits > 0 && disk_hits > 0);
    CHECK(mapped_mode ? mapped_hits > 0 : mapped_hits == 0);
    nvn_bc_astc_cache_prepare(NULL, NULL, 2u << 20, 0);
    CHECK(g_cache_small[small].length == 16);
    background_contract(root);
    CHECK([NSFileManager.defaultManager removeItemAtPath:root error:NULL]);
    printf("ASTC cache: %u checks, %u failures, %zu retained bytes\n", checks, failures, used);
    return failures != 0;
} }
