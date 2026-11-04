#!/bin/bash
# Builds a Release MarkdownBrowser.app and zips it into dist/.
# Signs with DEVELOPER_ID_APPLICATION and notarizes with NOTARY_PROFILE (or NOTARY_KEY_PATH,
# NOTARY_KEY_ID, NOTARY_ISSUER) when set; otherwise the app keeps its ad-hoc signature.
set -euo pipefail
cd "$(dirname "$0")/.."

TAG="${1:?usage: build-release.sh <version, e.g. 1.2.0 or v1.2.0-rc1>}"
VERSION="${TAG#v}"
if [[ ! "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}(-[0-9A-Za-z.]+)?$ ]]; then
  echo "error: '$TAG' is not a version like 1.2.0 or 1.2.0-rc1" >&2
  exit 1
fi
# CFBundleShortVersionString must be numeric, so the pre-release suffix only appears in the file name.
MARKETING_VERSION="${VERSION%%-*}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD)}"

DERIVED=build/release
APP="$DERIVED/Build/Products/Release/MarkdownBrowser.app"
DIST=dist
ZIP="MarkdownBrowser-$VERSION.zip"

xcodegen generate --quiet
if [[ "${SKIP_TESTS:-0}" != 1 ]]; then
  xcodebuild -project MarkdownBrowser.xcodeproj -scheme MarkdownBrowser -derivedDataPath build -quiet test
fi

rm -rf "$DERIVED"
xcodebuild -project MarkdownBrowser.xcodeproj -scheme MarkdownBrowser -configuration Release \
  -derivedDataPath "$DERIVED" -quiet \
  MARKETING_VERSION="$MARKETING_VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" build

rm -rf "$DIST"
mkdir -p "$DIST"

if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
  codesign --force --options runtime --timestamp \
    --entitlements MarkdownBrowser/MarkdownBrowser.entitlements \
    --sign "$DEVELOPER_ID_APPLICATION" "$APP"

  notary=()
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    notary=(--keychain-profile "$NOTARY_PROFILE")
  elif [[ -n "${NOTARY_KEY_PATH:-}" ]]; then
    notary=(--key "$NOTARY_KEY_PATH" --key-id "${NOTARY_KEY_ID:?}" --issuer "${NOTARY_ISSUER:?}")
  fi
  if (( ${#notary[@]} )); then
    ditto -c -k --keepParent "$APP" "$DIST/notarize.zip"
    xcrun notarytool submit "$DIST/notarize.zip" "${notary[@]}" --wait
    xcrun stapler staple "$APP"
    rm "$DIST/notarize.zip"
  fi
fi
codesign --verify --strict "$APP"

ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/$ZIP"
(cd "$DIST" && shasum -a 256 "$ZIP" > "$ZIP.sha256")
echo "Built $DIST/$ZIP (version $MARKETING_VERSION, build $BUILD_NUMBER)"
