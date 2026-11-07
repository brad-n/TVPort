#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <CommonCrypto/CommonDigest.h>
#include "nvn_astc_cache.h"
#include "nvn_astc.h"
#include "nvn_bcdec.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <stdatomic.h>
#include <time.h>
#include <errno.h>
#include <limits.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/mount.h>
#include <dirent.h>
#include <pthread.h>
#include <pthread/qos.h>

// BC1/2/3/7 (RGBA8 once decoded) are the formats ASTC LDR can stand in for. This tree's
// decoder reports the decoded pixel format through nvn_bc_unpacked; the encoded block
// is 8 bytes for BC1 and 16 for BC2/3/7.
typedef struct { uint32_t pixel_format; int pixel_bytes, block_bytes; } nvn_bc_format_info;
static int nvn_bc_format(uint32_t format, nvn_bc_format_info *info) {
    uint32_t pf; int bpp;
    if (!nvn_bc_unpacked(format, &pf, &bpp)) return 0;
    info->pixel_format = pf; info->pixel_bytes = bpp;
    info->block_bytes = (format == 0x41 || format == 0x42 || format == 0x45 || format == 0x46 || format == 0x49 || format == 0x4a) ? 8 : 16;
    return 1;
}
int nvn_bc_astc_format(uint32_t format, unsigned block, uint32_t *pixel_format) {
    nvn_bc_format_info info;
    if (block < 4 || block > 6 || !nvn_bc_format(format, &info) || (info.pixel_format != MTLPixelFormatRGBA8Unorm && info.pixel_format != MTLPixelFormatRGBA8Unorm_sRGB)) return 0;   // RGBA8 only: not BC4/5 nor BC6H (RG11B10Float is 4 bytes too)
    int srgb = info.pixel_format == MTLPixelFormatRGBA8Unorm_sRGB;
    if (pixel_format) *pixel_format = block == 4 ? (srgb ? MTLPixelFormatASTC_4x4_sRGB : MTLPixelFormatASTC_4x4_LDR)
                                    : block == 5 ? (srgb ? MTLPixelFormatASTC_5x5_sRGB : MTLPixelFormatASTC_5x5_LDR)
                                                 : (srgb ? MTLPixelFormatASTC_6x6_sRGB : MTLPixelFormatASTC_6x6_LDR);
    return 1;
}

// This namespace changes with encoder settings, version, or the stripe layout.
// Fixed-width little-endian parameters keep Mac-generated caches usable on tvOS.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static void cache_key(uint32_t format, uint32_t width, uint32_t height, unsigned block,
                      const void *source, size_t size, char key[65]) {
    static const char version[] = "nxnative-astc-arm-5.7.0-fastest-stripe4m-v1";
    uint32_t fields[] = {format, width, height, block};
    uint8_t parameters[16], digest[CC_SHA256_DIGEST_LENGTH];
    for (unsigned i = 0; i < 4; i++) for (unsigned j = 0; j < 4; j++) parameters[i * 4 + j] = fields[i] >> (j * 8);
    CC_SHA256_CTX hash;
    CC_SHA256_Init(&hash);
    CC_SHA256_Update(&hash, version, sizeof version);
    CC_SHA256_Update(&hash, parameters, sizeof parameters);
    CC_SHA256_Update(&hash, source, (CC_LONG)size);
    CC_SHA256_Final(digest, &hash);
    for (unsigned i = 0; i < sizeof digest; i++) snprintf(key + i * 2, 3, "%02x", digest[i]);
}
static void payload_hash(const void *data, size_t size, uint8_t digest[CC_SHA256_DIGEST_LENGTH]) {
    CC_SHA256(data, (CC_LONG)size, digest);
}
#pragma clang diagnostic pop

static int bg_write_allowed(const char *root, size_t size);
static int cache_write_counted(const char *root, NSString *path, const void *output, size_t size);
static NSString *cache_path(const char *root, const char *key) {
    if (!root || !*root) return nil;
    return [[NSString stringWithUTF8String:root] stringByAppendingPathComponent:[NSString stringWithFormat:@"%s.astc", key]];
}
static const uint8_t cache_magic[8] = {'N', 'X', 'A', 'S', 'T', 'C', '0', '1'};
static NSDictionary<NSString *, NSData *> *g_cache_small;
static NSDictionary<NSString *, NSData *> *g_cache_mapped;
static void *g_cache_mapped_base;
static size_t g_cache_mapped_size;
static int g_cache_snapshot_fd = -1;
static _Atomic int g_cache_small_ready;
static _Atomic uint64_t g_cache_memory_hits, g_cache_disk_hits, g_cache_mapped_hits;
const char *nvn_bc_astc_cache_status_name(nvn_astc_cache_status status) {
    static const char *names[] = {"unchecked", "disabled", "hit", "missing", "header", "size", "hash", "io"};
    return (unsigned)status < sizeof names / sizeof *names ? names[status] : "unknown";
}
static nvn_astc_cache_status cache_read_disk_status(NSString *path, void *output, size_t size) {
    if (!path) return NVN_ASTC_CACHE_DISABLED;
    FILE *file = fopen(path.fileSystemRepresentation, "rb");
    if (!file) return errno == ENOENT ? NVN_ASTC_CACHE_MISSING : NVN_ASTC_CACHE_IO;
    uint8_t header[40], digest[CC_SHA256_DIGEST_LENGTH];
    nvn_astc_cache_status status = NVN_ASTC_CACHE_HIT;
    if (fread(header, 1, sizeof header, file) != sizeof header) status = NVN_ASTC_CACHE_SIZE;
    else if (memcmp(header, cache_magic, sizeof cache_magic)) status = NVN_ASTC_CACHE_HEADER;
    else if (fread(output, 1, size, file) != size || fgetc(file) != EOF) status = NVN_ASTC_CACHE_SIZE;
    if (ferror(file)) status = NVN_ASTC_CACHE_IO;
    if (fclose(file)) status = NVN_ASTC_CACHE_IO;
    if (status != NVN_ASTC_CACHE_HIT) return status;
    payload_hash(output, size, digest);
    return memcmp(header + sizeof cache_magic, digest, sizeof digest) ? NVN_ASTC_CACHE_HASH : NVN_ASTC_CACHE_HIT;
}
static int cache_read_disk(NSString *path, void *output, size_t size) {
    return cache_read_disk_status(path, output, size) == NVN_ASTC_CACHE_HIT;
}

// Copy and validate with bounded scratch. An invalid source is a cache miss;
// a destination write failure stops snapshot growth. Neither is published.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static int cache_snapshot_copy(NSString *path, int fd, off_t offset, size_t size,
                                void *scratch, size_t scratch_size) {
    FILE *file = fopen(path.fileSystemRepresentation, "rb");
    if (!file) return 0;
    uint8_t header[40], digest[CC_SHA256_DIGEST_LENGTH];
    int valid = fread(header, 1, sizeof header, file) == sizeof header &&
                !memcmp(header, cache_magic, sizeof cache_magic);
    CC_SHA256_CTX hash; CC_SHA256_Init(&hash);
    for (size_t done = 0; valid == 1 && done < size;) {
        size_t count = MIN(size - done, scratch_size);
        if (fread(scratch, 1, count, file) != count) { valid = 0; break; }
        CC_SHA256_Update(&hash, scratch, (CC_LONG)count);
        size_t written = 0;
        while (written < count) {
            ssize_t n = pwrite(fd, (uint8_t *)scratch + written, count - written,
                               offset + (off_t)(done + written));
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) { valid = -1; break; }
            written += (size_t)n;
        }
        done += count;
    }
    if (valid == 1) {
        CC_SHA256_Final(digest, &hash);
        valid = fgetc(file) == EOF && !ferror(file) &&
                !memcmp(header + sizeof cache_magic, digest, sizeof digest);
    }
    fclose(file);
    return valid;
}
#pragma clang diagnostic pop

static NSDictionary<NSString *, NSData *> *cache_prepare_mapped(NSArray<NSDictionary *> *entries,
        NSDictionary<NSString *, NSData *> *small, size_t budget) {
    if (!budget || budget > INT64_MAX) return @{};
    char path[PATH_MAX];
    int length = snprintf(path, sizeof path, "%s/dm-astc-snapshot-XXXXXX", NSTemporaryDirectory().fileSystemRepresentation);
    if (length < 0 || (size_t)length >= sizeof path) return @{};
    int fd = mkstemp(path);
    if (fd < 0) return @{};
    if (unlink(path)) { close(fd); return @{}; }
    const size_t scratch_size = 256u << 10;
    void *scratch = malloc(scratch_size);
    if (!scratch) { close(fd); return @{}; }
    NSMutableDictionary<NSString *, NSArray<NSNumber *> *> *ranges = [NSMutableDictionary dictionary];
    size_t page = (size_t)getpagesize(), used = 0;
    for (NSDictionary *entry in entries) {
        NSString *name = entry[@"path"];
        if (small[name] || ranges[name]) continue;
        size_t size = [entry[@"bytes"] unsignedLongLongValue];
        if (!size || size > SIZE_MAX - (page - 1)) continue;
        size_t span = (size + page - 1) / page * page;
        if (span > budget - used) continue;
        int valid = cache_snapshot_copy(name, fd, (off_t)used, size, scratch, scratch_size);
        if (valid < 0) break;
        if (!valid) continue;
        ranges[name] = @[@(used), @(size)];
        used += span;
    }
    free(scratch);
    // Truncate any rejected trailing entry, then finish writes before gameplay.
    // The unlinked file cannot later be truncated or replaced through a cache
    // pathname, which would otherwise invalidate a verified mapping or SIGBUS.
    if (!used || ftruncate(fd, (off_t)used) || fsync(fd)) { close(fd); return @{}; }
    void *mapped = mmap(NULL, used, PROT_READ, MAP_SHARED, fd, 0);
    if (mapped == MAP_FAILED) { close(fd); return @{}; }
    NSMutableDictionary<NSString *, NSData *> *prepared = [NSMutableDictionary dictionary];
    for (NSString *name in ranges) {
        NSArray<NSNumber *> *range = ranges[name];
        prepared[name] = [NSData dataWithBytesNoCopy:(uint8_t *)mapped + range[0].unsignedLongLongValue
            length:range[1].unsignedLongLongValue freeWhenDone:NO];
    }
    // The process-lifetime dictionary owns this immutable file mapping. Its
    // pages may be reclaimed independently of the small retained heap cache.
    g_cache_mapped_base = mapped; g_cache_mapped_size = used;
    // Keep one descriptor for positional bulk reads. This lets the filesystem
    // service a range instead of serializing demand faults on the replay thread.
    // It neither pins mapped pages nor retains another copy of the payload.
    const char *bulk = getenv("DM_NVN_ASTC_SNAPSHOT_PREAD");
    if ((!bulk || strcmp(bulk, "0")) && !fcntl(fd, F_SETFD, FD_CLOEXEC)) g_cache_snapshot_fd = fd;
    else close(fd);
    (void)madvise(mapped, used, MADV_DONTNEED);
    return [prepared copy];
}

static int cache_snapshot_read(void *output, const void *source, size_t size) {
    uintptr_t base = (uintptr_t)g_cache_mapped_base, address = (uintptr_t)source;
    if (g_cache_snapshot_fd < 0 || !output || !size || address < base ||
        size > g_cache_mapped_size || address - base > g_cache_mapped_size - size) return 0;
    size_t offset = address - base;
    for (size_t done = 0; done < size;) {
        size_t count = MIN(size - done, 1u << 20);
        ssize_t n = pread(g_cache_snapshot_fd, (uint8_t *)output + done, count, (off_t)(offset + done));
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return 0;
        done += (size_t)n;
    }
    return 1;
}

static nvn_astc_cache_status cache_read_status(NSString *path, void *output, size_t size) {
    if (!path) return NVN_ASTC_CACHE_DISABLED;
    if (atomic_load_explicit(&g_cache_small_ready, memory_order_acquire)) {
        NSData *data = g_cache_small[path];
        if (data && data.length == size) {
            memcpy(output, data.bytes, size);
            atomic_fetch_add_explicit(&g_cache_memory_hits, 1, memory_order_relaxed);
            return NVN_ASTC_CACHE_HIT;
        }
        data = g_cache_mapped[path];
        if (data && data.length == size) {
            // The immutable mapping also supplies a complete fallback after a
            // failed or partial read; never publish a partially filled plane.
            if (!cache_snapshot_read(output, data.bytes, size)) memcpy(output, data.bytes, size);
            atomic_fetch_add_explicit(&g_cache_mapped_hits, 1, memory_order_relaxed);
            return NVN_ASTC_CACHE_HIT;
        }
    }
    nvn_astc_cache_status status = cache_read_disk_status(path, output, size);
    if (status == NVN_ASTC_CACHE_HIT) atomic_fetch_add_explicit(&g_cache_disk_hits, 1, memory_order_relaxed);
    return status;
}
static int cache_read(NSString *path, void *output, size_t size) {
    return cache_read_status(path, output, size) == NVN_ASTC_CACHE_HIT;
}
// ---- The read-only prebuilt cache as ONE file (astc-ro.pack, written by dm/gfx/tools/bntx_astc.py) ----
// Sending tens of thousands of small files to an Apple TV is far slower than sending one, so DM_NVN_ASTC_CACHE_RO may name a pack instead of a directory.
// Layout (little-endian): a header of 80 bytes {"NXASTCPK", u32 version 1, u32 index entry size 48, u64 entry count, u64 index offset, u64 file size, 32-byte input fingerprint, 8 zero bytes};
// the entries, each a complete cache file ("NXASTC01", SHA-256 of the blocks, the ASTC blocks) at a 16-byte boundary; at the end the index: count entries {32-byte key (the SHA-256 whose hex is
// the cache file name), u64 offset, u64 size} sorted by key. The index is mapped and binary-searched; an entry is read with pread (the pages of a multi-GB pack are never resident) and
// verified like a file. A pack whose header, size or index do not hold together is ignored whole: every lookup in it is a miss.
#define PACK_HEAD 80u
#define PACK_ENT 48u
enum { PACK_PACK = 1, PACK_DIR, PACK_BAD };
typedef struct { char *path; int kind, fd; uint64_t base, count, size; const uint8_t *index; void *map; size_t map_len; uint8_t fingerprint[32]; } nvn_pack;   // base: where the pack starts in fd (0 for a file of its own; an image's embedded pack: DMSPARS1 pack offset)
static pthread_mutex_t g_pack_mu = PTHREAD_MUTEX_INITIALIZER;
static nvn_pack **g_packs; static size_t g_pack_n, g_pack_cap;
static uint64_t le64(const uint8_t *p) { uint64_t v = 0; for (int i = 7; i >= 0; i--) v = v << 8 | p[i]; return v; }
static uint32_t le32(const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }
// Whether the `size` bytes at `base` of fd are a pack that holds together (all offsets in it are relative to base); fills p (descriptor and index mapping kept for the life of the process)
static int pack_open_at(int fd, uint64_t base, uint64_t size, nvn_pack *p) {
    uint8_t h[PACK_HEAD];
    if (size < PACK_HEAD || pread(fd, h, sizeof h, (off_t)base) != (ssize_t)sizeof h) return 0;
    uint64_t count = le64(h + 16), ioff = le64(h + 24), fsz = le64(h + 32);
    if (memcmp(h, "NXASTCPK", 8) || le32(h + 8) != 1 || le32(h + 12) != PACK_ENT || fsz != size || ioff < PACK_HEAD || ioff > fsz ||
        (ioff & 15) || count > (fsz - ioff) / PACK_ENT || count * PACK_ENT != fsz - ioff) return 0;
    size_t page = (size_t)getpagesize(), lead = (size_t)((base + ioff) % page), len = lead + (size_t)(count * PACK_ENT);
    void *map = NULL; const uint8_t *index = NULL;
    if (count) {
        map = mmap(NULL, len, PROT_READ, MAP_PRIVATE, fd, (off_t)(base + ioff - lead));
        if (map == MAP_FAILED) return 0;
        index = (const uint8_t *)map + lead;
    }
    for (uint64_t i = 0; i < count; i++) {   // sorted, no duplicates, every entry inside the entries area
        const uint8_t *e = index + i * PACK_ENT; uint64_t off = le64(e + 32), sz = le64(e + 40);
        if ((i && memcmp(e - PACK_ENT, e, 32) >= 0) || off < PACK_HEAD || (off & 15) || sz <= 40 || off > ioff || sz > ioff - off) { if (map) munmap(map, len); return 0; }
    }
    p->fd = fd; p->base = base; p->count = count; p->size = fsz; p->index = index; p->map = map; p->map_len = len; memcpy(p->fingerprint, h + 40, 32);
    return 1;
}
// Whether the file at `path` is a pack that holds together; fills p (descriptor and index mapping kept for the life of the process)
static int pack_open(const char *path, nvn_pack *p) {
    int fd = open(path, O_RDONLY | O_CLOEXEC); struct stat st;
    if (fd < 0) return 0;
    if (fstat(fd, &st) || !S_ISREG(st.st_mode) || !pack_open_at(fd, 0, (uint64_t)st.st_size, p)) { close(fd); return 0; }
    return 1;
}
// The pack a romfs image embeds (DMSPARS1, dm/host/romfs_sparse.h, docs/texture_once.md section 1): `fd` (kept open for the life of the process; closed here when the pack is not usable)
// holds it at [offset, offset + size). It is registered under the pseudo-root NVN_ASTC_EMBEDDED_ROOT, which any read-only-cache argument or DM_NVN_ASTC_CACHE_RO may then name; 1 when it holds together
int nvn_bc_astc_use_embedded_pack(int fd, uint64_t offset, uint64_t size) {
    pthread_mutex_lock(&g_pack_mu);
    for (size_t i = 0; i < g_pack_n; i++) if (!strcmp(g_packs[i]->path, NVN_ASTC_EMBEDDED_ROOT)) { pthread_mutex_unlock(&g_pack_mu); close(fd); return g_packs[i]->kind == PACK_PACK; }   // once per process
    nvn_pack *p = calloc(1, sizeof *p); int ok = 0;
    if (p) {
        p->fd = -1; p->path = strdup(NVN_ASTC_EMBEDDED_ROOT);
        ok = pack_open_at(fd, offset, size, p); p->kind = ok ? PACK_PACK : PACK_BAD;
        if (!ok) { close(fd); fprintf(stderr, "[RED] ASTC: the pack embedded in the RomFS image is not usable (corrupt or short)\n"); }
        if (g_pack_n == g_pack_cap) { g_pack_cap = g_pack_cap ? g_pack_cap * 2 : 4; g_packs = realloc(g_packs, g_pack_cap * sizeof *g_packs); }
        g_packs[g_pack_n++] = p;
    } else close(fd);
    pthread_mutex_unlock(&g_pack_mu);
    return ok;
}
// The pack that `root` names, or NULL when it is a directory, missing, or not a usable pack (one warning is printed for a file that is not). Remembered per path for the process
static const nvn_pack *pack_for(const char *root) {
    if (!root || !*root) return NULL;
    pthread_mutex_lock(&g_pack_mu);
    for (size_t i = 0; i < g_pack_n; i++) if (!strcmp(g_packs[i]->path, root)) { const nvn_pack *r = g_packs[i]->kind == PACK_PACK ? g_packs[i] : NULL; pthread_mutex_unlock(&g_pack_mu); return r; }
    struct stat st; const nvn_pack *r = NULL;
    if (!strcmp(root, NVN_ASTC_EMBEDDED_ROOT)) { pthread_mutex_unlock(&g_pack_mu); return NULL; }   // the embedded pack is registered by nvn_bc_astc_use_embedded_pack, never found by a path
    if (!stat(root, &st)) {   // a path that is missing now may appear later: not remembered
        nvn_pack *p = calloc(1, sizeof *p);
        if (p) {
            p->fd = -1; p->path = strdup(root);
            p->kind = S_ISDIR(st.st_mode) ? PACK_DIR : pack_open(root, p) ? PACK_PACK : PACK_BAD;
            if (p->kind == PACK_BAD) fprintf(stderr, "[dm] ASTC read-only cache %s is not a usable pack (corrupt or short): ignored\n", root);
            if (g_pack_n == g_pack_cap) { g_pack_cap = g_pack_cap ? g_pack_cap * 2 : 4; g_packs = realloc(g_packs, g_pack_cap * sizeof *g_packs); }
            g_packs[g_pack_n++] = p;
            if (p->kind == PACK_PACK) r = p;
        }
    }
    pthread_mutex_unlock(&g_pack_mu);
    return r;
}
static int key_bytes(const char *hex, uint8_t out[32]) {
    for (int i = 0; i < 32; i++) {
        int v[2];
        for (int j = 0; j < 2; j++) { char c = hex[i * 2 + j]; v[j] = c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10 : -1; if (v[j] < 0) return 0; }
        out[i] = (uint8_t)(v[0] << 4 | v[1]);
    }
    return 1;
}
static int pack_find(const nvn_pack *p, const char *hex, uint64_t *off, uint64_t *size) {
    uint8_t k[32]; uint64_t lo = 0, hi = p->count;
    if (!key_bytes(hex, k)) return 0;
    while (lo < hi) {
        uint64_t mid = lo + (hi - lo) / 2; const uint8_t *e = p->index + mid * PACK_ENT; int c = memcmp(e, k, 32);
        if (!c) { *off = le64(e + 32); *size = le64(e + 40); return 1; }
        if (c < 0) lo = mid + 1; else hi = mid;
    }
    return 0;
}
static int pread_full(int fd, void *buf, size_t size, uint64_t at) {
    for (size_t got = 0; got < size;) {
        ssize_t n = pread(fd, (uint8_t *)buf + got, size - got, (off_t)(at + got));
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return 0;
        got += (size_t)n;
    }
    return 1;
}
// The entry at pack offset off, sz bytes (a cache file: header and blocks), verified and read into output
static nvn_astc_cache_status pack_read_entry(const nvn_pack *p, uint64_t off, uint64_t sz, void *output, size_t size) {
    uint8_t header[40], digest[CC_SHA256_DIGEST_LENGTH];
    if (sz != size + 40) return NVN_ASTC_CACHE_SIZE;
    if (!pread_full(p->fd, header, sizeof header, p->base + off) || !pread_full(p->fd, output, size, p->base + off + 40)) return NVN_ASTC_CACHE_IO;
    if (memcmp(header, cache_magic, sizeof cache_magic)) return NVN_ASTC_CACHE_HEADER;
    payload_hash(output, size, digest);
    if (memcmp(header + sizeof cache_magic, digest, sizeof digest)) return NVN_ASTC_CACHE_HASH;
    atomic_fetch_add_explicit(&g_cache_disk_hits, 1, memory_order_relaxed);
    return NVN_ASTC_CACHE_HIT;
}
static nvn_astc_cache_status pack_read(const nvn_pack *p, const char *hex, void *output, size_t size) {
    uint64_t off, sz;
    if (!pack_find(p, hex, &off, &sz)) return NVN_ASTC_CACHE_MISSING;
    return pack_read_entry(p, off, sz, output, size);
}
// ---- Tagged planes (docs/texture_once.md section 2) ----
// A plane the stripping tool covered holds the first 8 bytes of its pack key, then zeros: its ASTC blocks are looked up by that prefix, without deswizzling or hashing
static _Atomic uint64_t g_tag_hits, g_tag_unresolved, g_tag_decoded;
int nvn_bc_astc_looks_tagged(const void *plane, size_t length) {
    const uint8_t *p = plane; uint64_t head;
    if (!p || length < 16) return 0;
    memcpy(&head, p, 8);
    if (!head) return 0;
    const uint8_t *q = p + 8, *end = p + length;
    while (q < end && ((uintptr_t)q & 7)) { if (*q++) return 0; }
    for (; q + 8 <= end; q += 8) { uint64_t w; memcpy(&w, q, 8); if (w) return 0; }
    for (; q < end; q++) if (*q) return 0;
    return 1;
}
int nvn_bc_astc_looks_tagged_rows(const void *plane, size_t row_bytes, size_t stride, size_t rows) {
    const uint8_t *p = plane;
    if (!p || !row_bytes || !rows || row_bytes * rows < 16) return 0;
    if (stride == row_bytes) return nvn_bc_astc_looks_tagged(p, row_bytes * rows);
    uint64_t head;
    if (row_bytes < 8) return 0;
    memcpy(&head, p, 8);
    if (!head) return 0;
    for (size_t r = 0; r < rows; r++) {
        const uint8_t *q = p + r * stride + (r ? 0 : 8), *end = p + r * stride + row_bytes;
        for (; q < end; q++) if (*q) return 0;
    }
    return 1;
}
// The entries whose key starts with tag and whose payload is `payload` bytes: 1 only when there is exactly one
static int pack_tag_find(const nvn_pack *p, const uint8_t *tag, size_t payload, uint64_t *off, uint64_t *sz) {
    uint64_t lo = 0, hi = p->count, found = 0;
    while (lo < hi) { uint64_t mid = lo + (hi - lo) / 2; if (memcmp(p->index + mid * PACK_ENT, tag, 8) < 0) lo = mid + 1; else hi = mid; }
    for (uint64_t i = lo; i < p->count; i++) {
        const uint8_t *e = p->index + i * PACK_ENT;
        if (memcmp(e, tag, 8)) break;
        if (le64(e + 40) == payload + 40) { if (++found > 1) return 0; *off = le64(e + 32); *sz = le64(e + 40); }
    }
    return found == 1;
}
static nvn_astc_tag_result tag_fetch_pack(const nvn_pack *p, const void *plane, size_t astc_size, void *output) {   // the plane looks tagged
    uint64_t off, sz;
    if (!p || !astc_size || !pack_tag_find(p, plane, astc_size, &off, &sz)) return NVN_TAG_MISS;
    if (!output) return NVN_TAG_HIT;
    if (pack_read_entry(p, off, sz, output, astc_size) != NVN_ASTC_CACHE_HIT) return NVN_TAG_MISS;
    atomic_fetch_add(&g_tag_hits, 1);
    return NVN_TAG_HIT;
}
nvn_astc_tag_result nvn_bc_astc_tag_fetch_root(const char *readonly_cache, const void *plane, size_t length, size_t astc_size, void *output) {
    if (!nvn_bc_astc_looks_tagged(plane, length)) return NVN_TAG_NONE;
    return tag_fetch_pack(pack_for(readonly_cache), plane, astc_size, output);
}
void nvn_bc_astc_tag_note(int kind) { atomic_fetch_add(kind == NVN_TAG_NOTE_DECODED ? &g_tag_decoded : &g_tag_unresolved, 1); }
void nvn_bc_astc_tag_stats(uint64_t *hits, uint64_t *unresolved, uint64_t *decoded) {
    *hits = atomic_load(&g_tag_hits); *unresolved = atomic_load(&g_tag_unresolved); *decoded = atomic_load(&g_tag_decoded);
}
// A read-only cache root is a pack file or a directory of <key>.astc files
static nvn_astc_cache_status ro_read_status(const char *root, const char *key, void *output, size_t size) {
    if (!root || !*root) return NVN_ASTC_CACHE_DISABLED;
    const nvn_pack *p = pack_for(root);
    return p ? pack_read(p, key, output, size) : cache_read_status(cache_path(root, key), output, size);
}
void nvn_bc_astc_plane_key(uint32_t format, uint32_t width, uint32_t height, unsigned block, const void *source, size_t source_size, nvn_astc_cache_key *key) {
    cache_key(format, width, height, block, source, source_size, key->hex);
}
int nvn_bc_astc_pack_info(const char *path, uint64_t *entries, uint64_t *bytes, uint8_t fingerprint[32]) {
    const nvn_pack *p = pack_for(path);
    if (!p) return 0;
    if (entries) *entries = p->count;
    if (bytes) *bytes = p->size;
    if (fingerprint) memcpy(fingerprint, p->fingerprint, 32);
    return 1;
}
// The entries and bytes of a read-only root that is a pack; 0 when it is not one
static int ro_pack_stats(const char *root, uint64_t *entries, uint64_t *bytes) {
    const nvn_pack *p = pack_for(root);
    if (!p) return 0;
    *entries = p->count; *bytes = p->size; return 1;
}

void nvn_bc_astc_cache_stats(uint64_t *memory_hits, uint64_t *disk_hits, uint64_t *mapped_hits) {
    *memory_hits = atomic_load_explicit(&g_cache_memory_hits, memory_order_relaxed);
    *disk_hits = atomic_load_explicit(&g_cache_disk_hits, memory_order_relaxed);
    *mapped_hits = atomic_load_explicit(&g_cache_mapped_hits, memory_order_relaxed);
}
void nvn_bc_astc_cache_prepare(const char *readonly_cache, const char *cache,
                                size_t budget, size_t mapped_budget) {
    if (!budget && !mapped_budget) return;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ @autoreleasepool {
        uint64_t started = clock_gettime_nsec_np(CLOCK_MONOTONIC);
        NSMutableSet<NSString *> *roots = [NSMutableSet set];
        if (readonly_cache && *readonly_cache) [roots addObject:@(readonly_cache)];
        if (cache && *cache) [roots addObject:@(cache)];
        NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
        NSFileManager *manager = NSFileManager.defaultManager;
        for (NSString *root in roots) {
            NSArray<NSURL *> *files = [manager contentsOfDirectoryAtURL:[NSURL fileURLWithPath:root isDirectory:YES]
                includingPropertiesForKeys:@[NSURLIsRegularFileKey, NSURLFileSizeKey]
                options:NSDirectoryEnumerationSkipsHiddenFiles error:NULL];
            for (NSURL *url in files) {
                if (url.lastPathComponent.length != 69 || ![url.pathExtension isEqualToString:@"astc"]) continue;
                NSNumber *regular = nil, *length = nil;
                if (![url getResourceValue:&regular forKey:NSURLIsRegularFileKey error:NULL] || !regular.boolValue ||
                    ![url getResourceValue:&length forKey:NSURLFileSizeKey error:NULL]) continue;
                uint64_t bytes = length.unsignedLongLongValue;
                if (bytes <= 40 || bytes - 40 > SIZE_MAX) continue;
                // NSURL can expand aliases such as /var to /private/var. Keep
                // the caller's spelling so cache_read builds the same key.
                NSString *path = [root stringByAppendingPathComponent:url.lastPathComponent];
                [entries addObject:@{@"path": path, @"bytes": @(bytes - 40)}];
            }
        }
        [entries sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            NSComparisonResult order = [a[@"bytes"] compare:b[@"bytes"]];
            return order == NSOrderedSame ? [a[@"path"] compare:b[@"path"]] : order;
        }];
        NSMutableDictionary<NSString *, NSData *> *prepared = [NSMutableDictionary dictionary];
        size_t used = 0;
        for (NSDictionary *entry in entries) {
            NSString *path = entry[@"path"];
            if (prepared[path]) continue;
            size_t size = [entry[@"bytes"] unsignedLongLongValue];
            if (size > 64u * 1024u || size > budget - used) break;
            void *bytes = malloc(size);
            if (!bytes) break;
            // Validate once before publication. Content-addressed entries never
            // change their meaning, so later reads use this verified snapshot.
            if (!cache_read_disk(path, bytes, size)) { free(bytes); continue; }
            prepared[path] = [NSData dataWithBytesNoCopy:bytes length:size freeWhenDone:YES];
            used += size;
        }
        g_cache_small = [prepared copy];
        g_cache_mapped = cache_prepare_mapped(entries, prepared, mapped_budget);
        atomic_store_explicit(&g_cache_small_ready, 1, memory_order_release);
        fprintf(stderr, "[dm] ASTC cache preparation: %lu small entries, %zu heap bytes / %zu budget, %lu mapped entries, %zu file bytes / %zu budget, %.1f ms\n",
                (unsigned long)g_cache_small.count, used, budget,
                (unsigned long)g_cache_mapped.count, g_cache_mapped_size, mapped_budget,
                (clock_gettime_nsec_np(CLOCK_MONOTONIC) - started) / 1e6);
        if (g_cache_mapped_base)
            fprintf(stderr, "[dm] ASTC snapshot mapping: %p, %zu bytes; reads %s\n", g_cache_mapped_base, g_cache_mapped_size,
                    g_cache_snapshot_fd >= 0 ? "pread (at most 1 MiB per call)" : "mapped memcpy");
    } });
}
static int cache_write(NSString *path, const void *output, size_t size) {
    if (!path) return 0;
    [[NSFileManager defaultManager] createDirectoryAtPath:path.stringByDeletingLastPathComponent
                            withIntermediateDirectories:YES attributes:nil error:NULL];
    char *temporary = strdup([[path stringByAppendingString:@".XXXXXX"] fileSystemRepresentation]);
    if (!temporary) return ENOMEM;
    int fd = mkstemp(temporary);
    if (fd < 0) { int error = errno; free(temporary); return error; }
    FILE *file = fdopen(fd, "wb");
    int error = file ? 0 : errno;
    if (file) {
        uint8_t header[40]; memcpy(header, cache_magic, sizeof cache_magic);
        payload_hash(output, size, header + sizeof cache_magic);
        if (fwrite(header, 1, sizeof header, file) != sizeof header || fwrite(output, 1, size, file) != size) error = errno ? errno : EIO;
        if (fclose(file) && !error) error = errno ? errno : EIO;
    } else close(fd);
    if (!error && rename(temporary, path.fileSystemRepresentation)) error = errno;
    unlink(temporary);
    free(temporary);
    return error;
}

int nvn_bc_astc_cache_read(const nvn_astc_cache_key *key, void *output, size_t size,
                           const char *cache, const char *readonly_cache) {
    if (!key || !output || !size || key->hex[64]) return 0;
    for (unsigned i = 0; i < 64; i++)
        if (!((key->hex[i] >= '0' && key->hex[i] <= '9') || (key->hex[i] >= 'a' && key->hex[i] <= 'f'))) return 0;
    @autoreleasepool {
        return ro_read_status(readonly_cache, key->hex, output, size) == NVN_ASTC_CACHE_HIT ||
               cache_read(cache_path(cache, key->hex), output, size);
    }
}

// Decode the BC plane in stripes and encode it with the codec contexts of `slot`; no cache involved
static int encode_plane(unsigned slot, uint32_t format, const void *source, uint32_t width, uint32_t height,
                        unsigned block, const nvn_bc_format_info *info, void *output) {
    size_t bc_pitch = ((size_t)width + 3) / 4 * info->block_bytes;
    size_t astc_pitch = ((size_t)width + block - 1) / block * 16;
    // Every stripe begins on both a BC and an ASTC block boundary. This bounds
    // decoded scratch without adding seams or retaining a second full texture.
    size_t row = (size_t)width * 4, alignment = block == 6 ? 12 : block == 5 ? 20 : 4;   // lcm(4, block)
    size_t rows = ((4u << 20) / row / alignment) * alignment;
    if (!rows) rows = alignment;
    if (rows > height) rows = height;
    uint8_t *pixels = malloc(rows * row);
    if (!pixels) return -1;
    int result = 0;
    for (uint32_t y = 0; y < height && !result; y += rows) {
        uint32_t count = MIN(rows, height - y);
        size_t offset = (size_t)y / 4 * bc_pitch;
        result = nvn_bc_decode(format, (const uint8_t *)source + offset, bc_pitch, width, count, pixels, row);
        if (!result) result = nvn_astc_encode_rgba8_slot(slot, pixels, width, count, info->pixel_format == MTLPixelFormatRGBA8Unorm_sRGB,
            block, (uint8_t *)output + (size_t)y / block * astc_pitch, astc_pitch * ((count + block - 1) / block));
    }
    free(pixels);
    return result;
}

int nvn_bc_astc_encode_report(uint32_t format, const void *source, size_t source_size,
                       uint32_t width, uint32_t height, unsigned block,
                       void *output, size_t output_size, const char *cache,
                       const char *readonly_cache, int *cache_hit,
                       nvn_astc_cache_key *saved_key, nvn_astc_cache_report *report) {
    if (cache_hit) *cache_hit = 0;
    if (saved_key) memset(saved_key, 0, sizeof *saved_key);
    if (report) memset(report, 0, sizeof *report);
    if (!source || !output || !width || !height || width > 16384 || height > 16384 || !nvn_bc_astc_format(format, block, NULL)) return -1;
    nvn_bc_format_info info; nvn_bc_format(format, &info);
    size_t bc_pitch = ((size_t)width + 3) / 4 * info.block_bytes;
    size_t astc_pitch = ((size_t)width + block - 1) / block * 16;
    if (source_size != bc_pitch * (((size_t)height + 3) / 4) || output_size != astc_pitch * (((size_t)height + block - 1) / block)) return -1;
    uintptr_t src = (uintptr_t)source, dst = (uintptr_t)output;
    if (dst >= src ? dst - src < source_size : src - dst < output_size) return -1;
    @autoreleasepool {
        char key[65]; cache_key(format, width, height, block, source, source_size, key);
        if (report) memcpy(report->key.hex, key, sizeof key);
        NSString *path = cache_path(cache, key), *readonly_path = pack_for(readonly_cache) ? nil : cache_path(readonly_cache, key);
        nvn_astc_cache_status ro = ro_read_status(readonly_cache, key, output, output_size), rw = NVN_ASTC_CACHE_UNCHECKED;
        if (ro != NVN_ASTC_CACHE_HIT)
            rw = [path isEqualToString:readonly_path] ? ro : cache_read_status(path, output, output_size);
        if (report) { report->readonly_status = ro; report->writable_status = rw; }
        if (ro == NVN_ASTC_CACHE_HIT || rw == NVN_ASTC_CACHE_HIT) {
            if (cache_hit) *cache_hit = 1;
            if (saved_key) memcpy(saved_key->hex, key, sizeof key);
            return 0;
        }
        int result = encode_plane(0, format, source, width, height, block, &info, output);
        if (!result) {
            int error = bg_write_allowed(cache, output_size) ? cache_write_counted(cache, path, output, output_size) : 0;   // the synchronous mode is limited like the workers
            if (report) { report->write_attempted = path != nil; report->write_error = error; }
            if (saved_key) memcpy(saved_key->hex, key, sizeof key);
        }
        return result;
    }
}

int nvn_bc_astc_encode_key(uint32_t format, const void *source, size_t source_size,
                       uint32_t width, uint32_t height, unsigned block,
                       void *output, size_t output_size, const char *cache,
                       const char *readonly_cache, int *cache_hit,
                       nvn_astc_cache_key *saved_key) {
    return nvn_bc_astc_encode_report(format, source, source_size, width, height, block,
        output, output_size, cache, readonly_cache, cache_hit, saved_key, NULL);
}

int nvn_bc_astc_encode(uint32_t format, const void *source, size_t source_size,
                       uint32_t width, uint32_t height, unsigned block,
                       void *output, size_t output_size, const char *cache,
                       const char *readonly_cache, int *cache_hit) {
    return nvn_bc_astc_encode_key(format, source, source_size, width, height, block,
                                  output, output_size, cache, readonly_cache, cache_hit, NULL);
}

// ---------------------------------------------------------------------------------------------
// Background miss policy (DM_NVN_ASTC_MISS=background, the default). A cache miss never encodes on the
// caller's thread: the texture goes up in its decoded format, the BC plane is copied into a bounded queue
// (nvn_bc_astc_learn), and low-priority worker threads encode it and write the cache file, so the next
// launch hits. The queue drops what does not fit; a cache size cap and a free-disk floor stop the writes.
// ---------------------------------------------------------------------------------------------
typedef struct bg_job {
    struct bg_job *next;
    char key[65];
    uint32_t format, width, height;
    unsigned block;
    size_t size;
    uint8_t data[];
} bg_job;

enum { BG_MAX_THREADS = 4 };
static struct {
    pthread_mutex_t mu;
    pthread_cond_t work, idle;
    bg_job *head, *tail;
    size_t queued_bytes, queue_cap;
    unsigned active, threads, running;
    int stop, configured;
    char *cache, *readonly;
    uint64_t cache_max, min_free;
    pthread_t thread[BG_MAX_THREADS];
    NSMutableSet<NSString *> *pending;
} g_bg = {.mu = PTHREAD_MUTEX_INITIALIZER, .work = PTHREAD_COND_INITIALIZER, .idle = PTHREAD_COND_INITIALIZER};
static _Atomic uint64_t st_hit, st_miss, st_queued, st_dropped, st_dropped_bytes, st_dups, st_encoded, st_encode_ns, st_encoded_rgba,
    st_written, st_skipped_cap, st_skipped_disk, st_write_errors, st_fetch_miss, st_cache_entries, st_cache_bytes, st_ro_entries, st_ro_bytes;

static uint64_t env_mb(const char *name, uint64_t fallback_mb) {
    const char *e = getenv(name);
    if (!e || !*e) return fallback_mb << 20;
    return (uint64_t)strtoull(e, NULL, 10) << 20;
}
static void bg_free_config(void) {
    free(g_bg.cache); free(g_bg.readonly); g_bg.cache = g_bg.readonly = NULL;
}
static void bg_set_config_locked(const nvn_astc_bg_config *c) {
    bg_free_config();
    g_bg.cache = c->cache && *c->cache ? strdup(c->cache) : NULL;
    g_bg.readonly = c->readonly && *c->readonly ? strdup(c->readonly) : NULL;
    g_bg.queue_cap = c->queue_cap; g_bg.cache_max = c->cache_max; g_bg.min_free = c->min_free;
    g_bg.threads = c->threads < 1 ? 1 : c->threads > BG_MAX_THREADS ? BG_MAX_THREADS : c->threads;
    g_bg.configured = 1;
    if (!g_bg.pending) g_bg.pending = [NSMutableSet set];
}
static void bg_env_config_locked(void) {
    if (g_bg.configured) return;
    nvn_astc_bg_config c = {
        .cache = getenv("DM_NVN_ASTC_CACHE"), .readonly = getenv("DM_NVN_ASTC_CACHE_RO"),
#if TARGET_OS_IPHONE
        .queue_cap = (size_t)env_mb("DM_NVN_ASTC_QUEUE_MB", 64),
#else
        .queue_cap = (size_t)env_mb("DM_NVN_ASTC_QUEUE_MB", 256),
#endif
        .cache_max = env_mb("DM_NVN_ASTC_CACHE_MAX", 2048), .min_free = env_mb("DM_NVN_ASTC_MIN_FREE_MB", 1024),
        .threads = getenv("DM_NVN_ASTC_THREADS") ? (unsigned)atoi(getenv("DM_NVN_ASTC_THREADS")) : 2,
    };
    bg_set_config_locked(&c);
}

// Entries and bytes of one cache directory; stale temporary files of a crashed write (older than an hour,
// named like one) are removed, and nothing else is ever deleted.
static void bg_scan(const char *dir, uint64_t *entries, uint64_t *bytes, int clean) {
    *entries = *bytes = 0;
    DIR *d = dir ? opendir(dir) : NULL;
    if (!d) return;
    struct dirent *e;
    while ((e = readdir(d))) {
        size_t n = strlen(e->d_name);
        if (n < 69 || strncmp(e->d_name + 64, ".astc", 5)) continue;
        char path[PATH_MAX];
        if (snprintf(path, sizeof path, "%s/%s", dir, e->d_name) >= (int)sizeof path) continue;
        struct stat st;
        if (lstat(path, &st) || !S_ISREG(st.st_mode)) continue;
        if (n == 69) { (*entries)++; *bytes += (uint64_t)st.st_size; }
        else if (clean && n == 76 && e->d_name[69] == '.' && time(NULL) - st.st_mtime > 3600) unlink(path);
    }
    closedir(d);
}
static uint64_t bg_free_bytes(const char *dir) {
    struct statfs fs;
    return dir && !statfs(dir, &fs) ? (uint64_t)fs.f_bavail * fs.f_bsize : UINT64_MAX;
}
// Whether `size` more bytes may be written to `root`: only the configured writable cache is limited
static int bg_write_allowed(const char *root, size_t size) {
    if (!root || !g_bg.cache || strcmp(root, g_bg.cache)) return 1;
    if (atomic_load(&st_cache_bytes) + size + 40 > g_bg.cache_max) { atomic_fetch_add(&st_skipped_cap, 1); return 0; }
    if (g_bg.min_free && bg_free_bytes(root) < g_bg.min_free + size + 40) { atomic_fetch_add(&st_skipped_disk, 1); return 0; }
    return 1;
}

// cache_write, and the size accounting of the configured writable directory
static int cache_write_counted(const char *root, NSString *path, const void *output, size_t size) {
    int error = cache_write(path, output, size);
    if (!error && g_bg.cache && root && !strcmp(root, g_bg.cache)) { atomic_fetch_add(&st_cache_entries, 1); atomic_fetch_add(&st_cache_bytes, size + 40); }
    return error;
}
static void *bg_worker(void *arg) {
    unsigned slot = 1 + (unsigned)(uintptr_t)arg;
    pthread_setname_np("dm-astc-encode");
    pthread_set_qos_class_self_np(QOS_CLASS_UTILITY, 0);
    for (;;) {
        pthread_mutex_lock(&g_bg.mu);
        while (!g_bg.head && !g_bg.stop) pthread_cond_wait(&g_bg.work, &g_bg.mu);
        if (g_bg.stop) { pthread_mutex_unlock(&g_bg.mu); return NULL; }
        bg_job *job = g_bg.head;
        g_bg.head = job->next; if (!g_bg.head) g_bg.tail = NULL;
        g_bg.active++;
        pthread_mutex_unlock(&g_bg.mu);
        @autoreleasepool {
            nvn_bc_format_info info; nvn_bc_format(job->format, &info);
            size_t out_size = ((size_t)job->width + job->block - 1) / job->block * 16 * (((size_t)job->height + job->block - 1) / job->block);
            uint8_t *out = malloc(out_size);
            uint64_t t0 = clock_gettime_nsec_np(CLOCK_MONOTONIC);
            if (out && !encode_plane(slot, job->format, job->data, job->width, job->height, job->block, &info, out)) {
                atomic_fetch_add(&st_encode_ns, clock_gettime_nsec_np(CLOCK_MONOTONIC) - t0);
                atomic_fetch_add(&st_encoded, 1); atomic_fetch_add(&st_encoded_rgba, (uint64_t)job->width * job->height * 4);
                const char *root = g_bg.cache;
                if (root && bg_write_allowed(root, out_size)) {
                    if (cache_write_counted(root, cache_path(root, job->key), out, out_size)) atomic_fetch_add(&st_write_errors, 1);
                    else atomic_fetch_add(&st_written, 1);
                }
            } else atomic_fetch_add(&st_write_errors, 1);
            free(out);
        }
        pthread_mutex_lock(&g_bg.mu);
        g_bg.queued_bytes -= job->size;
        [g_bg.pending removeObject:@(job->key)];
        g_bg.active--;
        if (!g_bg.head && !g_bg.active) pthread_cond_broadcast(&g_bg.idle);
        pthread_mutex_unlock(&g_bg.mu);
        free(job);
    }
}
static _Atomic int g_scan_done;
static void *bg_scan_main(void *unused) {
    (void)unused;
    pthread_set_qos_class_self_np(QOS_CLASS_UTILITY, 0);
    uint64_t t0 = clock_gettime_nsec_np(CLOCK_MONOTONIC), ce, cb, re, rb;
    char *cache = NULL, *ro = NULL;
    pthread_mutex_lock(&g_bg.mu); cache = g_bg.cache ? strdup(g_bg.cache) : NULL; ro = g_bg.readonly ? strdup(g_bg.readonly) : NULL; pthread_mutex_unlock(&g_bg.mu);
    bg_scan(cache, &ce, &cb, 1);
    if (!ro_pack_stats(ro, &re, &rb)) bg_scan(ro, &re, &rb, 0);
    atomic_store(&st_cache_entries, ce); atomic_store(&st_cache_bytes, cb); atomic_store(&st_ro_entries, re); atomic_store(&st_ro_bytes, rb);
    fprintf(stderr, "[dm] ASTC cache: writable %s: %llu entries, %.1f MB (cap %.0f MB, %.0f MB free on the disk, writes stop under %.0f MB); read-only %s: %llu entries, %.1f MB; "
            "misses encode in the background (%u threads, queue cap %.0f MB); scan %.1f ms\n",
            cache ?: "none", (unsigned long long)ce, cb / 1048576.0, g_bg.cache_max / 1048576.0, cache && bg_free_bytes(cache) != UINT64_MAX ? bg_free_bytes(cache) / 1048576.0 : -1.0, g_bg.min_free / 1048576.0,
            ro ?: "none", (unsigned long long)re, rb / 1048576.0, g_bg.threads, g_bg.queue_cap / 1048576.0, (clock_gettime_nsec_np(CLOCK_MONOTONIC) - t0) / 1e6);
    free(cache); free(ro);
    atomic_store(&g_scan_done, 1);
    return NULL;
}
// Start the worker threads (idempotent). Accounting of the writable directory is scanned first, on its own thread
static void bg_start_locked(void) {
    bg_env_config_locked();
    if (g_bg.running) return;
    g_bg.stop = 0; atomic_store(&g_scan_done, 0);
    if (g_bg.cache) [[NSFileManager defaultManager] createDirectoryAtPath:@(g_bg.cache) withIntermediateDirectories:YES attributes:nil error:NULL];
    pthread_t scanner; pthread_attr_t attr; pthread_attr_init(&attr); pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    pthread_create(&scanner, &attr, bg_scan_main, NULL);
    for (unsigned i = 0; i < g_bg.threads; i++)
        if (!pthread_create(&g_bg.thread[g_bg.running], NULL, bg_worker, (void *)(uintptr_t)i)) g_bg.running++;
}
void nvn_bc_astc_bg_start(void) {
    pthread_mutex_lock(&g_bg.mu); bg_start_locked(); pthread_mutex_unlock(&g_bg.mu);
}
void nvn_bc_astc_bg_configure(const nvn_astc_bg_config *config) {
    nvn_bc_astc_bg_wait(600);
    pthread_mutex_lock(&g_bg.mu);
    g_bg.stop = 1; pthread_cond_broadcast(&g_bg.work);
    unsigned n = g_bg.running; pthread_t threads[BG_MAX_THREADS]; memcpy(threads, g_bg.thread, sizeof threads);
    pthread_mutex_unlock(&g_bg.mu);
    for (unsigned i = 0; i < n; i++) pthread_join(threads[i], NULL);
    pthread_mutex_lock(&g_bg.mu);
    g_bg.running = 0; g_bg.stop = 0;
    bg_set_config_locked(config);
    [g_bg.pending removeAllObjects];
    atomic_store(&st_hit, 0); atomic_store(&st_miss, 0); atomic_store(&st_queued, 0); atomic_store(&st_dropped, 0); atomic_store(&st_dropped_bytes, 0);
    atomic_store(&st_dups, 0); atomic_store(&st_encoded, 0); atomic_store(&st_encode_ns, 0); atomic_store(&st_encoded_rgba, 0); atomic_store(&st_written, 0);
    atomic_store(&st_skipped_cap, 0); atomic_store(&st_skipped_disk, 0); atomic_store(&st_write_errors, 0); atomic_store(&st_fetch_miss, 0);
    bg_start_locked();
    pthread_mutex_unlock(&g_bg.mu);
    for (int i = 0; i < 5000 && !atomic_load(&g_scan_done); i++) usleep(1000);   // the scan is a detached thread: the accounting is current when the caller goes on
}
int nvn_bc_astc_bg_wait(double seconds) {
    struct timespec until; clock_gettime(CLOCK_REALTIME, &until);
    until.tv_sec += (time_t)seconds; until.tv_nsec += (long)((seconds - (time_t)seconds) * 1e9); if (until.tv_nsec >= 1000000000) { until.tv_sec++; until.tv_nsec -= 1000000000; }
    pthread_mutex_lock(&g_bg.mu);
    int ok = 1;
    while (g_bg.running && (g_bg.head || g_bg.active)) if (pthread_cond_timedwait(&g_bg.idle, &g_bg.mu, &until)) { ok = 0; break; }
    pthread_mutex_unlock(&g_bg.mu);
    return ok;
}
void nvn_bc_astc_bg_stats(nvn_astc_bg_stats *s) {
    memset(s, 0, sizeof *s);
    s->hits = atomic_load(&st_hit); s->misses = atomic_load(&st_miss); s->queued = atomic_load(&st_queued); s->dropped = atomic_load(&st_dropped);
    s->dropped_bytes = atomic_load(&st_dropped_bytes); s->duplicates = atomic_load(&st_dups); s->encoded = atomic_load(&st_encoded);
    s->encode_ns = atomic_load(&st_encode_ns); s->encoded_rgba_bytes = atomic_load(&st_encoded_rgba); s->written = atomic_load(&st_written);
    s->skipped_cap = atomic_load(&st_skipped_cap); s->skipped_lowdisk = atomic_load(&st_skipped_disk); s->write_errors = atomic_load(&st_write_errors);
    s->fetch_misses = atomic_load(&st_fetch_miss); s->cache_entries = atomic_load(&st_cache_entries); s->cache_bytes = atomic_load(&st_cache_bytes);
    pthread_mutex_lock(&g_bg.mu); s->queued_bytes_now = g_bg.queued_bytes; pthread_mutex_unlock(&g_bg.mu);
}
int nvn_bc_astc_bg_format_stats(char *buf, size_t size) {
    nvn_astc_bg_stats s; nvn_bc_astc_bg_stats(&s);
    double mb = s.encoded_rgba_bytes / 1048576.0;
    return snprintf(buf, size, "ASTC planes: %llu cache hits, %llu misses (%llu queued, %llu dropped for a full queue [%.1f MB], %llu already pending), %llu encoded in the background (%.0f ms per MB of RGBA8), "
        "%llu written, %llu not written for the size cap, %llu for low disk, %llu write errors; %.1f MB queued now; cache %llu entries %.1f MB; %llu corrupt-or-missing planes of ASTC textures",
        (unsigned long long)s.hits, (unsigned long long)s.misses, (unsigned long long)s.queued, (unsigned long long)s.dropped, s.dropped_bytes / 1048576.0, (unsigned long long)s.duplicates,
        (unsigned long long)s.encoded, mb > 0 ? s.encode_ns / 1e6 / mb : 0.0, (unsigned long long)s.written, (unsigned long long)s.skipped_cap, (unsigned long long)s.skipped_lowdisk,
        (unsigned long long)s.write_errors, s.queued_bytes_now / 1048576.0, (unsigned long long)s.cache_entries, s.cache_bytes / 1048576.0, (unsigned long long)s.fetch_misses);
}

static int plane_valid(uint32_t format, const void *source, size_t source_size, uint32_t width, uint32_t height, unsigned block, size_t *astc_size) {
    if (!source || !width || !height || width > 16384 || height > 16384 || !nvn_bc_astc_format(format, block, NULL)) return 0;
    nvn_bc_format_info info; nvn_bc_format(format, &info);
    if (source_size != ((size_t)width + 3) / 4 * info.block_bytes * (((size_t)height + 3) / 4)) return 0;
    *astc_size = ((size_t)width + block - 1) / block * 16 * (((size_t)height + block - 1) / block);
    return 1;
}
// Hand a missed plane to the workers: a copy of the BC bytes, unless it is already pending, there is no writable cache, or the queue is full
static void bg_enqueue(uint32_t format, const void *source, size_t size, uint32_t width, uint32_t height, unsigned block, const char *key) {
    pthread_mutex_lock(&g_bg.mu);
    bg_start_locked();
    NSString *k = @(key);
    if (!g_bg.cache) { pthread_mutex_unlock(&g_bg.mu); return; }
    if ([g_bg.pending containsObject:k]) { atomic_fetch_add(&st_dups, 1); pthread_mutex_unlock(&g_bg.mu); return; }
    if (g_bg.queued_bytes + size > g_bg.queue_cap) {
        atomic_fetch_add(&st_dropped, 1); atomic_fetch_add(&st_dropped_bytes, size);
        pthread_mutex_unlock(&g_bg.mu); return;
    }
    g_bg.queued_bytes += size; [g_bg.pending addObject:k];
    pthread_mutex_unlock(&g_bg.mu);
    bg_job *job = malloc(sizeof *job + size);   // the copy is made off the lock: the bytes belong to the caller (guest memory) and are not kept
    if (!job) {
        pthread_mutex_lock(&g_bg.mu); g_bg.queued_bytes -= size; [g_bg.pending removeObject:k]; pthread_mutex_unlock(&g_bg.mu);
        return;
    }
    job->next = NULL; memcpy(job->key, key, 65); job->format = format; job->width = width; job->height = height; job->block = block; job->size = size;
    memcpy(job->data, source, size);
    pthread_mutex_lock(&g_bg.mu);
    if (g_bg.tail) g_bg.tail->next = job; else g_bg.head = job;
    g_bg.tail = job;
    atomic_fetch_add(&st_queued, 1);
    pthread_cond_signal(&g_bg.work);
    pthread_mutex_unlock(&g_bg.mu);
}
static int cache_has(const char *root, const char *key, size_t payload) {
    if (!root || !*root) return 0;
    const nvn_pack *pk = pack_for(root);
    if (pk) { uint64_t off, sz; return pack_find(pk, key, &off, &sz) && sz == payload + 40; }
    @autoreleasepool {
        NSString *path = cache_path(root, key);
        if (atomic_load_explicit(&g_cache_small_ready, memory_order_acquire)) {
            NSData *data = g_cache_small[path]; if (data && data.length == payload) return 1;
            data = g_cache_mapped[path]; if (data && data.length == payload) return 1;
        }
        struct stat st;
        return !stat(path.fileSystemRepresentation, &st) && S_ISREG(st.st_mode) && (uint64_t)st.st_size == payload + 40;
    }
}
int nvn_bc_astc_learn(uint32_t format, const void *source, size_t source_size, uint32_t width, uint32_t height, unsigned block, nvn_astc_cache_key *saved_key) {
    size_t astc_size;
    if (!plane_valid(format, source, source_size, width, height, block, &astc_size)) return -1;
    char key[65]; cache_key(format, width, height, block, source, source_size, key);
    if (saved_key) memcpy(saved_key->hex, key, sizeof key);
    pthread_mutex_lock(&g_bg.mu); bg_env_config_locked(); const char *ro = g_bg.readonly, *rw = g_bg.cache; pthread_mutex_unlock(&g_bg.mu);
    if (cache_has(ro, key, astc_size) || cache_has(rw, key, astc_size)) { atomic_fetch_add(&st_hit, 1); return 1; }
    atomic_fetch_add(&st_miss, 1);
    bg_enqueue(format, source, source_size, width, height, block, key);
    return 0;
}
static int fetch_impl(uint32_t format, const void *source, size_t source_size, uint32_t width, uint32_t height, unsigned block, void *output, size_t output_size, int queue) {
    size_t astc_size;
    if (!plane_valid(format, source, source_size, width, height, block, &astc_size) || output_size != astc_size) return -1;
    char key[65]; cache_key(format, width, height, block, source, source_size, key);
    pthread_mutex_lock(&g_bg.mu); bg_env_config_locked(); NSString *ro = g_bg.readonly ? @(g_bg.readonly) : nil, *rw = g_bg.cache ? @(g_bg.cache) : nil; pthread_mutex_unlock(&g_bg.mu);
    @autoreleasepool {
        if (ro_read_status(ro.UTF8String, key, output, output_size) == NVN_ASTC_CACHE_HIT || cache_read(cache_path(rw.UTF8String, key), output, output_size)) { atomic_fetch_add(&st_hit, 1); return 1; }
    }
    atomic_fetch_add(&st_fetch_miss, 1);
    if (queue) bg_enqueue(format, source, source_size, width, height, block, key);
    return 0;
}
int nvn_bc_astc_fetch(uint32_t format, const void *source, size_t source_size, uint32_t width, uint32_t height, unsigned block, void *output, size_t output_size) {
    return fetch_impl(format, source, source_size, width, height, block, output, output_size, 1);
}
int nvn_bc_astc_fetch_noqueue(uint32_t format, const void *source, size_t source_size, uint32_t width, uint32_t height, unsigned block, void *output, size_t output_size) {
    return fetch_impl(format, source, source_size, width, height, block, output, output_size, 0);
}
int nvn_bc_astc_has_plane(uint32_t format, const void *source, size_t source_size, uint32_t width, uint32_t height, unsigned block) {
    size_t astc_size;
    if (!plane_valid(format, source, source_size, width, height, block, &astc_size)) return -1;
    char key[65]; cache_key(format, width, height, block, source, source_size, key);
    pthread_mutex_lock(&g_bg.mu); bg_env_config_locked(); const char *ro = g_bg.readonly, *rw = g_bg.cache; pthread_mutex_unlock(&g_bg.mu);
    return cache_has(ro, key, astc_size) || cache_has(rw, key, astc_size);
}
int nvn_bc_astc_readonly_ready(void) {
    pthread_mutex_lock(&g_bg.mu); bg_env_config_locked(); NSString *ro = g_bg.readonly ? @(g_bg.readonly) : nil; pthread_mutex_unlock(&g_bg.mu);
    if (!ro) return 0;
    if (pack_for(ro.UTF8String)) return 1;
    BOOL isdir = NO;
    return [NSFileManager.defaultManager fileExistsAtPath:ro isDirectory:&isdir] && isdir;
}
nvn_astc_tag_result nvn_bc_astc_tag_fetch(const void *plane, size_t length, size_t astc_size, void *output) {
    if (!nvn_bc_astc_looks_tagged(plane, length)) return NVN_TAG_NONE;
    pthread_mutex_lock(&g_bg.mu); bg_env_config_locked(); NSString *ro = g_bg.readonly ? @(g_bg.readonly) : nil; pthread_mutex_unlock(&g_bg.mu);
    return tag_fetch_pack(pack_for(ro.UTF8String), plane, astc_size, output);
}
