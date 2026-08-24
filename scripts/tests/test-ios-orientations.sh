#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

cd "$ROOT/iOS"
xcodegen generate --quiet

PLIST="$ROOT/iOS/App/Info.plist"

assert_orientation() {
    local key="$1"
    local orientation="$2"

    plutil -extract "$key" json -o - "$PLIST" \
        | jq -e --arg orientation "$orientation" 'index($orientation) != null' \
        > /dev/null
}

assert_orientation 'UISupportedInterfaceOrientations~ipad' UIInterfaceOrientationPortrait
assert_orientation 'UISupportedInterfaceOrientations~ipad' UIInterfaceOrientationPortraitUpsideDown
assert_orientation 'UISupportedInterfaceOrientations~ipad' UIInterfaceOrientationLandscapeLeft
assert_orientation 'UISupportedInterfaceOrientations~ipad' UIInterfaceOrientationLandscapeRight

assert_orientation UISupportedInterfaceOrientations UIInterfaceOrientationPortrait
assert_orientation UISupportedInterfaceOrientations UIInterfaceOrientationLandscapeLeft
assert_orientation UISupportedInterfaceOrientations UIInterfaceOrientationLandscapeRight
