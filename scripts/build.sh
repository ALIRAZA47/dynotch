#!/bin/bash
# Builds build/Dynotch.app. Usage: scripts/build.sh [release|debug]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
APP="$ROOT/build/Dynotch.app"
# Assembled and signed here, then moved into place, so a failed signing leaves no half-built app.
STAGE="$ROOT/build/Dynotch.app.building"

# macOS ties privacy permissions to the signature, and an ad hoc one changes with every build.
# scripts/make-signing-identity.sh makes a stable identity, in a keychain of its own that locks.
IDENTITY="${DYNOTCH_SIGNING_IDENTITY:-Dynotch Local Signing}"
KEYCHAIN="${DYNOTCH_SIGNING_KEYCHAIN:-$HOME/Library/Keychains/dynotch-signing.keychain-db}"

# "locked", "unlocked" or "unknown". The security tool can't say; the framework can.
keychain_state() {
    /usr/bin/python3 - "$1" 2> /dev/null <<'PY' || echo unknown
import ctypes, sys
security = ctypes.CDLL("/System/Library/Frameworks/Security.framework/Security")
security.SecKeychainOpen.argtypes = [ctypes.c_char_p, ctypes.POINTER(ctypes.c_void_p)]
security.SecKeychainGetStatus.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint32)]
keychain, status = ctypes.c_void_p(), ctypes.c_uint32()
if security.SecKeychainOpen(sys.argv[1].encode(), ctypes.byref(keychain)) or security.SecKeychainGetStatus(keychain, ctypes.byref(status)):
    print("unknown")
else:
    print("unlocked" if status.value & 1 else "locked")  # kSecUnlockStateStatus
PY
}

# Opens the signing keychain, asking for its password in the terminal. Without a terminal it
# stops, rather than letting codesign put up a dialog that may never be seen.
ensure_unlocked() {
    [ "$(keychain_state "$KEYCHAIN")" = locked ] || return 0
    if [ -t 0 ]; then
        echo "The Dynotch signing keychain is locked."
        security unlock-keychain "$KEYCHAIN"
    else
        echo "scripts/build.sh: the Dynotch signing keychain is locked, and there's no terminal to ask for its password." >&2
        echo "Unlock it, then build again:  security unlock-keychain \"$KEYCHAIN\"" >&2
        exit 1
    fi
}

if [ -f "$KEYCHAIN" ] && security find-identity -p codesigning "$KEYCHAIN" 2> /dev/null | grep -Fq "\"$IDENTITY\""; then
    SIGNING=keychain
    ensure_unlocked
elif security find-identity -p codesigning | grep -Fq "\"$IDENTITY\""; then
    SIGNING=login
else
    SIGNING=adhoc
fi

cd "$ROOT"
swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

if [ ! -f "$ROOT/Support/AppIcon.icns" ]; then
    mkdir -p "$ROOT/.build/tools"
    swiftc -O "$ROOT/scripts/make-icon.swift" -o "$ROOT/.build/tools/make-icon"
    "$ROOT/.build/tools/make-icon" "$ROOT/Support"
fi

rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BIN_DIR/Dynotch" "$STAGE/Contents/MacOS/Dynotch"
cp "$ROOT/Support/Info.plist" "$STAGE/Contents/Info.plist"
cp "$ROOT/Support/AppIcon.icns" "$STAGE/Contents/Resources/AppIcon.icns"
# The command-line tool travels with the app, so it can be linked onto PATH from wherever the app lives.
cp "$ROOT/scripts/dynotch" "$ROOT/scripts/notify-long-commands.zsh" "$STAGE/Contents/Resources/"

# The hardened runtime keeps other processes from loading code into Dynotch, which holds every
# permission the user gave it. The entitlements list what it still needs to reach.
sign() {
    codesign --force --options runtime --entitlements "$ROOT/Support/Dynotch.entitlements" --timestamp=none "$@" "$STAGE"
}
case $SIGNING in
    keychain)
        # The build may have outlasted the keychain's timeout.
        ensure_unlocked
        sign --sign "$IDENTITY" --keychain "$KEYCHAIN" ;;
    login)
        echo "Signing with \"$IDENTITY\" from the login keychain. Run scripts/make-signing-identity.sh to move it into a keychain of its own that locks."
        sign --sign "$IDENTITY" ;;
    adhoc)
        echo "Signing ad hoc. Run scripts/make-signing-identity.sh once so permissions survive rebuilds."
        sign --sign - ;;
esac
rm -rf "$APP"
mv "$STAGE" "$APP"
echo "Built $APP"
