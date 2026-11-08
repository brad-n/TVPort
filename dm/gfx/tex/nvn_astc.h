#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif
// RGBA8 input is tightly packed. Output contains tightly packed 16-byte ASTC
// blocks. Only 4x4 and 6x6 LDR blocks are supported; zero means success.
int nvn_astc_encode_rgba8(const uint8_t *pixels, uint32_t width, uint32_t height,
                         int srgb, unsigned block, uint8_t *output, size_t output_size);
// The same with the codec contexts of `slot` (0..4): threads that use different slots do not wait for each other
int nvn_astc_encode_rgba8_slot(unsigned slot, const uint8_t *pixels, uint32_t width, uint32_t height,
                              int srgb, unsigned block, uint8_t *output, size_t output_size);
// mode: 8-bit RGBA with the LDR or the sRGB profile, or half-float RGBA (8 bytes a pixel, tightly packed) with the HDR profile (HDR colour, LDR alpha)
enum { NVN_ASTC_LDR8 = 0, NVN_ASTC_SRGB8 = 1, NVN_ASTC_HDR16 = 2 };
int nvn_astc_encode_slot(unsigned slot, int mode, const void *pixels, uint32_t width, uint32_t height,
                         unsigned block, uint8_t *output, size_t output_size);
// mode: 8-bit RGBA with the LDR or the sRGB profile, or half-float RGBA (8 bytes a pixel, tightly packed) with the HDR profile (HDR colour, LDR alpha)
enum { NVN_ASTC_LDR8 = 0, NVN_ASTC_SRGB8 = 1, NVN_ASTC_HDR16 = 2 };
int nvn_astc_encode_slot(unsigned slot, int mode, const void *pixels, uint32_t width, uint32_t height,
                         unsigned block, uint8_t *output, size_t output_size);
#ifdef __cplusplus
}
#endif
