// tex_once_verify (2/2): every tagged plane of a stripped image resolves through the engine's runtime lookup (docs/texture_once.md sections 2 and 3).
//   tex_once_verify_tags <stripped romfs.img> <manifest from tex_once.py --manifest> [<report.json's planes tagged>]
// Opens the pack the image embeds the way the engine does (romfs_src_open for its place, nvn_bc_astc_use_embedded_pack(fd, offset, size)), then for each manifest record builds the plane the strip leaves
// (the 8-byte tag, zeros after it, its stored length) and calls nvn_bc_astc_tag_fetch_root on NVN_ASTC_EMBEDDED_ROOT with the plane's expected ASTC size, which reads the entry and checks its hash.
// A plane that does not resolve is classified from the pack's index (it is included as source, like t_astc_cache.m, to reach it): tag absent = missing; present but no entry of that payload size =
// wrong-size; several entries of that size = ambiguous. A resolved plane must also be the entry its full key names. A control (the same tag with a wrong size) must NOT resolve.
#include <unistd.h>
#include <errno.h>
#include <time.h>
#include "../../host/romfs_sparse.h"
#include "../tex/nvn_astc_cache.m"

static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (double)t.tv_sec + (double)t.tv_nsec * 1e-9; }
static int unhex(const char *s, uint8_t *out, int n) {
    for (int i = 0; i < n; i++) { unsigned v; if (sscanf(s + 2 * i, "%2x", &v) != 1) return 0; out[i] = (uint8_t)v; }
    return 1;
}

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: %s <stripped romfs.img> <manifest> [expected tagged planes]\n", argv[0]); return 2; }
    long long expected = argc > 3 ? atoll(argv[3]) : -1;
    int fd = open(argv[1], O_RDONLY); romfs_src s;
    if (fd < 0 || !romfs_src_open(fd, &s) || !s.sparse || !s.pack_size) { printf("FAIL: %s is not a DMSPARS1 image with an embedded pack\n", argv[1]); return 1; }
    double t0 = now();
    if (!nvn_bc_astc_use_embedded_pack(open(argv[1], O_RDONLY), s.pack_off, s.pack_size)) { printf("FAIL: the embedded pack is not usable\n"); return 1; }
    const nvn_pack *pk = pack_for(NVN_ASTC_EMBEDDED_ROOT);
    if (!pk) { printf("FAIL: no pack under the embedded root\n"); return 1; }
    printf("embedded pack: %" PRIu64 " bytes at %" PRIu64 ", %" PRIu64 " entries (%.2f s)\n", s.pack_size, s.pack_off, pk->count, now() - t0);
    FILE *f = fopen(argv[2], "r"); if (!f) { perror(argv[2]); return 1; }
    char line[4096]; size_t cap = 1 << 20; uint8_t *plane = calloc(1, cap), *out = malloc(cap); size_t plane_cap = cap;
    unsigned long long total = 0, unique = 0, ambiguous = 0, missing = 0, wrong_size = 0, not_tagged = 0, key_mismatch = 0, read_fail = 0, control_bad = 0, malformed = 0;
    unsigned long long printed = 0, tag_in_key_bad = 0;
    t0 = now();
    while (fgets(line, sizeof line, f)) {
        char tag[17], key[65]; unsigned nvn, w, h, level, layer, blk; unsigned long long astc, len;
        if (sscanf(line, "%16s %u %u %u %u %u %llu %llu %u %64s", tag, &nvn, &w, &h, &level, &layer, &astc, &len, &blk, key) != 10) { malformed++; continue; }
        uint8_t t8[8], k32[32];
        if (!unhex(tag, t8, 8) || !unhex(key, k32, 32) || len < 16 || !astc) { malformed++; continue; }
        total++;
        if (memcmp(t8, k32, 8)) tag_in_key_bad++;
        if (len > plane_cap) { plane_cap = (size_t)len; plane = realloc(plane, plane_cap); }
        if (astc > cap) { cap = (size_t)astc; out = realloc(out, cap); }
        memset(plane, 0, (size_t)len); memcpy(plane, t8, 8);
        nvn_astc_tag_result r = nvn_bc_astc_tag_fetch_root(NVN_ASTC_EMBEDDED_ROOT, plane, (size_t)len, (size_t)astc, out);
        // control: a size no entry of this tag has must not resolve
        if (nvn_bc_astc_tag_fetch_root(NVN_ASTC_EMBEDDED_ROOT, plane, (size_t)len, (size_t)astc + 16, NULL) == NVN_TAG_HIT) {
            // legitimate only if another entry with this tag has exactly that size; count it as a control failure only when no entry does
            uint64_t o, z; if (!pack_tag_find(pk, t8, (size_t)astc + 16, &o, &z)) control_bad++;
        }
        if (r == NVN_TAG_NONE) { not_tagged++; continue; }
        if (r == NVN_TAG_HIT) {
            uint64_t o1, z1, o2, z2;
            if (!pack_tag_find(pk, t8, (size_t)astc, &o1, &z1) || !pack_find(pk, key, &o2, &z2) || o1 != o2 || z1 != z2) key_mismatch++;
            else unique++;
            continue;
        }
        // MISS: say why
        uint64_t lo = 0, hi = pk->count, same_prefix = 0, same_size = 0;
        while (lo < hi) { uint64_t mid = lo + (hi - lo) / 2; if (memcmp(pk->index + mid * PACK_ENT, t8, 8) < 0) lo = mid + 1; else hi = mid; }
        for (uint64_t i = lo; i < pk->count && !memcmp(pk->index + i * PACK_ENT, t8, 8); i++) { same_prefix++; if (le64(pk->index + i * PACK_ENT + 40) == astc + 40) same_size++; }
        const char *why;
        if (!same_prefix) { missing++; why = "missing"; }
        else if (!same_size) { wrong_size++; why = "wrong-size"; }
        else if (same_size > 1) { ambiguous++; why = "ambiguous"; }
        else { read_fail++; why = "unique entry but unreadable/hash mismatch"; }
        if (printed++ < 10) printf("  unresolved %s: tag %s nvn 0x%x %ux%u level %u layer %u astc %llu\n", why, tag, nvn, w, h, level, layer, astc);
    }
    double sec = now() - t0;
    unsigned long long hits, unres, dec; nvn_bc_astc_tag_stats(&hits, &unres, &dec);
    printf("records=%llu resolved-unique=%llu ambiguous=%llu missing=%llu wrong-size=%llu unreadable=%llu not-looking-tagged=%llu entry!=key=%llu tag!=key-prefix=%llu control-resolved=%llu malformed=%llu (%.1f s, engine tag hits %llu)\n",
           total, unique, ambiguous, missing, wrong_size, read_fail, not_tagged, key_mismatch, tag_in_key_bad, control_bad, malformed, sec, hits);
    int ok = total && unique == total && !malformed && !control_bad && !tag_in_key_bad;
    if (expected >= 0) { printf("manifest records %llu vs report.json planes tagged %lld: %s\n", total, expected, (long long)total == expected ? "equal" : "DIFFERENT"); ok = ok && (long long)total == expected; }
    printf(ok ? "tags: PASS\n" : "tags: FAIL\n");
    return ok ? 0 : 1;
}
