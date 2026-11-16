# Apple TV game size: inventory and ranked cuts

Measured 2026-11-15 on the hub mini. Storage on the Apple TV 4K (3rd gen) is the limit, so every GB cut is room for another game. This note lists what an installed game holds, what each size idea would save, what it costs, and what to build first. Nothing here changes the engine; every number comes from a read of the build folders, the TV's file list (`devicectl device info files`, read only) and small samples.

Numbers are decimal GB (10^9) unless marked GiB. `devicectl` prints GiB: Mario Kart 8's `romfs.img` is 8.67 GiB = 9.31 GB, Ocarina of Time's 23.05 GiB = 24.75 GB. Sources of each number are in "How it was measured" at the end. "est." means extrapolated from a sample or from the other game.

## 1. Inventory: what is on the TV

`devicectl device info apps` prints no sizes, so sizes come from the TV's own file list (the data container) plus the build folders for the app bundle (the app is the signed `DmIOS.app` built in the build folder).

| Part | Ocarina of Time (Switch 2, cap 256) | Mario Kart 8 Deluxe (cap 0) |
|---|---|---|
| `Library/Caches/romfs.img` (sparse + zstd, ASTC pack embedded) | 24.75 | 9.31 |
| of which the embedded ASTC texture pack | 2.72 (7.23 raw) | est. 2.4 (4.99 raw) |
| of which game files | 22.02 | est. 6.9 (8.65 raw) |
| Shader libraries `msl/b-<chain>.img` (in the app) | 5.92 | 2.09 |
| Code (`DmIOS` binary) | 0.11 | est. 0.04 |
| Tables and assets (`dm/`, `Assets.car`, manual html) | 0.05 | est. 0.12 |
| Pipeline archive in the app | none (no `--gpu` archive is built) | none |
| Run-time Metal caches the OS keeps (`com.apple.metal`) | 0.46 and growing | 0.08 |
| Run-time ASTC cache (`astc-cache/`, 3,774 files) | 0.07 | about 0 |
| Debug leftovers (screenshots, logs) | 0.05 | 0.01 |
| **Total** | **about 31.4** | **about 11.7** |

The stale `astc-ro.pack` on the TV is 0 bytes for both (the pack is embedded). Nothing else of note.

### 1a. Ocarina of Time: the 22.02 GB of game files in the TV image

Measured per file from the RomFS index against the TV image's stored extents (`tvport-once/romfs.img`, the image that was sent). "Stored" is what the file costs on the TV after textures-once and zstd.

| Kind | Files | Original GB | Stored on TV GB | Note |
|---|---|---|---|---|
| Textures (`.bntx.zs`) | 21,658 | 9.59 | 5.77 | BC planes are already zeroed (pack holds them). What is left is mostly native ASTC at full size, see cut 1 |
| Baked GI (`*.bake_gi.extm`) | 46,324 | 5.71 | 5.68 | stores raw (99.5%): zstd gets nothing |
| Models, terrain, animation (`*bfres*`) | 8,133 | 2.74 | 2.73 | already zstd (`.zs`) |
| Audio (`.bwav`, `bars`) | 28,430 | 2.27 | 2.06 | 14 language sets of about 45 MB inside |
| Collision / probes (`.bkprb.zs`, Phive) | 9,674 | 1.87 | 1.87 | already zstd |
| Video (`.webm`, 26 files) | 26 | 1.64 | 1.64 | Staff credits 0.54, title loops 0.45, cutscenes the rest |
| The game's own shader binaries (`bphsc`, `vsetb`, ...) | 11,000 | 1.13 | 1.11 | the game hands these to the host |
| Culling (`.bcul.zs`) | 35,313 | 0.43 | 0.33 | |
| Terrain height (`.hght`) | 2,655 | 0.29 | 0.29 | |
| Other | 23,370 | 0.57 | 0.54 | |
| **Total** | 186,583 | 26.24 | 22.02 | plus the 2.72 GB pack |

### 1b. Mario Kart 8 Deluxe: the game files

The extracted RomFS of this build is gone from the Mini (the version-4.0.1 update exists only as `.nsz`, and the v3.0.5 update NSP fails its hash check), so MK8 cannot be indexed like Ocarina. The split below is from the base game's manifest (`nx_extract --manifest`, v1.0, 4,669 files, 7.21 GB; version 4.0.1 is 11.57 GB and 6,597 files, 12.13 GB in the Nov 7 spike) and from the Nov 7 texmap spike (`~/workspace/TVPort-texmap/mk8.json`). Treat as estimates.

| Kind (v1.0 base manifest) | Files | GB (original) | On TV |
|---|---|---|---|
| Yaz0 containers `.szs` (courses, map objects, karts: models plus textures) | 1,139 | 3.73 | texture planes zeroed; containers stay Yaz0 and do not compress further |
| Loose `.bfres` models | 583 | 1.32 | partly zeroed textures |
| Videos `.mp4` (StaffCredits 0.317, TrueCredits 0.316, MovieMenu 0.162) | 3 | 0.80 | stored raw (incompressible) |
| Music `.bfstm` | 169 | 0.62 | |
| Sound `.bars` | 737 | 0.31 | 11 language sets of 11.9 MB each (131 MB) |
| `.bntx`, `.sarc`, `.ptcl`, other | rest | 0.43 | |

Texture bytes the pack covers at cap 0: 6.30 GB of original BC planes (zeroed in the TV image), replaced by the 4.99 GB ASTC pack (4x4 for most formats, 6x6 for BC1), about 2.4 GB after zstd (measured ratio 0.483 on a 42 MB sample). The remaining 8.65 GB of game data (12.13 GB minus the zeroed texture bytes) compresses to about 6.9 GB.

## 2. Cuts: what each saves, and what it costs

Savings are GB on the TV, per game, for the two games measured. "-" means the idea does not apply.

| # | Cut | Ocarina | Mario Kart 8 | Effort | Risk and cost |
|---|---|---|---|---|---|
| 1 | Zero the mip levels above the texture cap in native ASTC textures (`tex_once` already does this for the BC planes the pack covers) | **est. 5.4** (up to 5.65) | - (all BC; cap 0) | S to M | Low. The runtime already skips these levels (`nvn_astc_skip_levels`), as it does for BC. The cap becomes baked in: changing it needs a rebuild and resend (already true for BC). Build time: the same recompress-into-slot work as today. Array and cube textures were not counted, so it is a lower bound there |
| 2 | Shader trimming (`feat/shader-trim`, built, not run on a TV): ship used shaders compiled, the rest as compressed MSL. **As built on `tv-all-trim`** ([below](#cut-2-as-built-shader-trimming)): the rest as zstd frames of the build's own libraries, inflated at first use | **est. 3.6** (5.92 to about 2.3); **as built 2.54, measured** (5.92 to 3.38) | **1.05** (2.09 to 1.04, measured by the branch); **as built 0.87, measured** (2.09 to 1.21) | S (merge, then TV validation) | Medium. Compiles on the TV (about 76 ms a shader on A15) when a game meets a new shader; the draw is skipped until then. Open: bracket depth 256 against the build's 1024, memory beside the game (2 GB), Metal source cache across launches. Ocarina's TV list has 124 rows; its 11,569 used keys come from the profile's `pso_manifest.tsv`. As built: no compile and no skipped draw (a miss is an inflate of the build's bytes), for about 1 GB less saving on Ocarina |
| 3 | Pack ASTC 6x6 instead of 4x4 for the formats still at 4x4 (BC5, BC6H, BC7, BC3; BC1 and BC4 are already 6x6) | **est. 1.2** | **0.4** (4.99 to 4.21 GB raw, 0.77 raw) | S (flags exist: `DM_NVN_BC_ASTC`, `--bc5-block`, `--bc6h-block`) | Quality: 3.56 against 8 bits a pixel, unmeasured here (no decode in the tools). BC5 normals and BC6H HDR are the sensitive ones; do BC7 colour first. Build time down, GPU read bandwidth down |
| 4 | Bigger zstd blocks and a higher level for the pack and audio (4 MB blocks with a long window, level 19) | 0.15 pack + 0.2 audio | 0.3 to 0.45 pack | M (block size is a parameter, but runtime reads need a block cache and the format version) | Build time: level 19 is slow (hours to tens of minutes on 8 cores). Run time: a plane read inflates a 4 MB block, so it needs a cache. See the table below |
| 5 | Texture cap 512 for Mario Kart 8 (setting, no code) | - | about 1.3 (pack 9.40 to 4.66 GB raw at 4x4 in the spike, so about half) | none | Visible: course textures are 1024 to 2048 at 1080p |
| 6 | Replace the credits movies with a tiny stub | 0.54 | 0.63 (two credits files) | M | A missing movie can hang the game (movies.md: "waits forever"), so a valid one-second stub is needed; credits are rarely seen |
| 7 | Keep one or two languages (zero the other language sets; holes cost nothing in the sparse image) | 0.27 | 0.10 | M | Switching the in-game language later loads zeros. Low value |
| 8 | Outlined raw lookup (`shader_raw_outline`, f810bdb3) | 0.36 on the 890 seen raw-lookup shaders (592 to 228 MB) | - (Maxwell, no raw lookups) | S, but the GPU slower | Reflection probe faces 0.77 to 1.33 ms. Rejected on the branch. A middle variant that keeps the fast path inline is untested; gain under trimming would stay near 0.36 |
| 9 | Ship only the used shader variants (`_bx` alpha/logic and `_bf` readable-tile are 42% of Ocarina's image and 46% of Mario Kart 8's) | not counted | not counted | L | The TV records keys, not variants; it needs variant-level recording first |
| 10 | Research: Ocarina's baked GI (`extm`, 5.7 GB, incompressible) and its own shader binaries (1.1 GB) | up to 6.8, unknown | - | L | Format unknown; the shader binaries are handed to the host by the game and its hash makes the key |

Combined, if 1, 2, 3 and 4 land: Ocarina about 31.4 to 20.8 GB (down 10.6), Mario Kart 8 about 11.7 to 9.9 GB (down 1.8). With cut 2 as built (2.54 and 0.87 GB): Ocarina about 21.9 GB (down 9.5), Mario Kart 8 about 10.1 GB (down 1.6).

### zstd on samples (cut 4)

Ratios (compressed / original) on 256 KiB blocks (what the image uses) and on 4 MiB blocks with `--long=27`, from random samples of the read-only files:

| Sample | L3 256K | L9 256K (shipped) | L19 256K | L9 4M | L19 4M |
|---|---|---|---|---|---|
| Mario Kart 8 ASTC pack (42 MB) | 0.496 | 0.483 | 0.461 | 0.423 | 0.401 |
| Ocarina ASTC pack (42 MB) | 0.409 | 0.402 | 0.389 | 0.419 | 0.400 |
| Ocarina `.bwav` audio (21 MB) | 0.891 | 0.885 | 0.863 | 0.808 | 0.790 |
| Ocarina `.bkprb.zs`, `.bntx.zs`, `bfres.zs`, `.webm` | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 |

Only the pack and audio gain. A trained dictionary was not tried: pack payloads are ASTC blocks of 10 KB and up, where dictionaries help little. Everything else is already compressed.

### ASTC 6x6 on the planes (cut 3)

Byte counts from the engine's own plane walk over 2,000 random Ocarina `.bntx.zs` files at cap 256 (897 converted textures, 558 MB of pack payload), with the 6x6 size computed from each plane's dimensions:

| Format | Planes | At today's block (MB) | At 6x6 (MB) |
|---|---|---|---|
| BC5U | 1,117 | 198.0 | 88.3 |
| BC7 | 237 | 163.0 | 72.7 |
| BC6HU | 148 | 151.7 | 67.7 |
| BC4U (already 6x6) | 5,579 | 40.7 | 40.7 |
| BC7 sRGB, BC1, BC3 | 929 | 4.9 | 3.8 |
| **Total** | | **558.3** | **273.3 (-51%)** |

Applied to Ocarina's 7.23 GB raw pack and its 0.40 zstd ratio: about 1.2 GB. For Mario Kart 8 the spike's own totals say 4.99 GB raw today against 4.21 GB at 6x6 everywhere (0.77 raw, about 0.4 after zstd); MK8's non-BC1 textures are a smaller share (BC5 signed, 1.9 GB, is not covered by the pack at all). The picture cost was not measured.

### Native ASTC mips above the cap (cut 1)

Same 2,000-file sample. Textures already ASTC in the file (the Switch 2's own) and their mip levels above 256, taken from the BNTX mip offsets for 2D textures:

| | Textures | Stored MB | Above cap MB |
|---|---|---|---|
| Native ASTC | 786 | 368.5 | 346.3 (94%) |
| BC and other (zeroed by tex_once already) | 714 | 219.1 | 106.3 |

Scaled by the sample's share of the 9.59 GB of texture files (x16.3): about 5.65 GB of native-ASTC bytes the runtime never loads at cap 256; the TV image's 5.77 GB of remaining texture bytes agrees. The planned figure of 5.4 GB leaves room for arrays and for slack.

### Shaders (cut 2)

Compiled image by file kind, with the used keys counted from the profile's `pso_manifest.tsv` plus `tvport-shaders.tsv` (`shader_trim.read_used`):

| | Ocarina | Mario Kart 8 |
|---|---|---|
| Image (MB) | 5,917 | 2,085 |
| `_b` library / `_bx` alpha-logic / `_bf` tile / `_bp` pulling / `_bv` / json (MB) | 2,423 / 1,796 / 677 / 541 / 315 / 165 | 714 / 663 / 297 / 273 / 45 / 94 |
| Keys: all / used | 42,848 / 11,569 | 29,651 / 12,651 |
| Bytes of used keys (MB) | 1,930 (33%) | 917 (44%) |
| Branch result: trimmed image | est. 2,300 (the rest as MSL at MK8's 10%) | 1,043 (branch measurement) |
| As built (the rest as zstd frames of their libraries): trimmed image | 3,378 (measured) | 1,213 (measured) |

## 3. Ranking

Ranked by GB saved, discounted by effort and risk, for these two games and the Switch 2 games like them:

1. **Cut 1: native ASTC above the cap.** Largest single number (est. 5.4 GB of Ocarina's 31), and the mechanism already exists in `tex_once.py` for BC planes. Only helps games with native ASTC (Switch 2 titles), and only with a cap.
2. **Cut 2: shader trimming.** Already built; helps every game, 1.05 GB on MK8 (measured) and an estimated 3.6 GB on Ocarina. Needs a TV run before anything else about it can be claimed. The Ocarina saving rests on its profile list (11.6k keys) and on MSL being 10% of compiled as in MK8. As built ([below](#cut-2-as-built-shader-trimming)): 2.54 GB on Ocarina and 0.87 GB on MK8, measured, with misses that compile nothing.
3. **Cut 3: ASTC 6x6 for BC7 first, then BC5/BC6H.** A flag change with an estimated 1.2 GB (Ocarina) and 0.4 GB (MK8); the cost is image quality that has to be looked at on screen.
4. **Cut 5: MK8 cap 512.** Free and about 1.3 GB, but a visible quality drop; leave to the user.
5. **Cut 4: bigger zstd blocks and level 19.** 0.3 to 0.5 GB, with a format change and slow builds.
6. **Cut 6/7: credits movies, languages.** 0.3 to 0.6 GB each for work and some hang risk.
7. **Cut 8: outlined raw lookups.** Rejected (GPU slower).
8. **Cuts 9/10: variant trimming, baked GI.** Large unknowns; study first.

## 4. Recommendation

Build **cut 1** first: extend `tex_once.py` to treat a native-ASTC plane above the cap as it treats a BC plane above the cap (zero it, recompress the container into its slot, `tex_once` self-check unchanged), and verify on Ocarina that nothing above the cap is read (the `[RED] ASTC: tagged ...` counters stay 0 and Link's house looks the same). Run **cut 2** to the TV in parallel, since it is already built; its first goal is the unknowns (A15 compile time, cache across launches, memory), not size (as built, the A15 inflates instead of compiling: [what the TV run must confirm](#what-the-tv-run-must-confirm)). Hold cut 3 until someone looks at BC7 versus BC5 at 6x6 on a screenshot. Together cuts 1 to 3 take Ocarina from about 31.4 to 21.2 GB and Mario Kart 8 from about 11.7 to 10.3 GB.

## How it was measured

- TV sizes: `xcrun devicectl device info files --device <id> --domain-type appDataContainer --domain-identifier <bundle>` (read only), 2026-11-15.
- Ocarina files: `romfs_image.read_index` over the extracted `RomFS.img`; stored bytes from `SparseImage.extents_ex()` of `tvport-once/romfs.img`, each file's share of every extent it overlaps.
- Ocarina app: `du` of `tvport-derived/.../DmIOS.app` (msl 5.92 GB, binary 111 MB, `dm/` 34 MB, `Assets.car` 18 MB).
- Shader image by kind: `romfs_image.read_index` of `shader/ios/b-<chain>.img`; used keys from `shader_trim.read_used` (feat/shader-trim).
- MK8: `nx_extract --manifest` over the base NSP only; texmap spike JSON; pack file for zstd samples; `tvport-astc/report.json`.
- Texture samples: `bntx_astc.Job` (libastc_prebuild from the Ocarina build, `encode=0`) over 2,000 random `.bntx.zs`, and BNTX mip offsets for cut 1. No ASTC encode or decode ran, so no quality number exists.
- zstd samples: `zstd` CLI over random 256 KiB and 4 MiB slices.
- Not measured: anything on the TV beyond its file list, MK8's TV image content, image quality, build times of the cuts, the Ocarina trimmed-image size (sources are in the 18 GB `cas.db`), the 4.0.1 update's manifest.

### Cut 3 measured: ASTC 6x6 quality and size (2026-11-15)

Planes sampled from Ocarina's TV build (cap 256), encoded with the pack's own encoder (astcenc FASTEST), decoded and compared with the decoded BC source (BC6H on a tone-mapped scale):

| Format | Planes | 4x4 median PSNR / SSIM | 6x6 median PSNR / SSIM | 6x6 worst |
|---|---|---|---|---|
| BC7 | 19 | 41.3 dB / 0.991 | 33.9 dB / 0.950 | 31.0 dB / 0.929 |
| BC7 sRGB | 31 | 45.4 dB / 0.993 | 36.5 dB / 0.968 | 26.4 dB / 0.886 |
| BC5 | 54 | 46.4 dB / 0.997 | 38.2 dB / 0.979 | 22.9 dB / 0.854 |
| BC6H | 28 | 50.8 dB / 0.999 | 39.5 dB / 0.992 | 24.9 dB / 0.923 |

BC5 normal maps: median mean angular error after renormalising 0.51 deg at 4x4, 1.38 deg at 6x6 (99th percentile 5.7 and 10.2 deg). Zoomed, 6x6 shows block seams in smooth normal gradients and loses the finest relief; BC7 smears fine streaks (grain, hair); typical BC6H light maps are indistinguishable. On the Mac with the TV texture path (4x4 against 6x6 for every format, BC5 included; house, forest, balcony, inside), the screenshots show no texture difference at the TV's render scale.

Pack payload on Ocarina (cap 256, from the engine's plane walk, which matches the built pack byte for byte): 7.22 GB at today's blocks; 4.98 GB with BC7 and BC6H at 6x6 (-2.24 GB raw, about 0.9 GB after zstd); 3.48 GB with BC5 at 6x6 too (-3.73 GB raw, about 1.5 GB). TVPort's Matched default is BC7 and BC6H at 6x6 and BC5 at 4x4; `--astc-bc5-block 6` takes the rest.

## Cut 2 as built: shader trimming

Built and measured 2026-11-15 on branch `tv-all-trim` (on tvport 73c4893e, build 1994, chain `f1f54db8499f`); TVPort's *Trim shaders*, off by default until an Apple TV run confirms it. The earlier `feat/shader-trim` (MSL compiled on the device) was not merged: this is the same idea with another miss form, for the reasons below. Nothing here ran on a TV.

### Design

- **What ships as it is:** every shader a list names, with all its files: the Apple TV's recorded list (`<build>/tvport-shaders.tsv`, kept by `remember_shaders`), the profile's prewarm list (`pso_manifest.tsv`) and its playtests' list (`shader_seen.tsv`): S and C rows, both keys of R rows, the task and mesh keys of M rows, key-only lines. A named shader keeps every variant the build made (`_b`, `_bx` alpha test and logic operation, `_bf` readable tile, `_bp` pulling, `_bv` shadow input, its reflection): the device records shaders, not variants (cut 9). Also kept: every compute, geometry, tessellation, task and mesh shader (Ocarina: 4,645, 0.22 GB), the pair libraries (`<vertex>_<geometry>_m3`) and every file that is not a shader's (the stamp, the markers).
- **What is kept for a miss:** every other vertex and pixel shader, packed as one zstd frame, `<key>.trim`, of its own build output byte for byte: its libraries (the build's AIR) and its reflection. Level 19, a 1 MB dictionary trained on the game's own packed shaders (`trim.dict`), a content checksum; `trim.tsv` indexes them. Same image format (`shader_lib.py`), so the app, `pack_ipa.py` and the host read it as before; the shader map does not change. `dm/gfx/tools/shader_trim.py split` makes it, `check` inflates every frame against the index.
- **How a miss is served** (`dm/gfx/nvn/nvn_shader_trim.inc`): the first read of any file of a packed shader (its reflection in `shader_load`, a library in `lib_from_file`: the draw, the parallel prefetch of the submission, the prewarm of a recorded list) inflates the shader's frame into `Library/Caches/shader-trim/<image id>/` and maps the file from there as a library folder's file is mapped. The thread that asks first inflates; another asking meanwhile waits for it. Nothing is skipped and nothing is compiled from source: the library is the full build's, so the picture and the pipeline compile are what an untrimmed app has for a shader it meets for the first time. The next start takes the files from the cache folder without inflating. `pso_user.tsv` records the shader as any other, `remember_shaders` brings it into `tvport-shaders.tsv` at the next install, and the next build ships it as it is.
- **What does not inflate:** the pipeline prebuild, which walks every pair the profile knows (Ocarina: 34,649 with `pso_pairs.tsv`) and would unpack them all: a packed shader counts there as a file the app does not carry until something has drawn with it (`msl_has`, as for a partial library), so its bases are built at its draws. Nor does the prefetch at program creation (below): a packed shader waits for a draw.
- **Cache folder:** one per trimmed image (an install of another one removes the others at the first use), emptied at the start when it holds more than `DM_SHADER_TRIM_CACHE_MB` (1024); `DM_SHADER_TRIM_CACHE` moves it.

### Why the build's libraries (AIR) and not MSL

A miss needs either the AIR (a `.metallib` is AIR: the device's GPU compiler turns it into machine code at pipeline creation, for every library) or the MSL, which the device would first have to compile to AIR with `newLibraryWithSource`. MSL is smaller, but that compile cannot be the build's:

| | MSL compiled on the device (`feat/shader-trim`) | AIR inflated (this branch) |
|---|---|---|
| Compile flags | `MTLCompileOptions` has no `-O1` (the front end's `-O2` turned Odyssey's alRenderMaterialUber into a 25-minute GPU compile), no `-fwrapv` (without it Ocarina's mesh shader 35785cddc971290c took its probe UVs from the wrong bits: the bright band on the Deku Tree), no `-fbracket-depth=1024` (the device keeps 256: a shader that needs more fails; none of the 150 here did); the OS's compiler, not the build's | the build's bytes |
| Cost of a miss | front end on the device: Ocarina's sources on this Mac (150 random packed shaders, `newLibraryWithSource`, relaxed math, invariance, MSL 3.2): 218 ms a shader on one thread (median 154, p90 441, max 1,816 ms), 84 ms a shader with 3 threads; the A15 is slower (the spike: 46 to 129 ms a shader for Mario Kart's and Smash's far smaller ones). The draw is skipped until it is done | an inflate, below |
| Across launches | Metal's source cache (the spike saw it persist; eviction unknown) | the cache folder, ours |
| Ocarina's packed set (27,898 shaders, 3.85 GB of libraries) | about 0.25 to 0.4 GB (their plain sources, 2.86 GB, are 0.22 GB at 12.8x with a dictionary; the variants' sources add to that) | 1.30 GB (2.96x) |

So AIR costs Ocarina about 1 GB of the saving and buys a miss that is exact and about two hundred times cheaper on this Mac (1 ms against 218). The size of the AIR frames was tried several ways on 800 packed Ocarina shaders: a frame per file 2.36x (110 KB dictionary) / 2.47x (1 MB), a frame per shader 2.68x / 2.80x, xz -9e per shader 2.60x, 32 shaders a frame 2.78x without a dictionary: a frame per shader with the 1 MB dictionary is kept (one inflate per miss, nearly the best ratio).

### Sizes

| | Ocarina of Time | Mario Kart 8 Deluxe |
|---|---|---|
| Library measured (the last TV builds: chain f3679572b069 / 1d619d0f520b) | 5.917 GB, 42,848 shaders | 2.085 GB, 29,651 shaders |
| Lists (keys) | 11,889 (TV 189, manifest 11,579, seen 7,278) | 12,651 (TV list, manifest) |
| Kept as it is | 2.071 GB | 0.918 GB |
| Packed | 27,898 shaders, 3.849 GB into 1.300 GB (2.96x) | 16,988 shaders, 1.170 GB into 0.290 GB (4.03x) |
| **Trimmed library** | **3.378 GB (-2.54 GB, -43%)** | **1.213 GB (-0.87 GB, -42%)** |
| Split time (4 threads, the Mac busy with a shader build) | 623 s | 365 s |
| Chain f1f54db8499f, from the seen subset | 14,855 shaders built: 1.092x the old chain's bytes (listed 1.115x, unlisted 1.041x); unlisted pack 2.79x. Full library est. 6.46 GB, trimmed est. 3.67 GB (-2.8 GB) | not built |

`shader_trim.py check` inflated all 27,898 of Ocarina's frames against the index in 7.9 s (one thread, Python), 0 problems. The earlier MSL branch measured Mario Kart at 1.043 GB: AIR costs it 0.17 GB.

### The miss: cost and behaviour

- **Inflate on this Mac** (M2 Pro, one thread, nothing else running; `inflbench` over 2,000 packed shaders of the new chain with the vendored decoder, as the host does it): 1.0 to 1.2 ms a shader (150 to 175 KB of files in 3 or 4 files): reading the frame 0.16 to 0.25 ms, inflating 0.18 to 0.21 ms (825 MB/s), writing the files 0.64 to 0.75 ms; the longest 7 to 11 ms. On the A15 (a core about 15 % slower, other flash) about 1.5 to 2.5 ms a shader, estimated: under 1 % of an MSL front end.
- **Mac runs** (`scripts/bench.py`, route `balcony-still` from the balcony save: the title, the save loaded, Kokiri Forest from above, a 30 s window; the TV-like switches of the Mac bench, `DM_PSO_PREBUILD=0`, a pipeline archive shared by every run; the new chain's seen subset, 14,855 shaders, as the library; two runs a variant, the variants in turn; base and real in a first set, nopw and stress in a second, after the change below):

| Variant | Library | Packed shaders inflated | Window: fps / frame p99 / max ms | Frames over 100 ms (whole run) | Frame 3000 reached |
|---|---|---|---|---|---|
| base | whole, profile prewarm list | - | 28.7 / 52.7 / 185 | 11, 12 | 77.1, 78.4 s |
| real | trimmed with the TV build's lists (4,989 packed), prewarm list | **0** (both runs) | 28.75 / 52.3 / 187 | 14, 13 | 78.2, 78.2 s |
| nopw | whole, no prewarm list (`DM_PSO_MANIFEST=off`) | - | 28.8 / 52.5 / 185 | 12, 12 | 76.3, 76.1 s |
| stress | trimmed with the Apple TV's list alone (13,393 of 14,855 packed: every shader the route draws is a miss), no prewarm list | 717 in run 1 (107 MB, 593 ms in all, longest 4.2 ms; the logged ones on the game's presentation thread, which the draws ran on); **0 in run 2, 717 from the cache folder** | 28.75 / 52.5 / 185 | 13, 13 | 77.1 (+0.9 s), 76.1 s |

The screenshots after the window differ between any two runs of one variant as much as between variants (mean absolute difference 4.8 to 6.8 of 255: Navi, the leaves); the picture with every drawn shader inflated is the balcony as it is with the whole library. No red line in any trimmed run beyond the variant's untrimmed twin (the 2,023 `failed to load shader` lines of the prewarm runs are the list's shaders the seen subset never built).

So a cold miss is a stall on the thread that draws, about 1 ms on the Mac, and nothing else: the window's frame times, the picture and the red lines do not change, a scene that meets 717 new shaders at once loads about 0.9 s later the first time, and not at all later from the cache folder. With the TV build's lists, the route met no packed shader.

**The prefetch at program creation is left out.** The first version inflated a packed shader wherever it was first loaded, which included the prefetch at program creation (`mtl_prog_prefetch`): on the stress variant that inflated 7,061 shaders (24,799 files, 1.28 GB in the cache folder, 19 s of inflating on the prefetch workers) for the 752 the route drew, the start reached frame 1400 about 2.5 s later, and the second start found the cache folder over its 1 GB limit and emptied it. The game makes programs for far more shaders than it draws; packed ones now wait for a draw (`DM_SHADER_TRIM_PREFETCH=1` brings the old behaviour back).

### Risks

- **Disk:** the cache folder grows with what is played until the next install moves those shaders into the shipped set; a player who sees most of the game before reinstalling holds them twice (packed and inflated). The 1 GB limit empties it at a start.
- **A miss stalls the thread that draws** for the inflate, about 1 ms a shader on the Mac (measured above); a scene with hundreds of new shaders loads a little later the first time.
- **Pipelines:** a packed shader's bases are built at its draws, not by the background prebuild, until it has been drawn once; an offline `--gpu` archive covers only the shaders kept as they are.
- **A frame that does not inflate** (damaged, a full disk) is that shader not loading: one red line, as a missing library today.
- **Storage purge:** tvOS may empty `Library/Caches`; the shaders are inflated again.
- **Memory:** an inflated library is a mapped file like the image's own entries (pages the system can drop); an inflate holds its frame and its output, a few MB at most, while it runs.

### What the TV run must confirm

1. The trimmed app installs and starts: `shader trimming: N vertex and pixel shaders of this library are packed` in `Documents/log.txt`.
2. The A15's cost: the `inflated from the library (... ms, on ...)` lines and the `shader trimming so far` lines (count, total and longest ms, how many on a thread a frame waits on); a new area's first visit should cost about a second at most, as on the Mac.
3. A second launch over the same route: `taken from the cache folder`, nothing inflated.
4. The picture and the frame times equal an untrimmed build's on the same route (house, balcony, forest), and memory (the footprint lines) does not rise.
5. The cache folder's size after a session (`devicectl device info files`), and that `Library/Caches/shader-trim` survives a relaunch.
6. After a reinstall, the shaders inflated before ship as they are (`tvport-shaders.tsv` names them: the pipelines drawn with them are its R rows).
