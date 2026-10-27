#!/bin/bash
# Builds build/Dynotch.app. Usage: scripts/build.sh [release|debug]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
APP="$ROOT/build/Dynotch.app"

cd "$ROOT"
swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

if [ ! -f "$ROOT/Support/AppIcon.icns" ]; then
    mkdir -p "$ROOT/.build/tools"
    swiftc -O "$ROOT/scripts/make-icon.swift" -o "$ROOT/.build/tools/make-icon"
    "$ROOT/.build/tools/make-icon" "$ROOT/Support"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Dynotch" "$APP/Contents/MacOS/Dynotch"
cp "$ROOT/Support/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Support/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# The command-line tool travels with the app, so it can be linked onto PATH from wherever the app lives.
cp "$ROOT/scripts/dynotch" "$ROOT/scripts/notify-long-commands.zsh" "$APP/Contents/Resources/"

# macOS ties privacy permissions to the signature, and an ad hoc one changes with every
# build. Sign with the local identity from scripts/make-signing-identity.sh when it's there.
IDENTITY="${DYNOTCH_SIGNING_IDENTITY:-Dynotch Local Signing}"
if security find-identity -p codesigning | grep -Fq "\"$IDENTITY\""; then
    codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
else
    echo "Signing ad hoc. Run scripts/make-signing-identity.sh once so permissions survive rebuilds."
    codesign --force --sign - --timestamp=none "$APP"
fi
echo "Built $APP"
