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

`nvn_astc_cache.m` decodes the deswizzled BC plane (stripes of at most 4 MB), encodes it with Arm's astc-encoder at ASTCENC_PRE_FASTEST, and keeps the result in a content-addressed cache: `<sha256(version tag, format, width, height, block, BC bytes)>.astc` under `DM_NVN_ASTC_CACHE` (written on a miss), read first from `DM_NVN_ASTC_CACHE_RO` if set. The key depends on the BC bytes, never on the machine, so a cache filled on a Mac is valid on the Apple TV. A buffer-to-texture copy into a BC texture is transcoded the same way (ASTC 4x4: any block-aligned region; 6x6: only regions on the 6x6 grid), a new texture reads zero blocks as the BC format would (void-extent blocks), and views of an ASTC texture are the ASTC format of the BC view format. Algorithm and cache layout follow [yuchanns/nxnative-tvos](https://github.com/yuchanns/nxnative-tvos) (MIT, `LICENSE.nxnative-tvos`).

Tests: `dm/gfx/tests/t_astc_cache` (CPU, ASan/UBSan), `t_astc_upload` (Mac GPU: formats, sampled error against the CPU decode, the cache, buffer-to-texture copies; `T_ASTC_BLOCK=6` runs the 6x6 case; `T_ASTC_MODE=maxdim` runs it with `DM_BC_MAX_DIM=64`).

### Texture cap (`DM_BC_MAX_DIM`)

`DM_BC_MAX_DIM` (TVPort's per-game Texture Detail) makes a 2D or 2D-array BC texture with a mip chain start at its first level whose longest side fits the cap (the last level when none does): `nvn_bc_skip_levels` in `nvn_astc_planes.c`. The runtime (`bc_skip` in `nvn_mtl.m`: the Metal texture's size and level count, the upload, the plane look-up, views and copies) and the offline prebuild (`bntx_astc.py --max-dim N`, which TVPort passes) both use that one function, so the pack holds exactly the planes the runtime asks for under the game's cap and none of the finer levels it skips. The cap is part of the pack's fingerprint: another cap rebuilds the pack.

## BC6H without BC formats (`DM_BC6H_R11G11B10`)

Unsigned BC6H (NVN `BPTC_UFLOAT`, 0x50) is decoded on the CPU into `RG11B10Float` (4 bytes a pixel; BC6H has no alpha and Metal samples 1 for it) instead of `RGBA16Float` (8 bytes); the half-float texels are rounded to the format's 6 (red, green) and 5 (blue) mantissa bits and clamped to its range. Signed BC6H (`BPTC_SFLOAT`, 0x4f) has negative texels, which `RG11B10Float` cannot hold, so it stays `RGBA16Float`. `DM_BC6H_R11G11B10=0` turns this off. Both are CPU paths (the GPU decoder `bcd` does not take BC6H) and go through `nvn_bc_unpacked`, so uploads, views, buffer-to-texture copies and memory accounting see one format. Test: `dm/gfx/tests/t_bc6h`.

### Cache misses (`DM_NVN_ASTC_MISS`)

Encoding takes 0.2 to 6 s for one 2048x2048 plane on an M2 Pro (see `t_astc_bench`), so a miss never encodes on the submit thread (the default, `background`). The texture is created and uploaded in its decoded format, exactly as without ASTC; its BC planes (deswizzled, keyed by the same hash) are copied into a queue bounded by `DM_NVN_ASTC_QUEUE_MB` (what does not fit is dropped and counted), and `DM_NVN_ASTC_THREADS` (2) utility-priority threads encode them and write `<key>.astc` into `DM_NVN_ASTC_CACHE` (temporary file, rename). The next launch finds them.

A texture's format is decided once, the first time `bc_astc()` is asked about it (`astc_decision`, nvn_mtl.m), and kept by serial: ASTC when its storage already holds BC data and every plane is in a cache, decoded otherwise (and then its planes are looked up and queued once). Views and buffer-to-texture copies follow the Metal texture's actual format. A plane of an ASTC texture that cannot be read (a file that went corrupt, new content in the same texture) is filled with void-extent blocks and queued, never encoded on the calling thread. A texture made with no data yet (filled later by copies) is decoded.

### Prebuilt cache: `astc-ro.pack`, `bntx_astc.py`

A cache that starts empty only warms while the game is played, and a plane that is still a miss is stored decoded for that run. For a game whose textures are BNTX (or Smash's NUTEXB) they can be encoded before the first launch, on a Mac, by `dm/gfx/tools/bntx_astc.py <RomFS.img or folder> --out DIR [--block 4|6]`, which finds the textures (loose `.bntx`; BNTX inside BFRES; inside zstd, Yaz0 `.szs` and SARC, nested; Super Smash Bros. Ultimate's `data.arc` NUTEXB files through `smash_arc.py`), forms their planes and writes `DIR/astc-ro.pack`. Every step that decides what a key is runs the engine's own code: the tool compiles `nvn_astc_walk_planes` (`nvn_astc_planes.c`, the same function `astc_probe` in `nvn_mtl.m` uses), `nvn_deswizzle`, `nvn_tex_layout`, the key and the encoder (`nvn_astc_cache.m`, `nvn_astc.mm`, the astc-encoder objects with the host Makefile's flags) into one library (`dm/gfx/tools/astc_prebuild.m`) and loads it with ctypes; Python only tells it what the game tells NVN (target, format, size, levels, the packaged layout's byte 0 from the BNTX; a NUTEXB has none and uses the automatic block height, which gives the recorded image size for every BC texture checked). `test_bntx_astc.py` builds textures, runs the tool and then looks every plane up through the runtime's walk and `nvn_bc_astc_learn` / `fetch`, comparing the blocks with the runtime encoder's.

Pack layout (little-endian): a header of 80 bytes (`NXASTCPK`, u32 version 1, u32 index entry size 48, u64 entries, u64 index offset, u64 file size, a 32-byte input fingerprint, 8 zero bytes); the entries, each a complete cache file at a 16-byte boundary; at the end the index, one {32-byte key, u64 offset, u64 size} per key, sorted by key. Two keys may name one entry (BC1 has two NVN formats, RGB_DXT1 and RGBA_DXT1, with the same blocks: the pack answers to both). The runtime maps only the index, binary-searches it and reads an entry with `pread`, checking its hash; a header, size or index that does not hold together makes the whole pack a miss. The fingerprint (the tool's and the engine's sources, the block size, the game files' identity) lets a rerun with nothing changed return at once.

Textures created empty and filled by buffer-to-texture copies (streaming) used to stay decoded for good. With a read-only cache (a pack or a directory) the decision is made at the texture's first copy, before its Metal texture exists (`astc_first_copy`): a copy of a whole level whose plane is in the cache makes the texture ASTC, any other leaves it decoded, and a missed plane is queued for the background encoder (so these textures warm the cache too). The counter line reports `created empty, first filled by copy: N (ASTC via pack M, a piece of a level K; X MB hashed in Y ms)`.

Limits: `DM_NVN_ASTC_CACHE_MAX` (2048 MB, counting what is in the directory), `DM_NVN_ASTC_MIN_FREE_MB` (1024) of disk to leave free. Nothing is ever deleted except stale `<key>.astc.XXXXXX` temporary files, older than an hour, in the cache directory. On tvOS the directories default to `<Library/Caches>/astc-cache` (writable) and `<Library/Caches>/astc-ro` (read-only, if present). One `[dm] ASTC cache:` line at start gives the directories, entries and bytes; the counters follow the `memory up to frame` lines. `DM_NVN_ASTC_MISS=sync` keeps the first version's behaviour (every eligible texture ASTC, a miss encoded on the submit thread) for tests.

`t_astc_bench` prints encode throughput (synthetic planes; no real BC data is in the repository).
