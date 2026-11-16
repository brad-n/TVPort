# Switch 2 games on the Apple TV (experimental)

This fork is the first to run a Switch 2 game on an Apple TV. **The Legend of Zelda: Ocarina of Time** (the Switch 2 edition, `0400486024DEC000`, update v131072) plays on an Apple TV 4K (3rd generation) from the title screen through the whole opening, where you get control of Link and cross Kokiri Forest, without crashing. It runs at about 20 frames a second through most of it (30 in lighter spots) and takes 23.2 GB on the TV. **This work is finished** (November 2026): 30 frames a second isn't within reach on the A15, whose GPU needs 35 to 46 ms for a Kokiri Forest frame where 30 fps needs under 33.3.

This page explains what you need and which settings to use. It also covers what it took to get here, what is still wrong, and what comes next. For how the game runs on a Mac, where it plays at about 60 fps, see the game's own page: [Ocarina of Time](../dm/games/0400486024DEC000/README.md).

**Status:** everything on this page is in the default branch, `tvport` ([TVPort 1.3.0 build 1996](https://github.com/brad-n/TVPort/releases/tag/v1.3.0-build.1996) or later). What was learned here carries on as general engine work for every game; see [What carries over](#what-carries-over-to-every-game).

## Why this is hard

A Switch 2 game expects about 9 GB of memory. The Apple TV 4K lets one app use about **2.05 GB** before tvOS ends it. The A15 GPU also can't read the BC texture formats the game ships in, so every texture has to be converted. The game's own data (25.6 GB) has to fit on the Apple TV next to the converted copy.

The A15 also does less than the M-series GPUs in Macs. A game that draws a frame in 15 ms on an M4 Pro takes about 34 ms on the TV.

A Mac hides one class of bugs. The M-series GPU keeps reading a buffer after the engine has stopped declaring it in use, but the A15 does not. A rendering bug that only appears on the TV usually comes from this. Reproduce it with the TV emulation settings (strict residency, the TV's shader math and texture path), not on a plain Mac run.

## What you need

- An **Apple TV 4K (3rd generation, A15)**. The 2nd generation (A12) is untested.
- A Mac with Apple silicon, to build. The test builds were made on a Mac mini M2 Pro.
- A paid Apple Developer Program account. Switch 2 games reserve about 12.5 GB of memory addresses, which tvOS only allows with the Extended Virtual Addressing permission. TVPort asks for it only for games that need it. It takes a one-time step per game on Apple's developer site.
- About **25 GB free on the Apple TV** for Ocarina of Time. Store textures once keeps the game's textures only once, in the Apple TV's own format.
- The game as a [NUP container](../README.md#switch-2-games) (a `.nup` file, 25.6 GB for Ocarina of Time), or the folder of its files. No `prod.keys` is needed.
- TVPort from this fork, built from `tvport` or `switch2-experimental`.

## Build and install

1. In TVPort, add the game's `.nup` file and choose the Apple TV.
2. Leave **Compressed textures** on. On the Apple TV it builds a pack of the game's textures already converted to ASTC, a format the A15 reads, so the TV doesn't have to convert them while you play. If the pack can't be made, the build stops and nothing is sent to the TV. The fork changed this on purpose: a build that installs without its pack runs out of memory in the first minutes.
3. Store textures once turns on by itself for the Apple TV. It removes the game's own copy of every texture that the pack holds, so 25.6 GB plus the pack fits.
4. Build & Install. The first build takes a while. Translating the shaders and building the texture pack are the long parts. Sending about 24 GB to the TV also takes time.

## Settings for Ocarina of Time on the Apple TV

The game reads environment switches from `env.txt` in the app's `Library/Caches` folder on the Apple TV, one `KEY=VALUE` per line. You can send the file from the Mac while the TV is connected:

```
xcrun devicectl device copy to --device <TV device id> --domain-type appDataContainer \
  --domain-identifier <the game's bundle id> --source env.txt --destination Library/Caches/env.txt
```

The set that played through the opening (run 18):

```
# picture: smaller 3D, no grass, no ground mist, slower reflection probes, smaller shadow map
DM_RENDER_SCALE=0.5
DM_UPSCALER=bilinear
DM_MOVIE_NETWORK=bypass
DM_SHADOW_MAP_SIZE=6144
DM_FOLIAGE=off
DM_GROUND_MIST=off
DM_REFLECTION_INTERVAL=8
# memory
DM_GUEST_FILE=1
DM_GUEST_FILE_CHUNK=512M
DM_GUEST_FILE_MIN_FREE=2G
DM_NVN_RESIDENCY_BUDGET_MB=auto
DM_NVN_GMEM_MODE=learned
DM_NVN_TEX_PURGE=1
DM_NVN_POOL_UNWIRE=1
DM_NVN_UPLOAD_IDLE_MS=500
DM_NVN_ASTC_MAP_CACHE=0
DM_NVN_ASTC_THREADS=1
DM_NVN_ASTC_QUEUE_MB=16
DM_OOM_FAILS_MAX=32
# GPU submission
DM_NVN_ALIAS_DIRTY=1
DM_NVN_CUT_FIRST=16
DM_NVN_CUT_DISPATCH=1
DM_NVN_LAZY_CLEAR_WIDE=1
# frame-rate counter
DM_SHOW_FPS=1
```

What the picture switches do:

| Switch | What changes | Why |
|---|---|---|
| `DM_RENDER_SCALE=0.5` | The game's 3D view at half its size, and its dynamic resolution off | Smaller render targets (memory) and less GPU work. The game's own dynamic resolution doesn't work well, and upstream advises against it |
| `DM_UPSCALER=bilinear` | A plain upscale instead of the game's upscaling network | The network is heavy compute for the A15 |
| `DM_MOVIE_NETWORK=bypass` | The movies skip their enhancement network | Saves GPU time and memory during the movies |
| `DM_SHADOW_MAP_SIZE=6144` | The fine static shadow texture at 6144 instead of 12288 pixels square | Saves about 311 MB, with shadows only slightly softer |
| `DM_FOLIAGE=off` | No grass, ferns, clover, ivy or moss | About 3.5 ms of GPU time a frame, plus memory |
| `DM_GROUND_MIST=off` | No haze over the forest floor | About 2 ms of GPU time a frame |
| `DM_REFLECTION_INTERVAL=8` | Reflections of the surroundings refresh 8 times more slowly | About 1 ms of GPU time a frame. Still images look the same |

The picture switches are also the fork's first "low quality" options for slower Macs. The [game page](../dm/games/0400486024DEC000/README.md#quality-options-for-slower-gpus) has their measurements. They are not in the launcher yet.

To measure a session, add these. Then copy `log.txt` and `memstat.tsv` back from `Library/Caches`:

```
DM_MEMSTAT=memstat.tsv
DM_NVN_LEDGER=10
DM_NVN_GPUPROF=every:61
DM_STALL_DUMP=10000
```

`memstat.tsv` has one line a second of the app's memory footprint and how much tvOS still allows. The log's `[ledger]` lines break GPU memory into render targets, sampled textures and pools. The `[gpuprof]` lines give the GPU time of each pass in every 61st frame. Every switch is described in [env_switches.tsv](env_switches.tsv).

## Results on the Apple TV 4K

Each run is one play session from a fresh build. The memory column is the highest footprint of the session. tvOS ends the app at about 2,050 to 2,080 MB.

| Run | Memory peak | How far it got |
|---|---|---|
| 15 | 1,930 MB | Crashed at the door of Link's house |
| 16 | 2,080 MB | Crashed as Saria walked up |
| 17 | 2,073 MB | Past Saria's close-up, then out of memory. That build had shipped without its texture pack, which is why a failed pack now stops the build |
| **18** | **1,978 MB** | **The whole opening, control of Link, and across Kokiri Forest. No crash** |
| 19 | 2,048 MB | Run 18's settings plus compressed render targets and the texture view cache: about 20 fps nearly everywhere (30 in Saria's close-up and tight areas), 16 minutes, then out of memory entering the Kokiri training area |
| 20 | 1,877 MB | The build with memory relief (render-target memory given back when the TV runs short) and unused attachments left out, driven by script with no one at the TV: 18.5 minutes in Kokiri Forest with no crash, 20 fps in the village (GPU 34–38 ms), 25–30 on the east side. The relief stepped in 48 times. The training area itself wasn't reached |
| 23 | 1,745 MB | Convert movies (the AV1 movies as HEVC, decoded in hardware), with the pipeline archive: from a new file, the title and the whole opening movie, its picture at the sound's pace (150 s of pictures in 157 s, 60 fps) where the AV1 in the same session took 258 s at 30 fps; the peak is the new file's first scene after the movie. No crash |
| **21** | **1,715 MB** | **The build after the upstream sync (306 commits), with the three size cuts: 23.2 GB on the TV instead of 31.4. Driven by script: 16.5 minutes in Kokiri Forest without a crash, 382 MB of headroom at the tightest point, 20 fps in the forest. Textures look right, and the plaid ground never appeared. SwitchTV's Options page set anisotropic filtering on the TV, and the game applied it** |

Frame rate in run 18, scene by scene:

| Scene | Frames a second |
|---|---|
| The Great Deku Tree | 23 to 28, about 24 on average |
| Navi's flight through the forest | 18 to 23, dips to 13 |
| Inside Link's house | 13 to 15 |
| First control of Link | drops to 5 while the area loads |
| The balcony | 14 |
| Talking to Saria | 17 |
| Mido | 5 while loading, then 19 to 20 |
| Walking across Kokiri Forest | a steady 14 |

At its peak, run 18 used 358 MB for the textures the game draws (1,578 of them as ASTC, 215 MB) and 198 MB for render targets. Another 399 MB held render-target memory that gets recycled. In 16.5 minutes it read 12.7 GB from storage, as tvOS paged the game's memory in and out.

In a second session of run 20 (compressed render targets off, the TV already hot after 35 minutes of play) the Apple TV itself restarted with a kernel panic, 3.5 minutes into play, with 461 MB of headroom: not the game running out of memory. Whether the heat or the game caused it is not known yet.

Runs can now be driven without anyone at the TV: `DM_CTL`'s `shot` command works on tvOS, so a script can look at the screen and press buttons, with its own save copy (`DM_SAVE`) so the player's saves are never touched.

## What it took

Everything here is on by default for the Apple TV unless the row says otherwise. Each item has an off switch for comparison.

| Change | What it does |
|---|---|
| Store textures once | The game's textures are kept once, in the Apple TV's format. Without it, Ocarina of Time plus its converted copy doesn't fit on the TV |
| Switch 2 texture layout | The Switch 2 stores the small blocks inside each texture tile in a different order from the Switch. Reading them the Switch way gave woven-looking lamps, leaves with holes, and a pack that mostly missed |
| ASTC for every BC format | The pack converts BC4, BC5 and BC6H textures too, about 39% of the game's textures, which the A15 would otherwise hold uncompressed at 2 to 4 times the size |
| A failed pack stops the build | The build stops instead of installing without the pack |
| Render targets retired (`DM_NVN_RT_RETIRE`) | The Metal texture of a GPU-only render target that nothing will read again is released instead of kept |
| Pools wired in chunks (`DM_NVN_WIRE_BOUND`) | A big memory pool is held in 16 MB pieces as the GPU reaches into it, not all at once |
| Zero pages dropped (`DM_GUEST_ZERO_PUNCH`) | Pages of the game's memory that only hold zeros are given back every 10 seconds |
| No empty depth copies (`DM_NVN_DEPTH_TWIN`) | A float texture over the same storage as a depth texture shares its Metal texture instead of holding a zeroed copy |
| Command allocators sized to fit (`DM_NVN_ALLOC_FIT`) | Each submission picks a command allocator its size, so all eight don't grow to the largest submission ever made |
| Lazy shader specialization (`DM_NVN_SPEC_LAZY`) | Shader variants are made when a draw needs them, not all at load |
| Texture spares released (`DM_NVN_PKG_SPARE_FRAMES`) | The spare copy kept for re-uploading a texture is released after 120 frames unused |
| Stand-ins fixed for GPUs without BC (`DM_NVN_POOL_STANDIN`) | Upstream's placeholder textures were BC4, which the A15 can't make. The first session on that build crashed with "invalid pixelFormat". Stand-ins now use a format the GPU has |
| Texture views cached by texture | Upstream PR #2260: the fork's early port (`DM_NVN_VIEW_BY_TEX`) until the 2026-11-15 sync, upstream's own view cache since. Ocarina of Time made 42 to 47 new views of its render targets every frame; with the early port it made none |
| Ground mist kept (`shader_select_guards 0`) | With upstream's guarded reads as selects, the ground mist shader drew nothing on the A15's GPU family. The game keeps them as branches |
| Fewer submissions (upstream) | Each frame went from 37 to 23 command buffers after the upstream sync of November 10 |

## Where it ended

- **Frame rate.** The Apple TV shows a new picture on whole screen refreshes: a frame needs under 33.3 ms of GPU time for 30 fps, and just over that drops it to 20. Kokiri Forest needs 35 to 46 ms on the A15. The time goes to the game's own lighting shaders, which hold more values than the GPU has registers for; translation changes, geometry options and cuts in memory traffic didn't close the gap. Compressed render targets were the one change that lifted the TV (13 to 17 fps up to about 20).
- **Heat.** After about 35 minutes of play the TV reaches its serious thermal state and slows to 13 or 14 fps; once, in run 20, it restarted with a kernel panic.
- **The opening movie.** It is AV1, decoded in software on the A15, and the picture fell behind the sound: in run 23's AV1 baseline, 150 s of the opening took 258 s at 30 fps. Convert movies (run 23) ships the movies as HEVC, which the A15 decodes in hardware: 157 s at 60 fps, the title movie's decode 3.9 ms a picture instead of 12.2, 2 late pictures instead of 274. See [AV1 movies as HEVC sidecars on the Apple TV](reference/movies.md#av1-movies-as-hevc-sidecars-on-the-apple-tv).

## What carries over to every game

- **Memory relief** (`DM_NVN_MEM_RELIEF`): cached render-target memory is given back before tvOS ends an app. It ended the out-of-memory crashes here.
- **Smaller installs on the Apple TV:** texture detail above the TV's cap is left out, colour and lighting textures are packed at ASTC 6x6, and Trim shaders ships only the shaders a game uses. Ocarina of Time went from 31.4 to 23.2 GB. See [What fills a game on the Apple TV](reference/tv-size.md).
- **Options on the TV:** SwitchTV's Options page sets a game's picture and performance settings, including Ocarina of Time's own (grass, ground mist, reflections, simpler models, shadow cascades), so none of the settings above need `env.txt`.
- **Frame pacing that keeps checking for 60 fps** (`DM_FPS_REPROBE`), so a GPU clock that drops at a steady 30 fps doesn't push games down to 20.
- **Convert movies:** every Switch 2 game's AV1 movies are converted to HEVC on the Mac at build time and decoded in hardware on the TV (Ocarina of Time: +1.00 GB; the AV1 stays as the fallback).
- **Scripted test sessions on the TV** with no one there, using `DM_CTL` and a save copy (`DM_SAVE`).

## Research branches

These measured something and are not on the default branch. They stay published for anyone who wants the data:

| Branch | What it measured |
|---|---|
| `tv-all-ptable` | A page table for the game's GPU memory addresses in the shader translator, and what the hot shaders would gain |
| `tv-all-wingback`, `tv-all-wingback-vs` | Shaders without their uniform bounds tests, in fragment and then vertex shaders |
| `tv-all-flatva-spike` | Metal's limits for a flat guest GPU address space, and a pointer-chase benchmark (also on `switch2-experimental`) |
| `tv-all-tvhot` | What per-pixel marks on a bitmap word cost the GPU, and how to compare an Apple TV pass with a Mac's (also on `switch2-experimental`) |
| `tv-all-strict` | Diagnostics for TV-only texture bugs: DM_NVN_READ_TRAP (a switch on that unmerged branch only; what reads a stripped texture's memory) and an upload check. Not merged yet: it conflicts with newer engine code |
| `tv-all-macbench` | Two still-standing Mac bench routes for Ocarina of Time and a ledger line of the residency set's buffers and heaps by size. The routes are in; the ledger line conflicts with newer engine code |
| `feat/shader-trim`, `spike/shader-trim` | Trimming each game's shader library to the shaders it uses, with a TVPort option. Not merged yet |

## Other Switch 2 games

Only Ocarina of Time has been tried on the Apple TV. On a Mac, Switch 2 games build from a NUP the same way: see [Switch 2 games](../README.md#switch-2-games). Upstream nxnative plays others there, such as [Hyrule Warriors: Age of Imprisonment](../dm/games/04003F40232DE000/README.md). A game this project has no profile for gets a provisional one, which may not boot.
