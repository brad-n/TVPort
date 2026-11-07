#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif
// BC1/2/3/7 can use LDR ASTC. BC4/5 and HDR BC6 retain their decoded formats.
int nvn_bc_astc_format(uint32_t format, unsigned block, uint32_t *pixel_format);
// Prepare verified immutable snapshots before gameplay. The first budget bounds
// heap payload bytes; the second bounds a private file snapshot whose read-only
// mapped pages remain reclaimable. Entries that do not fit keep the disk path.
// Snapshot reads use one retained descriptor and bounded pread calls unless
// DM_NVN_ASTC_SNAPSHOT_PREAD=0; failures fall back to the immutable mapping.
void nvn_bc_astc_cache_prepare(const char *readonly_cache, const char *cache,
                                size_t budget, size_t mapped_budget);
void nvn_bc_astc_cache_stats(uint64_t *memory_hits, uint64_t *disk_hits, uint64_t *mapped_hits);
typedef struct { char hex[65]; } nvn_astc_cache_key;
typedef enum {
    NVN_ASTC_CACHE_UNCHECKED, NVN_ASTC_CACHE_DISABLED, NVN_ASTC_CACHE_HIT,
    NVN_ASTC_CACHE_MISSING, NVN_ASTC_CACHE_HEADER, NVN_ASTC_CACHE_SIZE,
    NVN_ASTC_CACHE_HASH, NVN_ASTC_CACHE_IO
} nvn_astc_cache_status;
typedef struct {
    nvn_astc_cache_key key;
    nvn_astc_cache_status readonly_status, writable_status;
    int write_attempted, write_error;
} nvn_astc_cache_report;
const char *nvn_bc_astc_cache_status_name(nvn_astc_cache_status status);
// A read-only cache (DM_NVN_ASTC_CACHE_RO, `readonly_cache` below) is a directory of <key>.astc files or ONE pack file (astc-ro.pack, see nvn_astc_cache.m). 1 when `path` is a pack that
// holds together (header, size and index): its entry count, size and the input fingerprint the writer recorded; 0 for a directory, a missing path or a corrupt or short pack (ignored)
// 1 when a read-only cache is configured and usable (a valid pack, or a directory), so a plane can be looked up before a texture is made
int nvn_bc_astc_readonly_ready(void);
// The content address of a plane (the name of its cache entry): SHA-256 over the version tag, format, size, block and the tightly packed BC bytes. For tools that key planes without encoding them
void nvn_bc_astc_plane_key(uint32_t format, uint32_t width, uint32_t height, unsigned block, const void *source, size_t source_size, nvn_astc_cache_key *key);
int nvn_bc_astc_pack_info(const char *path, uint64_t *entries, uint64_t *bytes, uint8_t fingerprint[32]);
// Restore a previously encoded plane without touching its BC source. The caller
// must first prove that the source and its layout have not changed. A miss or a
// corrupt entry returns zero and requires the normal source upload.
int nvn_bc_astc_cache_read(const nvn_astc_cache_key *key, void *output, size_t size,
                           const char *cache, const char *readonly_cache);
// Tightly packed BC input and ASTC output. Optional caches contain only encoded
// blocks; callers retain no decoded pixels after this call. Zero means success.
int nvn_bc_astc_encode(uint32_t format, const void *source, size_t source_size,
                       uint32_t width, uint32_t height, unsigned block,
                       void *output, size_t output_size, const char *cache,
                       const char *readonly_cache, int *cache_hit);
int nvn_bc_astc_encode_key(uint32_t format, const void *source, size_t source_size,
                           uint32_t width, uint32_t height, unsigned block,
                           void *output, size_t output_size, const char *cache,
                           const char *readonly_cache, int *cache_hit,
                           nvn_astc_cache_key *saved_key);
// Per-call diagnostics never retain guest memory and do not change cache keys.
int nvn_bc_astc_encode_report(uint32_t format, const void *source, size_t source_size,
                              uint32_t width, uint32_t height, unsigned block,
                              void *output, size_t output_size, const char *cache,
                              const char *readonly_cache, int *cache_hit,
                              nvn_astc_cache_key *saved_key, nvn_astc_cache_report *report);
// ---- Background miss policy (DM_NVN_ASTC_MISS=background) ----
// A missed plane is never encoded on the caller's thread: nvn_bc_astc_learn copies its BC bytes into a bounded queue that low-priority workers
// encode into the writable cache, so a later run hits. Everything defaults from the environment (DM_NVN_ASTC_CACHE, DM_NVN_ASTC_CACHE_RO,
// DM_NVN_ASTC_QUEUE_MB, DM_NVN_ASTC_CACHE_MAX in MB, DM_NVN_ASTC_MIN_FREE_MB, DM_NVN_ASTC_THREADS) the first time anything needs it.
typedef struct { const char *cache, *readonly; size_t queue_cap; uint64_t cache_max, min_free; unsigned threads; } nvn_astc_bg_config;
typedef struct {
    uint64_t hits, misses, queued, dropped, dropped_bytes, duplicates, encoded, encode_ns, encoded_rgba_bytes, written, skipped_cap, skipped_lowdisk,
             write_errors, fetch_misses, cache_entries, cache_bytes, queued_bytes_now;
} nvn_astc_bg_stats;
void nvn_bc_astc_bg_start(void);                                 // starts the workers and logs the cache summary line (idempotent)
void nvn_bc_astc_bg_configure(const nvn_astc_bg_config *config); // replaces the configuration and resets the counters (tests)
int nvn_bc_astc_bg_wait(double seconds);                         // 1 once the queue is empty and the workers idle
void nvn_bc_astc_bg_stats(nvn_astc_bg_stats *stats);
int nvn_bc_astc_bg_format_stats(char *buffer, size_t size);      // one log line of counters
// 1: the plane is in a cache (header size only, no payload read). 0: a miss, queued for the workers (or dropped, or already pending). -1: invalid plane.
int nvn_bc_astc_learn(uint32_t format, const void *source, size_t source_size, uint32_t width, uint32_t height, unsigned block, nvn_astc_cache_key *saved_key);
// 1: the plane's ASTC blocks were read (verified) into output. 0: not there, queued as above; output untouched. -1: invalid.
int nvn_bc_astc_fetch(uint32_t format, const void *source, size_t source_size, uint32_t width, uint32_t height, unsigned block, void *output, size_t output_size);
#ifdef __cplusplus
}
#endif
