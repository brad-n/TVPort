#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif
// BC1/2/3/7 and unsigned BC4 (0x49) / BC5 (0x4b) use LDR ASTC, unsigned BC6H (0x50) HDR ASTC (the caller decides whether the GPU has it). The signed formats keep their decoded path: 0 for them.
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
// The read-only cache root that names the pack a RomFS image embeds (DMSPARS1): register it first with nvn_bc_astc_use_embedded_pack
#define NVN_ASTC_EMBEDDED_ROOT "dm:romfs-embedded-pack"
// fd holds an NXASTCPK pack at [offset, offset + size) (offsets inside it relative to offset). fd stays open for the life of the process (closed here when the pack is not usable). 1 when the pack holds together
int nvn_bc_astc_use_embedded_pack(int fd, uint64_t offset, uint64_t size);
// ---- Tagged planes (docs/texture_once.md section 2): a stripped plane is the first 8 bytes of its pack key, then zeros ----
typedef enum { NVN_TAG_NONE = 0 /* does not look tagged */, NVN_TAG_HIT /* exactly one entry of the expected size */, NVN_TAG_MISS /* looks tagged, no usable entry */ } nvn_astc_tag_result;
enum { NVN_TAG_NOTE_UNRESOLVED = 1, NVN_TAG_NOTE_DECODED = 2 };
// length >= 16, bytes [0,8) not all zero, bytes [8,length) all zero
int nvn_bc_astc_looks_tagged(const void *plane, size_t length);
// The same for a plane in rows of row_bytes bytes, stride apart (a copy source)
int nvn_bc_astc_looks_tagged_rows(const void *plane, size_t row_bytes, size_t stride, size_t rows);
// Look a tagged plane up in the read-only pack (by the 8-byte prefix) and, when output is not NULL, read its verified ASTC blocks (astc_size bytes) into it. NVN_TAG_HIT counts a tagged hit only when output is given
nvn_astc_tag_result nvn_bc_astc_tag_fetch(const void *plane, size_t length, size_t astc_size, void *output);
nvn_astc_tag_result nvn_bc_astc_tag_fetch_root(const char *readonly_cache, const void *plane, size_t length, size_t astc_size, void *output);
// Counts a tagged plane that no path resolved (it would draw from zeros) or that was decoded as BC bytes
void nvn_bc_astc_tag_note(int kind);
void nvn_bc_astc_tag_stats(uint64_t *hits, uint64_t *unresolved, uint64_t *decoded);
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
// nvn_bc_astc_fetch without queueing a miss (a plane whose bytes are a tag and zeros has nothing to encode), and a lookup that reads nothing and queues nothing: 1 in a cache, 0 not, -1 invalid
int nvn_bc_astc_fetch_noqueue(uint32_t format, const void *source, size_t source_size, uint32_t width, uint32_t height, unsigned block, void *output, size_t output_size);
int nvn_bc_astc_has_plane(uint32_t format, const void *source, size_t source_size, uint32_t width, uint32_t height, unsigned block);
#ifdef __cplusplus
}
#endif
