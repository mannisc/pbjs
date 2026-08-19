#!/usr/bin/env sh
# =============================================================================
# Build the example end to end: web app -> executable.
# =============================================================================
# Two steps, in this order, because the second depends on the first:
#
#   1. npm build in reactExample/main-window, producing dist/index.html;
#   2. pbcompiler on pbjsExample.pb, which embeds that file with IncludeBinary.
#
# dist/ is gitignored, so on a fresh clone step 2 fails with
# "Included file not found" until step 1 has run. That ordering is the single
# most common way a first build of this repo goes wrong, which is why it is a
# script rather than a paragraph.
#
# ⚠ Requires a LICENSED PureBasic. The free version caps source files at 800
#   lines EACH and modules/JSWindow.pb is ~3,500, so it answers "Source too big
#   for the Free version." See .github/workflows/ci.yml.
#
# Usage:
#   ./build.sh              build, output ./pbjsExample
#   ./build.sh --run        build, then launch it
#   ./build.sh -o path      build to a different output path
#
# Windows: build.cmd does the same thing.
# =============================================================================

set -eu

cd "$(dirname "$0")"
root=$(pwd)

out="${root}/pbjsExample"
run=0
while [ $# -gt 0 ]; do
  case "$1" in
    --run) run=1 ;;
    -o|--output) shift; out="$1" ;;
    -h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

echo "== 1/2  web app =="
cd "${root}/reactExample/main-window"
if [ -f package-lock.json ]; then
  npm ci
else
  npm install
fi
npm run build
test -f dist/index.html || {
  echo "The build did not produce dist/index.html — nothing for IncludeBinary to embed." >&2
  exit 1
}
echo "   OK  reactExample/main-window/dist/index.html"
echo

echo "== 2/2  executable =="
cd "$root"
# Resolved in exactly one place, shared with ci/check-purebasic.sh. PUREBASIC_HOME
# is not optional: pbcompiler refuses to start without it, and that is not in the
# online CLI reference.
PBC=$(ci/purebasic-home.sh)
PUREBASIC_HOME=$(dirname "$(dirname "$PBC")")
export PUREBASIC_HOME

"$PBC" pbjsExample.pb --output "$out" --quiet
echo "   OK  $out"

if [ "$run" = "1" ]; then
  echo
  echo "== running =="
  exec "$out"
fi
