# Store textures once (contract v1)

Status: building (2026-11-07). Owner decision: build it as a TVPort feature for every game; Smash is the first verification game.

## Why
On an A15 Apple TV each BC1/2/3/7 (and unsigned BC4/BC5/BC6H, dm/gfx/tex/README.md) texture is stored twice: the original BC bytes inside romfs.img and the ASTC copy in astc-ro.pack
(dm/gfx/tex/README.md). Measured (spike/texture-once d9f9d29e, ~/workspace/TVPort-texmap/*.json): Smash at cap 512 goes from 26.6 GB to
18.1 GB on the TV (original RomFS 17.6), MK8 at cap 0 from 21.5 to 18.2 GB (4x4).

Switch 2 games (BNTX platform tag `Ounc`, `.bntx.zs` files with or without a `Pack/ZsDic.pack.zs` dictionary) are read the same way; BC4/BC5/BC6H are half of their texture bytes. The signed forms are not covered (they stay in the game files untouched).

## Shape
Build time: every plane the pack covers is overwritten IN PLACE in the game files by a tag + zeros (sizes and offsets never change; compressed
containers are recompressed into their own slot). The result is written as a sparse image (zero runs are not stored) that also carries the
ASTC pack. Run time: a tagged plane goes straight to its pack entry; anything else behaves exactly as today.

## 1. Sparse image: DMSPARS1 (wraps one DMROMFS1 image)
Little-endian. The DMROMFS1 image it represents is the LOGICAL image; byte offsets below are PHYSICAL (in the DMSPARS1 file).

Header, 64 bytes at physical 0:
| off | type | field |
|---|---|---|
| 0 | char[8] | magic `DMSPARS1` |
| 8 | u32 | version = 1 |
| 12 | u32 | header size = 64 |
| 16 | u64 | logical size (bytes of the DMROMFS1 image) |
| 24 | u64 | extent count N (>= 1 unless the logical image is all zero) |
| 32 | u64 | extent table offset (16-byte aligned) |
| 40 | u64 | pack offset (16384-byte aligned; 0 = no pack) |
| 48 | u64 | pack size (0 when no pack) |
| 56 | u64 | reserved, 0 |

Extent table: N entries of 24 bytes `{u64 logical offset, u64 length, u64 physical offset}`, sorted by logical offset, non-overlapping,
length > 0, logical offset + length <= logical size. Logical bytes covered by no extent read as zero.
Writer rules: data extents start at 16-byte aligned physical offsets; a zero run shorter than 4096 bytes is not worth a hole and stays inside
an extent; extents may be split for any reason (readers must not assume maximal runs).

Embedded pack: an unchanged NXASTCPK file (dm/gfx/tex/nvn_astc_cache.m, 80-byte header, sorted 48-byte index) at the pack offset. Its own
offsets are relative to the pack start and its header "file size" equals the pack size.

Trailer, 32 bytes, the last bytes of the file: `char[8] "DMSPEND1"`, `u64 total file size`, `u64 extent table offset`, `u64 0`.
A file whose trailer is missing or disagrees with the header is incomplete (a cut-off copy) and is rejected, like a DMROMFS1 image whose
index does not end the file.

Reading logical [off, off+len): bytes inside an extent come from pread(physical + (off - extent.logical)); others are zero; reads past the
logical size are short, like a file. The DMROMFS1 rules (index written last and ending the logical image, damaged flags) apply to the logical
image unchanged. RomFS identity (dm/host/romfs_identity.h: logical size + hash of header and index) is computed over the LOGICAL image, so
stripping (which never changes the index or the size) keeps the identity of the original RomFS.img.

## 2. Plane tag
For each plane the pack covers and the tool chooses to tag (storage length >= 16 bytes):
- bytes [0, 8) of the plane's stored data (block-linear, exactly as in the file and in guest memory) = the first 8 bytes of that plane's pack key
  (the SHA-256 key nvn_astc_cache computes for the plane at the block size it was packed with);
- bytes [8, length) = 0.
Mip levels the runtime never loads (above the texture cap, nvn_bc_skip_levels) are all zero, untagged. Planes shorter than 16 bytes, planes the
pack does not hold, and planes whose layout the runtime would see differently (layout_differs) are left untouched.

Run time, per plane, before deswizzling and hashing: if length >= 16, bytes [0,8) are not all zero and bytes [8, length) are all zero, look the
8-byte prefix up in the pack's sorted index. Exactly one entry whose ASTC payload size matches the plane's expected ASTC size -> use it
(no deswizzle, no hash). Otherwise fall back to today's path (deswizzle + hash + lookup). Only if that also misses AND the plane looked
tagged, log `[RED] ASTC: tagged plane unresolved` (once per texture, with format/size/level) and count it: such a plane would draw from zeros.
Any BC decode of plane bytes that look tagged (the decoded/CPU path, partial copies) logs `[RED] ASTC: tagged plane decoded` once and counts it.
Counters join the existing ASTC counters line after each `memory up to frame` line: tagged hits, tagged unresolved, tagged decoded.

## 3. Engine (dm/host, dm/ios, dm/gfx)
- Every RomFS image read goes through one sparse-aware read (romfs_image.h loader, hle_fs.c h_fs_ReadFile, iOS startup validation in
  dm/ios/Sources/main.m, mac/launcher.c). A plain DMROMFS1 file keeps working unchanged.
- When the image (romfs.img on tvOS, DM_ROMFS on the Mac) embeds a pack, that pack is the read-only ASTC cache (precedence over
  DM_NVN_ASTC_CACHE_RO and <Caches>/astc-ro.pack). The pack reader takes (fd, offset, size).
- DM_TEST_NO_BC=1 lets the Mac run the tvOS texture path for tests. A stripped image must never be used where BC is native (no_bc() false):
  refuse it with a [RED] line naming the reason.

## 4. Tool: dm/gfx/tools/tex_once.py
`python3 -I dm/gfx/tools/tex_once.py <RomFS.img | build folder> --pack <astc-ro.pack> --out <dir> [--max-dim N] [--block 4|6] [--workers N] [--json]`
- Writes `<dir>/romfs.img` (DMSPARS1, pack embedded) and `<dir>/report.json`; exit 0 only when the self-check passed.
- Skips (exit 0, nothing rewritten) when `<dir>/report.json` records the same input fingerprint (RomFS size+index hash, pack fingerprint, cap, block).
- Container rules (spike section C): loose/uncompressed -> in place; Yaz0 -> recompress, zero tail in the slot (header keeps the decompressed size);
  zstd -> recompress into ONE frame that fills the slot exactly: its head compressed, its tail stored in raw blocks (tex_once_zstd.fill_frame), so the frame
  ends where the file ends, as every original does. It used to be the new stream plus a skippable frame of zeros to the slot's end: Ocarina of Time reads a file in
  902,912-byte pieces and decodes as it reads, and every stripped file larger than one piece was read again and again and never loaded (Link's house had no inside
  walls on the Apple TV, 31 GB read in 100 s). A container no split fits keeps its original stream. A BC texture with no mip chain is never stripped (tex_once SINGLE_LEVEL,
  counted as skipped single_level): Ocarina of Time's baked lighting lit the house's cloth wrongly when stripped (no game code read it from memory under a CPU read trap; its pack
  entries were made in the wrong GOB order, so the rule may go once packs are rebuilt). A Switch 2 game's planes are keyed and encoded in the Switch 2's GOB order (bntx_astc.gob_switch2,
  from the sdk module as the runtime decides; --gob sets it), and the pack's fingerprint holds the order, so a pack of the other order is refused; Smash data.arc -> recompress entries, update each entry's stored size in the zstd-compressed table, rewrite the
  table into its own slot the same way. Anything else holding covered planes: leave untouched and report it.
- Self-check before exit 0: re-walk the logical image with the prebuild's walker; every tagged plane reads tag+zeros and its tag resolves in the
  pack; every other decompressed byte equals the original; every container parses; the DMROMFS1 index is byte-identical.
- report.json: input fingerprint, bytes (logical, physical, pack), counts per container type, planes tagged / zeroed-above-cap / skipped (by reason).

## 5. TVPort (tvport/backend.py, tvport/app)
- Advanced option "Store textures once": Automatic (= On when Compressed textures is on for the Apple TV) / On / Off, saved per game.
- Build: after prebuild_astc, run tex_once.py into <build>/tvport-once/. The app is built with ROMFS=<that romfs.img> (identity unchanged).
- Install: send <build>/tvport-once/romfs.img as Library/Caches/romfs.img (same retries + size verify); do not send astc-ro.pack and remove a stale
  Library/Caches/astc-ro.pack from that game's container.
- If tex_once.py fails, log one warning and install exactly as today (plain RomFS.img + astc-ro.pack). The feature never fails a build.

## 6. Verification before Brad's TV
Mac, on the real stripped images (Smash cap 512, MK8 cap 0): the engine's C sparse reader reads each whole logical image and its SHA-256
matches the tool's logical image; the DMROMFS1 index, file count and RomFS identity match the original RomFS.img; every tag the tool wrote
resolves uniquely, at the expected ASTC size, through the engine's C tag lookup in the embedded pack (`tex_once_verify`). Plus the tool's
self-check and the engine's GPU tests (a tagged plane gives the same ASTC blocks as the hashed path).
Then on the Apple TV (Smash first): `tagged unresolved` = 0, `tagged decoded` = 0, tagged hits > 0 in the counters line, no `[RED] ASTC: tagged`
lines, and Brad sees no black or wrong textures. Fallback: "Store textures once: Off" and rebuild.
(Mac gameplay runs with DM_TEST_NO_BC=1 were dropped: they need macOS shader libraries for each game, hours of shader builds.)

## 7. Lossless compression (contract v2, 2026-11-08)
Goal: shrink what goes to the TV with zstd, losslessly, for every game (with or without a texture pack). Measured on MK8 (zstd -3, 64 KiB
samples): stored game data keeps 82%, ASTC pack payloads keep 53%. Readers stay compatible with every v1 file.

### 7a. DMSPARS1 version 2: compressed extents
- Header version = 2. Extent entries become 32 bytes: `{u64 logical offset, u64 length, u64 physical offset, u32 stored length, u32 kind}`;
  kind 0 = raw (stored length == length), kind 1 = zstd (one zstd frame of exactly `stored length` bytes that inflates to exactly `length`).
- zstd extents are at most 256 KiB of logical data (the tool's default block); raw extents may be any length. A block that does not shrink
  below 97% is stored raw. Holes (no extent) still read as zero.
- The embedded pack stays a separate physical region (16384-aligned, as in v1) and is NOT block-compressed: its index must stay mmap-able
  raw bytes. Pack payload compression is 7b.
- Readers: one shared decompressed-block cache (default 16 MiB, `DM_ROMFS_ZCACHE_MB`), safe for concurrent reads; a read spanning blocks
  decompresses each once; a corrupt frame or a size mismatch is a read error with one `[RED]` line, never silent zeros.
- Trailer and identity unchanged (identity = logical image).

### 7b. NXASTCPK version 2: compressed entries
- Header version = 2, index entry size 56: `{32-byte key, u64 offset, u64 stored size, u64 size}`; an entry whose stored size < size is
  one zstd frame inflating to exactly `size` bytes; stored size == size means raw. `size` is what every size check uses (the tag
  lookup's "expected ASTC size" compares `size`). Index stays sorted by key and mmap-able; v1 packs (48-byte entries) keep working.

### 7c. Tool and TVPort
- `tex_once.py ... --compress auto|on|off` (default auto = on) and `--zlevel N`; the pack embedded in the image is re-written as v2 when
  compressing. `tex_once.py <RomFS.img> --out <dir> --no-pack` writes a compressed DMSPARS1 v2 of a game with no texture pack (nothing
  stripped). Self-check inflates every compressed extent/entry and compares with the source.
- TVPort: Advanced "Compress game data" Automatic (= On) / On / Off. On: every game installs a DMSPARS1 v2 romfs.img (stripped + pack
  when Store textures once applies, else `--no-pack`). Off or any tool failure: today's behaviour.
