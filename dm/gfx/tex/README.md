# dm/gfx/tex — texture format mapping, block-linear deswizzling, BC decompression

The part of the graphics layer that deals with texture data, called by the replay layer `../nvn/nvn_mtl.m`. It does three things:

1. converts NVN texture format numbers to Metal pixel formats;
2. unpacks the Switch's "block-linear" layout into an ordinary row-by-row layout;
3. decompresses BC textures on GPUs that do not support BC compressed textures.

Block linear is how the Tegra X1 GPU stores textures: the data is not one row after another, but interleaved in small blocks of 64 bytes × 8 rows (GOBs), and several GOBs are then stacked into larger blocks according to a "block height" and a "block depth". The game's packaged texture files are in exactly this layout, and it must be undone before uploading to Metal.

## Files

| File | Contents |
|---|---|
| `nvn_fmt_mtl.h`, `nvn_fmt_mtl.c` | `nvn_fmt_to_mtl()`: NVN format (0x01–0x9C) → Metal pixel format + component remapping. Returns 1 for an exact match, 2 for a substitute (precision, bit order or interpretation differs and a conversion is needed), 0 when Metal has no corresponding format. How each format is handled is written in the comments inside the table. Pure C, no dependency on Metal headers |
| `nvn_deswizzle.h`, `nvn_deswizzle.c` | `nvn_deswizzle()`: deswizzles one level and one layer from block linear to linear; `nvn_swizzle()`: the reverse, used for round trips in unit tests; `nvn_bl_offset()`: the block-linear address of a single point. Pure C |
| `nvn_deswizzle_gpu.h`, `nvn_deswizzle_gpu.m` | A Metal compute shader version of the same deswizzling algorithm, used by the replay layer when uploading packaged textures; when initialization fails or an unsupported format is encountered, the replay layer falls back to the CPU version |
| `tests/` | Unit tests |

The offsets of each level and layer within the storage, and the block height and block depth actually used by each level, are all taken from `../nvn/nvn_tex.c` (`nvn_tex_layout`, `nvn_tex_level_offset`, `nvn_tex_level_tiles`); this directory only does addressing and moving within a level. Packaged parameters override the automatic block dimensions: [Packaged texture block dimensions and linear storage rows](../../../docs/reference/nvn-objects.md#packaged-texture-block-dimensions-and-linear-storage-rows).

## BC textures

Only GPUs with BC compressed textures are supported (`supportsBCTextureCompression` of `MTLDevice`: Apple silicon Macs and the latest iPhones), so BC textures are created and uploaded as BC; there is no decompression path. A device without them is refused at start ([GPUs without BC textures](../../../docs/reference/rendering.md#gpus-without-bc-textures-are-refused-at-start)). A BC texture is never a render target and its raw blocks are not sampled through an uncompressed view (Metal has no such views; Breath of the Wild encodes one 32×32 BC4 texture on the GPU, GitHub issue #4).

## Tests

```sh
make -C dm/gfx/tex/tests run       # run t_fmt_mtl and t_tex
```

- **`t_fmt_mtl`**: takes the mapping for every NVN format in 0x01–0x9C and, for every one whose mapping is not 0, actually creates a texture on the local Metal device; all of them must be created successfully. It also checks that every NVN format with sRGB in its name lands on a Metal sRGB format. No game files needed.
- **`t_tex`**: the deswizzling tests, in several groups:

  | Group | Criterion |
  |---|---|
  | A round trip | Writes random data into each level and layer and reads it back out; must be byte-for-byte equal. Covers 2D, 2D array and 3D, several bytes-per-block values and non-power-of-two sizes |
  | B address formula | The result of `nvn_bl_offset()` equals the address computed by hand from the public layout rules |
  | D differential copies | Both copy directions match a byte-address oracle for 1,029 deterministic layouts, including padded pitches, byte tails, sparse mip tails, packaged block dimensions, arrays and cubes; untouched storage and row padding are compared too |
  | E hand-made 3D | Places markers at hand-computed addresses, checks where they land after deswizzling, and checks block height, block depth and storage size |

  The A round trip can only prove "one-to-one and within bounds"; it cannot prove that the layout formula is right. What backs it up is the hand-computed addresses of groups B and E, and the games that render right.

## Limitations

- `nvn_deswizzle()` does not support multisampled textures, textures with the LINEAR flag (which are linear to begin with) or the BUFFER target; it returns -1 when it encounters them.
- Cubes and cube arrays are handled as layered textures.
- The component bit order of the 16-bit packed formats (565 / 5551 / 4444) is mapped according to the format names and has not been checked with real data; they are marked as "substitute" in the format table.

## BC textures as ASTC (`DM_NVN_BC_ASTC`)

On a GPU without BC formats (the Apple TV 4K's A15) BC textures are stored decoded: BC1 as RGBA8 (8 times the Switch size), BC2/3/7 as RGBA8 (4 times). With `DM_NVN_BC_ASTC=4` or `=6` the 2D and 2D-array BC1/2/3/7 textures are stored as ASTC 4x4 / 6x6 LDR instead (ASTC 4x4 is 1 byte a texel, a quarter of RGBA8, the Switch's own size for BC2/3/7 and twice it for BC1; 6x6 is 0.44 byte a texel); BC4/5, BC6H and 3D textures keep the decoded path. Unset or 0 changes nothing. The switch only acts where BC is stored decoded (`DM_TEST_NO_BC=1` makes a Mac do the same, for tests and for filling a cache).

`nvn_astc_cache.m` decodes the deswizzled BC plane (stripes of at most 4 MB), encodes it with Arm's astc-encoder at ASTCENC_PRE_FASTEST on the calling (submit) thread, and keeps the result in a content-addressed cache: `<sha256(version tag, format, width, height, block, BC bytes)>.astc` under `DM_NVN_ASTC_CACHE` (written on a miss), read first from `DM_NVN_ASTC_CACHE_RO` if set. The key depends on the BC bytes, never on the machine, so a cache filled on a Mac is valid on the Apple TV. A buffer-to-texture copy into a BC texture is transcoded the same way (ASTC 4x4: any block-aligned region; 6x6: only regions on the 6x6 grid), a new texture reads zero blocks as the BC format would (void-extent blocks), and views of an ASTC texture are the ASTC format of the BC view format. Algorithm and cache layout follow [yuchanns/nxnative-tvos](https://github.com/yuchanns/nxnative-tvos) (MIT, `LICENSE.nxnative-tvos`).

Tests: `dm/gfx/tests/t_astc_cache` (CPU, ASan/UBSan), `t_astc_upload` (Mac GPU: formats, sampled error against the CPU decode, the cache, buffer-to-texture copies; `T_ASTC_BLOCK=6` runs the 6x6 case).
