#!/bin/sh
# Builds libzstd with RLE blocks and RLE literals disabled (tex_once_zstd_norle.patch) as a dylib.
#   usage: tex_once_zstd_build.sh <work dir> <output dylib>
# Fetches facebook/zstd at the pinned tag into <work dir>/zstd-src (once; ZSTD_SRC=<a checkout of that tag> skips the network), applies the patch, compiles lib/common + lib/compress.
set -eu
TAG=v1.5.7
COMMIT=f8745da6ff1ad1e7bab384bd1f9d742439278e99
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$1; OUT=$2
mkdir -p "$WORK"
SRC=$WORK/zstd-src
if [ ! -d "$SRC/.git" ]; then
  if [ -n "${ZSTD_SRC:-}" ]; then git clone -q "$ZSTD_SRC" "$SRC"; else git clone -q --depth 1 --branch "$TAG" https://github.com/facebook/zstd.git "$SRC"; fi
fi
[ "$(git -C "$SRC" rev-parse HEAD)" = "$COMMIT" ] || { echo "zstd source is not $TAG ($COMMIT)" >&2; exit 1; }
git -C "$SRC" checkout -q -- .
git -C "$SRC" apply "$HERE/tex_once_zstd_norle.patch"
MAC=""; [ "$(uname)" = Darwin ] && MAC="-dynamiclib -mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET:-12.0}" || MAC="-shared"
clang -O2 -fPIC -DZSTD_MULTITHREAD=0 -DZSTD_DISABLE_ASM=1 -DZSTD_LEGACY_SUPPORT=0 $MAC -I"$SRC/lib" -I"$SRC/lib/common" \
  "$SRC"/lib/common/*.c "$SRC"/lib/compress/*.c -o "$OUT.$$.part"
mv "$OUT.$$.part" "$OUT"
