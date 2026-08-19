#!/usr/bin/env sh
# =============================================================================
# Build and run the native harnesses.
# =============================================================================
# Unlike ci/check-purebasic.sh, which only SYNTAX-checks, this compiles a real
# executable and runs it. The harness needs no GUI: every window it creates is a
# headless Sink registration, so it works over ssh and in a terminal.
#
# ⚠ Requires a LICENSED PureBasic (the free version caps source files at 800
#   lines and modules/JSWindow.pb is ~3,500). Same constraint as every other
#   compiler-touching check here — see .github/workflows/ci.yml.
#
# The harness WRITES tests/fixtures/native-frames.json, which the jsdom suite
# consumes. Re-run it after touching the escapers or any hand-built frame in
# pbjsBridge.pb, and commit the result: `git diff tests/fixtures` is then the
# review of what changed on the wire.
#
# Usage:  tests/pb/run.sh
# =============================================================================

set -eu

cd "$(dirname "$0")"
here=$(pwd)
root=$(cd ../.. && pwd)

PBC=$("${root}/ci/purebasic-home.sh")
PUREBASIC_HOME=$(dirname "$(dirname "$PBC")")
export PUREBASIC_HOME

out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

fail=0

# The harness resolves ../fixtures/native-frames.json relative to the WORKING
# DIRECTORY, so run from tests/pb regardless of where the caller stood.
cd "$here"

echo "== router harness =="
# --console: the harness reports through PrintN, and without a console-format
# executable that output has nowhere to go on macOS and Windows.
"$PBC" router-harness.pb --output "${out}/router-harness" --console --quiet
if "${out}/router-harness"; then
  echo "   OK"
else
  echo "   FAILED" >&2
  fail=1
fi

exit $fail
