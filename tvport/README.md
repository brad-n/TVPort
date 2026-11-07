# TVPort

A Mac app that builds Switch games you own into Apple TV apps and installs them. It sits on [nxnative](https://github.com/seedds/nxnative) (MIT), which runs the game's own code natively with its graphics rebuilt on Metal. No games, keys or Nintendo artwork are part of this project.

Tested hardware: Apple TV 4K (3rd generation, A15), tvOS 27.2, Xcode 27.2.

## Run it

**The packed app:** unzip `TVPort-<version>.zip` and open TVPort.app from any folder. It is signed ad hoc and not notarized, so the first time macOS refuses it: open **System Settings > Privacy & Security** and press **Open Anyway**. At its first start it sets itself up (see [The packed app](#the-packed-app)) and lists anything else this Mac needs in **Setup**.

**From this checkout**, which runs the checkout's own engine:

```bash
cd tvport/app && xcodegen generate
```

```bash
xcodebuild -project tvport/app/TVPort.xcodeproj -scheme TVPort -configuration Release -derivedDataPath tvport/app/build build
```

```bash
open tvport/app/build/Build/Products/Release/TVPort.app
```

That build needs the project folder to stay where it was built, because it runs `tvport/backend.py` from there.

Add a folder holding your game's `.nsp` or `.xci` files, pick your Apple TV, and press **Build & Install**. A first build takes 30 to 60 minutes and needs your `prod.keys`. After that a build takes a few minutes, because the game's rewritten code and shaders are kept in `<title ID>_build`, beside the game by default.

**File > Settings…** lets you choose a default build folder. Each game gets its own subfolder there; its original game files stay where they are. A game’s **Build folder** section has two mutually exclusive checkboxes: **Default folder from Settings** and **Next to original files**, with the selected location below. Without a default folder, Next to original files is selected; clicking Default folder from Settings opens Settings so you can choose one. Changing the location copies an existing build, including its local save backups, on the next build and keeps the original. Allow space for both copies. A missing destination drive stops the build instead of creating a replacement folder. **File > Manage Saves** opens the save manager; the setup status icon is beside Manage Saves in the sidebar toolbar.

**Build queue:** while one game builds, select another and press **Add to Queue**. Each entry keeps its selected Apple TV and build options. Sidebar artwork shows Building or its queue position; the queue count includes the active game. Stop or failure pauses waiting entries until **Resume Queue**. The queue is kept for the current session, so leave TVPort open until it finishes. TVPort prevents automatic system sleep during setup and each conversion/build/install, while allowing the display to sleep.

**Signing expiry:** built game headers show the built app’s provisioning-profile expiry with a live countdown and local date/time. Free-account profiles normally expire seven days after issuance; the app reads the actual profile date rather than estimating from installation time.

**Artwork** is fetched automatically from Nintendo’s eShop image servers, using the game’s title ID and the [TitleDB](https://github.com/blawar/titledb) catalog. TVPort can identify the title ID from an existing build or a source filename containing a single base-game title ID. Images are cached in `~/Library/Application Support/TVPort/artwork`. If lookup fails, the game’s extracted icon is used when available. The lookup and product-selection code is adapted from [NX2Apple](https://github.com/LNPANDY/NX2Apple), with its MIT license included in the app.

**Choose Artwork** takes any image and overrides automatic artwork. **Use Automatic Artwork** switches back to the eShop image or game icon. **Framing > Crop to fill** adds 100–300% zoom and horizontal/vertical crop position controls. Drag the preview to reposition it directly; previews are cached while switching games. **Reset Crop** returns to a centered crop, and **Automatic** restores the original framing. Choices are saved per game and applied to the preview and generated Apple TV assets at the next Build & Install. Choosing a different image resets the framing. The preview is drawn by the same code as the real icon (`dm/ios/tools/tv_icon.swift`), which also makes the Top Shelf banners.

**Controller:** **Swap A/B** and **Swap X/Y** are independent choices for each game. Games using the older combined swap keep both enabled. The most recently chosen pair of settings is saved as the default for newly added games; existing games keep their choices. Apply changes to the Apple TV game with the next Build & Install.

**Advanced** (a collapsed group on the game page) holds per-game options for unusual cases. They are saved with the game, apply at the next Build & Install, and with everything off or empty the build is unchanged.
- *Allow a damaged game manual* passes `--allow-damaged-manual` to `scripts/build_ipa_from_nsp.py`, which lets `nx_extract` write a damaged offline HTML manual as read. Damaged game data still stops the build.
- *Extra extractor arguments* are shell-style words, each sent as `--nx-extract-arg=<word>`. The build script (or `NX_EXTRACT_ARGS` in its environment) appends them to every `nx_extract` extraction call (manifest, RomFS image, HTML), never to the `--title`, `--contents` and `--keys` checks. `--allow-damaged` among them also turns off reuse of earlier results.
- *Game memory paging* is Automatic (writes nothing, so the engine's default for the target applies: always on for tvOS, automatic for iOS/iPadOS, off for Mac), On (`DM_GUEST_FILE=1`) or Off (`DM_GUEST_FILE=0`) in the app's `env.txt`; `backend.py build --guest-file on|off`. It keeps the game's own memory in files on the Apple TV's storage so it does not count against tvOS's ~2.1 GB app limit (`guest_file_wanted` in `dm/host/hle_svc.c`). The saved value is the three-way choice, not a tvOS-only flag.
- *Compressed textures (ASTC)* is Automatic (on for the Apple TV), On or Off, with a block size of 4×4 (the default) or 6×6: `backend.py build --astc auto|on|off --astc-block 4|6`, written as `DM_NVN_BC_ASTC=4|6|0` in the app's `env.txt`. The Apple TV's GPU has no BC texture formats, so the game's BC1/2/3/7 textures would be stored as RGBA8; with this on they are stored as ASTC (a quarter of the RGBA8 size at 4×4, about 0.44 byte a texel at 6×6). After the game's files are extracted, Build & Install runs `dm/gfx/tools/bntx_astc.py` over the RomFS image (it needs Xcode's command line tools; every core, incremental: an unchanged game, engine and block size returns its earlier pack at once) and makes `tvport-astc/astc-ro.pack` in the build folder, which `install()` sends as one file beside `romfs.img` (`Library/Caches/astc-ro.pack`, same retries and size check, and a fingerprint kept beside the pack so a pack of the same size but other contents is resent). A texture whose planes are not in the pack stays uncompressed and the game encodes it in the background for the next launch. If the prebuild fails the build goes on without it. The saved value is the three-way choice and the block size, not a tvOS-only flag.
- *Metal 4 pipelines* writes `DM_PSO_MTL4=1` into the app's `env.txt` and sets `IOS_PULL=1` for `dm/ios/tools/build_ipa.sh`, so the pulling shader libraries the stand-ins need are kept.
- *Pipeline archive GPU* is passed as `--gpu` to the build script (for example `g18p`; several separated by commas). Empty keeps `--gpu none`, as before.
- *Extra environment switches* are `KEY=VALUE` lines merged into the app's `env.txt` (`backend.py build --extra-env`). Keys must match `[A-Z0-9_]+`; blank lines and `#` lines are skipped; a switch replaces a generated one with the same key.

**Install:** a transient `devicectl` failure (`CoreDeviceError 3002`, "Failed to locate coordinated install", timeouts, lost connection) is tried again, up to 3 attempts with a 5 s then 15 s pause, and each retry is logged. The game data (`romfs.img`) is checked and sent after every successful install, its copy is retried the same way, and the size on the Apple TV must equal the one on this Mac or the build fails.

**Last Run Stats** opens a panel immediately, then reads the game's log and the system's memory reports from the Apple TV. It shows performance readings, explanations and a selectable run log. If the TV cannot be reached or there are no readings yet, the panel explains what to do and offers Refresh.

**3D resolution** appears for a game whose rewritten code has a render-scale stub, the same test the iPhone launcher uses (`# RENDER_SCALE` in the main's fixups; `backend.py` `render_scale_supported`). That is Tears of the Kingdom 1.4.2 and 1.4.3, and Breath of the Wild 1.9.0. Below Full, the build writes `DM_RENDER_SCALE` into the app's `dm/env.txt`, so the game draws its 3D scene at that fraction of its size. The size is then fixed in place of the game's own dynamic resolution, and the menus stay sharp. It takes effect at the next Build & Install. On the A15, Tears of the Kingdom at 75% went from 15 to 30 fps in the area after the opening movie, with the GPU at about 28 ms a frame.

**Frame rate** appears for a game whose profile has a frame-rate target (`fps_target`, read from the derived profile first; the iPhone launcher's `DM_GAME_FPS_TARGET!=0`). 30 fps writes `DM_FPS_TARGET=30`. The TV then does half the work, so it heats up more slowly, and a game it cannot run at 60 is steadier: Tears of the Kingdom's area after the opening movie needs about 29 ms of GPU a frame at 75%.

**Hold 30 fps when the Apple TV is hot** appears for a game with a frame step (`# FPS_STATE_OFF` in the main's fixups; `frame_step_supported`), and it is on by default. The Apple TV 4K has no fan. When tvOS reports thermal state serious, it lowers the chip's clocks itself, below any app: on iPhones the GPU runs at about a third of its speed ([A thermally serious iPhone holds 30 fps](../docs/reference/frame-rate.md#a-thermally-serious-iphone-holds-30-fps)). No public API turns that off, and it is what protects the TV. With this on, the frame step holds 30 fps until the TV has been back to fair for 30 s. Turned off, the build writes `DM_THERMAL_CAP=0`, and the game keeps trying for 60 fps. It then rarely reaches 60 at the lower clocks, and the TV stays hot, and slow, for longer. Tears of the Kingdom reached serious within 20 to 40 s of a launch in most runs on 2026-11-03. That throttling also slows its loading, which runs on the CPU. What keeps a TV cooler is less work and air around it: a lower 3D resolution and frame rate, and a place that is not shut in a cabinet or set on another warm device.

### Separate Top Shelf cover

**Top Shelf Cover** accepts PNG or JPEG images. The drop area previews the central 8:3 composition (recommended source size 1920 × 720 pixels) with independent framing, zoom and horizontal/vertical position controls. Automatic framing preserves the whole image over a blurred background. The 2320 × 720 wide asset adds 200 pixels of background on each side, keeping important artwork out of those outer edges. It uses the game artwork by default; **Use Game Artwork** removes the custom cover. The generated app includes standard and wide Top Shelf sizes. Changes apply at the next Build & Install. New games and newly chosen covers default to Crop to fill; existing framing choices are kept.

### Updates and DLC from other folders

**Updates & DLC support is under development and may cause games to crash.** A successful build or package check does not guarantee that the updated game will run.

Drop NSP, XCI, NSZ or XCZ updates/DLC onto a game in the sidebar or its game page, or use **Updates & DLC → Add Files**. TVPort reads package metadata with your keys and rejects packages for another game or region. Original files stay where they are; reconnect external drives before building. Removing an attachment keeps the original file. Build & Install applies attached content and removes detached content from the next app build. The engine selects the newest available update/DLC version. Content already in the original game folder is still discovered there.

## SwitchTV, the launcher

SwitchTV is a small Apple TV app that lists the games TVPort built and opens one with a press of Select. It lives in `tvport/switchtv/` (SwiftUI, tvOS 17+, bundle ID `dev.tvport.<team>.switchtv`); every colour is in `Sources/Theme.swift`.

**The home screen** (`Sources/HomeView.swift`) works like Plex or Netflix on the Apple TV. The top is a hero that follows focus: the game's artwork across the whole screen under a gradient, its title, publisher, year, players, genres and the first lines of its description, which crossfade to whichever poster has focus. The hero never scrolls; the poster rows (Recently Played, newest first; All Games, A-Z; one row per genre with at least two games) scroll in the space below it.

**Select plays the game.** Long-press Select opens a small menu (Play, Details); the Play/Pause button opens the details page (description, publisher, release date, players, genres, screenshots, and a Play button). A game whose app was built before this feature has no `switchtv-<id>` URL scheme, so SwitchTV cannot open it: it says "Rebuild <game> in TVPort to play it from SwitchTV" (an alert on Select, and a line on the details page) and never does nothing silently.

How it opens a game: each game app TVPort builds answers the URL scheme `switchtv-<title ID in lowercase>` (`dm/ios/project_tv.yml`, `CFBundleURLTypes`; the host just comes to the front). SwitchTV lists every game's scheme in `LSApplicationQueriesSchemes`, asks `canOpenURL`, and opens `switchtv-<id>://play`.

**Recently played** is shared through a keychain access group, `<team>.dev.tvport.switchtv` (`Shared/SharedStore.swift`): one keychain item per game (service `dev.tvport.switchtv`, account the title ID in capitals, value the Unix time of the last play). SwitchTV writes it when it opens a game; a game app writes its own when it comes to the front (`dm/ios/SourcesTV/TVLastPlayed.m`, from the next TVPort build of the game, which also gets the `keychain-access-groups` entitlement), so a game started from anywhere counts. A copy is kept in SwitchTV's preferences. It is a keychain group rather than an App Group because an App Group needs an App ID registered in the developer account, which Xcode can only do with an Apple ID signed in under Xcode > Settings > Accounts; the keychain group works under the wildcard profile automatic signing already has. Without the entitlement every call fails quietly.

**Top Shelf.** SwitchTV has a Top Shelf extension (`TopShelf/ContentProvider.swift`, `com.apple.tv-top-shelf`). With SwitchTV in the top row of the home screen, the shelf shows Recently Played (up to 8) then All Games, each with its poster; Select on one opens the game directly when its app can be opened (SwitchTV records which can, after it has run once), else opens SwitchTV on that game's details (`switchtv://game/<title ID>`). Until a game has been played, or SwitchTV has been opened, the shelf lists All Games with links into SwitchTV. The extension carries its own copy of the catalogue and images.

Putting it on the Apple TV: **Install SwitchTV** (toolbar, and in the Apple TV section of the settings), or `backend.py switchtv install --device <id>`. `switchtv catalog` only writes the catalogue, `build` builds without installing, and `sync` installs only when the catalogue changed (a fingerprint of the catalogue, its images and the app's own files, kept per Apple TV). The catalogue is made from the library, the artwork cache and blawar/titledb's US list (fetched once, about 90 MB, into `switchtv-cache/` in TVPort's folder; `TVPORT_SWITCHTV_CACHE` moves it). Fields the list lacks are simply left out. Under Settings, **Keep SwitchTV up to date** (on by default) refreshes SwitchTV after every Build & Install and after a game is removed; a failure there is a warning in the log and never fails a game build.

tvOS has no way for an app to put other apps in a home-screen folder: new apps appear at the end of the home screen. Make a "Games" folder there once by hand (hold the clickpad on an app, choose New Folder) to keep the top row clean.

### Changing the icon

The one file to swap is `tvport/switchtv/Branding/switchtv-icon-source.png`: a square PNG (the owner's is 1254 x 1254) with the mark above a wordmark on a white background. `Branding/make_branding.swift` cuts the mark (the App Icon, centred on the logo's own white) and centres the whole logo (the Top Shelf images), and `dm/ios/tools/tv_icon.swift` (with `DM_ICON_BACKDROP`) lays them out as the layered tvOS assets, on every install. If the new logo has its mark somewhere else, change `markRect` in `make_branding.swift`; if its red differs, set `accent` and `ink` in `Sources/Theme.swift` (`make_branding.swift` writes the sampled colours to `colors.txt`).

## The packed app

`python3 scripts/package_tvport.py` makes `tvport/dist/TVPort.app` and `TVPort-<version>.zip` (about 50 MB), an app that runs on any Mac without this checkout. It carries:

| In the app | What it is |
|---|---|
| `Contents/Resources/engine.tar.xz` | The engine: the tracked files of `dm/` and `scripts/` and `LICENSE`, 2,300 files, 300 MB unpacked. `engine.json` names its digest, commit and shader chain |
| `Contents/Resources/backend.py`, `requirements.txt` | This folder's, unchanged |
| `Contents/Helpers/uv` | [uv](https://github.com/astral-sh/uv), which makes the engine's Python |
| `Contents/Resources/Licenses` | nxnative's MIT notice, the engine's third-party licenses and uv's. The About window says the same |

At its first start the app unpacks the engine into `~/Library/Application Support/TVPort/engine/<digest>`, because the engine's tools write beside themselves and a signed app must not change. Then uv downloads Python 3.14 and the packages in `requirements.txt` into `python` and `venv` beside it: about 110 MB, a few seconds, and requires the internet. Automatic eShop artwork also needs the internet on its first lookup. Nothing goes into `~/.local` or a shared cache.

It cannot carry these, so **Setup** checks each and gives the command or the place to fix it:

- **Xcode** with its tvOS and iOS platforms and the Metal toolchain. The shaders are iOS Metal libraries, so a tvOS build needs the iOS platform too.
- **An Apple ID** signed in to Xcode (Settings > Accounts). A free one works, and TVPort finds its personal team itself.
- **xcodegen, zstd and glslang** from Homebrew, and the **.NET SDK 10**, which builds the game extractor and runs the shader translator.
- **Your own game dumps and `prod.keys`.** They stay in the folders you choose. TVPort reads the keys only during a first build.

**Updates:** a new TVPort.app carries a new engine. Its first start unpacks that engine, and its first build removes the engines of earlier releases. The Python is made again only when `requirements.txt` changes. Games already built keep their `<title ID>_build`. A new shader chain rebuilds a game's shaders at its next build, which then needs `prod.keys` again. The app does not look for updates itself.

**Never in the app:** game files, keys, built game apps, or anything a build makes. Only tracked files go into the engine, so a profile's shader tables from a game's build (`c1_full.tsv`, `cb_extent.tsv`), extracted files and builds in the checkout stay out. The script stops at a tracked file that looks like one of these, or that `.gitignore` says a build makes. It also leaves out `dm/tools/fuzz`, whose inputs are made-up game files. The game profiles nxnative publishes in `dm/games` are part of the engine. Built games must never be shared: each person builds from their own dumps.

`TVPORT_DATA` moves the app's folder, for a test run.

## What differs from nxnative

| Change | Where | Why |
|---|---|---|
| tvOS target | `dm/ios/project_tv.yml`, `SourcesTV/`, `build_ipa.sh` (`DM_TVOS=1`) | The app itself |
| Files in `Library/Caches` | `dm/ios/Sources/main.m` | tvOS apps have no lasting `Documents` |
| Controller routing | `front_ios.m` (`GCEventViewController`) | Keeps a controller's B button from also acting as the remote's Back |
| BC textures without BC hardware | `dm/gfx/nvn/nvn_mtl.m`, `dm/gfx/tex/nvn_bcdec.c` | The A15 can't read BC. BC1-5 decode in a GPU kernel, BC6H / BC7 / 3D on every CPU core. Restored from upstream's history (removed in `14fbcf9c`) |
| `DM_BC_MAX_DIM` | `nvn_mtl.m` | Drops the finest mip levels of those textures, which cost 4 to 8 times their Switch size once decoded |

Measured after these changes on the same scene load: 264 textures took 47 ms instead of 271 ms. Once the game had seen a scene, a run had 1 long frame instead of dozens.

The shaders are iOS Metal libraries, which tvOS 27 loads. TVPort 1.1 used chain `d1043b780a74`; the local 1.2 engine update uses `0ad559cdbb28`, matching the nxnative revision below. Existing games need their shaders rebuilt when next built with this engine. Previously installed game apps keep their own engine and shaders.

### Local 1.2 engine update

The engine is merged from nxnative revision `777a5f6c618a38cd2d7f795f465466fb56920534`, the upstream revision pinned by NX2Apple v1.1.1-rc2. This is the nxnative core with TVPort’s Apple TV adaptations, not NX2Apple’s complete patched engine. Unity 6000.3 parsing is included upstream. The pinned Metal compiler is `32023.922` (Xcode 27.2).

TVPort keeps its save/player integration, controller routing and button swap, BC texture decoding for the A15, and memory residency controls. UIKit touch menus and haptics stay iPhone-only. tvOS has no WebKit: HTML applets keep the existing no-web-view fallback, and actual HTML menus remain unsupported. Multi-program handoff records the next program for reopening from Home; tvOS cannot offer the iPhone’s relaunch notification.

Build 20 fixes an Apple TV startup regression from the merge: the iPhone hardware-BC check blocked the A15 before TVPort's texture decoder could run. See [the startup check](../docs/reference/rendering.md#gpus-without-bc-textures-are-refused-at-start). Previously built game apps must be rebuilt and installed with this corrected engine; updating the Mac app alone does not change their bundled runtime. The shader chain is unchanged by this fix.

The 1.2 work is separate from the stable 1.1 source and release. A successful unsigned synthetic tvOS build checks compilation and linking without game files or a signing slot. Game shader compilation and Apple TV gameplay regression runs are deferred at the owner’s request; the upstream game list does not establish Apple TV compatibility.

Validation: the Mac host and unsigned tvOS fixture compile and link; 84 TVPort tests, 19 Unity parser tests, iOS tool tests (42 passed, one skipped), GPU pool residency/chunk/readback tests, controller command tests, frame-limit tests and operating-environment tests pass. The Python lint ratchet has no new findings. The broad tool suite exposed an existing metadata mismatch: the TVPort frame-step patch also supports TOTK 1.4.2, while the profile registers only 1.4.3. The same registry test fails in the stable 1.1 source. The tested 1.4.2 patch is retained rather than changing which shader profile a build selects.

## Why games stutter or close

Measured on the A15 with Super Mario Odyssey, before these changes:

- **Closing:** tvOS kills an app at 2,097 MB, with no crash report: at most a `JetsamEvent` report with `per-process-limit`, and not every kill files one.
- **Stutter:** mostly texture loading, not shaders. One 556 ms frame spent 285 ms on 264 textures and none on shaders, because they were decoded on the CPU on the thread that submits the frame.
- **Some frames miss 60 fps on the GPU alone:** 17 to 23 ms a frame in docked mode.

## Getting past the memory limit

tvOS ends an app at 2,097 MB of *footprint*, and the Switch gives a game about 3.2 GB of its own, so a large game cannot fit in anonymous memory, the kind footprint counts. Footprint leaves out file pages. So on tvOS the game's memory is a shared mapping of a sparse file (`guest_file_init` in `dm/host/hle_svc.c`, on by default on tvOS), which the system pages to flash when it needs the room, as a swap file. This needs no entitlement and no paid account, only public APIs. `DM_GUEST_FILE=0` turns it off.

Super Mario Odyssey in Handheld at Medium texture detail, on an A15 Apple TV 4K, in MiB:

| | Anonymous memory | File-backed |
|---|---|---|
| During boot | 879 | 242 |
| Where it was killed | 2,097 | under 700 |
| Peak footprint | 2,097, then killed | 924 |
| Lowest headroom | none | 1,173 |
| Textures loaded | about 500 | 846 |
| Peak Metal allocation | 1,514 | 2,298 |

That run held 59-60 fps after the transition, and tvOS filed no kill. Its length was under 5 minutes, because the game left the foreground cleanly at 4:48. Longer sessions and later kingdoms are untested.

The trade-offs: the game needs up to 4 GB of free storage while it runs, which the system takes back when it ends, however it ends. It adds flash writes. A scene that uses more memory than the TV has free will read pages back from flash, which can hitch. Textures and render targets are still counted against the limit, so Full texture detail is not free.

To measure a run, pass the profiler at launch, because it starts before `env.txt` is read and `Documents` is not writable:

```bash
xcrun devicectl device process launch --device <UDID> --terminate-existing -e '{"DM_MEMSTAT":"../Library/Caches/memstat.tsv"}' <bundle ID>
```

## Saves

tvOS has no lasting storage for files: on tvOS 27.2, `Documents` refuses writes and `Application Support` cannot be created, and `Library/Caches`, where the game keeps its saves, can be purged while the app is closed. Preferences do last. A save is mostly zeros, so it fits there: Super Mario Odyssey's 2 MB save packs to 9 KB.

| Copy | Where | Survives |
|---|---|---|
| Working | `Library/Caches/save` on the TV | Until tvOS purges it |
| Protected | The app's preferences, seconds after each save (`dm/ios/SourcesTV/TVSaves.m`) | A cache purge, a reinstall. Not deleting the app |
| Backup | Managed save copies on this Mac or in iCloud Drive’s `TVPort Saves`, plus existing build-folder backups. Checked every 30 minutes while TVPort is open | Anything that happens to the TV |

The protected copy comes back by itself when the save folder is empty. Build & Install backs up first, and puts the newest backup on a TV that has lost its saves. Automatic recovery checks both working saves and persistent copies before writing; if either exists, or their absence cannot be verified, recovery is skipped. For manual backups, open **Manage Saves** and choose **Back Up to Mac** or **Back Up All Saves**.

### Manage Saves

**Manage Saves** opens a separate window with the native games installed on the selected Apple TV, including games absent from the Mac library. Select a game to see its save slots and these actions:

Saved backup records are loaded from this Mac and accessible iCloud Drive folders before contacting the TV. When the TV is unavailable, **Games** still lets you browse previous backups and open their save files in Finder. Devices with saved backups remain selectable even if Xcode cannot currently discover them. Restore and new Apple TV backups require a reachable TV and an accessible installed game; importing a new local copy works offline. An offline backup does not imply the game is still installed. iCloud-only files must be downloaded and accessible locally to browse them offline.

- **Import Save Copy:** opens a folder picker and adds a new independent saved copy for the selected game. It works offline and does not change or contact the Apple TV. Each import gets its own entry labelled **Local import**; earlier copies are retained. Choose the folder containing the save files, for example from Ryujinx, another compatible emulator, or a native Mac game. Files must match the game and its save format. Quit the Mac game before copying its save.
- **Back Up to Mac:** makes a read-only copy of the selected Apple TV save slot. **Show in Finder** reveals the ordinary save folder for use with a compatible Mac game or emulator.
- **Back Up All Saves:** copies every available player and shared save slot from supported games installed on the selected Apple TV. Empty slots are skipped; failures are reported while other backups continue. Each successful copy appears in that game’s Saved Copies & Backups and can be restored individually.
- **Saved Copies & Backups / Restore to Apple TV:** entries are labelled **Local import**, **Automatic backup**, **Apple TV backup**, or **Safety backup** to show where they came from. Restore asks you to choose an existing player/save slot on the TV. Restoring backs up the current save first, so it too can be undone. **Show in Finder** opens the backup’s **Save Files** folder directly; `record.json` stays outside the game’s save files. Older `before` folders are renamed when accessed, and remain readable under their old name if that location is read-only.

Restoring to the Apple TV closes only the selected game, snapshots its existing save before writing, replaces the selected slot rather than merging stale files, and reads the transfer back to verify its contents. If copying or verification fails, TVPort attempts to restore the original automatically and reports whether recovery succeeded. Other players’ slots are left alone. The persistent tvOS save is accounted for so it does not overwrite the imported files on next launch. After a successful verified restore, TVPort sends a completion notification or shows an in-app confirmation if notifications are unavailable. No game rebuild is needed to restore to an existing player. To add another player, update the game’s **Players** setting and rebuild first. Games with a shared console save still share that save; TVPort does not merge a game’s internal save slots.

**Keep backups in iCloud Drive**, in Manage Saves, applies to new automatic backups, manual backups, local imports and originals saved before restore. Manual backups normally live in `~/Library/Application Support/TVPort/save-imports`; with iCloud enabled and available, new copies go into `iCloud Drive/TVPort Saves/Managed Backups`. Earlier copies stay visible and restorable from either location when the setting changes. If iCloud Drive is unavailable, backups stay local and the window shows a notice. This stores backup folders in iCloud Drive; it is not direct cloud-save syncing on the Apple TV.

Local imports and manual backups are kept until you remove them yourself and are separate from the automatic build-folder backups below. Only developer apps whose save containers Xcode can access are eligible; **Show other apps** lists the rest without enabling import. Wake and pair the Apple TV through Xcode if it cannot be reached.

### Automatic backups

While TVPort is open, it checks saves for all supported games installed on the selected Apple TV every 30 minutes, including games built on another Mac or whose local build folders are unavailable. It only reads the TV and never launches or closes a game. Rounds wait while a build or save transfer is active. An unavailable TV is retried at the next 30-minute check; an inaccessible game does not stop the remaining games from being checked.

- **Changed saves only:** TVPort compares verified file contents with the newest saved backup for that player/slot. Identical copies do not create another backup. Checking still requires transferring the save data.
- **Consistent copies:** after copying, it checks the file listing again. If a game saved during the copy, that incomplete backup is discarded and a later round tries again.
- **Newest 10:** each game/player slot on each Apple TV keeps the newest 10 automatic backups. Cleanup follows a new verified backup; manual backups, local imports, safety backups and older unlabelled copies are preserved.
- **iCloud Drive:** new managed copies go to **iCloud Drive → TVPort Saves** when enabled and available, or to TVPort’s local backup folder otherwise. Manage Saves browses both locations. Existing build-folder backups remain usable.
- **Visible progress:** Manage Saves remains available for browsing during automatic backup. Status messages explain when a round is running or awaiting a retry. Builds can be queued to start when the round finishes.

The preferences abort the app past about 1 MB, so TVSaves.m keeps them under 900 KB, and a save that would pass that goes to a plain file in `Library/Preferences`. That folder took a write in testing, but Apple does not promise to keep it. `NSUserDefaults` is the documented one. Animal Crossing's island always goes there: it is 24 MB of encrypted files that do not compress. Saves are stored with LZFSE, which takes a fraction of a second, and the copy starts as soon as the app stops being active, so closing it from the app switcher right after a save no longer loses the copy.

### Players

Apple's way to give each Apple TV profile its own data is the User Management capability, which a free Apple ID cannot have: Xcode refuses it, so the app cannot see which profile is active. With two or more names in **Players**, the game asks "Who's playing?" before it starts, and each name gets its own saves (`dm/ios/SourcesTV/TVPlayers.m`). The first name listed keeps the save already on the TV, whoever picks first, and a name keeps its saves for good, so renaming someone starts them fresh. A game whose only save belongs to the console keeps one save for everyone instead, as on a Switch: in Animal Crossing each name is a resident of the same island, and the first name listed keeps the first user. Up to 8 names.

## Limits

- **Memory:** the file-backed guest memory above is what keeps a game under the limit. Everything else, mainly textures and render targets, still counts toward 2,097 MB. The Increased Memory Limit entitlement is silently dropped for a free Apple ID on tvOS.
- **Free Apple ID:** an install stops opening after 7 days. Build & Install renews it. Free accounts also have limits on apps and App IDs, so keep a game's bundle ID, which TVPort does for you.
- **Game files live in `Library/Caches`**, which tvOS may purge when storage runs low. Build & Install sends them again. Saves are protected separately: see [Saves](#saves).
- **First-use shader stalls.** The game records each shader on the TV, and each build copies that list to `tvport-shaders.tsv` beside the game and bundles it, so deleting the app does not lose it. A scene the game has never shown can still stall the first time.
- **Back stays in the game.** The remote's Back and a controller's B do not leave it. Use the TV button.
- **Launching needs an awake TV.** Installs work while it sleeps.
- Only one build runs at a time.

## Tests

```bash
python3 -I tvport/tests/test_backend.py
```

They need no Apple TV, and they never touch `~/Library/Application Support/TVPort` or iCloud Drive.
