# Ocarina of Time (Switch 2, `0400486024DEC000`) on the Apple TV 4K (3rd generation): a low-memory attempt

Status: research, 2026-11-08. Nothing here has been run on the TV. Brad expects it to fail; the point is to get as far as possible (lower FPS is fine) and see exactly where it breaks. Evidence is tagged **measured** (a number in the repo or a PR), **code** (read from the tree) or **guess**.

Target: A15, tvOS ends the app at about 2.1 GB of `phys_footprint`; no BC formats; ASTC LDR supported. On tvOS the file-backed guest memory is not counted, Metal allocations and the host heap are.

## 1. What upstream actually did for low-memory Switch 2 games

The recipe was found on Mario Kart World (MKW), on iPhones with 8 GiB and 12 GB, and Ocarina's own iPad report.

| Piece | Key | What it does | Measured effect | In this tree |
|---|---|---|---|---|
| Guest memory in unlinked sparse files | `DM_GUEST_FILE=1`, `DM_GUEST_FILE_CHUNK` (1G default; 512M used on the 18 Pro), `DM_GUEST_FILE_MIN_FREE` | Guest pages become file pages: out of `phys_footprint`, written out by the kernel under pressure | MKW 16 GB Mac peak footprint 11.6 -> 5.6 GiB (the same build with a larger view cache: 4.4-4.8 GiB); 8 GiB iPhone 18 Pro finishes races, 4.41 GB max over 13 min (docs/reference/memory.md, "iOS ends the app once the guest's touched pages reach its memory limit"; PR #1315) | yes; on iOS/tvOS on automatically when the pool is larger than the room at start (Ocarina: 9 GiB pool, so yes) |
| Application pool limit | profile `mem_map_limit on` | A map past the pool fails as on Horizon, so the SDK allocator hands back the pages it caches. Z-A: a 3.15 GB cached block was unmapped | Z-A: one refused map, then a 3.15 GB unmap. PR #1444 reports a black screen leaving the Deku Tree without it | yes, in the Ocarina profile already |
| Bigger texture view cache | `DM_NVN_VC_WAYS=64` (fork patches a7af145, 54d8697) | Fewer views rebuilt per texture, so fewer transient Metal textures | Part of the 4.4-4.8 GiB MKW runs. Not on main: `VC_WAYS` is a compile-time 4 (`nvn_mtl.m` ~6137) | no |
| Soft textures | `DM_NVN_TEX_SOFT`, `DM_NVN_TEX_RELEASE` (PR #1599, open) | Large BC texture's host texture made from level 1 (half size); guest pages only level 0 holds are released after 300 frames | MKW on an iPhone Duo, 4.2 min drive: footprint 3,737-3,868 MiB against 4,457-5,262 (peak 5,708) without; wrapped pools 3.7 GB -> 851 MB (fork's figure). The release part is a no-op when the guest is file-backed (PR text) | no |
| Mip omission | `DM_NVN_TEX_MIP_SKIP=<px>`, `DM_NVN_TEX_MIP_LEVELS=1..3` (PR #1418, open; its parent #1319 closed) | Drops 1-3 finest levels of compressed 2D / array / cube textures; a quarter of the memory per level dropped | Fixture only; "no standalone Ocarina measurement, no iPhone result" (PR text). #1319 aimed at an 8 GB Mac: PRAGMATA | no |
| Staging shrink | `DM_NVN_UPLOAD_IDLE_MS` (PR #1491) | Idle upload staging blocks go back | Ocarina on an M4 Pro: slots held 192 MB at every 30 s line with `0`, 0 MB in play with 2000. GPU time unchanged. Ocarina's iPad OOM report listed `private buffers 8, 224 MB` | yes, 2000 ms default on iOS/tvOS (commit a852395e) |
| Staging and texture budget from the real limit | none (automatic; `mem_limits.h`) | `os_proc_available_memory()` sets the staging block (16 MB on the TV, 96 MB retained at worst), batch (about 59 MB) and a texture creation budget (avail/16, about 118 MB) | arithmetic in the commit message, no run | yes (commit e2c9cfdb) |
| Pool unwiring | `DM_NVN_POOL_UNWIRE` | Takes memory pools the GPU stopped addressing out of the residency set | TotK on the TV: 590 MB of pools left in one pass, wired memory stayed near 1.2 GB instead of rising 742 -> 1,830 MB | yes, default on iOS/tvOS |
| Readback autorelease pools | none | Fixed Metal buffers kept alive on game threads | TotK on the TV: 2,480 buffers / 1,005 MB leaked by 100 s, then the game was ended at the limit; with the fix flat at 1.15 GB | yes |
| Store textures once | TVPort "Store textures once" (docs/texture_once.md) | Disk only: BC planes zeroed in the image once the ASTC pack has them | Smash 26.6 -> 18.1 GB on the TV (disk) | yes, on `feat/tex-once-int` |

Not found in this tree: `tex_soft`, `tex_release`, `DM_NVN_TEX_MIP_SKIP`, `DM_NVN_VC_WAYS`.

What the survey attributed MKW's 11.6 -> 4.4-4.8 GiB to is confirmed by the memory.md entry: guest file (11.6 -> 5.6), then the map limit and the larger view cache (5.6 -> 4.4-4.8). None of it targets Metal textures, which is where Ocarina's weight is.

## 2. Mapping to tvOS / A15 for Ocarina

Ocarina on a 16 GB Mac, measured: 6.4 GB guest + 3.8 GB Metal textures and targets + 1 GB IOAccelerator = 10.9-11.4 GB. On the TV the 6.4 GB guest is file-backed (not counted, but it must page through about 4 GB of RAM: expect stalls, see TotK's seconds-long area-load stalls). The counted part is therefore roughly the 3.8 GB + 1 GB, against 2.1 GB. Textures alone already exceed the limit on the Mac figure, so every texture byte matters.

| Item | Status on the TV |
|---|---|
| `DM_GUEST_FILE=1` | Applies; already automatic. Setting it explicitly only pins it. |
| `mem_map_limit on` | Already in `game.tsv`. |
| `DM_NVN_POOL_UNWIRE`, `DM_NVN_UPLOAD_IDLE_MS`, memory-sized staging | Already default on tvOS. Staging is at most 96 MB retained; small. |
| `DM_NVN_VC_WAYS` | Does not exist. Its effect is churn, not footprint. |
| `DM_BC_MAX_DIM` ("Texture detail": 0, 1024, 512, 256) | Applies to BC textures only. `nvn_bc_skip_levels` (dm/gfx/tex/nvn_astc_planes.c:50) returns 0 unless the format is one `nvn_bc_unpacked` accepts (BC1-7, BC6H, nvn_bcdec.c:19) and the target is 2D or 2D array. **Native ASTC textures (40% of Ocarina's) are not capped. This is the biggest gap.** |
| `DM_NVN_BC_ASTC=6`, `DM_NVN_BC1_ASTC=6` | Applies. BC1/2/3/7 as ASTC 6x6 (about 3.6 bits/texel) instead of RGBA8 (BC1 8x smaller, BC2/3/7 about 4x+). Needs the prebuilt pack, which TVPort builds with `bntx_astc.py` over the RomFS: unverified for Ocarina's texture container (**guess**: BNTX, as in the Tears of the Kingdom layout). A miss uploads decoded and costs RGBA8. |
| BC4/BC5/BC6H (39% of Ocarina's textures) | Still decoded on the A15: R8, RG8, RG11B10 (or RGBA16F), so 2x/2x/4x. Another builder is adding ASTC conversion. Until then these are only reduced by the cap. |
| Handheld (`DM_OPMODE=0`) | Applies. The game picks lower internal resolution in handheld, so its render targets shrink (**guess**: not measured for Ocarina; Docked top is 1536x864 on the Mac). Probably the largest cheap saving for the IOAccelerator part. |
| `DM_RENDER_SCALE` | **No effect for Ocarina.** It needs a render-scale stub from the rewriter (`RENDER_SCALE` fixup, patch_nso.py:1524); the profile has no patches ("no rewriter patches"). The TVPort "3D resolution" setting writes the key and the game ignores it. |
| `DM_FPS_TARGET` | Ocarina has no fps_target row (none in `game.tsv`); likely ignored unless the rewriter finds the field. It would not save memory anyway. |
| Dynamic resolution render targets | Open item in the game note: targets that move with dynamic resolution (1580 -> 1579 ...) each get a new Metal texture, about 2 GB added to the residency set per 300 frames on the Mac (depth buffer fixed in 863bc6b7, PR #1557; the rest not). On a 2.1 GB limit this alone could end the run. A fixed resolution would stop it, but the render scale stub does not exist. Handheld may still drift. |
| Upscaler | The game's own NDSR network (compute) runs by default (`DM_UPSCALER=game`). `DM_UPSCALER=metalfx` replaces it with MetalFX's spatial scaler: untested, may drop intermediate buffers. |
| ASTC pack side effects | `DM_NVN_ASTC_MAP_CACHE=0` avoids a 512 MB reclaimable file mapping; queue memory defaults to 64 MB on tvOS. |
| Pipeline archive | Ocarina has no bundled `pso_mtl4` on iOS; the pre-play list is all a first start has. Expect minutes of black screen first (issue #1477 on a Mac was 252 s for one frame). Not a memory issue but it will look like a failure. |

## 3. Deliverable A: the configuration to try

TVPort Performance settings (Advanced as noted):

| Setting | Value | Reason |
|---|---|---|
| Console mode (render mode) | Handheld (`DM_OPMODE=0`) | lower game resolution, smaller render targets |
| Texture detail | 256 (`DM_BC_MAX_DIM=256`); the first attempt can use 512 to compare | largest cut available, BC only; also fixes the prebuilt pack's plane set |
| 3D resolution | 50% | no effect on this build (no stub); set it anyway, the log line will confirm it was ignored |
| Frame rate | 30 | no effect on memory and may be ignored; lower is fine |
| Compressed textures | On, 6x6 for all | BC1/2/3/7 stored as ASTC 6x6 instead of RGBA8 |
| Store textures once | Automatic (On) | disk only, makes the 25.6 GB game plus pack fit |
| Game memory paging | On | pins `DM_GUEST_FILE=1` |

Extra environment switches:

```
DM_GUEST_FILE=1
DM_GUEST_FILE_CHUNK=512M
DM_GUEST_FILE_MIN_FREE=2G
DM_NVN_POOL_UNWIRE=1
DM_NVN_UPLOAD_IDLE_MS=500
DM_NVN_ASTC_MAP_CACHE=0
DM_NVN_ASTC_THREADS=1
DM_NVN_ASTC_QUEUE_MB=16
DM_NVN_BC_ASTC=6
DM_NVN_BC1_ASTC=6
DM_MEMSTAT=memstat.tsv
DM_NVN_ALLOCPROF=1
```

| Line | Reason |
|---|---|
| `DM_GUEST_FILE=1` | 6.4 GB of guest memory out of the footprint; pins what is automatic. |
| `DM_GUEST_FILE_CHUNK=512M` | the size MKW's 8 GiB iPhone run used; smaller flush stalls than 1G, about 25 files for the 12.5 GB block. |
| `DM_GUEST_FILE_MIN_FREE=2G` | default 5 GB would stop the game (exit 87) on a small Apple TV disk; the game is 25 GB. Watch disk. |
| `DM_NVN_POOL_UNWIRE=1` | explicit; default on tvOS. |
| `DM_NVN_UPLOAD_IDLE_MS=500` | staging goes back faster than the 2000 default. The cost is small allocation churn. Retained staging is at most 96 MB. |
| `DM_NVN_ASTC_MAP_CACHE=0` | avoids the 512 MB reclaimable mapping of the pre-play snapshot. |
| `DM_NVN_ASTC_THREADS=1`, `DM_NVN_ASTC_QUEUE_MB=16` | fewer encoder threads and BC bytes queued on a cache miss; matters only when the pack misses. |
| `DM_NVN_BC_ASTC=6`, `DM_NVN_BC1_ASTC=6` | written by the Compressed textures setting; shown so the extra block is self-contained. The extra block wins over the generated lines. |
| `DM_MEMSTAT=memstat.tsv` | one line a second: footprint, Metal allocation, resident by class. The path is relative; use the Caches folder if the file does not appear. This is how to see where it breaks. |
| `DM_NVN_ALLOCPROF=1` | charges Metal growth to each op and logs each new texture with size, format, storage: names what blows the limit. |

Second run to compare: add `DM_UPSCALER=metalfx` and note whether the first-frame allocation differs.

Expected effect (evidence is thin; no run on this game and platform):
- Guest 6.4 GB: out of the footprint (measured on MKW, mechanism the same).
- BC1/2/3/7 as ASTC 6x6 against RGBA8: 4x to 8x smaller per texture (code; ratio from the tex README), plus the cap's quarter per level dropped.
- Native ASTC: unchanged. BC4/5/6H: only the cap helps.
- Render targets: unknown until the first `DM_MEMSTAT` run; handheld should help.
- Counted footprint on the Mac figure, in the 2.1 GB budget: expect textures and targets to still be the largest block. First read of `DM_MEMSTAT` after load tells whether this is 1.5 GB (within reach) or 3 GB (not).

## 4. Deliverable B: gaps, ranked by expected memory saved on the TV

1. **Cap / mip skip for native ASTC textures.** Largest, because 40% of the textures are ASTC already and `DM_BC_MAX_DIM` ignores them. Dropping finest levels needs no transcoding: skip the levels at upload, shift views and copies by the skip, as `bc_skip` already does. Each level dropped is a quarter of the texture. Effort: medium (a few days). Files: `dm/gfx/tex/nvn_astc_planes.c` (`nvn_bc_skip_levels`, accept ASTC formats), `dm/gfx/tex/nvn_bcdec.c`, `dm/gfx/nvn/nvn_mtl.m` (`bc_skip` ~2597, upload ~3227, views ~6486, copies ~13193, ~13425, ~13729; `no_bc()` gate so the cap applies on a GPU with ASTC), `dm/gfx/tools/astc_prebuild.m` and `bntx_astc.py` only if it needs the cap in the pack. Alternatively port PR #1418 (`DM_NVN_TEX_MIP_SKIP`, open, fixture-tested) whose level translation covers views/copies/readbacks/sparse clamps; its recognition may already include native ASTC (**guess**, check).
2. **Fixed render resolution for Ocarina (render-scale stub or quantized dynamic-resolution targets).** Stops the new-Metal-texture-per-size churn (about 2 GB per 300 frames in the residency set on the Mac) and sets the target size by choice. Effort: medium. Files: `dm/tools/patch_nso.py` (`RENDER_SCALE` fixups for this build), `dm/host/loader.c` (render-scale state, ~307-316), `dm/games/0400486024DEC000/`; or, in `nvn_mtl.m`, recycle targets by size class (the 863bc6b7 family for the colour targets).
3. **ASTC conversion for BC4/BC5/BC6H** (39% of the textures; 2x/2x/4x decode today). In progress by another builder in `dm/gfx/tex` and `dm/gfx/tools`: do not touch. Gain depends on the split (BC6H is the expensive one).
4. **Texture residency budget with eviction.** The creation budget (`pool_budget`, avail/16, about 118 MB) only paces creation; nothing evicts a Metal texture that has not been drawn for N frames. The guest storage stays in file-backed pages, so a texture can be remade on demand (the tree makes textures only when read). Effort: large. Files: `nvn_mtl.m` (texture serial table, `tex_storage_live`, `mtl_tex_release`, the pool-age pass is the model), `hle_svc.c` for the storage.
5. **Soft textures (PR #1599).** Measured on MKW (iPhone Duo): peak 5,708 -> 3,868 MiB. For Ocarina on a file-backed guest only the half-size host texture helps (`nvn_dirty_release` is a no-op there), so it is mostly gap 1 for BC. Effort: large port, open PR. Files: `nvn_mtl.m`, `docs/reference/soft-textures.md` (PR).
6. Smaller: a runtime `DM_NVN_VC_WAYS` (compile-time 4 now; helps churn, not footprint); an IOAccelerator breakdown for this game from `DM_NVN_ALLOCPROF=2` before spending on any of the above.

## 5. Where Ocarina likely still falls short on the A15

- **The counted memory.** Even after the above, textures (native ASTC uncapped, BC4/5/6H decoded) plus targets plus the 1 GB IOAccelerator figure can sit past 2.1 GB. This is the expected failure, probably in the first area load or the first time dynamic resolution moves.
- **Paging.** 6.4 GB of touched guest memory on a 4 GB Apple TV means constant page-in from flash; expect multi-second stalls on area loads (TotK on the same TV).
- **Render target churn** (gap 2) can end it minutes in even if the load fits.
- **First start.** No pipeline archive on iOS for this game: minutes of black screen with music.
- **Disk.** 25.6 GB image plus ASTC pack plus guest files (up to the touched 6+ GB).
- **Unverified ASTC pack for Ocarina's container.** If the prebuild finds no BNTX, BC1/2/3/7 stay RGBA8 and the whole table above under-delivers.
- Compute-heavy title movie network (11.4 ms on an M6) and the upscaler may make the A15 slow regardless of memory.
