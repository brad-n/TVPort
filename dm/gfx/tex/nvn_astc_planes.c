// See nvn_astc_planes.h
#include "nvn_astc_planes.h"
#include "nvn_deswizzle.h"
#include <stdlib.h>

unsigned nvn_astc_layers(const nvn_texdesc *d) {
    return (d->target == 4 || d->target == 9) ? d->depth : d->target == 8 ? 6 : d->target == 3 ? d->height : 1;
}
int nvn_astc_walk_planes(const nvn_texdesc *d, const void *storage, unsigned skip, nvn_astc_plane_fn fn, void *ctx) {
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
        if (need > cap) { free(buf); buf = malloc(need); cap = need; if (!buf) { result = -1; break; } }
        for (unsigned y = 0; y < layers && !result; y++) {
            if (nvn_deswizzle(d, l + skip, y, storage, buf, pitch)) { result = -1; break; }
            result = fn(ctx, l + skip, y, w, h, buf, need);
        }
    }
    free(buf);
    return result;
}
