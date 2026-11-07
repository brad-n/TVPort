// The native half of dm/gfx/tools/bntx_astc.py, loaded with ctypes: the engine's own plane walk, key and encoder for one texture. No Metal device is created and no game is started.
// Built by bntx_astc.py from the engine's sources (nvn_tex.c, nvn_deswizzle.c, nvn_astc_planes.c, nvn_bcdec.c, nvn_astc.mm, nvn_astc_cache.m) and the same astc-encoder objects as the host,
// so a plane is keyed, decoded and encoded by the code the runtime runs. Every call is thread-safe; the tool uses one process per core.
#import <Foundation/Foundation.h>
#include "../tex/nvn_astc_cache.h"
#include "../tex/nvn_astc_planes.h"
#include "../tex/nvn_deswizzle.h"
#include <stdlib.h>
#include <string.h>

typedef struct {
    char key[65];
    uint8_t hit, error;       // hit: the entry was already in the cache; error: the encoder or the cache write failed
    uint32_t level, layer, width, height;
    uint32_t bc_bytes, astc_bytes;
    char key2[65];            // the key under `alt_format` (BC1 has two NVN formats, RGB and RGBA: the same blocks, the same entry), empty without one
} dm_plane;

typedef struct {
    uint32_t format, alt_format; unsigned block; const char *cache; int encode;
    dm_plane *out; uint32_t cap, n; int overflow;
} walk_ctx;

static int plane_cb(void *p, unsigned level, unsigned layer, uint32_t w, uint32_t h, const void *bc, size_t bc_size) {
    walk_ctx *c = p;
    if (c->n >= c->cap) { c->overflow = 1; return 1; }
    dm_plane *o = &c->out[c->n++];
    memset(o, 0, sizeof *o);
    o->level = level; o->layer = layer; o->width = w; o->height = h; o->bc_bytes = (uint32_t)bc_size;
    size_t astc = (size_t)((w + c->block - 1) / c->block) * 16 * ((h + c->block - 1) / c->block);
    o->astc_bytes = (uint32_t)astc;
    nvn_astc_cache_key key;
    if (c->alt_format) { nvn_astc_cache_key k2; nvn_bc_astc_plane_key(c->alt_format, w, h, c->block, bc, bc_size, &k2); memcpy(o->key2, k2.hex, 65); }
    if (!c->encode) { nvn_bc_astc_plane_key(c->format, w, h, c->block, bc, bc_size, &key); memcpy(o->key, key.hex, 65); return 0; }
    void *dst = malloc(astc);
    if (!dst) { o->error = 1; return 0; }
    int hit = 0;
    int rc = nvn_bc_astc_encode_key(c->format, bc, bc_size, w, h, c->block, dst, astc, c->cache, NULL, &hit, &key);
    free(dst);
    memcpy(o->key, key.hex, 65);
    o->hit = (uint8_t)hit; o->error = rc != 0;
    return 0;
}

// The planes of one texture, as the runtime enumerates them. `storage` is the texture's block-linear image (a BNTX's data from its first byte); pkg_block_h is the packaged layout's
// byte 0 + 1 (0: the automatic block height). encode=0 only keys the planes. Returns the plane count (>= 0), -1 for a texture the engine cannot lay out or whose storage is too short,
// -2 when out is too small
int dm_texture_planes(int target, int format, uint32_t width, uint32_t height, uint32_t depth, uint32_t levels, int pkg_block_h,
                      const void *storage, uint64_t storage_size, unsigned block, int alt_format, const char *cache, int encode, dm_plane *out, uint32_t cap) {
    nvn_texdesc d = {.target = target, .format = format, .width = width, .height = height, .depth = depth, .levels = levels, .pkg_block_h = pkg_block_h};
    nvn_texlayout L; nvn_tex_layout(&d, &L);
    if (!L.bpb || L.size > storage_size || nvn_bc_astc_format((uint32_t)format, block, NULL) != 1) return -1;
    walk_ctx c = {.format = (uint32_t)format, .alt_format = (uint32_t)alt_format, .block = block, .cache = cache, .encode = encode, .out = out, .cap = cap};
    @autoreleasepool {
        int r = nvn_astc_walk_planes(&d, storage, 0, plane_cb, &c);
        if (c.overflow) return -2;
        return r ? -1 : (int)c.n;
    }
}
// The storage bytes the engine's layout gives the texture (0 when it cannot lay it out)
uint64_t dm_texture_size(int target, int format, uint32_t width, uint32_t height, uint32_t depth, uint32_t levels, int pkg_block_h) {
    nvn_texdesc d = {.target = target, .format = format, .width = width, .height = height, .depth = depth, .levels = levels, .pkg_block_h = pkg_block_h};
    nvn_texlayout L; nvn_tex_layout(&d, &L);
    return L.bpb ? L.size : 0;
}
uint64_t dm_level_offset(int target, int format, uint32_t width, uint32_t height, uint32_t depth, uint32_t levels, int pkg_block_h, unsigned level) {
    nvn_texdesc d = {.target = target, .format = format, .width = width, .height = height, .depth = depth, .levels = levels, .pkg_block_h = pkg_block_h};
    return nvn_tex_level_offset(&d, level);
}
// 1 when the format is one DM_NVN_BC_ASTC stores as ASTC at this block size (BC1/2/3/7 and their sRGB forms)
int dm_format_eligible(int format, unsigned block) { return nvn_bc_astc_format((uint32_t)format, block, NULL); }
// Swizzle one level and layer of a linear plane into storage (tests build block-linear textures with it)
int dm_swizzle(int target, int format, uint32_t width, uint32_t height, uint32_t depth, uint32_t levels, int pkg_block_h, unsigned level, unsigned layer,
               const void *linear, size_t pitch, void *storage) {
    nvn_texdesc d = {.target = target, .format = format, .width = width, .height = height, .depth = depth, .levels = levels, .pkg_block_h = pkg_block_h};
    return nvn_swizzle(&d, level, layer, linear, pitch, storage);
}

// Yaz0 (Nintendo's LZ77: almost all of Mario Kart 8 Deluxe's RomFS is .szs = SARC inside Yaz0): the decoded bytes of the stream src[0..n) into dst (cap bytes), the size the header
// records (4 bytes big-endian at +4). The same stream shader_split.py yaz0() decodes, in C because pure Python runs at 20-45 MB/s. Returns the decoded size, -1 for a damaged stream
// or one that does not fit cap
int64_t dm_yaz0(const uint8_t *s, size_t n, uint8_t *dst, size_t cap) {
    if (n < 16 || memcmp(s, "Yaz0", 4)) return -1;
    size_t out = (size_t)s[4] << 24 | (size_t)s[5] << 16 | (size_t)s[6] << 8 | s[7];
    if (out > cap) return -1;
    size_t si = 16, di = 0;
    while (di < out) {
        if (si >= n) return -1;
        unsigned h = s[si++];
        for (int i = 0; i < 8 && di < out; i++, h <<= 1) {
            if (h & 0x80) {
                if (si >= n) return -1;
                dst[di++] = s[si++];
            } else {
                if (si + 1 >= n) return -1;
                unsigned b1 = s[si], b2 = s[si + 1]; si += 2;
                size_t dist = ((b1 & 15u) << 8 | b2) + 1, len = b1 >> 4;
                if (len) len += 2; else { if (si >= n) return -1; len = (size_t)s[si++] + 0x12; }
                if (dist > di) return -1;
                if (len > out - di) len = out - di;
                for (size_t k = 0; k < len; k++, di++) dst[di] = dst[di - dist];
            }
        }
    }
    return (int64_t)out;
}
