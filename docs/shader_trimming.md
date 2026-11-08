# Shader trimming (WIP design note)

Status: work in progress. Numbers below are measured on the Mac mini from the built apps; the design section is still to be written.

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
