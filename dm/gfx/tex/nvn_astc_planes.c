// See nvn_astc_planes.h
#include "nvn_astc_planes.h"
#include "nvn_deswizzle.h"
#include "nvn_bcdec.h"
#include <stdlib.h>

unsigned nvn_astc_layers(const nvn_texdesc *d) {
    return (d->target == 4 || d->target == 9) ? d->depth : d->target == 8 ? 6 : d->target == 3 ? d->height : 1;
}
int nvn_astc_plane_storage(const nvn_texdesc *d, unsigned level, unsigned layer, uint64_t *offset, uint64_t *length) {
    uint32_t row_bytes, rows, slices, bpb; uint64_t base; unsigned th, td;
    if (nvn_deswizzle_geom(d, level, layer, &row_bytes, &rows, &slices, &base, &th, &td, &bpb)) return -1;
    uint32_t lb = nvn_tex_level_gobs(d, level) * 64;   // the row as laid out (see nvn_deswizzle.c move)
    if (lb < row_bytes) lb = row_bytes;
    uint64_t gobs_x = ((uint64_t)lb + 63) >> 6, blocks_y = ((uint64_t)rows + 8u * (1u << th) - 1) >> (3 + th);
    *offset = base; *length = gobs_x * blocks_y * 512ull * (1u << th) * (1u << td);
    return 0;
}
int nvn_astc_walk_planes_raw(const nvn_texdesc *d, const void *storage, unsigned skip, nvn_astc_raw_fn raw, nvn_astc_plane_fn fn, void *ctx) {
    unsigned levels = d->levels ? d->levels : 1;
    if (skip >= levels) return -1;
    unsigned n = levels - skip, layers = nvn_astc_layers(d);
    int bw, bh, bpb = nvn_fmt_bpb(d->format, &bw, &bh);
    if (!bpb || bw != 4 || bh != 4) return -1;
    int result = 0; uint8_t *buf = NULL; size_t cap = 0;
    for (unsigned l = 0; l < n && !result; l++) {
        uint32_t w = d->width >> (l + skip), h = d->height >> (l + skip);
        if (!w) w = 1;
        if (!h) h = 1;
        size_t pitch = (size_t)((w + 3) / 4) * bpb, need = pitch * ((h + 3) / 4);
        for (unsigned y = 0; y < layers && !result; y++) {
            if (raw) {   // the plane's stored bytes, before any deswizzle
                uint64_t off, len;
                if (nvn_astc_plane_storage(d, l + skip, y, &off, &len)) { result = -1; break; }
                int r = raw(ctx, l + skip, y, w, h, (const uint8_t *)storage + off, (size_t)len);
                if (r > 0) continue;   // handled: no deswizzle, no fn
                if (r < 0) { result = r; break; }
            }
            if (need > cap) { free(buf); buf = malloc(need); cap = need; if (!buf) { result = -1; break; } }
            if (nvn_deswizzle(d, l + skip, y, storage, buf, pitch)) { result = -1; break; }
            result = fn(ctx, l + skip, y, w, h, buf, need);
        }
    }
    free(buf);
    return result;
}
int nvn_astc_walk_planes(const nvn_texdesc *d, const void *storage, unsigned skip, nvn_astc_plane_fn fn, void *ctx) {
    return nvn_astc_walk_planes_raw(d, storage, skip, NULL, fn, ctx);
}
unsigned nvn_bc_skip_levels(const nvn_texdesc *d, int cap) {
    uint32_t pf; int bpp;
    if (cap <= 0 || (d->target != 1 && d->target != 4) || !nvn_bc_unpacked(d->format, &pf, &bpp)) return 0;
    unsigned s = 0, n = d->levels ? d->levels : 1;
    while (s + 1 < n && (d->width >> s > d->height >> s ? d->width >> s : d->height >> s) > (unsigned)cap) s++;
    return s;
}
