# Changelog: brad-n/TVPort

What changes in this fork, release by release, in plain terms. The full description of each feature, and the switch that turns it off, is in the README's [What this fork adds](README.md#what-this-fork-adds-brad-ntvport) and the pages under [docs/](docs/).

**How releases work**

- **`tvport`** (the default branch) holds work that has been checked, on an Apple TV where it matters. Each release there is tagged `v<version>-build.<build>` and published under [Releases](https://github.com/brad-n/TVPort/releases). The build number is the one TVPort shows in About (Version 1.3.0 (build)), so you can match a release to the app you're running.
- **`switch2-experimental`** gets new work first: memory and speed changes for Switch 2 games on the Apple TV that are still waiting for a TV session to confirm them. Its snapshots are published as pre-releases, tagged `experimental-build.<build>`. The [Unreleased](#unreleased-on-switch2-experimental) section below lists what it has that `tvport` doesn't yet.
- Upstream nxnative is merged in about twice a day. Each sync is listed with its commit.

## Unreleased (on `switch2-experimental`)

Nothing yet: everything that was here is in build 1660.

## 1.3.0 build 1660 (2026-11-14)

**TV output: 4K** (Mac, Advanced settings)
- **TV output** (`DM_TV_OUTPUT=1080|2160`, "TV output" under Advanced in the Mac launcher): with 4K, a docked game is told the TV is 3840x2160 through every way a game can ask (the default display resolution, the largest display buffer, the display list, the Vulkan surface), so Switch 2 games that have a 4K mode can take it. Star Fox reads the largest display buffer and has a 4K mode (its 3D upscaled to 3072x1728); Ocarina of Time asks none of these and is unchanged. 1080p stays the default, and the Apple TV stays at 1080p for its memory. Not yet tried in a game that switches to 4K.

## 1.3.0 build 1656 (2026-11-14)

**Anisotropic filtering for every game** (Advanced settings)
- **Anisotropic filtering** (`DM_ANISO`, Auto / 2x / 4x / 8x / 16x, "Anisotropic filtering" under Advanced in the Mac and Apple TV launchers and in TVPort): sharper textures on ground and walls seen at a shallow angle. Switch games ask for very little to save the console's GPU: Ocarina of Time asks for none on 148 of its 154 sampler settings in Kokiri Forest, Mario Kart 8 Deluxe for none on all 64 in a race. At 16x, Mario Kart's road keeps its grain much further toward the horizon. Cost on a Mac mini M2 Pro: about 0.7 ms a frame in Mario Kart, within the noise in Ocarina of Time. Auto (the game's own choice) is the default; a game that asks for more keeps its own value, and point-filtered, mipless, shadow and the engine's own samplers are never changed.

## 1.3.0 build 1654 (2026-11-14)

**Resolution scale for every game** (Advanced settings)
- **Resolution scale** (`DM_RES_SCALE`, 50 to 200%, "Resolution scale" under Advanced in the Mac launcher and in TVPort): draws a game's 3D at a higher (or lower) resolution than the game chose, for any game. The engine scales the game's render targets and everything that touches them (viewports, clears, copies, reads back to the game at its own size), using the resolution-scaling code the shader translator inherited from Ryujinx. On a Mac mini M2 Pro, Mario Kart 8 Deluxe races hold 60 fps at 1.5x, and Ocarina of Time shows the same picture at 1.5x and 2x as at 1x.
- **When it appears:** the scaling code has to be in a game's shaders. It becomes the default at the next shader rebuild (the next upstream update to the shader translator), so nobody rebuilds just for this; until then the setting shows only for games built with it (a profile's `shader_no_rescale 0`). The launchers check the game's own shader library, so the setting never shows where it can't work.
- **A memory budget for it:** the extra memory a higher scale takes is capped at a tenth of what tvOS allows the app (about 210 MB on an Apple TV) and a quarter of a Mac's GPU working set (`DM_RES_SCALE_BUDGET_MB`); targets past it stay at the game's size.
- **The game's upscalers** (MetalFX, the plain scale and the DLSS stand-in) take the scaled picture.
- Games with their own render scale (Ocarina of Time, Star Fox) still have it: where a game can draw sharper itself, that's the better choice.

## 1.3.0 build 1643 (2026-11-14)

Everything below was checked with the full test pass (the iOS and tvOS compile check, the GPU tests, the TVPort and tool tests). Where an item says it is waiting for an Apple TV session, it works on a Mac with the Apple TV's limits simulated and has an off switch.

**Memory on the Apple TV**
- **Memory relief** (`DM_NVN_MEM_RELIEF`, on by default on Apple TV, iPhone and iPad): when the app gets within 256 MB of the memory tvOS allows it, the engine gives back memory it was only keeping for reuse, before tvOS ends the app. That covers spare render-target memory, render targets the game has already drawn over, unused upload space and oversized command memory. On a Mac mini with the Apple TV's memory limit simulated, it lowered the highest memory use by 150 to 270 MB, with no change in frame time. Waiting for an Apple TV session.
- **Render targets from finished scenes are let go:** a group of render targets the game made for an earlier scene is now released once every target in it is dead (before, the whole group stayed: up to 113 MB in Ocarina of Time).
- **The memory report names every MB** (`DM_NVN_LEDGER`): render-target memory is listed by what holds it, so a log from the TV says where the memory went.
- **Compressed render targets** (`DM_NVN_RT_LOSSY`, off by default): Metal's lossy compression for the game's render targets. On an Apple TV (run 19) Ocarina of Time ran at about 20 fps in places that ran at 13 to 17 without it, likely because the A15 reads memory far slower than a Mac. Being checked for a plaid pattern on the ground before it's turned on.

**Less memory traffic per frame on the Apple TV**
- **Passes leave out what they don't use** (`DM_NVN_DS_OMIT`, `DM_NVN_COLOR_OMIT`, on by default): a pass that never tests or writes depth no longer loads it, and a pass whose draws write no colour (a depth prepass) no longer loads and stores colour. In Ocarina of Time that is 9 to 14 MB a frame less, about 0.3 to 0.4 ms on an Apple TV by estimate.
- **Fixed: skipping stores that a clear makes unneeded** (`DM_NVN_STORE_ELIDE`, still off by default) trusted a clear the game can skip, which showed the village stream through a layer from the balcony. It now counts only clears that always happen.

**Star Fox on the Mac: a sharper picture**
- **Render scale** (`DM_RENDER_SCALE`, 0.5 to 2.0, "Render scale" in the launcher): Star Fox draws its 3D at 768x432 on a 1080p TV, its own docked size, which a Switch 2 also uses; its dynamic resolution was already at its top. 2.0 draws 1536x864. On a Mac mini M2, 1152x648 holds 60 fps with GPU time barely changed.
- **Dynamic resolution** (`DM_DYNAMIC_RESOLUTION`, off by default): on, the game lowers its resolution itself under load.
- **Fixed: game patches in very large games** could be placed where they couldn't reach their site (Star Fox's code needs two patch areas); every game now gets the area that reaches.
- **Frame-rate counter in Mac apps** (`DM_SHOW_FPS=1`): the real frames presented per second.

**Ocarina of Time: more quality options for slower GPUs** (all off by default)
- **Simpler models** (`DM_MODEL_LOD=<factor>`): models switch to their simpler versions as if they were further away. Factor 4 saves about 3 ms a frame on a Mac mini in the Deku Tree conversation, with the tree's roots visibly simpler.
- **One shadow cascade** (`DM_SHADOW_CASCADES=1`): about 0.3 ms a frame, with softer shadows close up.

**SwitchTV is its own project**
- [SwitchTV](https://github.com/brad-n/SwitchTV), the Apple TV launcher for the games TVPort built, moved to its own repository so it can be built without TVPort. TVPort includes it as a submodule at `tvport/switchtv`: clone with `git clone --recursive`, or run `git submodule update --init` in an existing clone. Nothing changes for players.

**For developers**
- `DM_AB_STATE`: A/B a game setting inside one run.
- Benchmarks `t_flatva_bench` (Metal's limits for a flat GPU address space) and `t_mark_bench` (per-pixel marks), and notes on comparing an Apple TV's GPU passes with a Mac's.

## 1.3.0 build 1609 (2026-11-13)

The first release of this fork's `tvport` branch. It is built on TVPort 1.2.3 and upstream nxnative `main` at `ced36121` (2026-11-10). Everything below is described in full in the README.

**Fixed in this release**
- **Mac apps build again** (`--platform mac-app`): the app's launcher reads the game's compressed files, but was built without the decoder for them, so every Mac app build stopped at its last step. It now links the decoder, and a test links the real launcher.

**Switch 2 games on the Apple TV** (experimental)
- **The Legend of Zelda: Ocarina of Time plays on an Apple TV 4K**, from the title through the opening and across Kokiri Forest. See [Switch 2 games on the Apple TV](docs/switch2-apple-tv.md) for the settings, the results of each test session and what's still missing.
- Switch 2 game files (`.nup`) are found and built by TVPort without keys, with app icon, Top Shelf art and game info from Nintendo's store.
- Options for Ocarina of Time on slower hardware: ground mist off, slower reflection probes, grass off, a smaller shadow map, a fixed render scale, plain-picture movies and a plain upscaler.

**SwitchTV**
- A launcher app on the Apple TV for every game TVPort built: box art, Recently Played, All Games, genre rows, a details page and a Top Shelf. TVPort keeps it up to date after every Build & Install.

**Smaller games on the Apple TV**
- **Store textures once:** textures are kept once, in the Apple TV's own format. Mario Kart 8 Deluxe went from 21.5 GB to 13.6 GB.
- Game data compression, more textures converted ahead of time, and a build that can't convert its textures stops instead of installing without them.

**Less memory while you play** (every game; on Ocarina of Time with the Apple TV's settings, 2.41 GB → 1.91 GB in Link's house)
- Command memory sized to what the game sends, spare texture copies let go, graphics programs prepared only when needed, render targets the game has drawn over let go, zeroed game memory given back, and GPU memory pinned only where it's used.
- Graphics memory isn't released and re-pinned over and over, and less is held while a save loads.

**Fixes for Ocarina of Time on the Apple TV**
- Link's house has its inside back, with no striped curtain or white specks; no woven lamps or leaves with holes; no white fog or door bloom; terrain no longer goes flat after streaming; no crash when Link learns an ocarina song; the Deku Tree's wall has no holes.

**Less GPU and CPU work per frame**
- The game's own upscaler is fast again, the last picture is drawn only where it shows, a 1080p picture on a 4K TV, texture views and stand-ins reused instead of rebuilt (upstream PR #2260, brought in early), and shorter graphics programs for every game. More switches, off until measured on an Apple TV, are listed in the README.

**Engine fixes reach games you already built**
- When the engine's patches for a game change, TVPort notices on the next build and rewrites that game's code again.

**Fixes from upstream pull requests, included early**
- #2260, #1486, #1876, #1491, #1459, #1142, #1162 and #1447, plus Manage Saves and offline backup browsing. The README lists what each one does.
