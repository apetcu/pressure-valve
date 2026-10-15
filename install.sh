#!/bin/zsh
# One-command install: fetches (or updates) the source, then builds and launches the app.
set -euo pipefail
REPO="${PV_REPO:-git@github.com:apetcu/pressure-valve.git}"
SRC="${PV_SRC:-$HOME/.local/src/pressure-valve}"

if ! xcode-select -p >/dev/null 2>&1; then
  echo "Installing the Xcode command line tools. Rerun this command when that finishes."
  xcode-select --install
  exit 1
fi

if [[ -d "$SRC/.git" ]]; then
  git -C "$SRC" pull --ff-only --quiet
else
  mkdir -p "${SRC:h}"
  git clone --quiet "$REPO" "$SRC"
fi
"$SRC/build.sh"
