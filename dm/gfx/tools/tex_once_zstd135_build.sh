#!/bin/sh
# Builds libzstd v1.3.5, the encoder Nintendo packed Super Smash Bros. Ultimate's data.arc with, as a dylib. Streaming API at an unknown size reproduces the archive's frames byte for byte.
# One minimal patch (tex_once_zstd135_norlelit.patch): no RLE literals, a feature the archive's frames never use (v1.3.5 never emits RLE blocks).
#   usage: tex_once_zstd135_build.sh <work dir> <output dylib>
# Fetches facebook/zstd at the pinned tag into <work dir>/zstd135-src (once; ZSTD135_SRC=<a clone that has the tag> skips the network), verifies the commit, applies the patch, compiles lib/common + lib/compress.
set -eu
TAG=v1.3.5
COMMIT=90ae50224d15e8dbcb9fa26b9be096366733db8e
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$1; OUT=$2
mkdir -p "$WORK"
SRC=$WORK/zstd135-src
if [ ! -d "$SRC/.git" ]; then
  if [ -n "${ZSTD135_SRC:-}" ]; then git clone -q "$ZSTD135_SRC" "$SRC"; git -C "$SRC" checkout -q "$COMMIT"; else git clone -q --depth 1 --branch "$TAG" https://github.com/facebook/zstd.git "$SRC"; fi
fi
[ "$(git -C "$SRC" rev-parse HEAD)" = "$COMMIT" ] || { echo "zstd source is not $TAG ($COMMIT)" >&2; exit 1; }
git -C "$SRC" checkout -q -- .
git -C "$SRC" apply "$HERE/tex_once_zstd135_norlelit.patch"
MAC=""; [ "$(uname)" = Darwin ] && MAC="-dynamiclib -mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET:-12.0}" || MAC="-shared"
clang -O2 -fPIC -DZSTD_MULTITHREAD=0 -DZSTD_LEGACY_SUPPORT=0 $MAC -I"$SRC/lib" -I"$SRC/lib/common" -I"$SRC/lib/compress" \
  "$SRC"/lib/common/*.c "$SRC"/lib/compress/*.c -o "$OUT.$$.part"
mv "$OUT.$$.part" "$OUT"
