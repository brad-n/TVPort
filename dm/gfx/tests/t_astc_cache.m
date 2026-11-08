// CPU-only cache tests: no Metal device, guest, or emulator is started.
#include <unistd.h>
#include <errno.h>
#include <stdatomic.h>
#include <sys/wait.h>
#include "../../host/romfs_sparse.h"   // before the pread fake below: the image reader is the real one
#include "../../host/tests/romfs_sparse_fixture.h"
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
// ---- the read-only cache as one pack file (astc-ro.pack): lookups, shared payloads, corrupt or short packs, and the pack and a directory both feeding the encoder, learn and fetch ----
typedef struct { uint8_t key[32]; const uint8_t *payload; size_t size; } pk_entry;
static NSString *hexkey(const uint8_t k[32]) { NSMutableString *s = [NSMutableString string]; for (int i = 0; i < 32; i++) [s appendFormat:@"%02x", k[i]]; return s; }
static int pk_cmp(const void *a, const void *b) { return memcmp(a, b, 32); }
// Writes a pack of the entries (a payload pointer may repeat: stored once); `damage` 0 none, 1 magic, 2 truncated short, 3 truncated mid-index, 4 index unsorted, 5 file size field wrong, 6 entry past the index, 7 version 2
static void write_pack(NSString *path, pk_entry *ents, size_t n, int damage) {
    qsort(ents, n, sizeof *ents, pk_cmp);
    NSMutableData *file = [NSMutableData dataWithLength:80], *index = [NSMutableData data];
    const uint8_t **seen = calloc(n, sizeof *seen); uint64_t *seen_off = calloc(n, 8); uint64_t *seen_len = calloc(n, 8); size_t ns = 0;
    for (size_t i = 0; i < n; i++) {
        size_t j; for (j = 0; j < ns; j++) if (seen[j] == ents[i].payload) break;
        if (j == ns) {
            uint8_t head[40]; memcpy(head, "NXASTC01", 8); CC_SHA256(ents[i].payload, (CC_LONG)ents[i].size, head + 8);
            seen[ns] = ents[i].payload; seen_off[ns] = file.length; seen_len[ns] = 40 + ents[i].size; ns++;
            [file appendBytes:head length:40]; [file appendBytes:ents[i].payload length:ents[i].size];
            size_t pad = -file.length & 15; [file increaseLengthBy:pad];
        }
        uint64_t off = seen_off[j], len = seen_len[j];
        [index appendBytes:ents[i].key length:32]; [index appendBytes:&off length:8]; [index appendBytes:&len length:8];
    }
    uint64_t ioff = file.length; [file appendData:index];
    uint64_t total = file.length, count = n; uint32_t version = damage == 7 ? 2 : 1, esz = 48;
    uint8_t *b = file.mutableBytes; memcpy(b, damage == 1 ? "NXASTCPX" : "NXASTCPK", 8); memcpy(b + 8, &version, 4); memcpy(b + 12, &esz, 4); memcpy(b + 16, &count, 8); memcpy(b + 24, &ioff, 8);
    uint64_t sz = damage == 5 ? total + 16 : total; memcpy(b + 32, &sz, 8);
    for (int i = 0; i < 32; i++) b[40 + i] = (uint8_t)(0xA0 + i);   // the input fingerprint
    if (damage == 4 && n >= 2) { uint8_t tmp[48]; memcpy(tmp, b + ioff, 48); memcpy(b + ioff, b + ioff + 48, 48); memcpy(b + ioff + 48, tmp, 48); }
    if (damage == 6 && n) { uint64_t off = total; memcpy(b + ioff + 32, &off, 8); }
    if (damage == 2) [file setLength:50];
    if (damage == 3) [file setLength:ioff + 60];
    [file writeToFile:path atomically:NO];
    free(seen); free(seen_off); free(seen_len);
}
static void pack_contract(NSString *root) {
    uint8_t pa[100], pb[256], pc[64], got[256]; memset(pa, 0xA1, sizeof pa); memset(pb, 0xB2, sizeof pb); memset(pc, 0xC3, sizeof pc);
    for (int i = 0; i < 256; i++) pb[i] = (uint8_t)(i * 7);
    pk_entry e[4]; memset(e, 0, sizeof e);
    for (int i = 0; i < 4; i++) for (int j = 0; j < 32; j++) e[i].key[j] = (uint8_t)(i * 37 + j * 11 + 1);
    e[0].payload = pa; e[0].size = sizeof pa; e[1].payload = pb; e[1].size = sizeof pb; e[2].payload = pc; e[2].size = sizeof pc; e[3].payload = pa; e[3].size = sizeof pa;   // e3 shares e0's payload
    uint8_t k0[32], k1[32], k2[32], k3[32], absent[32]; memcpy(k0, e[0].key, 32); memcpy(k1, e[1].key, 32); memcpy(k2, e[2].key, 32); memcpy(k3, e[3].key, 32); memset(absent, 0x5a, 32);
    NSString *pack = [root stringByAppendingPathComponent:@"ok.pack"];
    write_pack(pack, e, 4, 0);
    uint64_t entries, bytes; uint8_t fp[32];
    CHECK(nvn_bc_astc_pack_info(pack.fileSystemRepresentation, &entries, &bytes, fp) && entries == 4 && bytes == [[NSFileManager.defaultManager attributesOfItemAtPath:pack error:NULL] fileSize] && fp[0] == 0xA0 && fp[31] == 0xBF);
    nvn_astc_cache_key key; 
    #define KEYOF(k) do { NSString *h = hexkey(k); memset(&key, 0, sizeof key); strcpy(key.hex, h.UTF8String); } while (0)
    KEYOF(k0); CHECK(nvn_bc_astc_cache_read(&key, got, sizeof pa, NULL, pack.fileSystemRepresentation) && !memcmp(got, pa, sizeof pa));
    KEYOF(k3); CHECK(nvn_bc_astc_cache_read(&key, got, sizeof pa, NULL, pack.fileSystemRepresentation) && !memcmp(got, pa, sizeof pa));   // an alias: the same payload
    KEYOF(k1); CHECK(nvn_bc_astc_cache_read(&key, got, sizeof pb, NULL, pack.fileSystemRepresentation) && !memcmp(got, pb, sizeof pb));
    KEYOF(k2); CHECK(nvn_bc_astc_cache_read(&key, got, sizeof pc, NULL, pack.fileSystemRepresentation) && !memcmp(got, pc, sizeof pc));
    CHECK(!nvn_bc_astc_cache_read(&key, got, sizeof pc - 1, NULL, pack.fileSystemRepresentation));   // the wrong size is a miss
    KEYOF(absent); CHECK(!nvn_bc_astc_cache_read(&key, got, sizeof pc, NULL, pack.fileSystemRepresentation));
    CHECK(cache_has(pack.fileSystemRepresentation, hexkey(k1).UTF8String, sizeof pb) && !cache_has(pack.fileSystemRepresentation, hexkey(k1).UTF8String, sizeof pb + 1) && !cache_has(pack.fileSystemRepresentation, hexkey(absent).UTF8String, 1));
    // one payload byte flipped: the hash catches it, that entry only
    NSString *flip = [root stringByAppendingPathComponent:@"flip.pack"]; write_pack(flip, e, 4, 0);
    { uint64_t off = 0; NSData *d = [NSData dataWithContentsOfFile:flip]; const uint8_t *b = d.bytes; uint64_t ioff; memcpy(&ioff, b + 24, 8);
      for (int i = 0; i < 4; i++) if (!memcmp(b + ioff + 48 * i, k1, 32)) memcpy(&off, b + ioff + 48 * i + 32, 8);
      FILE *f = fopen(flip.fileSystemRepresentation, "r+b"); fseek(f, (long)off + 40 + 5, SEEK_SET); fputc(0x77, f); fclose(f); }
    KEYOF(k1); CHECK(!nvn_bc_astc_cache_read(&key, got, sizeof pb, NULL, flip.fileSystemRepresentation));
    KEYOF(k2); CHECK(nvn_bc_astc_cache_read(&key, got, sizeof pc, NULL, flip.fileSystemRepresentation));
    // corrupt or short packs are ignored whole: no hit, no crash, pack_info says so
    const char *names[] = {"", "bad-magic", "short", "cut-index", "unsorted", "size-field", "past-index", "version2"};
    for (int d = 1; d <= 7; d++) {
        NSString *p = [root stringByAppendingPathComponent:[NSString stringWithFormat:@"%s.pack", names[d]]]; write_pack(p, e, 4, d);
        KEYOF(k0); CHECK(!nvn_bc_astc_pack_info(p.fileSystemRepresentation, NULL, NULL, NULL)); 
        CHECK(!nvn_bc_astc_cache_read(&key, got, sizeof pa, NULL, p.fileSystemRepresentation));
    }
    { NSString *p = [root stringByAppendingPathComponent:@"empty.pack"]; [@"" writeToFile:p atomically:NO encoding:NSUTF8StringEncoding error:NULL];
      KEYOF(k0); CHECK(!nvn_bc_astc_cache_read(&key, got, sizeof pa, NULL, p.fileSystemRepresentation)); }
    // an empty but valid pack and a missing path are misses
    write_pack([root stringByAppendingPathComponent:@"zero.pack"], e, 0, 0);
    CHECK(nvn_bc_astc_pack_info([root stringByAppendingPathComponent:@"zero.pack"].fileSystemRepresentation, &entries, NULL, NULL) && entries == 0);
    CHECK(!nvn_bc_astc_pack_info([root stringByAppendingPathComponent:@"nope.pack"].fileSystemRepresentation, NULL, NULL, NULL));
    // the encoder, learn and fetch read a pack and a directory alike
    const unsigned W = 64, H = 64; const size_t bc = (size_t)W * H, astc = (size_t)((W + 3) / 4) * ((H + 3) / 4) * 16;
    uint8_t *plane = malloc(bc), *want = malloc(astc), *out = malloc(astc);
    bc7_plane(plane, bc, 77);
    NSString *dir = [root stringByAppendingPathComponent:@"ro-dir"]; int hit;
    CHECK(!nvn_bc_astc_encode(0x4d, plane, bc, W, H, 4, want, astc, dir.fileSystemRepresentation, NULL, &hit) && !hit);
    nvn_astc_cache_key pk; nvn_bc_astc_plane_key(0x4d, W, H, 4, plane, bc, &pk);
    uint8_t realkey[32]; for (int i = 0; i < 32; i++) { unsigned v; sscanf(pk.hex + 2 * i, "%2x", &v); realkey[i] = (uint8_t)v; }
    pk_entry real[2]; memset(real, 0, sizeof real); memcpy(real[0].key, realkey, 32); real[0].payload = want; real[0].size = astc;
    memset(real[1].key, 0x11, 32); real[1].payload = pc; real[1].size = sizeof pc;
    NSString *rp = [root stringByAppendingPathComponent:@"real.pack"]; write_pack(rp, real, 2, 0);
    memset(out, 0, astc);
    CHECK(!nvn_bc_astc_encode(0x4d, plane, bc, W, H, 4, out, astc, NULL, rp.fileSystemRepresentation, &hit) && hit && !memcmp(out, want, astc));   // hit in the pack, nothing encoded
    memset(out, 0, astc);
    CHECK(!nvn_bc_astc_encode(0x4d, plane, bc, W, H, 4, out, astc, NULL, dir.fileSystemRepresentation, &hit) && hit && !memcmp(out, want, astc));   // the directory
    nvn_astc_bg_config cfg = {.cache = NULL, .readonly = rp.fileSystemRepresentation, .queue_cap = 1u << 20, .cache_max = 1ull << 30, .min_free = 0, .threads = 1};
    nvn_bc_astc_bg_configure(&cfg);
    memset(out, 0, astc);
    CHECK(nvn_bc_astc_learn(0x4d, plane, bc, W, H, 4, NULL) == 1);
    CHECK(nvn_bc_astc_fetch(0x4d, plane, bc, W, H, 4, out, astc) == 1 && !memcmp(out, want, astc));
    bc7_plane(plane, bc, 78);   // another plane: a miss in the pack
    CHECK(nvn_bc_astc_fetch(0x4d, plane, bc, W, H, 4, out, astc) == 0);
    cfg.readonly = dir.fileSystemRepresentation; nvn_bc_astc_bg_configure(&cfg);
    bc7_plane(plane, bc, 77);
    CHECK(nvn_bc_astc_learn(0x4d, plane, bc, W, H, 4, NULL) == 1 && nvn_bc_astc_fetch(0x4d, plane, bc, W, H, 4, out, astc) == 1 && !memcmp(out, want, astc));
    free(plane); free(want); free(out);
    #undef KEYOF
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

// ---- Tagged planes and the pack embedded in a DMSPARS1 image (docs/texture_once.md sections 1 to 3) ----
static void tag_contract(NSString *root) {
    uint8_t pa[100], pb[256], pc[100], pd[100], got[256]; memset(pa, 0xA1, sizeof pa); for (int i = 0; i < 256; i++) pb[i] = (uint8_t)(i * 7); memset(pc, 0xC3, sizeof pc); memset(pd, 0xD4, sizeof pd);
    pk_entry e[7]; memset(e, 0, sizeof e);
    for (int i = 0; i < 7; i++) for (int j = 0; j < 32; j++) e[i].key[j] = (uint8_t)(i * 37 + j * 11 + 1);
    // e4 and e5 share the 8-byte prefix of e0 and differ after it: e4 has e0's payload size (100), e5 another (256); e6 shares e1's prefix with the same size as e1 (ambiguous)
    memcpy(e[4].key, e[0].key, 8); e[4].key[9] ^= 0x40; memcpy(e[5].key, e[0].key, 8); e[5].key[10] ^= 0x41; memcpy(e[6].key, e[1].key, 8); e[6].key[12] ^= 0x42;
    e[0].payload = pa; e[0].size = 100; e[1].payload = pb; e[1].size = 256; e[2].payload = pc; e[2].size = 100; e[3].payload = pd; e[3].size = 100;
    e[4].payload = pd; e[4].size = 100; e[5].payload = pb; e[5].size = 256; e[6].payload = pb; e[6].size = 256;
    uint8_t k0[32], k1[32], k2[32], k3[32]; memcpy(k0, e[0].key, 32); memcpy(k1, e[1].key, 32); memcpy(k2, e[2].key, 32); memcpy(k3, e[3].key, 32);
    NSString *pack = [root stringByAppendingPathComponent:@"tag.pack"]; write_pack(pack, e, 7, 0);
    const char *ro = pack.fileSystemRepresentation;
    uint8_t plane[64]; uint8_t out[256];
    // e0's prefix is shared with e4 (same payload size, 100) and e5 (256): two entries of size 100 -> ambiguous; e2 and e3 have unique prefixes
    memset(plane, 0, sizeof plane); memcpy(plane, k2, 8);
    CHECK(nvn_bc_astc_tag_fetch_root(ro, plane, sizeof plane, 100, NULL) == NVN_TAG_HIT);                          // a unique prefix: found without reading anything
    uint64_t h0, u0, d0; nvn_bc_astc_tag_stats(&h0, &u0, &d0);
    memset(out, 0, sizeof out); CHECK(nvn_bc_astc_tag_fetch_root(ro, plane, sizeof plane, 100, out) == NVN_TAG_HIT && !memcmp(out, pc, 100));   // and read
    uint64_t h1, u1, d1; nvn_bc_astc_tag_stats(&h1, &u1, &d1); CHECK(h1 == h0 + 1 && u1 == u0 && d1 == d0);        // only a read counts as a tagged hit
    // the same plane through the hash path's key: the entry the tag names is the entry the key names
    { nvn_astc_cache_key key; NSString *hx = hexkey(k2); strcpy(key.hex, hx.UTF8String); uint8_t viakey[256]; CHECK(nvn_bc_astc_cache_read(&key, viakey, 100, NULL, ro) && !memcmp(viakey, out, 100)); }
    CHECK(nvn_bc_astc_tag_fetch_root(ro, plane, sizeof plane, 101, out) == NVN_TAG_MISS);                          // looks tagged, the size differs: no entry
    memset(plane, 0, sizeof plane); memcpy(plane, k3, 8); CHECK(nvn_bc_astc_tag_fetch_root(ro, plane, sizeof plane, 100, out) == NVN_TAG_HIT && !memcmp(out, pd, 100));
    // prefix shared by two entries: the one of the expected size is picked when only one has it, none when both do
    memset(plane, 0, sizeof plane); memcpy(plane, k0, 8);
    CHECK(nvn_bc_astc_tag_fetch_root(ro, plane, sizeof plane, 100, out) == NVN_TAG_MISS);                          // e0 and e4 both hold 100 bytes: ambiguous
    memset(out, 0, sizeof out); CHECK(nvn_bc_astc_tag_fetch_root(ro, plane, sizeof plane, 256, out) == NVN_TAG_HIT && !memcmp(out, pb, 256));   // e5 is the only one of 256
    memset(plane, 0, sizeof plane); memcpy(plane, k1, 8);   // e1 and e6: both 256
    CHECK(nvn_bc_astc_tag_fetch_root(ro, plane, sizeof plane, 256, out) == NVN_TAG_MISS);                          // two entries of the size: ambiguous, so not resolved by the tag
    memset(plane, 0, sizeof plane); memset(plane, 0x5a, 8);   // a prefix no entry has
    CHECK(nvn_bc_astc_tag_fetch_root(ro, plane, sizeof plane, 100, out) == NVN_TAG_MISS);
    // what does not look tagged is not looked up at all
    memset(plane, 0, sizeof plane); CHECK(nvn_bc_astc_tag_fetch_root(ro, plane, sizeof plane, 100, out) == NVN_TAG_NONE && !nvn_bc_astc_looks_tagged(plane, sizeof plane));   // all zero
    memcpy(plane, k2, 8); plane[63] = 1; CHECK(nvn_bc_astc_tag_fetch_root(ro, plane, sizeof plane, 100, out) == NVN_TAG_NONE);                // a tag-like prefix with data after it: an untagged plane
    memset(plane, 0, sizeof plane); memcpy(plane, k2, 8); plane[8] = 1; CHECK(!nvn_bc_astc_looks_tagged(plane, sizeof plane));
    memset(plane, 0, sizeof plane); memcpy(plane, k2, 8); CHECK(nvn_bc_astc_looks_tagged(plane, 16) && !nvn_bc_astc_looks_tagged(plane, 15) && nvn_bc_astc_looks_tagged(plane, 17) && !nvn_bc_astc_looks_tagged(NULL, 16));
    { uint8_t z[64] = {0}; z[3] = 9; CHECK(nvn_bc_astc_looks_tagged(z, 64)); z[15] = 1; CHECK(!nvn_bc_astc_looks_tagged(z, 16)); }   // one nonzero byte in the head is enough
    { uint8_t r[8 * 4 * 3] = {0}; memcpy(r, k2, 8); CHECK(nvn_bc_astc_looks_tagged_rows(r, 8, 24, 4) && nvn_bc_astc_looks_tagged_rows(r, 24, 24, 4) && !nvn_bc_astc_looks_tagged_rows(r, 8, 24, 0));
      r[24 * 2 + 7] = 5; CHECK(!nvn_bc_astc_looks_tagged_rows(r, 8, 24, 4)); r[24 * 2 + 7] = 0; r[24 * 2 + 9] = 5; CHECK(nvn_bc_astc_looks_tagged_rows(r, 8, 24, 4));   // padding between rows is not looked at
      CHECK(!nvn_bc_astc_looks_tagged_rows(r, 4, 24, 1)); }
    // a corrupt payload is a miss, never a wrong plane, and never counted as a hit
    NSString *flip = [root stringByAppendingPathComponent:@"tag-flip.pack"]; write_pack(flip, e, 7, 0);
    { uint64_t off = 0; NSData *d = [NSData dataWithContentsOfFile:flip]; const uint8_t *b = d.bytes; uint64_t ioff; memcpy(&ioff, b + 24, 8);
      for (int i = 0; i < 7; i++) if (!memcmp(b + ioff + 48 * i, k2, 32)) memcpy(&off, b + ioff + 48 * i + 32, 8);
      FILE *f = fopen(flip.fileSystemRepresentation, "r+b"); fseek(f, (long)off + 40 + 5, SEEK_SET); fputc(0x77, f); fclose(f); }
    memset(plane, 0, sizeof plane); memcpy(plane, k2, 8); nvn_bc_astc_tag_stats(&h0, &u0, &d0);
    CHECK(nvn_bc_astc_tag_fetch_root(flip.fileSystemRepresentation, plane, sizeof plane, 100, out) == NVN_TAG_MISS); nvn_bc_astc_tag_stats(&h1, &u1, &d1); CHECK(h1 == h0);
    // a directory as the read-only cache has no index to search: looks tagged, resolves to nothing
    CHECK(nvn_bc_astc_tag_fetch_root(root.fileSystemRepresentation, plane, sizeof plane, 100, out) == NVN_TAG_MISS && nvn_bc_astc_tag_fetch_root(NULL, plane, sizeof plane, 100, out) == NVN_TAG_MISS);
    nvn_bc_astc_tag_note(NVN_TAG_NOTE_UNRESOLVED); nvn_bc_astc_tag_note(NVN_TAG_NOTE_DECODED); nvn_bc_astc_tag_note(NVN_TAG_NOTE_DECODED);
    uint64_t h2, u2, d2; nvn_bc_astc_tag_stats(&h2, &u2, &d2); CHECK(u2 == u1 + 1 && d2 == d1 + 2 && h2 == h1);

    // the pack embedded in a DMSPARS1: offsets are relative to the pack; the same lookups work through the pseudo-root
    NSData *pk = [NSData dataWithContentsOfFile:pack];
    uint8_t *wrapped; size_t wn; uint8_t logical[3000]; for (int i = 0; i < 3000; i++) logical[i] = (uint8_t)(i % 251 + (i > 1000 && i < 2500 ? 0 : 1));
    memset(logical + 1000, 0, 1500);
    CHECK(fx_write_sparse(NULL, logical, sizeof logical, 64, 700, pk.bytes, pk.length, &wrapped, &wn) > 2);
    NSString *img = [root stringByAppendingPathComponent:@"wrapped.img"]; [[NSData dataWithBytes:wrapped length:wn] writeToFile:img atomically:NO];
    pid_t kid = fork();   // a damaged embedded pack is refused (it is remembered for the process, so a child shows it)
    if (!kid) { int fd = open(img.fileSystemRepresentation, O_RDONLY); romfs_src s; if (!romfs_src_open(fd, &s)) _exit(2); _exit(nvn_bc_astc_use_embedded_pack(fd, s.pack_off + 8, s.pack_size) ? 1 : 0); }
    int status = 0; waitpid(kid, &status, 0); CHECK(WIFEXITED(status) && WEXITSTATUS(status) == 0);
    kid = fork();
    if (!kid) { int fd = open(img.fileSystemRepresentation, O_RDONLY); romfs_src s; if (!romfs_src_open(fd, &s)) _exit(2); _exit(nvn_bc_astc_use_embedded_pack(fd, s.pack_off, s.pack_size - 16) ? 1 : 0); }   // a pack size that is not its header's
    waitpid(kid, &status, 0); CHECK(WIFEXITED(status) && WEXITSTATUS(status) == 0);
    int fd = open(img.fileSystemRepresentation, O_RDONLY); romfs_src s; CHECK(romfs_src_open(fd, &s) && s.sparse && s.pack_size == pk.length && s.pack_off % 16384 == 0);
    CHECK(!nvn_bc_astc_pack_info(NVN_ASTC_EMBEDDED_ROOT, NULL, NULL, NULL));   // nothing registered yet
    CHECK(nvn_bc_astc_use_embedded_pack(fd, s.pack_off, s.pack_size));
    uint64_t entries, bytes; CHECK(nvn_bc_astc_pack_info(NVN_ASTC_EMBEDDED_ROOT, &entries, &bytes, NULL) && entries == 7 && bytes == pk.length);
    nvn_astc_cache_key key; strcpy(key.hex, hexkey(k1).UTF8String);
    CHECK(nvn_bc_astc_cache_read(&key, got, 256, NULL, NVN_ASTC_EMBEDDED_ROOT) && !memcmp(got, pb, 256));          // by key, through the embedded pack
    memset(plane, 0, sizeof plane); memcpy(plane, k2, 8);
    memset(out, 0, sizeof out); CHECK(nvn_bc_astc_tag_fetch_root(NVN_ASTC_EMBEDDED_ROOT, plane, sizeof plane, 100, out) == NVN_TAG_HIT && !memcmp(out, pc, 100));   // by tag
    CHECK(nvn_bc_astc_use_embedded_pack(open(img.fileSystemRepresentation, O_RDONLY), s.pack_off, s.pack_size));   // a second registration changes nothing
    // the pack's entries are read at pack offset + entry offset, not from the file's start: the file's first bytes are not a pack
    { uint8_t head[8]; CHECK(pread(fd, head, 8, 0) == 8 && !memcmp(head, "DMSPARS1", 8)); }
    // the writer's logical image reads back around the pack
    { uint8_t *back = malloc(sizeof logical); CHECK(romfs_src_read(&s, back, sizeof logical, 0) && !memcmp(back, logical, sizeof logical)); free(back); }
    romfs_src_free(&s); free(wrapped);
}

// ---- NXASTCPK version 2 (docs/texture_once.md section 7b): compressed and raw entries, `size` in every size check, as a file, and embedded in a DMSPARS1 version 2 ----
static void pack_v2_contract(NSString *root) {
    enum { N = 5 };
    uint8_t pa[100], pb[256], pb2[300], pc[4000], pd[100]; memset(pa, 0xA1, sizeof pa); for (int i = 0; i < 256; i++) pb[i] = (uint8_t)(i * 7 + 1); memset(pb2, 0x5C, sizeof pb2); memset(pc, 0xC3, sizeof pc); for (int i = 0; i < 100; i++) pd[i] = (uint8_t)(i * 3 + 2);
    const uint8_t *pay[N] = {pa, pb, pb2, pc, pd}; size_t len[N] = {100, 256, 300, 4000, 100};
    uint8_t keys[N][32], hash[N][32];
    for (int i = 0; i < N; i++) { for (int j = 0; j < 32; j++) keys[i][j] = (uint8_t)(0x10 * (i + 1) + j * 7 + i); CC_SHA256(pay[i], (CC_LONG)len[i], hash[i]); }
    // entry 2 shares entry 1's 8-byte prefix and sorts right after it; keys[2] > keys[1] by its last byte, keys[3] > keys[2] by its first byte
    memcpy(keys[2], keys[1], 32); keys[2][31] += 1; for (int j = 0; j < 32; j++) { keys[3][j] = (uint8_t)(0x40 + j * 3); keys[4][j] = (uint8_t)(0x50 + j * 5); }
    unsigned zmask = 1u << 0 | 1u << 2 | 1u << 3;   // a, b2 and c compressed; b and d raw
    uint8_t *pk; size_t pkn = fx_pack2(&pk, N, keys, pay, len, hash, zmask);
    CHECK(pkn > 0 && pk[8] == 2 && pk[12] == 56);
    NSString *path = [root stringByAppendingPathComponent:@"v2.pack"]; [[NSData dataWithBytes:pk length:pkn] writeToFile:path atomically:NO];
    const char *ro = path.fileSystemRepresentation;
    uint64_t entries, bytes; CHECK(nvn_bc_astc_pack_info(ro, &entries, &bytes, NULL) && entries == N && bytes == pkn);
    // stored sizes: the compressed entries are smaller than their size, the raw ones equal
    { const uint8_t *ix = pk + le64(pk + 24); int c = 0, r = 0; for (int i = 0; i < N; i++) { uint64_t st = le64(ix + 56 * i + 40), sz = le64(ix + 56 * i + 48); CHECK(sz == 40 + len[i]); if (st < sz) c++; else if (st == sz) r++; } CHECK(c == 3 && r == 2); }
    uint8_t got[4000]; nvn_astc_cache_key key;
    for (int i = 0; i < N; i++) {
        strcpy(key.hex, hexkey(keys[i]).UTF8String); memset(got, 0, sizeof got);
        CHECK(nvn_bc_astc_cache_read(&key, got, len[i], NULL, ro) && !memcmp(got, pay[i], len[i]));
        CHECK(!nvn_bc_astc_cache_read(&key, got, len[i] - 1, NULL, ro) && !nvn_bc_astc_cache_read(&key, got, len[i] + 1, NULL, ro));
    }
    // the tag lookup compares `size`: entry 1 and 2 share a prefix and differ in size, entry 0 is compressed
    uint8_t plane[64], out[4000];
    memset(plane, 0, sizeof plane); memcpy(plane, keys[1], 8);
    memset(out, 0, sizeof out); CHECK(nvn_bc_astc_tag_fetch_root(ro, plane, sizeof plane, 256, out) == NVN_TAG_HIT && !memcmp(out, pb, 256));
    memset(out, 0, sizeof out); CHECK(nvn_bc_astc_tag_fetch_root(ro, plane, sizeof plane, 300, out) == NVN_TAG_HIT && !memcmp(out, pb2, 300));
    CHECK(nvn_bc_astc_tag_fetch_root(ro, plane, sizeof plane, 301, out) == NVN_TAG_MISS && nvn_bc_astc_tag_fetch_root(ro, plane, sizeof plane, 300, NULL) == NVN_TAG_HIT);
    memset(plane, 0, sizeof plane); memcpy(plane, keys[3], 8); memset(out, 0, sizeof out);
    CHECK(nvn_bc_astc_tag_fetch_root(ro, plane, sizeof plane, 4000, out) == NVN_TAG_HIT && !memcmp(out, pc, 4000));
    uint64_t h0, u0, d0, h1, u1, d1; nvn_bc_astc_tag_stats(&h0, &u0, &d0);
    memset(plane, 0, sizeof plane); memcpy(plane, keys[0], 8); CHECK(nvn_bc_astc_tag_fetch_root(ro, plane, sizeof plane, 100, out) == NVN_TAG_HIT && !memcmp(out, pa, 100));
    nvn_bc_astc_tag_stats(&h1, &u1, &d1); CHECK(h1 == h0 + 1);
    // a damaged compressed entry (frame magic, and a flipped payload run byte) is a miss, never wrong bytes or a hit; truncated stored size too
    for (int dmg = 0; dmg < 3; dmg++) {
        uint8_t *bad = malloc(pkn); memcpy(bad, pk, pkn); const uint8_t *ix = bad + le64(bad + 24); uint64_t off = 0, st = 0;
        for (int i = 0; i < N; i++) if (!memcmp(ix + 56 * i, keys[3], 32)) { off = le64(ix + 56 * i + 32); st = le64(ix + 56 * i + 40); }
        if (dmg == 0) bad[off] ^= 0xFF; else if (dmg == 1) bad[off + st - 1] ^= 0x01; else { for (int i = 0; i < N; i++) if (!memcmp(ix + 56 * i, keys[3], 32)) fx_put64(bad + le64(bad + 24) + 56 * i + 40, st - 2); }
        NSString *bp = [root stringByAppendingPathComponent:[NSString stringWithFormat:@"v2bad%d.pack", dmg]]; [[NSData dataWithBytes:bad length:pkn] writeToFile:bp atomically:NO]; free(bad);
        strcpy(key.hex, hexkey(keys[3]).UTF8String); memset(got, 0, sizeof got);
        CHECK(!nvn_bc_astc_cache_read(&key, got, 4000, NULL, bp.fileSystemRepresentation));
        memset(plane, 0, sizeof plane); memcpy(plane, keys[3], 8); nvn_bc_astc_tag_stats(&h0, &u0, &d0);
        CHECK(nvn_bc_astc_tag_fetch_root(bp.fileSystemRepresentation, plane, sizeof plane, 4000, out) == NVN_TAG_MISS); nvn_bc_astc_tag_stats(&h1, &u1, &d1); CHECK(h1 == h0);
        strcpy(key.hex, hexkey(keys[0]).UTF8String); CHECK(nvn_bc_astc_cache_read(&key, got, 100, NULL, bp.fileSystemRepresentation) && !memcmp(got, pa, 100));
    }
    // a v2 header with the v1 entry size (or the reverse) is refused whole
    { uint8_t *bad = malloc(pkn); memcpy(bad, pk, pkn); fx_put32(bad + 12, 48); NSString *bp = [root stringByAppendingPathComponent:@"v2mismatch.pack"]; [[NSData dataWithBytes:bad length:pkn] writeToFile:bp atomically:NO]; free(bad);
      CHECK(!nvn_bc_astc_pack_info(bp.fileSystemRepresentation, NULL, NULL, NULL)); }
    // embedded in a DMSPARS1 version 2 image (the pack stays raw there); a child process, since the embedded pack registers once per process
    { uint8_t logical[40000]; for (int i = 0; i < 40000; i++) logical[i] = (uint8_t)(i / 5000 % 2 ? 0x31 : 1 + (i * 37u >> 3) % 250);
      uint8_t *w; size_t wn; long nz; fx_write_sparse2(logical, sizeof logical, 8192, 1, pk, pkn, &w, &wn, &nz);
      NSString *img = [root stringByAppendingPathComponent:@"wrapped2.img"]; [[NSData dataWithBytes:w length:wn] writeToFile:img atomically:NO];
      pid_t kid = fork();
      if (!kid) {
          unsigned fail0 = failures;
          int fd = open(img.fileSystemRepresentation, O_RDONLY); romfs_src s; CHECK(romfs_src_open(fd, &s) && s.sparse && s.pack_size == pkn && nz > 0);
          CHECK(nvn_bc_astc_use_embedded_pack(fd, s.pack_off, s.pack_size));
          uint8_t *back = malloc(sizeof logical); CHECK(romfs_src_read(&s, back, sizeof logical, 0) && !memcmp(back, logical, sizeof logical)); free(back);
          for (int i = 0; i < N; i++) { strcpy(key.hex, hexkey(keys[i]).UTF8String); memset(got, 0, sizeof got); CHECK(nvn_bc_astc_cache_read(&key, got, len[i], NULL, NVN_ASTC_EMBEDDED_ROOT) && !memcmp(got, pay[i], len[i])); }
          memset(plane, 0, sizeof plane); memcpy(plane, keys[3], 8); memset(out, 0, sizeof out);
          CHECK(nvn_bc_astc_tag_fetch_root(NVN_ASTC_EMBEDDED_ROOT, plane, sizeof plane, 4000, out) == NVN_TAG_HIT && !memcmp(out, pc, 4000));
          _exit(failures != fail0 ? 1 : 0);
      }
      int st = 0; waitpid(kid, &st, 0); CHECK(WIFEXITED(st) && WEXITSTATUS(st) == 0);
      free(w); }
    free(pk);
}
// Block 5 (BC1 at 5x5 beside 4x4 / 6x6 for the rest): the format mapping, the keys, and a plane whose stripes (16384 texels wide: 60 rows at a time) must start on a BC and an ASTC row
static void block5_contract(NSString *root) {
    uint32_t pf;
    CHECK(nvn_bc_astc_format(0x42, 5, &pf) == 1 && pf == MTLPixelFormatASTC_5x5_LDR);
    CHECK(nvn_bc_astc_format(0x41, 5, &pf) == 1 && pf == MTLPixelFormatASTC_5x5_LDR);
    CHECK(nvn_bc_astc_format(0x46, 5, &pf) == 1 && pf == MTLPixelFormatASTC_5x5_sRGB);
    CHECK(nvn_bc_astc_format(0x4e, 5, &pf) == 1 && pf == MTLPixelFormatASTC_5x5_sRGB);
    CHECK(nvn_bc_astc_format(0x44, 5, &pf) == 1 && pf == MTLPixelFormatASTC_5x5_LDR);
    CHECK(nvn_bc_astc_format(0x42, 4, &pf) == 1 && pf == MTLPixelFormatASTC_4x4_LDR && nvn_bc_astc_format(0x46, 6, &pf) == 1 && pf == MTLPixelFormatASTC_6x6_sRGB);
    CHECK(nvn_bc_astc_format(0x42, 3, NULL) == 0 && nvn_bc_astc_format(0x42, 7, NULL) == 0 && nvn_bc_astc_format(0x49, 5, NULL) == 0);
    // one plane keys differently per block
    enum { W = 40, H = 25 }; size_t bc = (size_t)(W / 4) * ((H + 3) / 4) * 8; uint8_t *plane = malloc(bc);
    for (size_t i = 0; i < bc; i++) plane[i] = (uint8_t)(i * 37 + 11);
    nvn_astc_cache_key k4, k5, k6; nvn_bc_astc_plane_key(0x42, W, H, 4, plane, bc, &k4); nvn_bc_astc_plane_key(0x42, W, H, 5, plane, bc, &k5); nvn_bc_astc_plane_key(0x42, W, H, 6, plane, bc, &k6);
    CHECK(strcmp(k4.hex, k5.hex) && strcmp(k5.hex, k6.hex) && strcmp(k4.hex, k6.hex));
    for (unsigned blk = 4; blk <= 6; blk++) {
        size_t astc = (size_t)((W + blk - 1) / blk) * ((H + blk - 1) / blk) * 16; uint8_t *a = malloc(astc), *b = malloc(astc); int hit;
        NSString *dir = [root stringByAppendingPathComponent:[NSString stringWithFormat:@"b5-%u", blk]];
        CHECK(!nvn_bc_astc_encode(0x42, plane, bc, W, H, blk, a, astc, dir.fileSystemRepresentation, NULL, &hit) && !hit);
        CHECK(!nvn_bc_astc_encode(0x42, plane, bc, W, H, blk, b, astc, dir.fileSystemRepresentation, NULL, &hit) && hit && !memcmp(a, b, astc));
        CHECK(nvn_bc_astc_encode(0x42, plane, bc, W, H, blk, b, astc + 16, NULL, NULL, &hit) == -1);   // a wrong output size is refused
        free(a); free(b);
    }
    free(plane);
    // striped: 16384 x 130 BC1 (height not a multiple of 20 or 12)
    {
        const unsigned SW = 16384, SH = 130; size_t sbc = (size_t)(SW / 4) * ((SH + 3) / 4) * 8; uint8_t *sp = malloc(sbc);
        for (size_t i = 0; i < sbc; i++) sp[i] = (uint8_t)((i * 2654435761u) >> 13);
        for (unsigned blk = 4; blk <= 6; blk++) {
            size_t astc = (size_t)((SW + blk - 1) / blk) * ((SH + blk - 1) / blk) * 16; uint8_t *o = malloc(astc); int hit;
            CHECK(!nvn_bc_astc_encode(0x42, sp, sbc, SW, SH, blk, o, astc, NULL, NULL, &hit));
            free(o);
        }
        free(sp);
    }
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
    block5_contract(root);
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
    pack_contract(root);
    pack_v2_contract(root);   // before tag_contract: that one registers the process's embedded pack; the v2 one runs in a child
    tag_contract(root);
    background_contract(root);
    CHECK([NSFileManager.defaultManager removeItemAtPath:root error:NULL]);
    printf("ASTC cache: %u checks, %u failures, %zu retained bytes\n", checks, failures, used);
    return failures != 0;
} }
