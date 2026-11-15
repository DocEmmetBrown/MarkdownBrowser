#!/bin/bash
# Builds the Rust core (native/mdb-core) for the architectures being built into the library folder, and its Swift
# bindings into native/generated. Skipped when nothing changed.
set -euo pipefail

export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
cd "$(dirname "$0")"

LIB_DIR="${1:?usage: build.sh <library-dir>}"
GENERATED="$PWD/generated"
ARCHS="${ARCHS:-$(uname -m)}"
PROFILE=$([[ "${CONFIGURATION:-Debug}" == Release ]] && echo release || echo dev)
STAMP_DIR="${DERIVED_FILE_DIR:-$PWD/target}"
STAMP="$STAMP_DIR/mdb-core.stamp"
mkdir -p "$STAMP_DIR" "$LIB_DIR" "$GENERATED"

if command -v rustup >/dev/null; then
  # Use rustup's toolchain, which is the one `rustup target add` installs targets for.
  CARGO="$(rustup which cargo)"
  RUSTC="$(rustup which rustc)"
  export RUSTC
elif command -v cargo >/dev/null; then
  CARGO=cargo
  RUSTC=rustc
else
  echo "error: Rust is required to build the native core (brew install rustup && rustup-init)" >&2
  exit 1
fi

HASH="$( (find Cargo.toml Cargo.lock build.sh mdb-core -type f -not -path '*/target/*' -print0 | sort -z | xargs -0 shasum
  echo "$ARCHS $PROFILE $LIB_DIR") | shasum | cut -d' ' -f1)"
if [[ -f "$STAMP" && "$(cat "$STAMP")" == "$HASH" && -f "$LIB_DIR/libmdb_core.a" \
  && -f "$GENERATED/MdbCore.swift" && -f "$GENERATED/MdbCoreFFI.h" && -f "$GENERATED/module.modulemap" ]]; then
  echo "Native core up to date"
  exit 0
fi

OUT_DIR=$([[ "$PROFILE" == dev ]] && echo debug || echo release)
LIBS=()
for ARCH in $ARCHS; do
  case "$ARCH" in
    arm64) TARGET=aarch64-apple-darwin ;;
    *) echo "error: unsupported architecture $ARCH (the app targets Apple silicon only)" >&2; exit 1 ;;
  esac
  if [[ ! -d "$("$RUSTC" --print target-libdir --target "$TARGET")" ]]; then
    echo "error: the Rust standard library for $TARGET is missing: rustup target add $TARGET" >&2
    exit 1
  fi
  "$CARGO" build --locked --quiet -p mdb-core --lib --profile "$PROFILE" --target "$TARGET"
  LIBS+=("target/$TARGET/$OUT_DIR/libmdb_core.a")
done
lipo -create "${LIBS[@]}" -output "$LIB_DIR/libmdb_core.a"

# Generate into a scratch folder and only replace files that changed, so Xcode doesn't recompile the bindings.
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
"$CARGO" run --locked --quiet -p mdb-core --features bindgen --bin uniffi-bindgen -- \
  generate --library "${LIBS[0]}" --language swift --out-dir "$SCRATCH"
mv "$SCRATCH/MdbCoreFFI.modulemap" "$SCRATCH/module.modulemap"
for FILE in MdbCore.swift MdbCoreFFI.h module.modulemap; do
  cmp -s "$SCRATCH/$FILE" "$GENERATED/$FILE" || cp "$SCRATCH/$FILE" "$GENERATED/$FILE"
done
echo "$HASH" > "$STAMP"
