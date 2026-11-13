# Changelog: brad-n/TVPort

What changes in this fork, release by release, in plain terms. The full description of each feature, and the switch that turns it off, is in the README's [What this fork adds](README.md#what-this-fork-adds-brad-ntvport) and the pages under [docs/](docs/).

**How releases work**

- **`tvport`** (the default branch) holds work that has been checked, on an Apple TV where it matters. Each release there is tagged `v<version>-build.<build>` and published under [Releases](https://github.com/brad-n/TVPort/releases). The build number is the one TVPort shows in About (Version 1.3.0 (build)), so you can match a release to the app you're running.
- **`switch2-experimental`** gets new work first: memory and speed changes for Switch 2 games on the Apple TV that are still waiting for a TV session to confirm them. Its snapshots are published as pre-releases, tagged `experimental-build.<build>`. The [Unreleased](#unreleased-on-switch2-experimental) section below lists what it has that `tvport` doesn't yet.
- Upstream nxnative is merged in about twice a day. Each sync is listed with its commit.

## Unreleased (on `switch2-experimental`)

**Memory on the Apple TV**
- **Memory relief** (`DM_NVN_MEM_RELIEF`, on by default on Apple TV, iPhone and iPad): when the app gets within 256 MB of the memory tvOS allows it, the engine gives back memory it was only keeping for reuse, before tvOS ends the app. That covers spare render-target memory, render targets the game has already drawn over, unused upload space and oversized command memory. On a Mac mini with the Apple TV's memory limit simulated, it lowered the highest memory use by 150 to 270 MB, with no change in frame time. Waiting for an Apple TV session.
- **Render targets from finished scenes are let go:** a group of render targets the game made for an earlier scene is now released once every target in it is dead (before, the whole group stayed: up to 113 MB in Ocarina of Time).
- **The memory report names every MB** (`DM_NVN_LEDGER`): render-target memory is listed by what holds it, so a log from the TV says where the memory went.
- **Compressed render targets** (`DM_NVN_RT_LOSSY`, off by default): Metal's lossy compression for the game's render targets. On an Apple TV (run 19) Ocarina of Time ran at about 20 fps in places that ran at 13 to 17 without it, likely because the A15 reads memory far slower than a Mac. Being checked for a plaid pattern on the ground before it's turned on.

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
