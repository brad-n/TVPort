#!/bin/bash
# tex_once_verify: check "Store textures once" against real stripped images with the engine's own C code (no game run, no GPU).
#   dm/gfx/tests/tex_once_verify.sh <game> [work dir]        game: smash | mk8   (or: <stripped dir> <original RomFS.img> <astc-ro.pack> <max-dim> <block> via env, see below)
# Steps per game: (1) reader equivalence: the engine's sparse reader (tex_once_verify_read.c) and sparse_image.py hash the same logical image; the DMROMFS1 index loads, its file count and identity
# equal the original's. (2) tex_once.py --manifest lists every tagged plane the strip keeps (from the original image); tex_once_verify_tags.m resolves each through the engine's pack reader.
# Heavy (tens of minutes, ~20 GB of reads): runs niced, 3 workers. A manifest in the work dir is reused (delete it to rebuild). Needs GAME for the host Makefile only to build libastcenc.a.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
TEX=${TEXONCE_DIR:-$HOME/workspace/TVPort-texonce}; ASTC=${TVPORT_ASTC_DIR:-$HOME/workspace/TVPort-astc}; SW="${SWITCH_GAMES:-$HOME/Downloads/switch games}"
case "${1:-}" in
  smash) ID=01006A800016E000; SRC="$SW/super smash/${ID}_build/extract/${SMASH_VERSION:-v2031616}/RomFS.img"; CAP=512 ;;
  mk8)   ID=0100152000022000; SRC="$SW/Mario Kart 8 Deluxe/${ID}_build/extract/${MK8_VERSION:-v1507328}/RomFS.img"; CAP=0 ;;
  *) echo "usage: $0 smash|mk8 [work dir]" >&2; exit 2 ;;
esac
WORK=${2:-/tmp/texonce-verify}; mkdir -p "$WORK"; IMG="$TEX/$ID/romfs.img"; REPORT="$TEX/$ID/report.json"
LOW="taskpolicy -b nice -n 10"
PY=${PYTHON:-/opt/homebrew/bin/python3}   # tex_once.py needs the Python the TVPort tools use (3.14+ for zstd), not the system 3.9
fail=0
BIN=$WORK/bin; mkdir -p "$BIN"
CF="-O2 -g -Wall -Wno-unused-function -I$ROOT/dm/gfx/nvn/include -I$ROOT/dm/host/gen/$ID"
# the profile header the engine's headers include comes from the host Makefile
[ -f "$ROOT/dm/host/gen/$ID/game_profile.h" ] || $LOW make -C "$ROOT/dm/host" game_profile GAME=$ID >/dev/null || exit 1
LIB=$ROOT/dm/host/gen/astc/libastcenc.a
[ -f "$LIB" ] || $LOW make -C "$ROOT/dm/host" GAME=$ID gen/astc/libastcenc.a -j3 >/dev/null || exit 1
clang $CF -o "$BIN/tex_once_verify_read" "$HERE/tex_once_verify_read.c" || exit 1
clang $CF -fobjc-arc -o "$BIN/tex_once_verify_tags" "$HERE/tex_once_verify_tags.m" "$ROOT/dm/gfx/tex/nvn_bcdec.c" "$ROOT/dm/gfx/tex/nvn_astc.mm" "$LIB" -lc++ -framework Foundation -framework Metal || exit 1

echo "== $ID: reader equivalence"
$LOW "$BIN/tex_once_verify_read" "$IMG" "$SRC" > "$WORK/$ID.read.out" 2>&1 & p1=$!
$LOW $PY -I "$HERE/sparse_sha.py" "$IMG" > "$WORK/$ID.py.out" 2>&1 & p2=$!
wait $p1 || fail=1; wait $p2 || fail=1
cat "$WORK/$ID.read.out" "$WORK/$ID.py.out"
c=$(grep '^sha256=' "$WORK/$ID.read.out" | cut -d= -f2); py=$(grep '^sha256=' "$WORK/$ID.py.out" | cut -d= -f2)
if [ -n "$c" ] && [ "$c" = "$py" ]; then echo "logical SHA-256 match (engine C reader vs sparse_image.py): yes"; else echo "logical SHA-256 match: NO ($c vs $py)"; fail=1; fi

echo "== $ID: tags through the runtime lookup"
M=$WORK/$ID.manifest
if [ ! -s "$M" ]; then
  $LOW $PY -I "$ROOT/dm/gfx/tools/tex_once.py" "$SRC" --pack "$ASTC/$ID/astc-ro.pack" --out "$WORK/$ID" --max-dim $CAP --block 4 --workers 3 --manifest "$M" 2>&1 | tail -2 || fail=1
fi
N=$($PY -I -c "import json,sys;print(json.load(open(sys.argv[1]))['planes']['tagged'])" "$REPORT")
$LOW "$BIN/tex_once_verify_tags" "$IMG" "$M" "$N" || fail=1
[ $fail = 0 ] && echo "tex_once_verify $ID: PASS" || echo "tex_once_verify $ID: FAIL"
exit $fail
