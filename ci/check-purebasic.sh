#!/usr/bin/env sh
# =============================================================================
# Syntax-check pbjs with the real PureBasic compiler.
# =============================================================================
# Two checks:
#
#   1. STANDALONE — ci/standalone-check.pb includes pbjs and nothing else. This
#      is the one that matters: pbjs is developed as a nested repo inside a host
#      app where extra modules happen to be in scope, so a dependency on a
#      host-only symbol compiles fine for its author and fails in a stranger's
#      terminal. (That is not hypothetical — `UseModule Ptym` shipped exactly
#      that way until roadmap step 1.1.)
#
#   2. THE EXAMPLE — pbjsExample.pb, but only if the web app has been built,
#      because it embeds dist/index.html with IncludeBinary and dist/ is
#      gitignored. Skipped with a clear message rather than failing, so this
#      script is useful on a fresh checkout.
#
# ⚠ Requires a LICENSED PureBasic. The free version caps source files at 800
# lines EACH (not cumulatively — verified), and modules/JSWindow.pb alone is
# ~3,500, so the free compiler answers "Error: Source too big for the Free
# version." and exits 1. There is no arrangement of this repo that fits, and
# contorting the file layout to satisfy the free compiler is not worth doing.
# See .github/workflows/ for how that shapes CI.
#
# Usage:  ci/check-purebasic.sh
# =============================================================================

set -eu

cd "$(dirname "$0")/.."
root=$(pwd)

PBC=$(ci/purebasic-home.sh)
# purebasic-home.sh exports PUREBASIC_HOME in its own shell, which does not
# survive the subshell — derive it again here for the compiler's benefit.
PUREBASIC_HOME=$(dirname "$(dirname "$PBC")")
export PUREBASIC_HOME

echo "PureBasic: $PBC"
# `pbcompiler --version` exits 1 even when it succeeds (verified, 6.21), so
# under `set -e` this line would end the script before a single check ran —
# and it would look like a compiler failure with no error message.
"$PBC" --version || true
echo

fail=0

echo "== 1/2  standalone (pbjs with no host in scope) =="
if "$PBC" ci/standalone-check.pb --check; then
  echo "   OK"
else
  echo "   FAILED — pbjs does not compile on its own." >&2
  fail=1
fi
echo

echo "== 2/2  example (pbjsExample.pb) =="
if [ -f "${root}/reactExample/main-window/dist/index.html" ]; then
  if "$PBC" pbjsExample.pb --check; then
    echo "   OK"
  else
    echo "   FAILED" >&2
    fail=1
  fi
else
  echo "   SKIPPED — reactExample/main-window/dist/index.html is missing."
  echo "   Build it first:  cd reactExample/main-window && npm ci && npm run build"
fi

exit $fail
