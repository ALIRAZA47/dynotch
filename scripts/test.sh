#!/bin/bash
# Runs the tests. Arguments go on to `swift test`, such as --filter NotesStoreTests.
#
# One test at a time: several suites go through the app's shared stores, like the notch's notices,
# and running them side by side lets one see what another posted.
#
# The Command Line Tools keep Swift Testing's macros in a folder SwiftPM doesn't look in, so
# it has to be told. Xcode needs no help.
set -euo pipefail
cd "$(dirname "$0")/.."

plugins="$(xcode-select -p)/usr/lib/swift/host/plugins/testing"
if [ -d "$plugins" ]; then
    exec swift test --no-parallel -Xswiftc -plugin-path -Xswiftc "$plugins" "$@"
fi
exec swift test --no-parallel "$@"
