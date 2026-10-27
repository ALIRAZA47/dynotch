#!/bin/bash
# Builds Dynotch and packages it for a release: dist/Dynotch-VERSION.dmg, which opens to the
# app beside an Applications link, and dist/Dynotch-VERSION.zip. VERSION comes from Support/Info.plist.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Dynotch.app"
DIST="$ROOT/dist"

cd "$ROOT"
"$ROOT/scripts/build.sh" release
codesign --verify --deep --strict "$APP"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"

STAGE="$(mktemp -d)"
trap 'rm -rf "${STAGE:?}"' EXIT
ditto "$APP" "$STAGE/Dynotch.app"
ln -s /Applications "$STAGE/Applications"

mkdir -p "$DIST"
rm -f "$DIST/Dynotch-$VERSION.dmg" "$DIST/Dynotch-$VERSION.zip"
hdiutil create -quiet -volname "Dynotch $VERSION" -srcfolder "$STAGE" -format UDZO "$DIST/Dynotch-$VERSION.dmg"
ditto -c -k --keepParent "$APP" "$DIST/Dynotch-$VERSION.zip"

cd "$DIST"
shasum -a 256 "Dynotch-$VERSION.dmg" "Dynotch-$VERSION.zip"
echo "Packaged $DIST/Dynotch-$VERSION.dmg and Dynotch-$VERSION.zip"
