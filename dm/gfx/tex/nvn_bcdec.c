// See nvn_bcdec.h. Decoding uses bcdec (dm/third_party/bcdec, single header, MIT / public domain).
#define BCDEC_IMPLEMENTATION
#define BCDEC_BC4BC5_PRECISE   // interface with signed variants of BC4 / BC5
#include "../../third_party/bcdec/bcdec.h"
#include "nvn_bcdec.h"
#include <dispatch/dispatch.h>
#include <stdlib.h>
#include <string.h>

enum { RG11B10Float = 92, R8Unorm = 10, R8Snorm = 12, RG8Unorm = 30, RG8Snorm = 32, RGBA8Unorm = 70, RGBA8Unorm_sRGB = 71, RGBA16Float = 115 };
// NVN: 0x41 RGB_DXT1, 0x42 RGBA_DXT1, 0x43 DXT3, 0x44 DXT5, 0x45–0x48 the same in sRGB, 0x49 / 0x4a BC4 unsigned / signed, 0x4b / 0x4c BC5, 0x4d / 0x4e BC7 (sRGB), 0x4f / 0x50 BC6H signed / unsigned
// DM_BC6H_R11G11B10 (default on, 0 turns it off): unsigned BC6H is stored as RG11B10Float, 4 bytes a pixel instead of RGBA16Float's 8. Signed BC6H has negative texels, which RG11B10Float cannot hold
static int g_r11g11b10 = -1;
int nvn_bc6h_r11g11b10(void) {
    if (g_r11g11b10 < 0) { const char *e = getenv("DM_BC6H_R11G11B10"); g_r11g11b10 = !(e && !strcmp(e, "0")); }
    return g_r11g11b10;
}
void nvn_bc6h_r11g11b10_set(int on) { g_r11g11b10 = on ? 1 : 0; }
int nvn_bc_unpacked(uint32_t f, uint32_t *pf, int *bpp) {
    switch (f) {
    case 0x41: case 0x42: case 0x43: case 0x44: case 0x4d: *pf = RGBA8Unorm; *bpp = 4; return 1;
    case 0x45: case 0x46: case 0x47: case 0x48: case 0x4e: *pf = RGBA8Unorm_sRGB; *bpp = 4; return 1;
    case 0x49: *pf = R8Unorm; *bpp = 1; return 1;
    case 0x4a: *pf = R8Snorm; *bpp = 1; return 1;
    case 0x4b: *pf = RG8Unorm; *bpp = 2; return 1;
    case 0x4c: *pf = RG8Snorm; *bpp = 2; return 1;
    case 0x50: if (nvn_bc6h_r11g11b10()) { *pf = RG11B10Float; *bpp = 4; return 1; }   // else the same as 0x4f
        *pf = RGBA16Float; *bpp = 8; return 1;
    case 0x4f: *pf = RGBA16Float; *bpp = 8; return 1;
    default: return 0;
    }
}

// A non-negative half float's bits as an unsigned float with mbits mantissa bits (RG11B10Float: 6 for red and green, 5 for blue; 5 exponent bits like a half): the mantissa rounds to nearest even,
// a value past the largest finite one (and infinity and NaN, which the format has no use for here) is the largest finite one, a negative value is 0
static uint32_t half_to_ufloat(uint16_t h, int mbits) {
    if (h & 0x8000) return 0;
    int shift = 10 - mbits; uint32_t v = h, r = (v + ((1u << (shift - 1)) - 1) + ((v >> shift) & 1)) >> shift, max = (30u << mbits) | ((1u << mbits) - 1);
    return (h & 0x7c00) == 0x7c00 || r > max ? max : r;
}
static void block(uint32_t f, const uint8_t *b, uint8_t *o, int op) {   // one block → 4×4 pixels (o has op bytes per row)
    switch (f) {
    case 0x41: case 0x42: case 0x45: case 0x46: bcdec_bc1(b, o, op); break;
    case 0x43: case 0x47: bcdec_bc2(b, o, op); break;
    case 0x44: case 0x48: bcdec_bc3(b, o, op); break;
    case 0x49: bcdec_bc4(b, o, op, 0); break;
    case 0x4a: bcdec_bc4(b, o, op, 1); break;
    case 0x4b: bcdec_bc5(b, o, op, 0); break;
    case 0x4c: bcdec_bc5(b, o, op, 1); break;
    case 0x4d: case 0x4e: bcdec_bc7(b, o, op); break;
    case 0x50: if (nvn_bc6h_r11g11b10()) {   // RG11B10Float: red 0-10, green 11-21, blue 22-31; no alpha (a sampled alpha is 1)
        uint16_t rgb[16 * 3]; bcdec_bc6h_half(b, rgb, 4 * 3, 0);
        for (int y = 0; y < 4; y++) for (int x = 0; x < 4; x++) {
            const uint16_t *s = rgb + (y * 4 + x) * 3;
            ((uint32_t *)(o + y * op))[x] = half_to_ufloat(s[0], 6) | half_to_ufloat(s[1], 6) << 11 | half_to_ufloat(s[2], 5) << 22;
        }
        break; }
        // fall through
    case 0x4f: {   // bcdec outputs RGB half-float; add alpha = 1.0
        uint16_t rgb[16 * 3]; bcdec_bc6h_half(b, rgb, 4 * 3, f == 0x4f);
        for (int y = 0; y < 4; y++) for (int x = 0; x < 4; x++) {
            uint16_t *d = (uint16_t *)(o + y * op) + x * 4; const uint16_t *s = rgb + (y * 4 + x) * 3;
            d[0] = s[0]; d[1] = s[1]; d[2] = s[2]; d[3] = 0x3c00;
        }
        break; }
    }
}

int nvn_bc_decode(uint32_t f, const uint8_t *src, size_t pitch, uint32_t w, uint32_t h, uint8_t *dst, size_t dpitch) {
    uint32_t pf; int bpp; if (!nvn_bc_unpacked(f, &pf, &bpp)) return -1;
    int bb = (f == 0x41 || f == 0x42 || f == 0x45 || f == 0x46 || f == 0x49 || f == 0x4a) ? 8 : 16;   // bytes per block
    size_t nrows = (h + 3) / 4;
    void (^row)(size_t) = ^(size_t by) {
        uint8_t tmp[4 * 4 * 8];
        for (uint32_t bx = 0; bx * 4 < w; bx++) {
        const uint8_t *b = src + by * pitch + bx * bb;
        uint32_t cw = w - bx * 4 < 4 ? w - bx * 4 : 4, ch = h - (uint32_t)by * 4 < 4 ? h - (uint32_t)by * 4 : 4;
        uint8_t *o = dst + (size_t)by * 4 * dpitch + (size_t)bx * 4 * bpp;
        if (cw == 4 && ch == 4) { block(f, b, o, (int)dpitch); continue; }
        block(f, b, tmp, 4 * bpp);   // blocks at the edge that are not a full 4×4: decode into a temporary block first, then copy the needed part
        for (uint32_t y = 0; y < ch; y++) memcpy(o + y * dpitch, tmp + y * 4 * bpp, cw * bpp);
        }
    };
    // One texture of a scene's load can be 2048x2048 of BC7: its rows go to every core, so one texture does not hold the submit thread for a whole frame
    if ((size_t)w * h >= 256 * 256) dispatch_apply(nrows, DISPATCH_APPLY_AUTO, row);
    else for (size_t by = 0; by < nrows; by++) row(by);
    return 0;
}

// Unsigned or signed BC6H into RGBA16Float (8 bytes a pixel, alpha 1.0), full half precision: the source of the HDR ASTC encoder (the sampled texture of nvn_bc_decode may be RG11B10Float)
int nvn_bc6h_decode_half(uint32_t f, const uint8_t *src, size_t pitch, uint32_t w, uint32_t h, uint8_t *dst, size_t dpitch) {
    if (f != 0x4f && f != 0x50) return -1;
    for (uint32_t by = 0; by * 4 < h; by++) for (uint32_t bx = 0; bx * 4 < w; bx++) {
        uint16_t rgb[16 * 3]; bcdec_bc6h_half(src + (size_t)by * pitch + (size_t)bx * 16, rgb, 4 * 3, f == 0x4f);
        uint32_t cw = w - bx * 4 < 4 ? w - bx * 4 : 4, ch = h - by * 4 < 4 ? h - by * 4 : 4;
        for (uint32_t y = 0; y < ch; y++) for (uint32_t x = 0; x < cw; x++) {
            uint16_t *d = (uint16_t *)(dst + (size_t)(by * 4 + y) * dpitch) + (bx * 4 + x) * 4; const uint16_t *s = rgb + (y * 4 + x) * 3;
            d[0] = s[0]; d[1] = s[1]; d[2] = s[2]; d[3] = 0x3c00;
        }
    }
    return 0;
}
