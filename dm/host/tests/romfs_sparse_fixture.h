// Test-only writer of DMSPARS1 files (dm/host/romfs_sparse.h documents the layout; docs/texture_once.md section 1 is the contract). Written from the contract, not from the reader.
#pragma once
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void fx_put64(uint8_t *p, uint64_t v) { for (int i = 0; i < 8; i++) p[i] = (uint8_t)(v >> (8 * i)); }
static void fx_put32(uint8_t *p, uint32_t v) { for (int i = 0; i < 4; i++) p[i] = (uint8_t)(v >> (8 * i)); }
// A minimal NXASTCPK pack with `count` entries, each `payload` bytes of `fill` behind a 40-byte entry header (the keys are given, ascending); the whole pack in *out (malloc), its size returned
static size_t fx_pack(uint8_t **out, unsigned count, const uint8_t (*keys)[32], size_t payload, uint8_t fill) {
    size_t entries = 80, ent = 40 + payload, ioff = entries + (size_t)count * ((ent + 15) & ~(size_t)15), total = ioff + (size_t)count * 48;
    uint8_t *p = calloc(1, total);
    memcpy(p, "NXASTCPK", 8); fx_put32(p + 8, 1); fx_put32(p + 12, 48); fx_put64(p + 16, count); fx_put64(p + 24, ioff); fx_put64(p + 32, total);
    for (unsigned i = 0; i < count; i++) {
        size_t off = entries + (size_t)i * ((ent + 15) & ~(size_t)15);
        memcpy(p + off, "NXASTC01", 8); memset(p + off + 40, fill, payload);   // the SHA-256 field (8..40) is the caller's business when it matters
        memcpy(p + ioff + (size_t)i * 48, keys[i], 32); fx_put64(p + ioff + (size_t)i * 48 + 32, off); fx_put64(p + ioff + (size_t)i * 48 + 40, ent);
    }
    *out = p; return total;
}
// Writes `logical` (n bytes) as DMSPARS1: zero runs of at least min_hole bytes become holes; no extent is longer than split (0 = unlimited); the pack (pack_n bytes, may be NULL) is embedded at a
// 16384-byte boundary. Returns the extent count, -1 on a write error. The file is built in memory: *file / *file_n receive it when file is not NULL (malloc), else it goes to path
static long fx_write_sparse(const char *path, const uint8_t *logical, size_t n, size_t min_hole, size_t split, const uint8_t *pack, size_t pack_n, uint8_t **file, size_t *file_n) {
    typedef struct { uint64_t lo, len, phys; } ex;
    ex *ext = calloc(n / 2 + 2, sizeof *ext); size_t ne = 0, i = 0;
    while (i < n) {
        if (!logical[i]) { size_t j = i; while (j < n && !logical[j]) j++; if (j - i >= min_hole) { i = j; continue; } }   // a hole
        size_t s = i;
        while (i < n) {   // a data run: ends at the first hole worth the name
            if (!logical[i]) { size_t j = i; while (j < n && !logical[j]) j++; if (j - i >= min_hole) break; i = j; } else i++;
        }
        for (size_t at = s; at < i;) { size_t len = i - at; if (split && len > split) len = split; ext[ne++] = (ex){at, len, 0}; at += len; }
    }
    size_t phys = 64; uint8_t *buf = calloc(1, 64);
    for (size_t k = 0; k < ne; k++) {
        size_t old = phys; phys = (phys + 15) & ~(size_t)15; buf = realloc(buf, phys + ext[k].len + 16); memset(buf + old, 0, phys + (size_t)ext[k].len + 16 - old);
        ext[k].phys = phys; memcpy(buf + phys, logical + ext[k].lo, (size_t)ext[k].len); phys += (size_t)ext[k].len;
    }
    size_t poff = 0;
    if (pack) { poff = (phys + 16383) & ~(size_t)16383; buf = realloc(buf, poff + pack_n); memset(buf + phys, 0, poff - phys); memcpy(buf + poff, pack, pack_n); phys = poff + pack_n; }
    size_t toff = (phys + 15) & ~(size_t)15, total = toff + ne * 24 + 32;
    buf = realloc(buf, total); memset(buf + phys, 0, total - phys);
    for (size_t k = 0; k < ne; k++) { fx_put64(buf + toff + k * 24, ext[k].lo); fx_put64(buf + toff + k * 24 + 8, ext[k].len); fx_put64(buf + toff + k * 24 + 16, ext[k].phys); }
    memset(buf, 0, 64); memcpy(buf, "DMSPARS1", 8); fx_put32(buf + 8, 1); fx_put32(buf + 12, 64); fx_put64(buf + 16, n); fx_put64(buf + 24, ne); fx_put64(buf + 32, toff); fx_put64(buf + 40, poff); fx_put64(buf + 48, pack ? pack_n : 0);
    memcpy(buf + total - 32, "DMSPEND1", 8); fx_put64(buf + total - 24, total); fx_put64(buf + total - 16, toff);
    free(ext);
    if (file) { *file = buf; *file_n = total; return (long)ne; }
    FILE *f = fopen(path, "wb"); long r = f && fwrite(buf, 1, total, f) == total ? (long)ne : -1; if (f) fclose(f);
    free(buf); return r;
}
// A DMROMFS1 image (romfs_image.py's layout) of /data/f0 .. f<k-1> with the given contents: index last, ending the file. Returns the size; *out is malloc'd
static size_t fx_romfs(uint8_t **out, unsigned k, const uint8_t *const *data, const size_t *size) {
    size_t total = 32; for (unsigned i = 0; i < k; i++) total += (size[i] + 15) & ~(size_t)15;   // each file starts 16-byte aligned
    size_t nent = 2 + k, names = 4 + 2 * (size_t)k, isz = nent * 24 + names, all = total + isz;
    uint8_t *p = calloc(1, all); memcpy(p, "DMROMFS1", 8); fx_put64(p + 8, total); fx_put64(p + 16, isz); fx_put64(p + 24, nent);
    uint8_t *e = p + total; uint8_t *nm = e + nent * 24; memcpy(nm, "data", 4);
    // entry: u64 a, u64 b, u32 name, u16 nlen, u8 type, u8 flags
    #define FX_ENT(i, a, b, name, nlen, type) do { fx_put64(e + (i) * 24, (a)); fx_put64(e + (i) * 24 + 8, (b)); fx_put32(e + (i) * 24 + 16, (name)); e[(i) * 24 + 20] = (nlen) & 255; e[(i) * 24 + 21] = (nlen) >> 8; e[(i) * 24 + 22] = (type); } while (0)
    FX_ENT(0, 1, 1, 0, 0, 0); FX_ENT(1, 2, k, 0, 4, 0);
    size_t at = 32;
    for (unsigned i = 0; i < k; i++) {
        memcpy(p + at, data[i], size[i]);
        nm[4 + 2 * i] = 'f'; nm[5 + 2 * i] = (uint8_t)('0' + i);   // k <= 10
        FX_ENT(2 + i, at, size[i], 4 + 2 * i, 2, 1); at += (size[i] + 15) & ~(size_t)15;
    }
    *out = p; return all;
}
