#!/bin/bash
# Baut steno-macos.app (PRODUCT_NAME in project.yml) aus project.yml + StenoKit.
# Nutzung: scripts/build-app.sh [--run]
set -euo pipefail

cd "$(dirname "$0")/.."

xcodegen generate --quiet

if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
    xcodebuild -project Steno.xcodeproj \
        -scheme Steno \
        -configuration Debug \
        DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
        -derivedDataPath .build/DerivedData \
        build | tail -5
else
    xcodebuild -project Steno.xcodeproj \
        -scheme Steno \
        -configuration Debug \
        -derivedDataPath .build/DerivedData \
        build | tail -5
fi

APP=".build/DerivedData/Build/Products/Debug/steno-macos.app"
echo "App: $PWD/$APP"

if [[ "${1:-}" == "--run" ]]; then
    open "$APP"
fi
