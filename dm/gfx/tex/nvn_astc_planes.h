// The BC planes of a texture, as DM_NVN_BC_ASTC hashes them. The runtime (nvn_mtl.m, astc_probe) and the offline prebuild (dm/gfx/tools/bntx_astc.py, through
// astc_prebuild.m) both enumerate a texture's planes through this one function, so a plane the tool keys is the plane the runtime looks up.
#pragma once
#include <stddef.h>
#include <stdint.h>
#include "../nvn/nvn_tex.h"

// Called for each plane, level by level and layer by layer within a level: the level (counted from the texture's level 0) and layer, the plane's width and height in texels,
// and its tightly packed BC blocks. A non-zero return stops the walk and is returned by it.
typedef int (*nvn_astc_plane_fn)(void *ctx, unsigned level, unsigned layer, uint32_t width, uint32_t height, const void *bc, size_t bc_size);
// Layers the walk visits for each level: the array layers, 6 for a cube, 1 for a plain 2D texture
unsigned nvn_astc_layers(const nvn_texdesc *d);
// Deswizzle every level from `skip` on of the texture whose block-linear storage is `storage` and hand each (level, layer) plane to fn. 0 when the walk finished; -1 for a format
// that is not 4x4 blocks, a level that cannot be deswizzled, or no memory; otherwise fn's non-zero result
int nvn_astc_walk_planes(const nvn_texdesc *d, const void *storage, unsigned skip, nvn_astc_plane_fn fn, void *ctx);
