#!/usr/bin/env sh
# =============================================================================
# Resolve the PureBasic install directory into PUREBASIC_HOME, and echo the
# path of pbcompiler.
# =============================================================================
# PUREBASIC_HOME is not optional and not merely a convention — pbcompiler
# refuses to start without it ("Error: The 'PUREBASIC_HOME' env variable needs
# to be set to the install directory before using PureBasic."), and that fact
# is not in the online CLI docs. It must point at the directory holding
# compilers/, purelibraries/ and residents/.
#
# An already-set PUREBASIC_HOME always wins — same escape hatch the compiler
# itself honours, and the only way to support a non-standard install.
#
# This mirrors the probe order of the host app's scripts/purebasic-home.js.
# Keep the two in step; do not add locations to a caller.
#
# Usage:  PB=$(ci/purebasic-home.sh) || exit 1
# =============================================================================

set -eu

tried=""
note() { tried="${tried}  - $1
"; }

# Given a candidate install root, accept it if pbcompiler is inside it.
try_home() {
  candidate="$1"
  note "$candidate"
  if [ -x "${candidate}/compilers/pbcompiler" ]; then
    PUREBASIC_HOME="$candidate"
    export PUREBASIC_HOME
    printf '%s\n' "${candidate}/compilers/pbcompiler"
    exit 0
  fi
  return 0
}

# 0. Explicit override.
if [ -n "${PUREBASIC_HOME:-}" ]; then
  if [ -x "${PUREBASIC_HOME}/compilers/pbcompiler" ]; then
    printf '%s\n' "${PUREBASIC_HOME}/compilers/pbcompiler"
    exit 0
  fi
  echo "PUREBASIC_HOME is set to '${PUREBASIC_HOME}' but ${PUREBASIC_HOME}/compilers/pbcompiler is not executable." >&2
  exit 1
fi

case "$(uname -s)" in
  Darwin)
    # The app bundle's Resources dir is the install root.
    try_home "/Applications/PureBasic.app/Contents/Resources"
    # Versioned side-by-side installs: "PureBasic 6.21.app".
    for app in /Applications/PureBasic*.app; do
      [ -d "$app" ] || continue
      try_home "${app}/Contents/Resources"
    done
    ;;
  Linux)
    # No installer and no canonical prefix on Linux — it ships as a tarball you
    # extract anywhere, which is the whole reason this search exists.
    try_home "/usr/share/purebasic"
    try_home "/opt/purebasic"
    try_home "/usr/local/purebasic"
    try_home "/usr/local/share/purebasic"
    try_home "${HOME}/purebasic"
    for d in /opt/purebasic* /opt/PureBasic* "${HOME}"/purebasic* "${HOME}"/PureBasic*; do
      [ -d "$d" ] || continue
      try_home "$d"
    done
    ;;
esac

# Last resort: pbcompiler already on PATH. Derive the home from its location,
# since it will refuse to run without one.
if command -v pbcompiler >/dev/null 2>&1; then
  pbc=$(command -v pbcompiler)
  home=$(dirname "$(dirname "$pbc")")
  note "PATH (${pbc})"
  if [ -d "${home}/purelibraries" ] || [ -d "${home}/residents" ]; then
    PUREBASIC_HOME="$home"
    export PUREBASIC_HOME
    printf '%s\n' "$pbc"
    exit 0
  fi
fi

echo "PureBasic compiler not found. Tried:" >&2
printf '%s' "$tried" >&2
echo "Set PUREBASIC_HOME to your install directory (the one containing compilers/)." >&2
exit 1
