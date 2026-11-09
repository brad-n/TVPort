// The BC planes of a texture, as DM_NVN_BC_ASTC hashes them. The runtime (nvn_mtl.m, astc_probe) and the offline prebuild (dm/gfx/tools/bntx_astc.py, through
// astc_prebuild.m) both enumerate a texture's planes through this one function, so a plane the tool keys is the plane the runtime looks up.
#pragma once
#include <stddef.h>
#include <stdint.h>
#include "../nvn/nvn_tex.h"

// Called for each plane, level by level and layer by layer within a level: the level (counted from the texture's level 0) and layer, the plane's width and height in texels,
// and its tightly packed BC blocks. A non-zero return stops the walk and is returned by it.
typedef int (*nvn_astc_plane_fn)(void *ctx, unsigned level, unsigned layer, uint32_t width, uint32_t height, const void *bc, size_t bc_size);
// Where a plane's STORED bytes lie in the texture's storage (block-linear, exactly as in the file and in guest memory): offset from the storage's start and the length the layout gives the plane
// (whole GOBs: ceil(row bytes / 64) x ceil(rows / block height) blocks). docs/texture_once.md section 2 tags the first 8 of these bytes and zeros the rest. -1 for a texture that cannot be deswizzled
int nvn_astc_plane_storage(const nvn_texdesc *d, unsigned level, unsigned layer, uint64_t *offset, uint64_t *length);
// Called for each plane before it is deswizzled, with its stored bytes: > 0 means it was handled (no deswizzle, fn is not called for it), 0 goes on as nvn_astc_walk_planes does, < 0 stops the walk with that value
typedef int (*nvn_astc_raw_fn)(void *ctx, unsigned level, unsigned layer, uint32_t width, uint32_t height, const void *storage, size_t storage_len);
int nvn_astc_walk_planes_raw(const nvn_texdesc *d, const void *storage, unsigned skip, nvn_astc_raw_fn raw, nvn_astc_plane_fn fn, void *ctx);
// Layers the walk visits for each level: the array layers, 6 for a cube, 1 for a plain 2D texture
unsigned nvn_astc_layers(const nvn_texdesc *d);
// Deswizzle every level from `skip` on of the texture whose block-linear storage is `storage` and hand each (level, layer) plane to fn. 0 when the walk finished; -1 for a format
// that is not 4x4 blocks, a level that cannot be deswizzled, or no memory; otherwise fn's non-zero result
int nvn_astc_walk_planes(const nvn_texdesc *d, const void *storage, unsigned skip, nvn_astc_plane_fn fn, void *ctx);
// DM_BC_MAX_DIM=<cap>: how many of a texture's finest levels the runtime leaves out on a GPU without BC (0 for no cap, a 3D/cube/1D texture, or a non-BC format). The first level kept has its longest side
// <= cap, or it is the last level when none fits. nvn_mtl.m bc_skip and the offline prebuild (bntx_astc.py --max-dim) both take it from here, so the planes the pack holds are the planes the runtime asks for
unsigned nvn_bc_skip_levels(const nvn_texdesc *d, int cap);
// DM_ASTC_MAX_DIM: the same for a texture that is ASTC in the file (NVN formats 0x79-0x94, any block size, LDR and sRGB; NVN has no ASTC HDR format). Only 2D and 2D array textures; nothing is ever upscaled.
// *short_chain (optional) is set when the texture is over the cap but its mip chain has no level that fits, so it keeps its last level (a texture without mips is left whole). nvn_mtl.m bc_skip uses it
int nvn_fmt_astc_native(uint32_t nvn_fmt);
unsigned nvn_astc_skip_levels(const nvn_texdesc *d, int cap, int *short_chain);
