#!/bin/bash
# The complete pre-release check, in one run: the iOS compile check, the GPU checks (dm/gfx/tests), the host tests (dm/host/tests), every Python suite, the env switch table
# and a TVPort app build. Each step's output goes to its own log; the summary lists every step with its status and test count, and the exit status is 1 when any step failed.
#   scripts/full_check.sh     GAME defaults to 0400486024DEC000 (the profile the checks are built for); LOGS=<dir> moves the logs (default ~/workspace/tests-scratch/full_check-<time>)
# The Python suites run under TVPort's venv python (capstone, lz4 and unicorn, which the nsp, nro and rewrite tests import) when it exists, else python3.
# The GPU checks need an Apple-silicon Mac with Metal 4 and take a while; none of the steps needs game files, and none runs a game.
set -u
cd "$(dirname "$0")/.." || exit 2
export PATH=/opt/homebrew/bin:$PATH
export GAME=${GAME:-0400486024DEC000}
export DM_GAME=${DM_GAME:-$GAME}
LOGS=${LOGS:-$HOME/workspace/tests-scratch/full_check-$(date +%Y%m%d-%H%M%S)}
UV=${UV:-$HOME/workspace/TVPort-tools/uv-0.13.7/bin/uv}
VENV_PY="$HOME/Library/Application Support/TVPort/venv/bin/python3"
if [ -x "$VENV_PY" ]; then PY=$VENV_PY; else PY=python3; fi
mkdir -p "$LOGS"
SUMMARY=()
FAILED=0

step() {   # step <name> <command...>: run it, log it, record its status and the count of tests it printed
    local name=$1; shift
    local log="$LOGS/$name.log" t0=$SECONDS
    echo "== $name"
    "$@" >"$log" 2>&1; local rc=$?
    local count; count=$(grep -hE '^Ran [0-9]+ tests?' "$log" | awk '{n += $2} END {if (NR) print n " tests"}')
    if [ $rc -eq 0 ]; then SUMMARY+=("PASS  $name  ${count:-}  ($((SECONDS - t0)) s)")
    else SUMMARY+=("FAIL  $name  ${count:-}  (exit $rc; $log)"); FAILED=$((FAILED + 1)); tail -15 "$log" | sed 's/^/    /'; fi
}

py_suite() {   # py_suite <dir>: every test file of the folder, discovered from the folder as its own tests expect
    "$PY" -m unittest discover -s "$1" -p 'test_*.py'
}

app_build() {   # a TVPort app build, then its dist folder removed
    python3 -I scripts/package_tvport.py --uv "$UV" && rm -rf tvport/dist
}

step compile-check python3 -I dm/ios/tools/compile_check.py
step gpu-checks    make -C dm/gfx/tests GAME="$GAME" -j4 run
step host-tests    make -C dm/host/tests GAME="$GAME" run
step py-dm-tools   py_suite dm/tools/tests
step py-dm-ios     py_suite dm/ios/tests
step py-dm-gfx     py_suite dm/gfx/tests
step py-tvport     py_suite tvport/tests
step env-switches  python3 dm/tools/env_switches.py --check
step tvport-app    app_build

echo
echo "full_check: logs in $LOGS"
printf '%s\n' "${SUMMARY[@]}"
if [ $FAILED -eq 0 ]; then echo "full_check: all steps passed"; else echo "full_check: $FAILED step(s) failed"; fi
[ $FAILED -eq 0 ]
