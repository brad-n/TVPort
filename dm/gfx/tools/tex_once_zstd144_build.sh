#!/bin/sh
# Builds libzstd v1.4.4, the encoder Nintendo packed The Legend of Zelda: Ocarina of Time (Switch 2)'s .zs frames with (one-shot ZSTD_compress at level 19: content size, single segment; v1.4.1 to v1.4.5 make the same bytes), as a dylib.
# Unpatched: it emits the RLE literals and blocks the game's own frames contain.
#   usage: tex_once_zstd144_build.sh <work dir> <output dylib>
# Fetches facebook/zstd at the pinned tag into <work dir>/zstd144-src (once; ZSTD144_SRC=<a clone that has the tag> skips the network), verifies the commit, compiles lib/common + lib/compress.
set -eu
TAG=v1.4.4
COMMIT=10f0e6993f9d2f682da6d04aa2385b7d53cbb4ee
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$1; OUT=$2
mkdir -p "$WORK"
SRC=$WORK/zstd144-src
if [ ! -d "$SRC/.git" ]; then
  if [ -n "${ZSTD144_SRC:-}" ]; then git clone -q "$ZSTD144_SRC" "$SRC"; git -C "$SRC" checkout -q "$COMMIT"; else git clone -q --depth 1 --branch "$TAG" https://github.com/facebook/zstd.git "$SRC"; fi
fi
[ "$(git -C "$SRC" rev-parse HEAD)" = "$COMMIT" ] || { echo "zstd source is not $TAG ($COMMIT)" >&2; exit 1; }
git -C "$SRC" checkout -q -- .
MAC=""; [ "$(uname)" = Darwin ] && MAC="-dynamiclib -mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET:-12.0}" || MAC="-shared"
clang -O2 -fPIC -DZSTD_MULTITHREAD=0 -DZSTD_LEGACY_SUPPORT=0 $MAC -I"$SRC/lib" -I"$SRC/lib/common" -I"$SRC/lib/compress" \
  "$SRC"/lib/common/*.c "$SRC"/lib/compress/*.c -o "$OUT.$$.part"
mv "$OUT.$$.part" "$OUT"
