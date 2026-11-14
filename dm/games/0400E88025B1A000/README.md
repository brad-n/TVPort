# Star Fox (`0400E88025B1A000`)

A Switch 2 game: update v131072, SDK 21.4.4 built for the Switch 2 (`Ounce`), NVN2 with DLSS. A custom engine (its own prefixes: `vfs`, `vrender`, `vjob`, `vscript`, `vspirv`, `veffects`, `vphysics`; project name `eclipse`), with Wwise 2024.1 for audio, Bullet physics and NPLN for online play. Modules `main`, `sdk`, `subsdk0` (the SDK's movie module), `subsdk3` (`nn::camera`); `subsdk1` (the C library) and `subsdk2` (`NintendoSDK_DLSS`) are shipped but `main` imports nothing from them. **Plays on the Mac** (M4 Pro, 48 GB): the title, the prologue cinematic and the tutorial flight, with sound. The tutorial runs at 56 to 60 fps with a 4K screenshot every 4 s and at 60 without them; the cinematic at 30 fps, which looks like the game's own choice (not checked). Scripted input here reached the tutorial's first lesson and worked its options menus; flying under input has not been watched on this Mac (pull request #1259's author reports 7 minutes of it with a controller on an M5 Max). No IPA has been built.

## What it needs

| Setting | Where | Why |
|---|---|---|
| `mem_alias 0x400000000`, `mem_reserve 0x550000000`, `mem_stack 0x10000000`, `app_pool 0x240000000` | [`game.tsv`](game.tsv) | the Switch 2's 9 GB. The alias region mapped up to +8.26 GB of its 16 GB, 6.78 GB at most at once, through the tutorial's start; 8.5 GB resident, 4 GB of it allocated on the GPU |
| `sys_resource 0x1000000` | `game.tsv` | the NPDM declares 16 MB, so virtual address memory is on; `main` never sets a heap |
| `modules main subsdk0 subsdk3 sdk` | `game.tsv` | `main` imports 17 movie functions from `subsdk0` and 19 `nn::camera` functions from `subsdk3`, nothing from `subsdk1` or `subsdk2` |
| `romfs_marker data.zip` | `game.tsv` | the RomFS has two files, and this is the game |
| `zip_store .zip:.metallib` | `game.tsv` | the archive's members are LZ4-compressed already |
| `shader_groups /data.zip=shader` | `game.tsv` | every shader is a member of the archive |

One game-specific patch, the render scale and dynamic resolution stubs of [`patches.py`](patches.py) ([The picture](#the-picture)), and only v131072's build row: the base game, v0, has not been run.

## Files

- A NUP container of 30 GB: a base package (v0) and an update package (v131072), each with its own ExeFS and RomFS. Neither package carries a NACP or an icon, so the name comes from the profile, the display version is the placeholder `v131072`, and the app has no icon.
- The RomFS is two files: `data.zip` (14.5 GB) and `veclipse_build.cvar` (a JSON line: `system.is_shipping_build: true`). `main` opens `rom:/data.zip` through its own virtual file system (`vfs.zip.c`): [LZ4-chained zip members behind a VZIP preamble](../../../docs/reference/shaders.md#lz4-chained-zip-members-behind-a-vzip-preamble-and-shader-binaries-of-one-stage). Its 114,154 members are named by a 16-digit hash with no folders or extensions; 92,069 are chained, 22,085 (the Wwise `RIFF` sound files and `BKHD` banks) stored plain.
- `main` is 192 MB of code with 1,036 imports, of which the host and the other modules supply all but two (gRPC thread-local initialisers, `_ZTH…`). No shader is in any code module.

## Shaders

2,856 in [`shader_map.tsv`](shader_map.tsv): 1,483 vertex, 1,305 pixel, 68 compute; 2,828 one per archive member, no task or mesh shaders, and the rest from the two NDSR upscaler networks embedded in `VIPR` containers. All of them translate. A build takes about 4 minutes in all on an M4 Pro. Each member is the engine's shader binary (`_vrender_shader_binary_t`), read as a single-stage program and paired at draw time (`separable_pairs`: 1,480 cover pairs).

## The picture

- **The size is the game's own.** Docked on a 1080p screen every 3D target is 768x432, and that is the top of the game's dynamic resolution, not its floor (as this note supposed until 2026-11-13). The host answers `vi::QueryDisplayBufferMaxResolution` with the display it is shown on, 1920x1080 here, as a Switch 2 on that screen would. The game's NDSR networks output 0.8 of it, 1536x864; the 3D views are that times `render.resolution_scale`, 0.5 docked (768x432 at the default; the console override at 0.75 and 1.0 gave 1152x648 and 1536x864; `render.resolution_scale_console`, "Nintendo only", overrides it when not zero), capped at 1.0 by the frame function (`main+0xb447300` on v131072, the cap at `+0x25e4`). MetalFX stands in for DLSS at 768x432 to 768x432, the networks take that to 1536x864, and the game scales it to the 1920x1080 picture in the top-left of the 3840x2160 swap chain. A console on a 1080p TV renders the same.
- **Its dynamic resolution works and sits at the top.** The update (`main+0xb45ae40`, `render.dynres_*`) runs within 0.5 to 1.0 of those views. Probes on the base M2 Mac mini at the title and in the main menu: mode 1, a proportional controller (each of the last 16 frames' scale times the square root of the budget over its GPU time, weighted 0.9 a frame, every 8 frames); a budget of 15 ms (0.9 of the 16.7 ms frame); a GPU time of 13.0 ms p50 (the frame's start-to-end span, 13.9 ms, less a bracketed section of about 0.8 ms), against the host's own 13.1 ms busy and 13.9 ms span; and an output of 1.07 to 1.13, clamped to 1.0. In the 30 fps cinematics (a 33 ms budget, 20 ms of GPU) it stayed at the top too, once dipping to 758x426. So the host's timer is right and the controller is not the cause: the game was rendering at its own docked size.
- **Raising it.** The render scale (`DM_RENDER_SCALE`, the launcher's **Render scale**, 0.5 to 2.0) multiplies the game's resolution scale before its cap: 1.5 renders 1152x648, 2.0 1536x864, the networks' own output size (they then pass it through at 1:1). `DM_DYNAMIC_RESOLUTION` (**Dynamic resolution**, off by default) lets the game's controller lower the size under load; off, its output is handed on as its top, so the size is fixed. Both are function-matched stubs in [`patches.py`](patches.py) (the frame function's and the update's fingerprints; their sites lie 180 MB into the text, so their code goes in the back patch area: [rewriter](../../../docs/reference/rewriter.md)). With the stubs `main` has a frame step state page, so a `DM_FPS_TARGET` would pace it: leave it unset.
- **Cost.** On Apple GPUs this game's cost hardly depends on the 3D size (as for [Ocarina of Time](../0400486024DEC000/README.md#dynamic-resolution)): through the overlay below at 1152x648 (2.25 times the pixels) the base M2 Mac mini held 60.0 fps at the title (GPU busy p50 11.4 ms, 12.9 at 768x432) and in the main menu (12.9 ms, 12.1), and 30 fps in the cinematic (19.7 ms, 20.3), every run the same route on the same save, 20 s, 15 s and 15 s windows (2026-11-13). 1536x864 and play in a level were not measured yet: the TV was in use.
- **A 4K display** (`render.present_resolution_override` 3, "2160p", through a RomFS overlay: below) makes the networks output 3072x1728 and the 3D 1536x864 at the game's own scale, and the host scales the 4K picture down to the 1080p screen. Not measured yet.
- **Cvars from a RomFS overlay.** The game reads `rom:/veclipse_build.cvar` (JSON) at boot and takes any cvar in it, so `DM_ROMFS_OVERLAY=<folder>` with a copy that adds keys sets them without a build: `render.resolution_scale_console` (0.75, 1.0), `render.present_resolution_override` (0 default, 1 1080p, 2 1440p, 3 2160p), `render.dynres_enabled`. Measuring the sizes above that way needed no stub.

## Driving it on the Mac

`python3 scripts/build_ipa_from_nsp.py <folder> --platform mac` builds the Mac shaders and the host and prints the run command. Headless, through `DM_CTL`: the title is up about 40 s after boot and `A` starts the game. The prologue cinematic follows, about 4 minutes on every run (a save holds no progress yet, and skipping it was not tried), then the tutorial's first question, about 300 s after boot: `LDown`, `A` answers no. Shots of the swap chain hold the picture in their top-left quarter. A `shot` takes about 165 ms: a hitch every few seconds in a run that takes them is the shot's.

## Found on this game

- [SDK 21 socket initialization and overloads](../../../docs/reference/services.md#sdk-21-socket-initialization-and-overloads) and [Socket `Poll` and `Select` with nothing to wait on](../../../docs/reference/services.md#socket-poll-and-select-with-nothing-to-wait-on): the game's HTTP thread aborted on a failed `poll`.
- [SDK 21's OutputStream on a virtual output device](../../../docs/reference/audio.md#sdk-21s-outputstream-on-a-virtual-output-device) and [SDK 21's hardware Opus decoder manager](../../../docs/reference/audio.md#sdk-21s-hardware-opus-decoder-manager): its voice and music.
- [GameChat queries from the title screen (SDK 21)](../../../docs/reference/services.md#gamechat-queries-from-the-title-screen-sdk-21): a null read in `nn::chat::GetChattingUid`.
- [The camera commands of SDK 21's own camera module](../../../docs/reference/services.md#the-camera-commands-of-sdk-21s-own-camera-module): the game's own camera module, a console with no camera plugged in.
- [sRGB textures loaded and stored raw through an image](../../../docs/reference/rendering.md#srgb-textures-loaded-and-stored-raw-through-an-image): the pale picture with grey blacks (the upscaler network's encoded store was encoded again); measured on a build of our fork, not on `main`.
- [A GPU copy into a texture uploaded from its storage uploaded all of it again](../../../docs/reference/nvn-objects.md#a-gpu-copy-into-a-texture-uploaded-from-its-storage-uploaded-all-of-it-again): 7.6 s and 10 s frames at the prologue's scene changes; measured on a build of our fork, not on `main`.
- [The DLSS network resized](../../../docs/reference/rendering.md#the-dlss-network-resized): `nvnDlssNetworkResize`.
- [TXD through a uniform register kept no handle](../../../docs/reference/shaders.md#txd-through-a-uniform-register-kept-no-handle): 281 pixel shaders, the fur shells among them.
- [A handle pair ORed sampler word first](../../../docs/reference/shaders.md#a-handle-pair-ored-sampler-word-first): 62 pixel shaders.
- [NVN2 compute's separate handles in c\[0\]](../../../docs/reference/shaders.md#nvn2-computes-separate-handles-in-c0): `1002069a331ceded`, dispatched in the prologue.
- [Ampere BMSK and the read of a covered pixel](../../../docs/reference/shaders.md#ampere-bmsk-and-the-read-of-a-covered-pixel): the last 3 shaders, `58046f286de779e1`, `46040940ce0fd49b` and `826168691af2e211`, none asked for in play so far.
- [Compute pipelines compiled at first use](../../../docs/reference/shaders.md#compute-pipelines-compiled-at-first-use): 233 compute pipelines in the app's archive, none built at the title.
- [Compute pipelines outside the bundled archive built at every start](../../../docs/reference/shaders.md#compute-pipelines-outside-the-bundled-archive-built-at-every-start): the second headless start took its 8 from the device's archive.

## Open

- `[RED] DLSS: the game's bias mask (a reactive mask for MetalFX) is not passed on`.
- The game's wake-up eventfd fails (the host refuses `nn::socket::EventFd`), so its HTTP thread polls without a wake-up; harmless offline.
- A `pso_manifest.tsv` has not been recorded; `render_cond` not tried; the later levels and combat, and iOS, not tested.
- Mario Kart World 1.8.0 has not been run with the camera answers changed for this game.
