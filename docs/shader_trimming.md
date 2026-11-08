# Shader trimming: ship the used shaders compiled, the rest as compressed MSL

Status: built (branch feat/shader-trim). The design and measurements below are the spike's; the section "As built" is what the code does. The A15 numbers are from the test app (`~/workspace/TVPort-spikes/shader-compile/results-A15-2026-11-08`): newLibraryWithSource costs about 129 ms per vertex shader, 46 ms per pixel shader and 58 ms per kernel cold, 76 ms of wall time per shader with 4 threads, and Metal returns an unchanged source in about 0 ms on the next launch (the cache persists across launches). Pipeline creation is about 0.1 ms.

## As built

**Image.** `dm/gfx/tools/shader_trim.py split` makes one image, `b-<chain>.img`, the same romfs format as before (`dm/tools/shader_lib.py`, read in place by `msl_image.h`), from the app image of the build (`shader/ios/b-<chain>.img`, compiled) and the Mac cache image of the same build (`shader/cache/b-<chain>.img`, which keeps each shader's `_b.metal`). A vertex or pixel shader whose key is in the used list keeps all its compiled files. Every other vertex or pixel shader becomes source entries, zstd level 19 with a dictionary trained on the game's own sources (112 KB for the MSL, 32 KB for the reflection json):

| entry | holds |
|---|---|
| `<key>_b.msl` | the shader's plain MSL (`_b.metal` of the cache image) |
| `<key>_bp.msl` | the pulling vertex library's MSL, only when the reflection has `pull` (`dmsh_pull.variant`) |
| `<key>_bv.msl` | the shadow-input library's MSL, only when the reflection has `vin` (`dmsh_vin.variant`) |
| `<key>_bu.msl` | the compile unit that `_bx` (alpha test, logic operation) and `_bf` (readable tile) are cut from at build time (`dmsh_side.unit`, folded by `dmsh_fetch.fold` when the reflection has `fetch`); one library serves both names on the device. Only when the reflection has `alpha`, `logic` or `fetch` |
| `<key>_b.jsonz` | the reflection json, zstd with its own dictionary (the host reads it where it read `<key>_b.json`) |
| `trim.dict`, `trim_json.dict`, `trim.tsv` | the dictionaries, and the index of what is in source form |

The variants are regenerated from `_b.metal` by the functions `dmsh_build.py` calls, so the sidecar libraries are the build's own (checked: the `_b`, `_bp` and `_bv` libraries compiled from the entries are byte-identical to the shipped ones; `_bx` and `_bf` are cuts of a compile of `_bu`, so only their function lists can be compared). The sidecar sources live in the same image because the host's one reader (`msl_image_find`) finds them by name. Compute, geometry and tessellation shaders, shaders without a source in the cache image, and the files that are not a shader's (`inputs.tsv`, the geometry kernels) stay compiled. `shader_trim.py` also writes `shader_map.tsv` with a sixth column, `form`: `lib` (a compiled library in the image, as before) or `src`. A map without the column is all `lib`. `shader_trim.py check <dir>` verifies image against map; `count --used` counts the shaders the lists name.

**Used list.** Keys of the S and C rows, and the vertex and fragment keys of the R rows (`pso_skey_hex`), of the Apple TV's recorded list (`<build>/tvport-shaders.tsv`, kept by `remember_shaders`) and the profile's `pso_manifest.tsv`.

**Runtime.** `dm/gfx/nvn/nvn_shader_trim.m` (module) and `nvn_mtl.m` (wiring):
- `shmap_read` reads column 6, starts `nvn_shader_trim.m`'s compile threads (3; `DM_SHADER_TRIM_JOBS`, 2 to 4 sensible) and gives it the `src` keys.
- `shader_load` of a `src` key asks the module for the shader (`trim_ensure`). The first request queues one job that, on a compile thread, inflates every source entry of the shader (zstd with the dictionary, 0.1 to 0.3 ms) and compiles it with `newLibraryWithSource`; the shader is ready when all its libraries are, so its sidecars never compile on the submit thread. Until then `shader_load` returns nil with `t_trim_pending` set: no error line, nothing recorded.
- Three request modes: the prefetch (`mtl_prog_prefetch`, `shader_prefetch_rest`) queues behind the rest, a draw's `prog_get` goes to the front, the prewarm (`warm_task`, which runs while the game loads) goes to the front and waits.
- `prog_get`: a program with a pending shader is returned incomplete, flagged `trim_pending`, kept apart from the serial table (so the stage is not lost for good) and reused until its shaders are ready; it is then built normally. The draw (`draw`, "a shader is compiling from source") skips a draw with a flagged program: counted per draw, logged once per shader (the first 200).
- Recording: once a shader has loaded, `shader_get` writes its S row to `pso_user.tsv` exactly as for a compiled one, so `remember_shaders` folds it into the next build's used list and it ships compiled next time. A shader that was only skipped is not recorded until it has loaded (the game keeps drawing, so that is the next frame).
- `lib_from_file` serves a source shader's `_b`, `_bp`, `_bv`, `_bx`, `_bf` from the module; `msl_data` serves its json from `<key>_b.jsonz`.
- Counters on the `[bootprof]` line and the "pipeline prewarm done" neighbourhood: shaders compiled on the device, libraries, compile time, failures, draws skipped and shaders skipped.
- Compile options (`trim_compile_options`): `mathMode = relaxed`, `preserveInvariance = YES`, MSL 3.2 (iOS 18), the default optimization level. Not matchable: `-O1` (`MTLCompileOptions` has only Default and Size), `-fbracket-depth=1024` (the front end keeps its 256 nested brackets, so a shader that needs more fails on the device; the build's largest need to be checked on the TV), the precompiled header (an output-neutral speed-up). The device compiler is also the OS's, not the build's `metal` of Xcode, so the machine code can differ.

**TVPort.** Advanced > Trim shaders: Automatic (on when the used list, the TV's and the profile's together, names at least 1,000 shaders) / On / Off. `--trim-shaders auto|on|off` of `backend.py build`; `trim_shaders` runs `shader_trim.py split` into `<build>/tvport-shadertrim` (cached by a fingerprint of the images, the lists, the map and the tool), `generate_project` builds against it (`MSL_IOS`) and copies its shader map over the project's. Any failure builds the full set with one log line. A pipeline archive (`--gpu`) is made from the same image, so it covers the compiled shaders only.

**Numbers (this Mac, `shader_trim.py split`, level 19, 4 threads, 12 to 14 minutes each).** Image `b-<chain>.img` of the game's app, from the build folders in `~/Downloads/switch games`, lists = the Apple TV's recorded list plus the profile's:

| | image today | trimmed image | compiled | source + json | used / all shaders | source-form shaders |
|---|---|---|---|---|---|---|
| Mario Kart 8 Deluxe | 2,091 MB | 1,043 MB (-50%) | 837 MB + 37 MB json | 112 MB + 2 MB | 12,641 / 29,651 | 16,998 (57%), 34,006 source entries |
| Super Smash Bros. Ultimate | 2,618 MB | 934 MB (-64%) | 633 MB + 32 MB json | 218 MB + 2 MB | 10,891 / 35,012 | 24,088 (69%), 48,176 source entries |

The rest of the app is unchanged (MK8 about 0.1 GB, Smash about 0.5 GB), so the apps come to about 1.15 GB (was 2.1 GB) and 1.45 GB (was 2.9 GB). A random sample of the trimmed shaders (300 from MK8, 200 from Smash, all their libraries: 598 and 400) inflated and compiled on the Mac mini (M2 Pro, 3 threads) with the runtime's own module and options with no failure, about 100 ms of wall time per shader with the machine busy; the A15 is slower (the spike's 76 ms per shader with 4 threads, so a scene that meets 50 new shaders is without them for a few seconds).

**Open risks.** Not measured on the Apple TV (nothing was installed): the A15 compile time under real play, whether Metal's source cache survives eviction between launches, memory while 3 compiles run beside the game (the 2 GB limit), and whether a shader that needs more than 256 nested brackets (the build uses 1024) fails to compile on the device (the 500 samples all compiled on the Mac, which has the same limit). A scene that meets many new shaders draws without those objects until they compile (their draws are skipped, not stalled); the first run of a game with a short list is mostly this. All of a shader's libraries compile together, so a pulling or alpha-test library that would be used late is compiled early. A pipeline archive (`--gpu`) covers the compiled shaders only. `_bx` and `_bf` come from one compile of the unit and not the build's two cuts, so their machine code can differ from a full build's.

---

# Design and measurements (the spike)

Status of this part: the design as written before the build, with its measurements; "As built" above is what the code does (the differences: one image, not a second file; sidecar libraries regenerated from `_b.metal`; the unit serves `_bx` and `_bf`; misses are not recorded but pending).


## App contents (measured)

| | Smash | MK8 | Overcooked |
|---|---|---|---|
| app size | 2.9 GB | 2.1 GB | 24 GB |
| msl/b-<chain>.img | 2,618 MB | 2,091 MB | 25,999 MB |
| shaders (keys) in image | 35,012 | 29,651 | 520,394 |
| shaders in shader_map.tsv | 35,012 | 29,785 | 520,394 |
| files in image | 115,204 | 103,091 | 1,663,190 |
| TV-recorded shaders (S rows) | 10,891 (+3,405 R, 8 C) | 12,098 | none recorded |
| share of image bytes for used keys | 26.6% (696 MB) | 42.6% (887 MB) | n/a |

Image breakdown (Smash): _b.metallib 1,425 MB, _bp (pulling) 707 MB, _bx (alpha/logic side) 239 MB, _bf (readable tile) 151 MB, _b.json 90 MB.
Other bundle parts (Smash): main binary 322 MB, html 131 MB, dm tables 32 MB, Assets.car 24 MB.
Translated MSL (Mac cache image, _b.metal only): 2,878 MB for Smash. zstd -19 per file 15.9x, with a trained 110 KB dictionary 22x (sample of 100 files, 7.06 MB raw).

## Runtime path (dm/gfx/nvn/nvn_mtl.m)
- shmap_read (5555) reads shader_map.tsv: key -> stage. The game hands NVN binaries to the host; prog_get (6040) derives the key and calls shader_get(<key>_b) -> shader_load (5836) -> msl_data/lib_from_file (5737) -> newLibraryWithData from the image.
- A missing shader logs "[RED] shader <key> (<stage>) failed to load" (6055) and the program has no stage: that draw is skipped. The miss is not written to pso_user.tsv (the S row is written only after a successful load, 5975), so a trimmed build would need a separate "missed" record.
- Runtime newLibraryWithSource is already used for small built-in shaders (2943, 7696, 11720, 11817, 14582), and a Metal 4 compiler exists (8065). The translator (dmsh_xlate) is a .NET (Ryujinx) tool and spirv-cross is C++; the Python post-processing is 1,862 lines: none of it runs on tvOS, so ship pre-translated MSL.
- Shipped compile flags (dm/ios/tools/ios_metal.py:9): -O1 -fmetal-math-mode=relaxed -fpreserve-invariance -fbracket-depth=1024.

## What a seen-shaders build does today (upstream, Mac only)
`SEEN_SHADERS` / `--seen-shaders` (scripts/build_ipa_from_nsp.py:69, 2267-2290, 2957-2958; docs/development.md:707-722). It needs `--platform mac` or `mac-app` (2958 raises for anything else), so it never applies to tvOS. Keys = profile `shader_seen.tsv` + `shader/partial-keys.txt` + keys the Mac logs report missing (SHADER_MISSING regex, 2261), intersected with the shader map. `dmsh_build.py` is given those keys and builds only them into `shader/partial/b-<chain>`. No `inputs.tsv` stamp, so c1_full.tsv / cb_extent.tsv are not used. A shader not built never loads: the red line above, and the draw runs without that stage ("areas the list does not cover draw without the rest"). The TV-recorded list (`pso_user.tsv`, 14,304 rows for Smash) is a different file from `shader_seen.tsv` and is not read by that mode.

## Where the bytes go
Smash app 2.9 GB: image 2,618 MB (90%), main binary 322 MB, html 131 MB. MK8 2.1 GB: image 2,091 MB, binary 43 MB, html 59 MB. Overcooked 24 GB: image 25,999 MB. The image holds per shader `_b.metallib` + `_b.json`, and for some `_bp` (pulling vertex), `_bx` (alpha test / logic), `_bf` (readable tile). Bytes include every variant of a used key, so the used share is not an overestimate. Used keys are 31% of Smash's shaders (10,891 of 35,012; 5,377 vertex, 5,493 pixel, 20 compute) and 41% of MK8's (12,098 of 29,651). For Smash the pulling libraries alone are 707 MB. The shaders a game uses are a small slice and more play adds more: Smash's list was 14,304 rows after normal play.

## Compressing the compiled libraries is not enough
Per file zstd -19 on 52 real metallibs: 1.93x (1.57 MB to 0.81 MB), 3.2x solid. The MSL of the same shaders: 15x per file (3.07 MB to 0.20 MB), 22x with a 110 KB trained dictionary (100-file test: 7.06 MB to 0.32 MB). The source is smaller than the compressed binary by about 4x, which is why source is the right form for the unused part.

## Runtime path and a miss today
- prog_get (nvn_mtl.m:6040) turns the program's control+code hash into a key, looks it up in g_shmap (5555), and calls shader_get (5967) -> shader_load (5836). shader_load reads `<key>_b.json` with msl_data (5547) and builds the library with lib_from_file (5737): the file in the folder first, else the one image mapped in place (`msl_image_find`), then `newLibraryWithData`. Other loaders of the same files: 7252, 7271 (pulling), 7577, 7650 (`_bx`), 8534-8536, 11498 (`_bf`).
- mtl_prog_prefetch (13050) runs shader_load on a background queue when a program is created; warm_start/pso_prebuild (8855, 8952) rebuild the pso_user.tsv list at launch.
- Miss: shader_load returns nil, prog_get logs `[RED] shader <key> (<stage>) failed to load` (6055), the stage is left empty and that draw does not render. A miss is not written to pso_user.tsv, because the S row is written only after success (5975-5977). Misses are not cached either, so each new program with the key tries again.
- Run-time compile exists only for small built-ins (`newLibraryWithSource` at 2943, 7696, 11720, 11817, 14582). The Metal 4 compiler is created at 8065. The translator is not on the device: dmsh_xlate is the Ryujinx C# translator (dm/gfx/tools/dmsh_xlate/Program.cs, 27 KB, plus 7.6 MB of .NET assemblies), spirv-cross is a C++ binary, and dmsh_build.py (1,862 lines of Python) adds the c1/pulling/alpha/logic/geometry passes and the answer tables. None of it runs on tvOS. The MSL the app would compile is the same MSL the build already feeds to `metal` for iOS (dmsh_build.py:12, ios_metal.py:9), so it is exactly the final text.

## Design
1. Build: unchanged translation (cas.db keeps everything). New step after `pack_libraries`: given a key set U, write the app image from U only (the existing `shader_lib.subset` machinery, extended with a key filter) and a second file `msl/b-<chain>.msl` holding, for every key not in U, the MSL text of `_b`, `_bp`, `_bx`, `_bf` (the sources are in cas.db / the Mac image) compressed per entry with zstd level 19 and one trained dictionary, plus the `_b.json` (also compressed; it is 90 MB raw for Smash). Same romfs index format so msl_image_find and the mmap path are reused. U = TV-recorded keys (`tvport-shaders.tsv`: S rows, C rows, and the vs/fs of R rows) plus profile seed list. zstd is already vendored for texture_once (tex_once_zstd_build.sh).
2. Runtime: in lib_from_file, when the file and the compiled image both lack the entry, find `<name>.metal` in the `.msl` file, zstd-decompress (about 0.3-1 ms), then `newLibraryWithSource` with options matching the shipped flags: languageVersion 3.1, mathMode relaxed, preserveInvariance YES, optimizationLevel default (`-O1` and `-fbracket-depth=1024` have no MTLCompileOptions equivalent: the biggest MSL could differ in speed or fail, and the test app compares them). Do it on the prefetch queue (already exists, 13050) so the first draw that needs it skips or waits like any other in-flight library, with a bounded thread count. Record the shader as S in pso_user.tsv as soon as it compiles (the existing code path), and also record misses that fail.
3. Cache: there is no public API to save a compiled MTLLibrary. Metal caches `newLibraryWithSource` results itself (Mac: a repeat in 0.1 ms vs 50 ms); whether that survives a relaunch and cache eviction on tvOS is the first question the test app answers (run it twice). If it does not persist, every launch recompiles the shaders in pso_user.tsv that are not in the app: the prewarm then costs front end time for each of them (about 55 ms/shader on an M2 Pro; unknown on A15). That is why the build should ship them compiled as soon as they are seen.
4. Growing the list: the TV records into pso_user.tsv; `remember_shaders` (tvport/backend.py:907) already merges it into `tvport-shaders.tsv` at each install; the next build reads that file as U. Games never played on the TV start with the profile seed (pso_manifest.tsv, MK8: 1,518 rows, Smash: empty) or an empty U, and compile everything on first use. The tvOS version of seen-shaders should not use `shader_seen.tsv` (different semantic, Mac logs) but `tvport-shaders.tsv`.
5. Hitch: a first-use shader costs front end + the pipeline compile that exists today. On the Mac mini (M2 Pro) a pair is about 105 + 38 ms front end for a typical vertex and fragment, up to 574 ms for the largest vertex shader; pipeline creation about 21 ms. The A15 is probably 2-4x slower (assumption, to be measured), so a newly seen pair may take 0.3-0.6 s of background work, 4-6 cores, versus the 14,304-row prewarm of today (33 s) which would grow. Expect visible stalls in a scene that uses dozens of new shaders at once; a loading-time warm of the seen list does not help for never-seen shaders.
6. Memory: the source and the compiler's working set are transient (the compile runs in Metal's compiler service, which tvOS does not charge to the 2 GB app limit as far as we know, unverified); the library objects are the same as today. Keep at most 2-4 compiles in flight.

## Expected sizes
| | now | compiled used | MSL for the rest | other | total | cut |
|---|---|---|---|---|---|---|
| Smash | 2.9 GB | 0.70 GB | about 0.2 GB (24,121 keys x about 3.7 KB for `_b`, x about 1.8 for the side libraries, + json) | 0.5 GB | about 1.4 GB | 52% |
| MK8 | 2.1 GB | 0.89 GB | about 0.12 GB | 0.1 GB | about 1.1 GB | 48% |
| Overcooked | 24 GB | unknown (no TV list); 2% of keys 0.5 GB, 5% 1.3 GB | about 1.9 GB (520k keys, median metallib 25 KB so MSL smaller than Smash's) | 0.3 GB | 2.7-3.5 GB | 85-89% |
MSL estimates scale the measured Smash ratio (22x with dictionary, 15x without); sidecar sources were not measured (the Mac image keeps only `_b.metal`). Block-compressing 64 shaders together (solid, 32x vs 17x per-file for lzma) would shave Overcooked's MSL further at 5-10 ms per random access.

## Alternatives
- Ship fewer variants: `_bp` is 27% of Smash's image and exists for the Metal 4 pulling path; a lazy variant-level trim (only the variants used) cuts more but needs the TV to record variants (it records keys only).
- Compile the unused part at install on the Mac and stream: no, that is the 24 GB.

## Open risks
- A15 front-end cost and whether Metal's source cache persists across launches: the test app answers both; everything in Design 3/5 depends on it.
- Compile flag parity (-O1, bracket depth 1024, the precompiled header): runtime compile may be slower to run or fail on the largest shaders; MTL4 compiler is an alternative option.
- Memory under the 2 GB tvOS limit while compiling.
- A shader that fails at runtime is a hole like today's miss; keep logging them and record them.
- Games never played have no list: first run is slow and noisy; consider shipping the Mac-side "seen" keys (Mac play) as a seed.
- Sidecar sources (`_bx`, `_bf`, `_bp`) need the build to keep them (cas.db today); sizes unmeasured.
