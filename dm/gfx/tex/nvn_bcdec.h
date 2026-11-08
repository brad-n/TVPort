// GPUs without BC compressed format support (A15 / A16 etc., Apple GPU family Apple8 and below): BC textures are decompressed on the CPU into uncompressed formats.
// On a GPU without BC every BC texture is stored decompressed; BC1-5 are decoded on the GPU at upload (nvn_mtl.m, bcd), BC6H / BC7 / 3D textures go through here (d2r-mobile's offline ASTC pack is not part of this repository).
#pragma once
#include <stddef.h>
#include <stdint.h>

// Unsigned BC6H (0x50) is decoded into RG11B10Float (4 bytes a pixel) unless DM_BC6H_R11G11B10=0; signed BC6H (0x4f) is RGBA16Float (8 bytes). The _set form is for tests
int nvn_bc6h_r11g11b10(void);
void nvn_bc6h_r11g11b10_set(int on);
// NVN format is BC → returns 1, *mtl_pf = Metal pixel format after decompression, *bpp = bytes per pixel after decompression; returns 0 if not BC
int nvn_bc_unpacked(uint32_t nvn_fmt, uint32_t *mtl_pf, int *bpp);
// Decode a w×h pixel region: src is laid out by block rows (pitch bytes per block row), dst has dpitch bytes per pixel row. Returns 0 on success
int nvn_bc_decode(uint32_t nvn_fmt, const uint8_t *src, size_t pitch, uint32_t w, uint32_t h, uint8_t *dst, size_t dpitch);
// BC6H (0x50 unsigned, 0x4f signed) into RGBA16Float, 8 bytes a pixel, alpha 1.0, always at full half precision (nvn_bc_decode may write RG11B10Float)
int nvn_bc6h_decode_half(uint32_t nvn_fmt, const uint8_t *src, size_t pitch, uint32_t w, uint32_t h, uint8_t *dst, size_t dpitch);
