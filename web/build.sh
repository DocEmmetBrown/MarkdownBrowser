#!/bin/bash
# Builds the editor bundle into the app's Resources/Web folder; skipped when sources are unchanged.
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
cd "$(dirname "$0")"

OUT="${1:?usage: build.sh <output-dir>}"
STAMP_DIR="${DERIVED_FILE_DIR:-$PWD/.build}"
STAMP="$STAMP_DIR/web-bundle.stamp"
mkdir -p "$STAMP_DIR"

if ! command -v npm >/dev/null; then
  echo "error: npm is required to build the editor bundle (brew install node)" >&2
  exit 1
fi

HASH="$( (find src index.html package-lock.json vite.config.ts -type f -print0 | sort -z | xargs -0 shasum; echo "$OUT") | shasum | cut -d' ' -f1)"
if [[ -f "$STAMP" && "$(cat "$STAMP")" == "$HASH" && -f "$OUT/index.html" ]]; then
  echo "Editor bundle up to date"
  exit 0
fi

[[ -d node_modules ]] || npm ci --no-audit --no-fund
npx vite build --outDir "$OUT" --emptyOutDir --logLevel warn
echo "$HASH" > "$STAMP"
