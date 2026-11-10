# TVPort 1.2.3

<img src="docs/images/tvport/app-icon.png" alt="TVPort app icon" width="128" height="128">

## What this fork adds (brad-n/TVPort)

Changes in this fork that the TVPort and nxnative releases don't have yet, in plain terms. This fork's TVPort shows **Version 1.3.0** in About, with a build number that goes up with every change, so you can tell which build you're running. Upstream fixes we brought in early are listed with their pull request numbers, so they're easy to drop once upstream accepts them.

**Synced to upstream:** nxnative `main` at commit `dbf84998` (41 more Ocarina of Time prewarm pipelines; earlier syncs `04811a63`, `2ae28018`, `143c0d09`) (2026-11-09; 4 commits past the previous sync: texture gathers whose four offsets form a square read as one gather, compute threads that return before a barrier checked on an Apple M6, a snapshot of an attachment that lands a clear still waiting first, and 41 more Ocarina of Time pipelines built while the game prepares, so a cold first start on Death Mountain Trail no longer stalls on them; the sync before brought 30 commits, including Ocarina of Time's movie network run as the host's own Metal kernels, terrain tiles that no longer vanish after walking, uncompressed textures for render targets that change size, the depth sampled in its own pass, guest files that give disk space back, the present path, dirty pages that are opened instead of counted as written, an index beside each pipeline archive file, and 60 fps on ProMotion screens). #1492 is in upstream now and was dropped from the list below.

**Engine fixes reach games you already built**
- **Patch changes re-apply:** when the engine's code patches for a game change (its patches, the code rewriter, or its game profile), TVPort now notices on the next build and rewrites that game's code again, instead of reusing the old result. It re-uses everything else already built (the extracted files and shaders), so this is much quicker than a first build. It needs your prod.keys file, as a first build does.

**Fixes for Ocarina of Time on the Apple TV (white bloom, terrain, memory readout)**
- **Link's house had no inside on the Apple TV (Store textures once):** the Apple TV's copy of the game files (made by Store textures once) put each shrunk texture file back in its old space as a short compressed stream followed by padding. Ocarina reads its bigger files in pieces of about 900 KB and decodes as it goes, and every shrunk file bigger than one piece, about 850 of them, ended its stream in the first piece: the game read those files again and again for as long as it ran (31 GB in 100 seconds, against 1.7 GB from the original files) and never finished loading them. The inside walls of Link's house were among them, so the house had none. The files are now packed as one stream that fills its space exactly, as the originals are, and load at once. The TVPort build makes the Apple TV's game files again by itself (the tool changed), so the next build and install fixes it; this also takes away a constant stream of file reads in every area.
- **Graphics memory let go and pinned again over and over (`DM_NVN_POOL_AGE_MS`, `DM_NVN_RESIDENCY_WINDOW_MS`, on by default):** the app keeps the pieces of game memory the GPU uses pinned in RAM and lets go of the ones it has not used lately. Both checks of "lately" counted the game's submissions, and Ocarina of Time submits 37 times a frame: "unused for 150 submissions" was 4 frames, and the memory budget looked back only two or three submissions. So pieces the next frame needed were let go and pinned again, one kernel call each: 2,854 calls and 3.9 s per 300 frames in Apple TV run 13. Now a piece must go unused for 5 s before it is let go, and the budget only lets go of what nothing used for 1 s. In Link's house on the Mac mini with run 13's settings: 1,211 calls per 300 frames standing still and 9,112 walking around before, 48 and 458 after, same picture; walking, frames went from 33 to 17 ms (p50). With a budget the house does not fit in (1,536 or 1,024 MB) the old check also kept turning a piece the GPU reads through raw pointers back into zeros, and the GPU hung within a minute; now it plays on. Two smaller fixes ride along: a texture made directly on part of a large memory piece now keeps that part pinned when the piece is re-cut (the budget could otherwise unpin it under the texture, which the Apple TV reads as zeros), and `DM_NVN_RESIDENCY_BUDGET_MB=auto` on the Apple TV is 75% of the app's memory limit (about 1,549 MB) instead of 2,048 MB, which was the whole limit.
- **White fog and white door bloom (`DM_NVN_FINITE_RG11`, on by default):** the ground mist divides by zero in some frames, and on the Switch the resulting infinity or NaN is stored as black in the main picture buffer. Here it was stored as the brightest value there is, and the glow effect spread it over the screen as a white fog and blinding white at doors. Graphics programs now store 0 for a non-finite colour whenever the buffer they draw into has that format (the only place this matters). Set `DM_NVN_FINITE_RG11=0` to turn it off. This changes the graphics programs, so they are rebuilt with the next build.
- **Terrain that goes flat after streaming (`DM_NVN_GWS_PAGES`, on by default):** after the GPU writes into some memory and the game then writes part of it, a leftover piece smaller than a page could never notice a later write, so Hyrule Field's height tiles stayed empty (upstream pull request #1876). `DM_NVN_GWS_PAGES=0` puts the old behaviour back.
- **Where the graphics memory goes (`DM_NVN_LEDGER=<seconds>`, off by default):** writes a `[ledger]` block to the run log every that many seconds: what Metal has allocated against what the game holds resident, render targets by size and format, textures (ASTC, BC, other), memory-pool buffers, heaps, waiting recycled heaps and upload staging. Meant to show what fills the 1.55 GB at Link's house.
- **Less graphics memory while a save loads (`DM_NVN_ALIAS_SWEEP_MB`, on by default where memory is tight: Apple TV, iPhone, iPad and Macs with 16 GB or less; `DM_NVN_C1_LAZY`, on everywhere):** loading a save makes about 800 temporary picture buffers for the new scene, and the game lets most of them go within seconds. The engine used to keep each one until the game happened to reuse its spot, about 30 seconds, which kept the graphics memory near its loading peak the whole time: the riskiest window for the Apple TV, which ends the app at about 2 GB. Now the ones nothing uses any more go after a second once more than 64 MB of them are waiting. On a Mac mini with the Apple TV's settings, the 30 seconds after the load starts now average 110-210 MB less and stay above 2 GB for 10 seconds instead of 27; load time and the picture are unchanged. The first few seconds of the load are not lower: the game itself still holds those buffers then. Each graphics program's built-in constants are also only set up the first time the program draws, instead of for every program loaded ahead of time. That matters when a build lacks its constants table (64 KB per program, about 470 MB for Ocarina of Time), and an Apple TV build now stops if that table, or the uniform-size table, doesn't match its graphics programs. The memory readout no longer counts small text pictures at 8 MB each.
- **Crash when Link learns an ocarina song ("-[NvPkg buffer]: unrecognized selector"):** a texture the game had written itself could, in one narrow moment while the game was freeing its memory, be handed to the drawing code as its bookkeeping record instead of the texture, and the app stopped. Every place that hands out a texture now unpacks the record first (a test reproduces the moment). Found by the ninboy-hat-for-macos fork.
- **Deku Tree wall holes (upstream issue #1678):** our shader build is past the change the report blames (`b97f0dc6`), and upstream has no fix for it yet. The report's shader, `35785cddc971290c`, is the one the `-fwrapv` fix (below) repairs, and that fix is in, so the holes may be gone already; this has not been checked on the TV, and no shader-translation change was made for it.

**Less memory while you play (every game; measured on Ocarina of Time with the Apple TV's settings on a Mac mini: 2.41 GB → 1.91 GB in Link's house)**
- **Command memory sized to what the game sends (`DM_NVN_ALLOC_FIT`, on by default):** the app keeps eight blocks of memory for the GPU commands it writes, and each grew to the largest batch the game ever sent and stayed there: 185 MB in Link's house, most of it left over from loading the save. Batches now go to a block of their own size, and memory left over from a loading screen is given back within seconds: 79-96 MB. `DM_NVN_ALLOC_FIT=0` puts the old behaviour back.
- **Spare copies of rewritten textures let go (`DM_NVN_PKG_SPARE_FRAMES=120`, on by default):** when the game rewrites a texture, the app keeps the old copy for the next rewrite. That suits a movie, rewritten every frame, but the streamed terrain is rewritten once in a while, and its old copies stayed for good: 39 of them, 62 MB in Link's house. A spare nothing has taken for 120 frames (about 2 seconds) is now let go. `DM_NVN_PKG_SPARE_FRAMES=0` keeps them as before.
- **Graphics programs prepared only when a picture needs them (`DM_NVN_SPEC_LAZY`, on by default on the Apple TV and iPhone):** before the first frame the app loads every graphics program the game has (8,376 in Ocarina of Time) and prepared a finished copy of most of them, plus spare variants few ever use, each a compile and some memory. Now a program is finished the first time a picture is drawn with it: in Link's house the app's own memory went from 461 to 285 MB. `DM_NVN_SPEC_LAZY=0` prepares them all up front as before.
- **A smaller zero buffer, and no leftovers from reading the shader list (always on):** the 64 MB buffer of zeros the app used to blank new textures is now 4 MB, used in strips; and reading the game's shader list left 24 MB of temporary text behind on a game thread that never cleans up.
- **Where the memory goes (diagnostics, off by default):** `DM_NVN_LEDGER_TSV=<file>` writes every graphics object the app holds to a table, and `DM_GUEST_FILE_SCAN=1` now also says which of the game's changed memory pages belong to graphics memory: most of them are graphics memory the GPU was given, which counts as changed even when nothing wrote it, and the system does not count those pages against the app.

**Smaller games on the Apple TV**
- **Store textures once:** the game's textures are kept once, in the Apple TV's own format, instead of twice (original plus converted copy). Mario Kart 8 Deluxe went from 21.5 GB to 13.6 GB.
- **Compress game data:** the game file on the Apple TV is compressed without losing anything and unpacked as it's read. Mario Kart 8 Deluxe went from 13.6 GB to 9.3 GB.
- **More textures converted ahead of time:** more of the Switch's texture formats (BC4, BC5, BC6H) are converted on the Mac before install, so the Apple TV does less work while you play.
- **Graphics memory cap for games that read memory through pointers (opt-in):** some games, like Ocarina of Time, have graphics programs that follow raw addresses, so the app keeps all of the game's graphics memory pieces loaded into the GPU (about 1.6 GB) and the Apple TV's GPU runs out of memory. `DM_NVN_GMEM_BUDGET_MB=<n>` (or `auto`) limits that to the pieces recently used or known to be written, and loads others only when a draw needs them. Off by default; not yet tested on the TV.
- **Texture size cap for native ASTC textures:** large textures that are already in the Apple TV's format (mostly Switch 2 games) are shrunk to the cap you choose. At a cap of 256, Ocarina of Time's textures use about 90% less memory.
- **Give idle textures back when memory runs short (`DM_NVN_TEX_PURGE=1`, off by default):** the Apple TV ends the app at about 2 GB, and a lot of that is graphics memory holding textures the game has not drawn with for a while. When the app is within about 900 MB of that limit, textures that came from the game's files and have sat unused for a second or so are put aside: the system may take their memory, and after four more seconds they are emptied outright. The moment the game uses one again it comes back, rebuilt exactly from the game's data (or the converted copy on disk), and until it does the game sees a plain stand-in. Pictures the game draws into, and anything the game wrote to, are never touched. Tuning switches are `DM_NVN_TEX_PURGE_IDLE`, `_EMPTY_IDLE`, `_LOW_MB`, `_HIGH_MB`, `_KEEP_MB`, `_MIN_KB`. Idea from the yuchanns tvOS fork.

**Less GPU work per frame (Ocarina of Time, untested on the Apple TV: each switch can be turned off in `env.txt`)**
- **The game's own upscaler is fast again after upstream made its math exact (every game with these networks):** upstream changed how the upscaler and movie networks round their numbers so they match the Switch 2's hardware exactly (nothing looked wrong before; the numbers were a hair off). On older Apple chips (M1, M2 and the Apple TV's A15) that made Ocarina of Time's upscaler pass three times slower, 1.0 to 3.3 ms a frame on the Mac mini. The same rounding is now done a different way the GPU handles well, giving exactly the same numbers (checked on 4.2 million values): 1.5 ms. No switch: it is simply how the shaders are built now.
- **Draw-pass barriers with dynamic resolution (`DM_NVN_BARRIER_HEAP=pass|global`):** a game that resizes its render targets keeps the different sizes in one shared piece of memory, and the engine used to answer that by waiting for the previous draw pass to finish completely before starting each new one, for the whole game (about 94 full waits a frame in Ocarina of Time, none saved). Now only the passes that draw into that shared memory, and the pass right after them, wait; the rest overlap again as the game's own profile asks. `global` brings the old behaviour back.
- **Clears can wait for the pass that draws there (`DM_NVN_LAZY_CLEAR_BINDLESS=1|0`):** a clear that arrives before a pass used to get a pass of its own whenever the next draw looked up its textures by handle (every draw in Ocarina of Time: about 5.5 extra passes a frame). Now the clear is folded into the pass that draws into that target unless the draw can really read the cleared texture.
- **Skip saving what is cleared next (`DM_NVN_STORE_ELIDE=1`, off by default) and skip loading what is covered (`DM_NVN_LOAD_ELIDE=1`, off by default):** a render target the game clears whole before it uses it again in the same frame is no longer written out at the end of its pass, and a colour target whose first draw covers all of it is no longer read in. Textures the game can look up by handle, copies, window images, and anything shared are always kept. The log line `gpu pass efficiency` shows what each switch did. Checked again in Link's house: Ocarina of Time gives neither much to do. About 1 MB of the 130 MB it saves a frame is cleared before it is used, and no load can be skipped at all, because the game places its full-screen pictures through numbers the engine can't read ahead of time; both stay off.
- **Reflection probes check depth before shading (shader library, every game):** the graphics programs that draw Ocarina of Time's reflection probes keep a log of the game memory they read, and that bit of bookkeeping made the GPU shade every pixel of every object in a probe before checking whether something nearer hides it. They now check first, as the game's own programs do on the Switch. On a Mac mini a probe face costs half as much (2.0 → 1.0 ms) and the frames that draw one no longer stand out (1.1 → 0.1 ms extra), same picture; 415 of the game's 22,352 pixel programs change. An alpha-tested draw of such a program still checks after shading, as on the Switch. It takes effect with the next build's shader library, which is translated again in full.
- **The last picture drawn only where it shows (`DM_NVN_WINDOW_AREA`, on by default, every game):** Ocarina of Time draws its finished 1920x1080 picture into the top-left corner of a 2560x1440 screen image, and the whole 2560x1440 image was read into the GPU and written back every frame just to change that corner. Now the pass covers only the corner and leaves the rest as it was: 28 MB → 16 MB of memory traffic a frame (Mac mini, Link's house, same GPU time there; the Apple TV, with a sixth of the memory bandwidth, spent 0.35 ms on that pass). Only the game's screen images get this, and a draw outside the corner still reaches the whole image. `DM_NVN_WINDOW_AREA=0` puts the old behaviour back.
- **1080p picture on a 4K TV (every game):** the Apple TV used to draw each frame at the TV's full 4K, even though games make a 1080p picture at most. It now draws at 1080p and lets the TV's own hardware scale it up, which saves a full-screen upscale every frame and about 75 MB of memory; docked Switch 2 games are also no longer told the screen is 4K, so they don't render 4K output. `DM_TV_MAX_WIDTH=0` restores the old behaviour.
- **Clears wait for their pass more often (`DM_NVN_LAZY_CLEAR_WIDE=1`, off by default):** when the game clears a picture and draws into it a little later, the clear is done as the drawing starts. A texture bind, a GPU timer or query, or a compute job that has nothing to do with that picture used to force the clear out early, in an extra pass that saved the cleared picture to memory just to load it again. Ocarina of Time on the balcony: 2 fewer passes and about 8 MB less memory traffic a frame. On the Mac the GPU time doesn't change measurably; the Apple TV has far less memory bandwidth.
- **Fewer GPU cache flushes (`DM_NVN_ALIAS_DIRTY=1`, off by default):** Ocarina of Time keeps most of its graphics memory in one 2.4 GB block, which the engine has to reach through overlapping windows. Every step of the GPU's work used to start or end with a flush that keeps those windows in agreement. Now the flush happens only after the GPU has actually written memory. Balcony: about 0.4 ms less GPU time a frame.
- **No empty GPU batches (`DM_NVN_EMPTY_SUB=1`, off by default, being checked):** the game splits each frame into many batches at its sync points, and a few have nothing in them. Each still went to the GPU, which then paused around it. Now an empty batch only marks its place. Balcony: the GPU's busy stretch per frame 26.8 → 25.3 ms. One of four test runs had a few seconds of slow frames that the others didn't, so it stays off until that's understood.
- **The GPU gets its first work of each batch sooner (`DM_NVN_CUT_FIRST=16`, `DM_NVN_CUT_DISPATCH=1`, both off by default):** the engine hands the GPU each submission in pieces while it keeps translating the rest. The first piece now goes after 16 draws instead of 64, and a compute job between two passes is a place where a piece can be handed over too. Ocarina of Time's main scene had no such place, so the GPU waited for all of it to be translated. Balcony: the GPU's busy stretch per frame about 0.4-0.6 ms shorter (two test sessions).
- **Wider compute reordering (`DM_NVN_CS_HOIST_WIDE=1`, off by default):** compute jobs between two draws on the same picture can now also move ahead of the drawing when GPU timers, occlusion queries or conditional drawing sit between them. Ocarina of Time gains nothing from it: its draws look up their textures by handle, so the engine can't prove a move is safe. Kept for other games.
- **GPU profile per command buffer (`DM_NVN_GPUPROF`, `dm/tools/gpuprof.py --gaps`):** the profile now also says when each batch of GPU work was recorded, handed over and run, so you can see whether the GPU waited for the engine. The pass dump names what ended each pass.
- **No border-colour fix where a game never needs it (`shader_border_emu 0` in a game profile, Ocarina of Time has it):** the graphics programs normally carry an extra check, and a spare copy of each picture lookup, in case a game wants a picture edge colour the Apple TV cannot draw. Ocarina of Time never asked for one in seven Apple TV runs, so its profile now leaves the check out: the programs compile about 15% faster and come out a few percent smaller, and the app does a little less work on every draw. If a scene ever does need it, the log says so and the setting goes back to 1.
- **Faster memory lookups in the graphics programs (`shader_raw_regs` and `shader_wide_device`, on for every game since the defaults pass below):** some of Ocarina's graphics programs read game memory through addresses they load, and every such read first looks up which block of memory the address is in. The ground mist (one full-screen fog layer) does 43 of these reads for every pixel. Each read went back to the block table, even when it read the same block as the read before. Now the program keeps the block it found last. (Writing the lookup's search once as a loop, `shader_raw_loop`, measured no faster and stays off.) A change earlier tonight (the read log) had also made these programs read their light records one number at a time; they read whole records again. On the Mac mini with the Apple TV settings, the ground-mist pass went from 2.1 to 1.7–1.8 ms a frame and the main lit pass (whose mesh program does 139 such reads) from 3.3 to 3.1 ms, about 0.6 ms less GPU work a frame in all; the picture is unchanged. Not yet measured on the Apple TV; its GPU is slower and has far less memory bandwidth, so the saving there may well be larger. Changing a key rebuilds the game's shaders.
- **Exact shortcuts that measured no faster on a Mac (`shader_fragw_fold`, `shader_ftz_cmp`, `shader_unord_cmp`, `shader_no_rescale`; on for every game since the defaults pass below):** four places where the translated programs do work that cannot change the result can be written shorter: every interpolated input multiplied by w and then by 1/w, number comparisons spelled out the long way (two kinds), and a divide by a screen scale that is always 1. On the Mac mini this made no difference we could measure; since they cannot change the picture, they are now on everywhere (one shader rebuild together with the upstream sync).
- **Where each frame's GPU time goes (diagnostics, all off by default):** to find out why Ocarina of Time's draws cost the GPU so much, the engine can now name every compute pass as well as every draw pass in Instruments traces and in its own GPU profile (`DM_NVN_ENC_LABEL=1` with `DM_NVN_GPUPROF`), drop only the mesh draws that have a task shader or only those without one (`DM_NVN_SKIP_MESH=task` / `notask`), drop chosen compute jobs (`DM_NVN_SKIP_CS`) and up to 64 pixel shaders (`DM_NVN_SKIP_FS`), and list each mesh draw in the pass dump. A small tool, `dm/gfx/tools/pipeline_stats.m`, prints the per-shader register and spill counts Xcode shows. What they found on a Mac mini: the cost per draw is almost all pixel shading, not the draws themselves (well under 2 µs a draw), led by the lit model shaders, which use every register the GPU allows; and the mist and reflection-probe shaders, which look up game memory through pointers at every pixel.

**On for every game now (defaults pass, 2026-11-09): fixes that change nothing in the picture except where a game needed them**
- **Skip-if drawing is followed automatically (`render_cond`, automatic):** some games tell the GPU "skip this clear or this draw if a counter says so". The engine ignored that unless a game's profile switched it on (ten did), and without it Tears of the Kingdom and Animal Crossing: New Horizons came out black. Now every game gets it the moment it first asks for it, so a game that never asks is unchanged and the ten profiles no longer need their line. Portal 2 keeps it off, because its furniture vanished with it on (`render_cond off` in a profile does the same for any game).
- **Shorter graphics programs for every game (`shader_raw_regs`, `shader_wide_device`, `shader_no_rescale`, `shader_ftz_cmp`, `shader_unord_cmp`, `shader_fragw_fold`; on):** six ways of writing the translated programs more cheaply that give exactly the same results, which were switches only Ocarina of Time used (or none did). Games whose programs look up memory through addresses they load get the faster lookups Ocarina got (its ground mist pass went from 2.1 to 1.7 ms on the Mac mini); the other four remove work that cannot change any pixel. Each is checked by a test that compares results on the GPU, and any one can still be turned off in a game profile with `0`. Applies when a game's shaders are next built.

**Less CPU work per draw (every game; measured on Ocarina of Time on a Mac mini M2 Pro with the Apple TV's settings)**
- **Texture stand-ins kept instead of rebuilt (`DM_NVN_VIEW_KEEP=30`, on by default on every platform):** Ocarina of Time leaves texture slots pointing at textures it has already thrown away, and the engine has to keep something valid in each of those slots. It used to rebuild that stand-in after every one of the game's ~37 batches a frame that needed it: 20-40 stand-ins a frame on the balcony, about 250 a frame in stretches where the game streams, each one a new Metal texture object (about 3 µs of CPU each on the Mac). They now live 30 frames (at most 64 batches a frame of them, 4,096 stand-ins) before they are made again: under 1 a frame. The picture and graphics memory are unchanged. On the Mac the frame time doesn't change (the GPU is the limit there) and the CPU saving is within the run-to-run noise in the quiet stretches; the busy stretches are where it shows, and the Apple TV's slower CPU feels them more. `DM_NVN_VIEW_KEEP=0` brings back one batch.
- **The translator stops waiting for the Metal encoder after each batch (`DM_NVN_ENC_ASYNC=1`, off until measured on an Apple TV):** on the Apple TV (and iPhone) the engine translates the game's commands on one thread and hands them to Metal on another. After each of the ~37 batches a frame, the translating thread waited until the other had caught up: 1.55 ms a frame on the Mac. With this switch it hands the batch over and goes on; the frame still only goes to the screen once its work is on the GPU's queue. On the Mac it changes nothing you can measure, because the GPU is the limit there and the translator just waits for the GPU instead; it should help where the CPU is the limit, which is the Apple TV, but that hasn't been measured yet.
- **Argument blocks reused across program switches and passes (`DM_NVN_ARGS_CACHE=1`, off):** the engine re-describes each draw's textures and buffers to the GPU whenever anything may have changed. This switch keeps a description while exactly what it was made from is still bound, across shader switches and later passes. Measured on Ocarina of Time it doesn't help: almost every draw there binds a different uniform buffer (92% of the descriptions are new, only 8% repeat one made earlier in the frame), so it reuses about 3 more descriptions a frame out of ~3,100. Kept as an option for games that draw many things with the same bindings.

**Switch 2 games (experimental)**
- **Plain-picture movies (`DM_MOVIE_NETWORK=bypass`):** Ocarina of Time runs its movies through a neural enhancement network that costs about 90 ms a frame on an Apple TV 4K (3rd generation), so movies played in slow motion. This option skips the network and scales the movie's own picture instead, about 1-2 ms a frame. It is off by default, and uses no MetalFX. Upstream now runs the network itself as the engine's own GPU programs by default (`DM_NDVE_ENGINE`, about half the GPU time on a Mac); `bypass` still takes precedence when set and skips the network entirely.
- **Game's own upscaler off (`DM_UPSCALER=bilinear`):** Ocarina of Time enlarges its picture (1536x864 to 2048x1152) with a neural network. This option, "Game's upscaler: Off (plain scale)" in the launcher, turns the network off and stretches the picture with a plain smooth scale instead: much less work for the Apple TV's GPU and no extra memory beyond one small image, at the cost of some sharpness. It never calls MetalFX, which has frozen an Apple TV. Off by default.
- **Ground mist off (`DM_GROUND_MIST=off`, off by default):** the soft haze that drifts over Kokiri Forest's floor in Ocarina of Time is one of the most expensive things the game draws. This option tells the game to skip drawing it (the haze's movement is still worked out, because the grass follows it). From Link's balcony the distant floor just looks a little clearer and darker; down on the forest floor, where the haze is thick, the scene looks noticeably darker and more saturated without it. Nothing else changes. On a Mac mini with the Apple TV's settings it saves about 2.2 ms of GPU time a frame, so expect several times that on an Apple TV.
- **Reflections refreshed less often (`DM_REFLECTION_INTERVAL=2`, `4` or `8`, off by default):** Ocarina of Time keeps small pictures of the surroundings for shiny and wet surfaces to reflect, and redraws one side of one of them every frame, which costs as much as a big part of the scene each time. With this option the game redraws them only on every 2nd, 4th or 8th frame, so reflections catch up with a change of light or place that much later. Standing still the picture is the same. Mac mini with the Apple TV's settings: about 0.7, 1.0 and 1.2 ms less GPU time a frame; 4 is the suggested setting.
- **Switch 2 game files (`.nup`):** TVPort finds and builds them, needs no keys, and names the app from the folder when the package carries no name.
- **Larger address space:** Switch 2 games reserve about 12.5 GB of memory addresses, which tvOS only allows with Apple's Extended Virtual Addressing permission. TVPort asks for it only for games that need it. This needs a paid Apple Developer Program account, plus a one-time step per game on Apple's developer site to enable the permission for that game's app ID.
- **App icon, Top Shelf art and game info from Nintendo's store:** the public title list TVPort normally uses has no Switch 2 games, so a Switch 2 game used to get no icon and no details in SwitchTV. When that list has nothing for a game, TVPort now looks the game up on Nintendo's own store page and uses its picture as the app icon and Top Shelf art, and its name, description, publisher, release date and genres in SwitchTV. It only fills gaps: artwork you chose, or anything the title list already has, is left alone, and with no internet the game just has no art, as before.

**Fixes from upstream pull requests, included early** (nxnative by seedds; not yet merged upstream)
- **#1486:** on iOS and tvOS the first GPU out-of-memory failure ends the game cleanly with a report of what was resident, instead of drawing broken frames. `DM_OOM_FAILS_MAX=32` brings back the old tolerance.
- **#1876:** see the terrain fix above.
- **#1491:** upload staging that shrinks when idle was already in this fork.
- **#1459:** the "use Apple's MetalFX upscaler" setting now works on Ocarina of Time. It was looking for the wrong file, so it did nothing.
- **A residency budget for the whole GPU set** (`DM_NVN_RESIDENCY_BUDGET_MB=<n>|auto`). The raw-memory cap only covered one way pools get wired; the set still overflowed through texture-upload and draw lookups (Ocarina of Time on the Apple TV 4K ran out of GPU memory at the world load). Over the budget, the least recently used memory pools leave the set, never one the current or a running submission uses; if what is in use alone is over the budget, the log says which kinds and how many MB, so you can tell a "frame too big" problem from a pool problem.
- **#1142:** the graphics code remembers the memory pool it looked up last and tries it first, which saves a little CPU time on every draw.
- **#1162:** the graphics code remembers when a draw has nothing waiting to be written before it, so repeated draws of the same material skip that check (switch it off with `DM_NVN_UBDC=0`).
- **#1447, the guest's copy of an uploaded texture (`DM_TEX_RELEASE=1|2`, off by default):** once a texture is on the GPU, the game's own copy in memory is replaced by blank pages and the memory handed back (upstream measured about 2.3 GB on a Mac). Built in, but it does nothing on the Apple TV: the game's memory already lives in files there, where the pages cost no footprint, so the release is skipped on purpose. It also restores Link's hat embroidery when a texture is made again over released storage. The same pull request's terrain-holes fix was already in this tree.

## What’s new in TVPort 1.2.3 build 44

- Added separate Swap A/B and Swap X/Y controls. Existing combined swaps stay enabled, and new games inherit your most recent choices.
- Reduced automatic save checks to every 30 minutes. Backups are still created only when saves change, keeping the newest 10 automatic copies per game and player/save slot.
- Kept Updates & DLC attachments editable during automatic save checks and fixed the Add Files dialog.
- Kept separate generated game profiles when input files change, fixing the cached base-game profile error when adding an update. Previous profiles are preserved for switching back.
- Made Last Run show the complete available run log, added text-file export for build and run logs, and made the build log follow new output. Save Log now sits beside the status and Show/Hide Log controls.
- Kept the prod.keys picker visible in game settings.
- Made Crop to fill the default for new App Icons and when choosing replacement artwork. Top Shelf uses the App Icon image unless a separate cover is selected, with a clearer Use App Icon Image action.
- Added an in-app warning that Updates & DLC support is under development and may cause games to crash.

Known issue: Snufkin reached gameplay with the newer engine without the game update, but the updated game still crashes during loading. The latest updated-game log repeats the same null-pointer fault as earlier tests. The cause remains under investigation; Updates has not been isolated as the cause. This is not a confirmed crash fix.


## What’s new in TVPort 1.2.3

- Added a build queue: prepare several games, see Building and numbered Queued badges, and remove waiting games. Stop or a failed build pauses the queue until you resume it.
- Added each built game’s signing expiry, with a live countdown and local date and time.
- Kept the Mac awake during setup, conversion, building and installation. The display can still turn off, and normal sleep resumes when the work finishes or stops.
- Added a confirmation after a save is successfully restored and verified on Apple TV, with an in-app fallback when notifications are unavailable.
- Automatically back up saves for all supported games installed on the selected Apple TV, including games built on another Mac.
- Save automatic backups only when their contents change, keeping the newest 10 per game and player/save slot. Manual backups, local imports, safety backups and older unlabelled copies are preserved.
- Kept saved backups available to browse during automatic backup, with clearer progress and retry messages. Builds can wait in the queue until backup finishes.
- Added drag-to-position for App Icon and Top Shelf artwork, cached previews for faster switching, and Crop to fill as the default for new Top Shelf covers.
- Fixed artwork disappearing after Stop and build results or installation messages appearing on the wrong game.

See the [1.2.3 changelog](tvport/CHANGELOG-1.2.3.md) for validation and release details. Earlier features and instructions remain below.

## What’s new in TVPort 1.2

- Updated the embedded nxnative engine and shader tools while retaining TVPort’s Apple TV adaptations.
- Fixed Unity 6000.3 shader parsing and the Apple TV startup check that incorrectly rejected GPUs using decoded BC textures.
- Added drag-and-drop for game folders and NSP, XCI, NSZ and XCZ files.
- Added an Updates & DLC section: attach files from other folders or drives, check that they belong to the game, and apply them on the next Build & Install.
- Added a separate Top Shelf cover with PNG/JPEG import, a wide preview, and independent zoom and position controls.
- Made the full build log selectable and readable in dark mode. The frame-rate counter now defaults to off for new games.
- Added a new app icon and refined labels, alignment and toolbar spacing.
- Fixed Last Run Stats appearing out of view. It now opens in a dedicated panel with loading status, clear errors, Refresh and a selectable run log.

Existing features and instructions remain below.

Download [TVPort 1.2.3 build 44](https://github.com/0to101/TVPort/releases/tag/v1.2.3-build44). Earlier downloads remain available in the release history. See [the TVPort guide](tvport/README.md) for setup and build instructions.

## Features retained from TVPort 1.1

This fork builds on [the original TVPort](https://github.com/68hctmzzjf-svg/TVPort) with improvements to the Mac app’s library, artwork, controller settings and save management. It keeps the original TVPort and nxnative engine foundations, with the following additions:

- **Manage Saves:** browse supported games installed on your Apple TV, back up one game or all available saves, restore previous backups, and import compatible saves from Ryujinx or other emulators and native Mac games. Import adds a separate local copy without touching the Apple TV. Restore lets you choose an existing player/save slot, backs up its current save first, verifies the transfer, and attempts recovery if it fails. Backups can be opened in Finder and optionally stored in iCloud Drive.
- **Offline backup browsing:** see games with saved backups and open their save files in Finder even when the Apple TV is disconnected. Local imports work offline too. Restore and new Apple TV backups become available when the TV and game can be reached.
- **Game artwork:** automatic artwork lookup, custom images, and controls for scaling and cropping Apple TV icons. Artwork thumbnails also appear in the library and save manager. The lookup is adapted from NX2Apple, with its MIT attribution included; downloaded cover artwork is not bundled with the app or added by this fork to the repository.
- **Controller and frame-rate settings:** a per-game A/B and X/Y swap, clearer FPS-counter explanations, and a visible frame-rate selector that stays disabled until the game supports it.
- **Build locations:** choose a default build folder in Settings, then select that folder or a location next to the original files for each game. Existing builds are copied when changing location, with the originals kept.
- **New app icon:** a red TV-and-controller design with built-in dark and clear appearances that follow macOS icon settings.
- **Mac interface improvements:** a fixed-width sidebar, clearer setup status, revised buttons and spacing, game versions in save-manager headings, File-menu access to Settings and Manage Saves, and clearer Last Run Stats and Show Log actions. Removing the last library game no longer leaves the detail view referencing a deleted entry.
- **Safer automatic save recovery:** installation checks for both working and persistent saves before restoring a backup, and skips recovery when it cannot verify that saves are absent.
- **Upscaler choice per game:** a setting on each game's page to pick how its picture is scaled up: the game's own way (the default), Apple's MetalFX, or Off for simple scaling that leaves the most speed for the game. Turning it off is the way to give a demanding game more room on the Apple TV.
- **Ocarina of Time render scale:** a 3D resolution setting for The Legend of Zelda: Ocarina of Time, the same one Tears of the Kingdom and Breath of the Wild have. It fixes the game's 3D view at a fraction of its size (for example 75%) and turns off the game's changing resolution, which asks the Apple TV for less graphics memory when the world loads.
- **Ocarina of Time shadow map size:** a switch (`DM_SHADOW_MAP_SIZE`) for The Legend of Zelda: Ocarina of Time that makes the game's huge fixed-shadow picture smaller (for example 6144 instead of 12288 pixels a side, about 220 MB less graphics memory), which helps the Apple TV keep the game inside its memory limit. Its fixed (static) shadows get blurrier.

These fork-specific features are included in 1.2.3. The original project’s release downloads do not include them.

Play your own Nintendo Switch games on an Apple TV 4K. TVPort is a fork of [nxnative](https://github.com/seedds/nxnative) by seedds. It adds an Apple TV build of the engine and a Mac app that turns a game you own into an Apple TV app and installs it on your TV, with no command line.

Like nxnative, it is not an emulator: the game's own code runs on the Apple chip, and its graphics are rebuilt on Metal. Nothing from any game, and no keys, are in this repository or its releases. The project is not affiliated with Nintendo, Apple or any game publisher. Use it only with games you own and dumped from your own console.

## App preview

These screenshots use fictional games, dummy artwork and sample save records.

![TVPort game library and build settings with dummy games](docs/images/tvport/main-window.png)

![Manage Saves showing local imports, Apple TV backups and safety backups](docs/images/tvport/manage-saves.png)

## What TVPort adds

- **An Apple TV build** (tvOS 26 or later; tested on an Apple TV 4K, 3rd generation, A15, tvOS 27.2). The game's memory is backed by a file, which keeps large games under tvOS's 2 GB limit per app ([tvport/README.md](tvport/README.md#getting-past-the-memory-limit)). The A15 has no BC texture formats, so those textures are stored decompressed.
- **Saves that last.** tvOS can clear an app's caches at any time. Each save is copied to the app's preferences a few seconds after the game saves it, and comes back by itself. The Mac checks saves every 30 minutes while TVPort is open and backs them up only when they change, in iCloud Drive if you like.
- **"Who's playing?"** Each player on a shared TV gets their own saves. For a game with one save per console, such as Animal Crossing: New Horizons' island, each name is a resident of the same island instead.
- **The TVPort Mac app.** Pick a folder holding your game's NSP or XCI files and your `prod.keys`, pick your Apple TV, and press **Build & Install**. Settings for render mode, texture detail, 3D resolution, frame rate and heat appear when the game supports them. **Last Run** reads the TV's log and memory reports and says what went wrong in plain words.
- **Engine fixes found on the TV**, which help every game:
  - a leak of render-pass readback buffers on game threads;
  - normal speed for game versions the profile was not made for;
  - memory pools the GPU stops using are unwired, so tvOS can page them out;
  - new memory, paging and stall diagnostics.

## Games tested on the Apple TV

| Game | Version | Result |
|---|---|---|
| Super Mario Odyssey | 1.3.0 | Plays |
| Animal Crossing: New Horizons | 1.0.0 | Plays, one shared island for every player |
| The Legend of Zelda: Tears of the Kingdom | 1.4.2 | Plays at 30 fps in Handheld mode at 75% 3D resolution. Loading screens slow down a lot once the TV gets hot |

Many more games run on iPhone and iPad with nxnative; see the [games table](dm/games/README.md#games). On the Apple TV, a game needs a 64-bit build. Mario Kart 8 Deluxe before update 2.0 is 32-bit, for example, and cannot run.

## Getting started

1. **The Mac:** Apple silicon, with macOS 26.6 or later and Xcode 27.2 (see [Build from the command line](#build-from-the-command-line) below).
2. **The Apple TV:** an Apple TV 4K with tvOS 26 or later, in developer mode and paired with Xcode (**Window > Devices and Simulators**).
3. **An Apple ID signed in to Xcode** (**Settings > Accounts**). A free one works, but its installs stop opening after 7 days. **Build & Install** renews them.
4. **TVPort:** download `TVPort-1.2.zip` from [this fork’s releases](https://github.com/0to101/TVPort/releases), unzip it and open TVPort.app. It is signed ad hoc and not notarized, so the first time macOS refuses it: open **System Settings > Privacy & Security** and press **Open Anyway**.
5. **First run:** TVPort sets itself up and lists anything else the Mac needs in **Setup** (Homebrew packages and the .NET SDK).
6. **Build your game:** add your game's folder and press **Build & Install**. A game's first build takes 30 to 60 minutes. After that a build takes a few minutes.

[tvport/README.md](tvport/README.md) has the details: the design, the memory and save mechanisms, the settings, and the limits.

## Credits

nxnative is by [seedds](https://github.com/seedds/nxnative), under the MIT License ([LICENSE](LICENSE)). The original TVPort is by [68hctmzzjf-svg](https://github.com/68hctmzzjf-svg/TVPort). TVPort's additions are under the same license. Artwork lookup includes code adapted from [NX2Apple](https://github.com/LNPANDY/NX2Apple); its [MIT notice](tvport/app/Resources/NX2Apple-LICENSE.txt) is included.

---

# nxnative

Play your own Nintendo Switch and Switch 2 games natively on Apple silicon Macs, iPhone and iPad. One script packs your game into a Mac app or an unsigned IPA that you sideload.

It is not an emulator: the game's own code runs directly on the Apple chip, with Switch graphics rebuilt on Metal. Nothing from any game is in this repository, and the project is not affiliated with Nintendo or any game publisher.

[Games](#games) · [Community front ends](#community-front-ends) · [Requirements](#requirements) · [How to play](#how-to-play) · [Discussions](#discussions) · [For developers](#for-developers)

## Games

The full [tested games table](dm/games/README.md#games) includes original Switch games, tested builds, engines and graphics APIs. Each game's note records its tested platforms, progress and known issues.

These Switch 2 games have passed Mac gameplay testing. Build them from a [`.nup` file or a dump folder](#switch-2-games):

- [Donkey Kong Bananza](dm/games/040074A01BF12000/README.md)
- [Fire Emblem Fortune's Weave](dm/games/04007EF01F8AE000/README.md) — up to 120 fps
- [Hyrule Warriors: Age of Imprisonment](dm/games/04003F40232DE000/README.md)
- [Kirby Air Riders](dm/games/040077201BE50000/README.md)
- [Mario Kart World](dm/games/0400C3F00006E000/README.md)
- [Mario Tennis Fever](dm/games/0400D4201C6EA000/README.md)
- [Pokémon Pokopia](dm/games/0400A3A01EE4C000/README.md)
- [Splatoon Raiders](dm/games/0400380020056000/README.md)
- [Star Fox](dm/games/0400E88025B1A000/README.md)
- [The Legend of Zelda: Ocarina of Time](dm/games/0400486024DEC000/README.md)
- [Yoshi and the Mysterious Book](dm/games/0400245021D2C000/README.md)

## Community front ends

Community projects build on nxnative with tools to turn your games into apps for your iPhone, iPad or Mac without the command line, and libraries to organize and launch them. They are separate projects: questions and bugs about them go to their own pages.

- [NX2Apple](https://github.com/LNPANDY/NX2Apple) — Mac builder with a shared iPhone/iPad game library.
- [NX Play](https://github.com/varyform/nx-native-wrapper) — Mac library with device installs and save sync.
- [NxNative Launcher](https://github.com/rennan101/nxnative_Launcher) — Mac launcher with guided builds and controller mapping.
- [LumaNX](https://github.com/Xc1Ym/LumaNX) — Mac game builder with IPA export.
- [GameCase](https://github.com/Tiaoge-tou/GameCase) — iOS game library based on LiveContainer.

## Requirements

- **Mac:** Apple silicon, macOS 26.6 or later. Building games requires Xcode 27.2.
- **iPhone:** A17 Pro chip or later, with iOS 26 or later.
- **iPad:** M1 chip or later, with iPadOS 26 or later.

The games' textures are BC-compressed, which older iPhones cannot read. Switch 2 builds are tested on the Mac; check each game's note for device-specific validation.

For a game without a profile, the script writes a survey and tries a provisional build with guessed settings. That build may not start; see [Port another game](docs/development.md#port-another-game).

## How to play

Switch 2 games are built from one `.nup` file or a folder of their files, not from NSPs, and are tested on the Mac only: see [Switch 2 games](#switch-2-games).

### Build from the command line

You need a Mac with macOS 26.6 or later, [Xcode](https://developer.apple.com/download/all/?q=Xcode%2027.2) 27.2, [Homebrew](https://brew.sh) and Python 3.12 or newer (an arm64 one, not an Intel Homebrew's). An iPhone build also needs Xcode's iOS platform (Xcode → Settings → Components).

The shaders are built with Xcode 27.2's Metal compiler. Select it before step 1: `sudo xcode-select -s /Applications/Xcode.app`. With several Xcode versions installed, name this one `Xcode-27.2.app` and select it with `sudo xcode-select -s /Applications/Xcode-27.2.app`.

**1. Install the tools** (only once), in Terminal:

```
xcodebuild -downloadComponent MetalToolchain
git clone https://github.com/seedds/nxnative.git && cd nxnative
brew install xcodegen zstd glslang
python3 -m pip install lz4 "capstone>=5,<6" fonttools nsz zbic "backports.zstd; python_version < '3.14'"
```

**2. Put your game in a folder**: the game, plus its update and DLC if you have them (`.nsp`, `.xci`, `.nsz` or `.xcz`):

```
~/Games/MarioWonder/
  Super Mario Bros. Wonder [010015100B514000][v0].nsp
  Super Mario Bros. Wonder [010015100B514800][v327680].nsp
```

**3. Build**, with your game folder and your `prod.keys`:

```
python3 scripts/build_ipa_from_nsp.py ~/Games/MarioWonder -k ~/keys/prod.keys
```

The IPA appears in the game's folder. The first build takes 30–60 minutes and needs free disk space of about twice the game's size plus 10 GB; building again is much faster.

To play on the Mac instead, add `--platform mac-app`: you get a Mac app of the game to open from Finder. All options: [The packing script in detail](docs/development.md#the-packing-script-in-detail).

### Install

Install the IPA on your iPhone or iPad with a sideloading tool such as AltStore, Sideloadly or LiveContainer. If your tool offers **Increased Memory Limit**, turn it on: the bigger games need it.

Game too big to install? Build again with `--romfs separate`, and run the command the script prints once to copy the game files to your phone ([Quick reinstalls](docs/development.md#quick-reinstalls)). With AltServer, also add `--shader-files`: it cannot install a file of 2 GiB or more.

Controls, saves and settings: [Playing](docs/playing.md).

### Switch 2 games

A Switch 2 game is built from one [NUP](https://github.com/a55uka/nup) container (a `.nup` file) or a folder of its files, not from NSPs. Neither needs `prod.keys`. A game this project has no profile for is surveyed and gets a provisional profile, as NSPs do ([Port another game](docs/development.md#port-another-game)), which may not boot. You get a Mac app; iPhone and iPad are untested.

**From a `.nup` file**, which holds the base game, its updates and DLC in one file. Give the file, or a folder that holds it:

```
python3 scripts/build_ipa_from_nsp.py ~/Games/DonkeyKongBananza.nup --platform mac-app
```

[Hyrule Warriors: Age of Imprisonment](dm/games/04003F40232DE000/README.md) is played this way: its 47 GB NUP unpacks in under five minutes. A NUP that carries the game's control data (its NACP) and icon gives the app the game's name and icon; otherwise the name comes from the game's profile and the app has no icon unless you give it one with `--icon <image>` (`ICON` in Spyder; a JPEG or PNG of any size).

A NUP without the base game also works, when its base package is empty or it has none and its updates are marked `standalone_update`: the update is taken as the whole game, and the script says so. If the game then stops on missing files, that update holds only what changed: pack a NUP with the base game. The newest update is selected by default; `--package v<N>` selects another version in the container. Such a container has no `v0` (base game) to select.

**From a folder of files**. The script expects this layout (`updates` and `dlc` are optional):

```
~/Games/DonkeyKongBananza/
  base/exefs/                     main, main.npdm, sdk, rtld
  base/romfs/
  updates/458752/exefs/           the update's version, as a decimal number
  updates/458752/romfs/           the patched RomFS, not a patch
  dlc/040074a01bf13001/0/romfs/   the DLC's title ID
```

```
python3 scripts/build_ipa_from_nsp.py ~/Games/DonkeyKongBananza --platform mac-app
```

An update's folder alone will do (no `base/`), and so will `exefs/` and `romfs/` directly in the folder, as `nup extract` writes them, which count as `base/`. The app has no icon, because the folder holds none; `--icon <image>` (`ICON` in Spyder) gives it one. To turn such a folder into a NUP: `nup pack ~/Games/DonkeyKongBananza game.nup`.

## Discussions

Questions, how a game runs on your Mac or iPhone, and ideas go in [Discussions](https://github.com/seedds/nxnative/discussions); [Issues](https://github.com/seedds/nxnative/issues) are for bugs, with the log. Ocarina of Time's performance (frame rate, resolution, which Macs hold 60 fps) is followed in [Ocarina of Time: state on main](https://github.com/seedds/nxnative/discussions/1789).

## For developers

[How it works](docs/development.md) · [Game notes](dm/games/README.md#games) · [Bring-up and debugging](docs/agents/README.md) · [Front ends](docs/frontends.md) · [Contributing](CONTRIBUTING.md)

## Acknowledgements

This project is built on other people's work ([licenses](dm/third_party/README.md)):

- **[d2r-mobile](https://github.com/jhaizhou-ops/d2r-mobile)** (MIT) developed this native-execution approach, for Diablo II: Resurrected. nxnative started as a copy of its generic parts: the NSO rewriter, the host that stands in for Horizon, the NVN-on-Metal layer and the iOS app shell. Fixes go both ways.
- **Ryujinx** (MIT): its shader translator (`Ryujinx.Graphics.Shader`, `Ryujinx.Common` and `Spv.Generator` 1.3.2, in `dm/third_party/ryujinx` with a few fixes listed in [its README](dm/third_party/ryujinx/README.md)) turns the games' shaders into SPIR-V. Its emulation of the kernel and system services is also a reference when the host's behaviour is in doubt.
- **[Atmosphère](https://github.com/Atmosphere-NX/Atmosphere)**: its kernel, mesosphère, is the reference for Horizon's synchronization semantics (address arbiter, condition variables).
- **[LibHac](https://github.com/Thealexbarney/LibHac)**: reads NSPs and layers updates over the base game in `dm/tools/nx_extract`.
- **[SPIRV-Cross](https://github.com/KhronosGroup/SPIRV-Cross)**: SPIR-V to Metal Shading Language.
- **[glslang](https://github.com/KhronosGroup/glslang)** compiles the GLSL of OpenGL games to SPIR-V for it.
- **[MacNativeGames](https://github.com/ly05010419/MacNativeGames)** (MIT): the GPU widening of 8-bit indices and in-pass clears in `dm/gfx/nvn/nvn_mtl.m`, and the visibility-counter lowering in the shader translator.

## License

MIT ([LICENSE](LICENSE)). Third-party code keeps its own license ([dm/third_party](dm/third_party/README.md)).
