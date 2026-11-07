# Arm ASTC Encoder

Library sources from [Arm ASTC Encoder 5.7.0](https://github.com/ARM-software/astc-encoder/tree/baff485b0ff36d2f95d28961605106502c653966), commit `baff485b0ff36d2f95d28961605106502c653966`, under the Apache 2.0 license in `LICENSE.txt`.

Only the unmodified library sources and headers from `Source/` are included. The command-line application and image loaders are excluded. `dm/host/Makefile` builds the static library `gen/astc/libastcenc.a` with C++14, invariant floating-point arithmetic (`-ffp-contract=off`) and a maximum block size of 36 texels (the renderer uses ASTC 4x4 and 6x6 LDR only); `dm/ios/tools/gen_build.py` compiles the same files for the tvOS and iOS projects.

`dm/gfx/tex/nvn_astc.mm` provides the C interface (one ASTCENC_PRE_FASTEST context per block size and sRGB-ness, serialized by a mutex). It, `dm/gfx/tex/nvn_astc_cache.m` (decode, encode and the content-addressed cache) and the `DM_NVN_BC_ASTC` hooks in `dm/gfx/nvn/nvn_mtl.m` come from [yuchanns/nxnative-tvos](https://github.com/yuchanns/nxnative-tvos) (MIT, copyright 2026 jhaizhou; the license text is `dm/gfx/tex/LICENSE.nxnative-tvos`), adapted to this tree.
