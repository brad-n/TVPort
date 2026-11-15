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
| 2 | Shader trimming (`feat/shader-trim`, built, not run on a TV): ship used shaders compiled, the rest as compressed MSL | **est. 3.6** (5.92 to about 2.3) | **1.05** (2.09 to 1.04, measured by the branch) | S (merge, then TV validation) | Medium. Compiles on the TV (about 76 ms a shader on A15) when a game meets a new shader; the draw is skipped until then. Open: bracket depth 256 against the build's 1024, memory beside the game (2 GB), Metal source cache across launches. Ocarina's TV list has 124 rows; its 11,569 used keys come from the profile's `pso_manifest.tsv` |
| 3 | Pack ASTC 6x6 instead of 4x4 for the formats still at 4x4 (BC5, BC6H, BC7, BC3; BC1 and BC4 are already 6x6) | **est. 1.2** | **0.4** (4.99 to 4.21 GB raw, 0.77 raw) | S (flags exist: `DM_NVN_BC_ASTC`, `--bc5-block`, `--bc6h-block`) | Quality: 3.56 against 8 bits a pixel, unmeasured here (no decode in the tools). BC5 normals and BC6H HDR are the sensitive ones; do BC7 colour first. Build time down, GPU read bandwidth down |
| 4 | Bigger zstd blocks and a higher level for the pack and audio (4 MB blocks with a long window, level 19) | 0.15 pack + 0.2 audio | 0.3 to 0.45 pack | M (block size is a parameter, but runtime reads need a block cache and the format version) | Build time: level 19 is slow (hours to tens of minutes on 8 cores). Run time: a plane read inflates a 4 MB block, so it needs a cache. See the table below |
| 5 | Texture cap 512 for Mario Kart 8 (setting, no code) | - | about 1.3 (pack 9.40 to 4.66 GB raw at 4x4 in the spike, so about half) | none | Visible: course textures are 1024 to 2048 at 1080p |
| 6 | Replace the credits movies with a tiny stub | 0.54 | 0.63 (two credits files) | M | A missing movie can hang the game (movies.md: "waits forever"), so a valid one-second stub is needed; credits are rarely seen |
| 7 | Keep one or two languages (zero the other language sets; holes cost nothing in the sparse image) | 0.27 | 0.10 | M | Switching the in-game language later loads zeros. Low value |
| 8 | Outlined raw lookup (`shader_raw_outline`, f810bdb3) | 0.36 on the 890 seen raw-lookup shaders (592 to 228 MB) | - (Maxwell, no raw lookups) | S, but the GPU slower | Reflection probe faces 0.77 to 1.33 ms. Rejected on the branch. A middle variant that keeps the fast path inline is untested; gain under trimming would stay near 0.36 |
| 9 | Ship only the used shader variants (`_bx` alpha/logic and `_bf` readable-tile are 42% of Ocarina's image and 46% of Mario Kart 8's) | not counted | not counted | L | The TV records keys, not variants; it needs variant-level recording first |
| 10 | Research: Ocarina's baked GI (`extm`, 5.7 GB, incompressible) and its own shader binaries (1.1 GB) | up to 6.8, unknown | - | L | Format unknown; the shader binaries are handed to the host by the game and its hash makes the key |

Combined, if 1, 2, 3 and 4 land: Ocarina about 31.4 to 20.8 GB (down 10.6), Mario Kart 8 about 11.7 to 9.9 GB (down 1.8).

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

## 3. Ranking

Ranked by GB saved, discounted by effort and risk, for these two games and the Switch 2 games like them:

1. **Cut 1: native ASTC above the cap.** Largest single number (est. 5.4 GB of Ocarina's 31), and the mechanism already exists in `tex_once.py` for BC planes. Only helps games with native ASTC (Switch 2 titles), and only with a cap.
2. **Cut 2: shader trimming.** Already built; helps every game, 1.05 GB on MK8 (measured) and an estimated 3.6 GB on Ocarina. Needs a TV run before anything else about it can be claimed. The Ocarina saving rests on its profile list (11.6k keys) and on MSL being 10% of compiled as in MK8.
3. **Cut 3: ASTC 6x6 for BC7 first, then BC5/BC6H.** A flag change with an estimated 1.2 GB (Ocarina) and 0.4 GB (MK8); the cost is image quality that has to be looked at on screen.
4. **Cut 5: MK8 cap 512.** Free and about 1.3 GB, but a visible quality drop; leave to the user.
5. **Cut 4: bigger zstd blocks and level 19.** 0.3 to 0.5 GB, with a format change and slow builds.
6. **Cut 6/7: credits movies, languages.** 0.3 to 0.6 GB each for work and some hang risk.
7. **Cut 8: outlined raw lookups.** Rejected (GPU slower).
8. **Cuts 9/10: variant trimming, baked GI.** Large unknowns; study first.

## 4. Recommendation

Build **cut 1** first: extend `tex_once.py` to treat a native-ASTC plane above the cap as it treats a BC plane above the cap (zero it, recompress the container into its slot, `tex_once` self-check unchanged), and verify on Ocarina that nothing above the cap is read (the `[RED] ASTC: tagged ...` counters stay 0 and Link's house looks the same). Run **cut 2** to the TV in parallel, since it is already built; its first goal is the unknowns (A15 compile time, cache across launches, memory), not size. Hold cut 3 until someone looks at BC7 versus BC5 at 6x6 on a screenshot. Together cuts 1 to 3 take Ocarina from about 31.4 to 21.2 GB and Mario Kart 8 from about 11.7 to 10.3 GB.

## How it was measured

- TV sizes: `xcrun devicectl device info files --device <id> --domain-type appDataContainer --domain-identifier <bundle>` (read only), 2026-11-15.
- Ocarina files: `romfs_image.read_index` over the extracted `RomFS.img`; stored bytes from `SparseImage.extents_ex()` of `tvport-once/romfs.img`, each file's share of every extent it overlaps.
- Ocarina app: `du` of `tvport-derived/.../DmIOS.app` (msl 5.92 GB, binary 111 MB, `dm/` 34 MB, `Assets.car` 18 MB).
- Shader image by kind: `romfs_image.read_index` of `shader/ios/b-<chain>.img`; used keys from `shader_trim.read_used` (feat/shader-trim).
- MK8: `nx_extract --manifest` over the base NSP only; texmap spike JSON; pack file for zstd samples; `tvport-astc/report.json`.
- Texture samples: `bntx_astc.Job` (libastc_prebuild from the Ocarina build, `encode=0`) over 2,000 random `.bntx.zs`, and BNTX mip offsets for cut 1. No ASTC encode or decode ran, so no quality number exists.
- zstd samples: `zstd` CLI over random 256 KiB and 4 MiB slices.
- Not measured: anything on the TV beyond its file list, MK8's TV image content, image quality, build times of the cuts, the Ocarina trimmed-image size (sources are in the 18 GB `cas.db`), the 4.0.1 update's manifest.
