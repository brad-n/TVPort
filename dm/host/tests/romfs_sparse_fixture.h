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

// ---- Version 2 (docs/texture_once.md section 7): zstd frames written by hand (the engine builds the decoder only), and the v2 writers ----
// A zstd frame is a header and blocks; a raw block and an RLE block are real zstd blocks any decoder inflates, so a frame of runs shrinks without a compressor. Frame header: magic, descriptor 0xA0 (single segment, 4-byte
// content size), the content size; each block header is 3 bytes {last | type << 1 | size << 3} (type 0 raw, 1 RLE).
static size_t fx_zframe_cap(size_t n) { return n + 16 + 3 * (n / 100000 + 2); }
static size_t fx_runlen(const uint8_t *s, size_t i, size_t n) { size_t r = 1; while (i + r < n && s[i + r] == s[i] && r < 100000) r++; return r; }
static size_t fx_zframe(uint8_t *out, const uint8_t *src, size_t n) {   // runs of 8 or more equal bytes become RLE blocks, the rest raw blocks (each at most 100000 bytes)
    size_t o = 0; out[o++] = 0x28; out[o++] = 0xB5; out[o++] = 0x2F; out[o++] = 0xFD; out[o++] = 0xA0; fx_put32(out + o, (uint32_t)n); o += 4;
    size_t i = 0;
    if (!n) { out[o++] = 1; out[o++] = 0; out[o++] = 0; return o; }   // an empty last raw block
    while (i < n) {
        size_t run = fx_runlen(src, i, n), blk = run; int rle = run >= 8;
        if (!rle) while (i + blk < n && blk < 100000 && fx_runlen(src, i + blk, n) < 8) blk += fx_runlen(src, i + blk, n);
        int last = i + blk >= n; uint32_t h = (uint32_t)(last ? 1 : 0) | (rle ? 1u << 1 : 0) | (uint32_t)(blk << 3);
        out[o++] = (uint8_t)h; out[o++] = (uint8_t)(h >> 8); out[o++] = (uint8_t)(h >> 16);
        if (rle) out[o++] = src[i]; else { memcpy(out + o, src + i, blk); o += blk; }
        i += blk;
    }
    return o;
}
// real zstd frame (level 3) of fx_real_plain(): 2873 bytes -> 20000
static const uint8_t fx_real_frame[2873] = {
40,181,47,253,96,32,77,125,89,0,250,150,188,35,54,32,74,50,31,143,199,203,1,136,
138,63,54,187,94,151,183,85,198,78,221,129,205,0,151,108,88,65,89,152,54,92,111,135,
140,140,247,202,245,65,231,135,129,44,183,13,74,233,242,222,138,144,145,209,130,41,2,47,
2,45,2,189,170,17,133,37,178,207,40,99,255,95,84,2,174,196,198,56,185,19,73,117,
170,58,154,196,177,215,26,61,109,36,123,187,123,133,88,58,33,103,2,138,10,113,40,15,
29,103,60,45,162,172,68,77,34,77,165,175,160,13,53,178,60,79,160,205,231,33,227,172,
141,14,83,31,194,83,62,5,24,131,147,133,228,234,43,237,144,155,195,51,47,193,83,54,
169,226,227,105,172,109,190,23,152,195,89,170,170,228,229,227,46,202,32,176,205,95,237,218,
187,203,107,44,40,129,211,16,158,108,117,233,145,170,70,81,218,68,87,230,255,189,74,81,
9,184,207,155,197,184,3,53,185,139,73,137,57,85,168,158,131,46,97,61,246,158,69,219,
106,111,129,123,133,244,207,129,94,112,168,207,251,102,75,221,173,66,77,218,136,190,141,22,
0,218,242,60,31,248,61,98,156,181,210,97,234,179,148,157,242,236,20,224,173,147,72,114,
117,241,209,74,58,228,48,204,34,102,94,130,39,153,228,15,230,207,215,231,239,133,225,44,
85,109,225,201,70,113,23,101,16,216,95,237,154,226,42,221,117,106,188,51,202,149,152,14,
134,3,78,254,96,101,246,28,144,118,44,8,210,39,100,126,223,203,20,197,149,124,222,11,
140,91,118,49,145,52,7,170,195,209,36,184,41,45,146,109,111,119,175,16,111,144,230,92,
32,8,30,250,251,134,102,90,68,89,133,104,245,54,58,124,188,149,120,108,126,140,17,218,
33,46,5,90,202,80,121,112,6,103,177,182,186,50,125,14,74,122,185,57,60,243,12,218,
78,216,31,204,68,99,109,243,213,50,133,179,84,149,23,27,197,217,101,16,88,231,143,102,
178,34,83,92,164,187,142,26,133,215,130,114,69,100,250,235,96,33,28,112,6,200,3,88,
93,122,36,42,111,100,159,145,46,203,252,190,87,9,247,185,191,89,140,91,98,34,98,78,
21,170,231,160,75,112,91,163,34,201,222,2,119,90,188,65,154,51,17,102,64,199,185,161,
161,22,81,86,77,162,190,222,78,0,42,225,86,114,173,78,163,207,231,50,137,52,18,133,
64,31,79,135,179,209,100,48,23,75,133,242,75,163,208,103,207,35,143,191,219,235,244,185,
60,14,127,187,99,176,215,234,52,250,230,108,46,147,199,226,48,248,235,237,114,183,218,25,
172,149,42,149,58,153,202,255,88,28,6,127,189,93,238,164,54,139,189,90,171,212,201,68,
18,129,60,1,74,96,76,36,137,135,183,32,127,173,46,61,25,137,101,159,145,46,119,175,
191,239,21,18,197,149,124,110,176,24,119,160,42,119,49,209,244,68,5,170,163,73,112,99,
82,90,32,79,27,201,142,59,189,33,247,2,69,133,16,80,244,247,182,184,11,53,35,168,
244,245,118,88,3,212,120,243,80,0,250,60,230,110,113,116,120,146,250,88,57,229,39,96,
131,89,106,36,87,95,105,71,3,102,17,51,65,8,39,108,82,5,102,194,175,109,180,76,
225,108,164,218,34,27,229,120,81,118,254,106,86,164,11,228,94,227,85,174,196,38,232,96,
161,11,224,228,15,214,165,3,146,145,199,18,205,72,159,232,98,255,87,72,244,136,115,125,
222,234,177,7,106,203,46,38,130,33,158,124,212,225,104,50,215,122,76,1,121,178,236,119,
220,105,113,87,138,204,129,94,132,168,15,14,205,150,90,68,89,133,154,68,90,170,29,230,
26,111,44,207,19,104,243,231,238,243,8,237,48,151,250,88,145,137,228,233,236,20,96,12,
78,22,146,171,143,86,210,33,111,155,9,152,129,6,177,73,21,152,9,79,99,125,192,55,
0,166,112,86,93,242,98,24,196,95,148,67,96,157,191,7,166,24,159,75,174,54,123,45,
40,131,49,127,106,178,254,96,93,246,100,164,170,145,101,239,94,127,223,171,20,69,150,220,
120,143,61,80,91,118,48,24,162,170,158,131,46,193,173,30,123,173,226,106,191,179,66,204,
65,138,124,129,80,25,208,111,12,216,82,69,77,218,136,190,6,2,26,160,30,39,208,230,
247,152,107,165,169,143,149,83,126,2,54,56,131,179,70,114,45,237,144,195,48,139,120,177,
157,176,73,152,143,159,175,109,190,204,89,74,201,147,141,48,136,191,8,129,117,254,104,38,
100,74,233,174,163,246,102,149,43,49,255,191,0,222,130,60,128,213,165,39,35,25,89,246,
120,250,68,87,230,247,50,69,143,37,31,27,111,245,216,195,14,38,130,9,213,115,208,100,
238,49,165,53,122,218,118,220,105,113,87,58,33,247,2,189,8,113,40,28,154,109,133,34,
202,42,212,140,64,75,233,219,97,13,80,227,173,229,121,214,124,30,115,247,121,132,86,122,
146,250,200,80,121,58,91,5,56,131,179,182,242,205,244,109,51,1,51,208,219,41,169,2,
91,219,124,47,204,80,45,60,89,252,69,25,140,173,153,144,41,119,29,53,10,175,5,229,
105,250,235,66,56,224,107,242,215,234,18,179,210,142,6,204,51,193,83,18,8,51,225,215,
7,124,3,16,206,82,75,30,0,249,56,187,12,254,213,76,200,20,215,61,2,181,217,171,
92,137,137,76,147,58,88,232,130,22,95,151,158,172,106,220,141,236,233,238,239,123,33,113,
247,247,2,94,106,114,7,19,157,212,225,104,110,204,49,165,5,242,180,237,237,238,180,152,
131,20,153,51,1,69,33,160,60,116,156,241,118,170,91,53,104,170,244,245,176,0,208,91,
139,2,208,239,49,63,143,208,74,135,184,148,16,149,167,32,5,56,131,147,69,117,213,33,
55,135,103,160,167,108,18,79,99,125,14,96,150,106,225,141,114,196,217,101,44,205,132,76,
113,129,220,117,106,188,22,148,49,127,58,65,247,10,225,201,95,151,158,140,202,99,53,40,
119,127,223,43,138,43,249,188,199,30,90,96,34,24,98,46,84,207,65,147,185,45,146,209,
182,183,43,32,238,74,115,46,144,16,135,250,220,140,183,84,148,85,131,38,145,54,162,111,
39,16,22,0,218,242,80,120,224,239,99,156,197,90,233,48,245,89,138,228,217,42,192,24,
156,44,53,146,171,139,175,164,67,222,54,139,152,121,6,109,167,44,16,102,194,207,15,248,
106,153,17,80,85,94,108,132,65,188,28,2,219,52,197,32,123,46,144,187,142,26,133,55,
171,140,137,76,127,157,73,8,15,95,147,7,96,58,32,85,48,242,88,162,120,218,68,247,
127,133,28,113,174,207,155,197,216,3,85,185,3,128,168,83,129,114,200,92,235,145,87,92,
237,221,226,13,210,63,7,18,162,50,160,227,220,208,84,64,89,53,24,210,70,244,53,18,
128,182,60,64,155,191,159,159,163,195,143,165,80,118,202,211,217,42,192,206,226,181,233,155,
149,244,242,182,57,252,204,38,85,66,240,243,245,249,203,156,85,91,114,196,93,128,104,254,
104,166,24,164,75,71,237,85,174,196,68,166,63,12,190,38,127,176,46,123,51,82,213,104,
143,167,79,116,101,124,33,81,9,184,207,141,247,2,29,168,34,24,162,78,21,170,195,185,
49,173,17,203,106,191,227,22,111,200,153,128,132,168,15,29,135,102,91,220,133,154,67,154,
74,95,111,135,185,198,155,231,9,124,224,243,152,203,56,139,135,185,20,72,40,59,209,217,
41,192,78,34,201,213,71,43,193,16,241,114,202,38,127,48,127,253,157,141,84,151,178,81,
156,93,6,99,127,52,211,21,73,186,71,160,174,241,102,3,191,222,46,119,131,112,202,38,
97,62,94,130,181,205,87,203,76,85,151,60,0,70,121,23,101,16,216,230,239,138,244,185,
64,238,106,20,94,11,193,216,244,215,193,66,56,224,12,144,191,61,25,169,202,99,137,236,
51,210,229,238,255,123,133,224,92,31,27,111,22,227,14,212,150,152,136,120,162,250,128,151,
224,90,143,45,210,147,197,70,178,119,139,55,32,115,47,80,84,136,67,125,232,14,220,208,
108,139,187,149,168,57,164,141,212,104,35,192,53,222,74,60,78,224,3,127,46,67,59,60,
73,129,150,65,153,72,158,14,198,80,172,145,92,153,190,89,73,135,60,28,188,157,100,146,
42,176,16,188,4,235,47,51,194,72,117,201,139,97,16,127,81,6,99,157,63,43,50,197,
117,143,0,133,55,171,92,153,78,208,193,66,120,248,215,133,84,53,242,26,216,227,233,238,
31,18,61,226,110,176,24,123,160,182,236,96,136,39,170,58,186,4,55,230,216,123,178,172,
246,59,238,21,28,164,63,40,42,68,125,28,184,217,86,40,174,68,77,34,109,68,223,70,
32,204,133,30,111,44,10,64,155,207,99,46,227,60,2,102,136,91,174,160,242,20,176,111,
156,44,181,171,139,175,180,67,222,54,207,188,220,178,201,159,143,159,219,124,47,204,170,75,
94,142,120,57,4,246,71,51,93,145,41,174,187,78,77,86,25,140,249,73,19,60,156,108,
101,246,100,36,35,203,62,35,109,162,139,253,125,175,82,84,130,235,115,127,171,199,94,170,
114,23,19,77,137,170,80,253,1,116,9,235,145,215,2,121,178,216,72,246,59,110,5,196,
127,238,21,21,226,80,31,186,3,55,52,219,162,110,213,28,170,244,53,208,97,13,80,227,
141,229,161,224,247,152,159,197,90,233,73,234,99,41,19,201,79,192,190,1,99,112,214,84,
87,166,207,129,94,14,67,196,211,118,202,38,85,96,120,26,235,239,44,85,93,242,100,163,
28,46,202,33,176,52,83,12,210,231,42,169,107,188,89,101,204,255,117,175,80,11,242,215,
186,148,25,81,26,216,211,38,186,50,255,43,122,196,125,108,188,213,99,111,114,23,19,193,
16,117,170,143,122,14,154,4,247,200,107,145,158,70,27,107,111,119,167,197,28,164,127,206,
4,244,34,132,128,250,208,113,110,198,91,42,202,42,212,36,210,84,250,10,208,97,13,208,
150,19,248,160,199,185,0,45,204,48,181,12,202,242,108,21,219,226,170,233,11,137,9,168,
20,0,255,251,255,3,227,191,3,20,32,97,192,0,129,1,135,107,46,119,29,129,136,124,
197,92,24,74,203,140,3,144,245,138,123,175,54,95,147,62,231,58,210,95,174,47,81,234,
223,12,87,141,101,28,251,75,127,194,56,175,240,117,122,122,133,24,115,126,41,89,184,48,
116,119,111,49,21,32,108,178,13,7,65,125,105,88,134,79,220,101,46,193,177,19,246,112,
243,135,28,116,20,233,193,161,131,153,10,166,86,131,204,127,16,90,204,106,156,92,130,239,
106,193,118,253,202,95,86,194,80,2,54,104,53,28,162,226,156,2,153,75,214,143,54,7,
61,89,95,218,228,103,147,201,120,79,82,88,119,231,180,205,26,66,88,46,23,111,75,196,
184,151,35,132,97,241,201,5,58,115,85,207,98,63,120,108,96,253,7,9,208,175,106,111,
240,104,105,180,165,220,37,248,238,45,142,5,63,86,127,253,180,98,124,218,201,96,63,239,
186,127,80,24,181,128,119,219,147,119,143,17,134,13,86,8,97,121,218,140,99,55,124,218,
166,54,63,108,26,57,242,28,42,100,175,220,183,204,185,68,153,83,31,13,2,97,49,158,
176,169,60,135,88,208,195,125,186,70,48,251,0,36,216,89,0,186,169,142,180,14,171,77,
143,120,226,55,110,60,111,214,85,146,241,100,227,146,206,235,253,51,104,83,76,155,252,25,
106,110,134,222,155,197,48,156,6,218,233,9,128,254,107,23,18,167,112,56,128,76,230,125,
210,218,35,92,165,237,83,73,16,28,214,75,42,2,2,174,55,35,146,117,125,145,150,105,
53,200,28,116,160,181,37,252,107,154,178,143,164,145,202,167,133,76,79,43,68,178,145,236,
163,21,219,76,101,149,176,141,195,150,124,186,70,126,209,255,167,124,146,83,87,29,80,196,
121,174,198,249,225,229,164,225,36,56,132,131,104,34,178,213,210,47,189,183,141,219,150,124,
75,164,87,211,109,115,202,177,250,153,200,127,51,118,76,7,223,180,60,23,133,160,43,36,
43,161,33,111,14,198,43,178,152,134,131,208,191,38,85,239,80,169,99,15,34,10,33,108,
146,56,53,152,205,111,114,191,197,97,13,13,219,214,43,215,4,205,28,192,161,59,216,58,
13,37,112,35,64,104,115,158,149,55,134,67,191,2,183,72,174,146,128,38,210,73,214,92,
128,30,10,151,180,225,178,225,96,123,184,66,234,228,234,31,132,2,172,100,31,172,147,222,
226,164,185,151,200,28,60,28,133,224,191,48,36,255,255,255,15,
};

static void fx_real_plain(uint8_t *in) {   // the 20000 bytes fx_real_frame inflates to
    unsigned s = 7;
    for (int i = 0; i < 20000; i++) { s = s * 1103515245u + 12345u; in[i] = (uint8_t)(1 + ((i % 97) * 3 + ((i % 13 == 0) ? ((s >> 16) & 3) : 0)) % 200); }
}
// DMSPARS1 version 2 of `logical`: cut at multiples of blk (<= 256 KiB); a piece of zeros (>= 4096) is a hole, else a zstd extent when zmode says so (0 none, 1 all, 2 every other piece, 3 only pieces that are a run of one byte) and
// the frame (fx_zframe, or fx_real_frame for a piece equal to fx_real_plain) is smaller than the piece when zmode is 3, else a raw extent. *stats = {extents, zstd extents}. Built in memory (*file, *file_n; malloc)
static long fx_write_sparse2(const uint8_t *logical, size_t n, size_t blk, int zmode, const uint8_t *pack, size_t pack_n, uint8_t **file, size_t *file_n, long *zcount) {
    typedef struct { uint64_t lo, len, phys; uint32_t stored, kind; } ex;
    size_t np = (n + blk - 1) / blk; ex *ext = calloc(np + 1, sizeof *ext); size_t ne = 0, phys = 64, k = 0; uint8_t *buf = calloc(1, 64); long nz = 0;
    uint8_t real[20000]; fx_real_plain(real);
    for (size_t at = 0; at < n; at += blk, k++) {
        size_t len = n - at < blk ? n - at : blk; size_t z = 0; while (z < len && !logical[at + z]) z++;
        if (z == len && len >= 4096) continue;   // a hole
        int uniform = 1; for (size_t j = 1; j < len; j++) if (logical[at + j] != logical[at]) { uniform = 0; break; }
        int zs = zmode == 1 || (zmode == 2 && (k & 1)) || (zmode == 3 && uniform);
        uint8_t *frame = NULL; size_t fn = 0;
        if (zs) {
            if (len == 20000 && !memcmp(logical + at, real, len)) { frame = malloc(sizeof fx_real_frame); memcpy(frame, fx_real_frame, sizeof fx_real_frame); fn = sizeof fx_real_frame; }
            else { frame = malloc(fx_zframe_cap(len)); fn = fx_zframe(frame, logical + at, len); }
        }
        size_t old = phys; phys = (phys + 15) & ~(size_t)15; size_t sl = zs ? fn : len;
        buf = realloc(buf, phys + sl + 16); memset(buf + old, 0, phys + sl + 16 - old);
        memcpy(buf + phys, zs ? frame : logical + at, sl); free(frame);
        ext[ne++] = (ex){at, len, phys, (uint32_t)sl, zs ? 1u : 0u}; nz += zs; phys += sl;
    }
    size_t poff = 0;
    if (pack) { poff = (phys + 16383) & ~(size_t)16383; buf = realloc(buf, poff + pack_n); memset(buf + phys, 0, poff - phys); memcpy(buf + poff, pack, pack_n); phys = poff + pack_n; }
    size_t toff = (phys + 15) & ~(size_t)15, total = toff + ne * 32 + 32;
    buf = realloc(buf, total); memset(buf + phys, 0, total - phys);
    for (size_t i = 0; i < ne; i++) { uint8_t *e = buf + toff + i * 32; fx_put64(e, ext[i].lo); fx_put64(e + 8, ext[i].len); fx_put64(e + 16, ext[i].phys); fx_put32(e + 24, ext[i].stored); fx_put32(e + 28, ext[i].kind); }
    memset(buf, 0, 64); memcpy(buf, "DMSPARS1", 8); fx_put32(buf + 8, 2); fx_put32(buf + 12, 64); fx_put64(buf + 16, n); fx_put64(buf + 24, ne); fx_put64(buf + 32, toff); fx_put64(buf + 40, poff); fx_put64(buf + 48, pack ? pack_n : 0);
    memcpy(buf + total - 32, "DMSPEND1", 8); fx_put64(buf + total - 24, total); fx_put64(buf + total - 16, toff);
    free(ext); *file = buf; *file_n = total; if (zcount) *zcount = nz; return (long)ne;
}
// An NXASTCPK version 2 pack (56-byte index entries {key, offset, stored size, size}) of `count` entries whose payloads are payload[i] (len[i] bytes) behind a 40-byte header "NXASTC01" + `hash[i]` (32 bytes, the caller's: the
// engine verifies SHA-256 of the payload). zmask bit i set: entry i is a zstd frame of its 40 + len[i] bytes (stored smaller than size when the payload has runs), else raw. Keys ascending, given.
static size_t fx_pack2(uint8_t **out, unsigned count, const uint8_t (*keys)[32], const uint8_t *const *payload, const size_t *len, const uint8_t (*hash)[32], unsigned zmask) {
    size_t total = 80; size_t *off = calloc(count + 1, sizeof *off), *st = calloc(count + 1, sizeof *st); uint8_t *buf = calloc(1, 80);
    for (unsigned i = 0; i < count; i++) {
        size_t sz = 40 + len[i]; uint8_t *cf = malloc(sz); memcpy(cf, "NXASTC01", 8); memcpy(cf + 8, hash[i], 32); memcpy(cf + 40, payload[i], len[i]);
        uint8_t *fr = NULL; size_t fn = sz;
        if (zmask >> i & 1) { fr = malloc(fx_zframe_cap(sz)); fn = fx_zframe(fr, cf, sz); }
        total = (total + 15) & ~(size_t)15; buf = realloc(buf, total + fn + 16); memset(buf + total, 0, fn + 16);
        memcpy(buf + total, fr ? fr : cf, fn); off[i] = total; st[i] = fn; total += fn; free(fr); free(cf);
    }
    size_t ioff = (total + 15) & ~(size_t)15, all = ioff + (size_t)count * 56; buf = realloc(buf, all); memset(buf + total, 0, all - total);
    memcpy(buf, "NXASTCPK", 8); fx_put32(buf + 8, 2); fx_put32(buf + 12, 56); fx_put64(buf + 16, count); fx_put64(buf + 24, ioff); fx_put64(buf + 32, all);
    for (unsigned i = 0; i < count; i++) { uint8_t *e = buf + ioff + (size_t)i * 56; memcpy(e, keys[i], 32); fx_put64(e + 32, off[i]); fx_put64(e + 40, st[i]); fx_put64(e + 48, 40 + len[i]); }
    free(off); free(st); *out = buf; return all;
}
