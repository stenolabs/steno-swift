#!/bin/bash
# Builds steno-macos.app (PRODUCT_NAME in project.yml) from project.yml and StenoKit.
# Usage: scripts/build-app.sh [--run]
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=require-native-apple-silicon.sh
source "$SCRIPT_DIRECTORY/require-native-apple-silicon.sh"
require_native_apple_silicon

cd "$SCRIPT_DIRECTORY/.."

xcodegen generate --quiet

xcodebuild -project Steno.xcodeproj \
    -scheme Steno \
    -arch arm64 \
    -configuration Debug \
    -derivedDataPath .build/DerivedData \
    build | tail -5

APP=".build/DerivedData/Build/Products/Debug/steno-macos.app"
echo "App: $PWD/$APP"

if [[ "${1:-}" == "--run" ]]; then
    open "$APP"
fi
