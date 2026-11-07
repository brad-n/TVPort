#include "nvn_astc.h"
#include "../../third_party/astc-encoder/astcenc.h"
#include <mutex>

namespace {
struct Codec {
    std::mutex mutex;
    astcenc_context *context;
    Codec() : context(NULL) {}
    ~Codec() { if (context) astcenc_context_free(context); }
};
// Slot 0 is the calling thread of the synchronous mode; the background workers take slots 1.., each with contexts of its own, so planes encode in parallel
const unsigned kSlots = 5;
Codec codecs[kSlots][3][2];   // [slot][block 4, 5, 6][sRGB]
}

int nvn_astc_encode_rgba8(const uint8_t *pixels, uint32_t width, uint32_t height,
                         int srgb, unsigned block, uint8_t *output, size_t output_size) {
    return nvn_astc_encode_rgba8_slot(0, pixels, width, height, srgb, block, output, output_size);
}

int nvn_astc_encode_rgba8_slot(unsigned slot, const uint8_t *pixels, uint32_t width, uint32_t height,
                              int srgb, unsigned block, uint8_t *output, size_t output_size) {
    if (slot >= kSlots || !pixels || !output || !width || !height || width > 16384 || height > 16384 ||
        (block < 4 || block > 6)) return -1;
    uint64_t required = ((uint64_t)width + block - 1) / block * ((height + block - 1) / block) * 16;
    if (required != output_size) return -1;
    Codec &codec = codecs[slot][block - 4][srgb != 0];
    std::lock_guard<std::mutex> lock(codec.mutex);
    astcenc_error result;
    if (!codec.context) {
        astcenc_config config;
        result = astcenc_config_init(srgb ? ASTCENC_PRF_LDR_SRGB : ASTCENC_PRF_LDR,
            block, block, 1, ASTCENC_PRE_FASTEST, 0, &config);
        if (result != ASTCENC_SUCCESS) return result;
        result = astcenc_context_alloc(&config, 1, &codec.context, nullptr);
        if (result != ASTCENC_SUCCESS) return result;
    }
    void *plane = const_cast<uint8_t *>(pixels);
    astcenc_image image = {width, height, 1, ASTCENC_TYPE_U8, &plane};
    const astcenc_swizzle swizzle = {ASTCENC_SWZ_R, ASTCENC_SWZ_G, ASTCENC_SWZ_B, ASTCENC_SWZ_A};
    result = astcenc_compress_image(codec.context, &image, &swizzle, output, output_size, 0);
    astcenc_compress_reset(codec.context);
    return result;
}
