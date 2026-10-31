#!/bin/bash
# Runs the tests. Arguments go on to `swift test`, such as --filter NotesStoreTests.
#
# The Command Line Tools keep Swift Testing's macros in a folder SwiftPM doesn't look in, so
# it has to be told. Xcode needs no help.
set -euo pipefail
cd "$(dirname "$0")/.."

plugins="$(xcode-select -p)/usr/lib/swift/host/plugins/testing"
if [ -d "$plugins" ]; then
    exec swift test -Xswiftc -plugin-path -Xswiftc "$plugins" "$@"
fi
exec swift test "$@"
