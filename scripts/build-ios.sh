#!/bin/bash
# Baut die iOS-App aus iOS/project.yml + StenoKit.
#
# Nutzung:
#   scripts/build-ios.sh                 # generisch, nur bauen
#   scripts/build-ios.sh --simulator     # bauen und im gebooteten Simulator starten
#   scripts/build-ios.sh --device [UUID]  # bauen und aufs iPhone; ohne UUID das erste
#
# Fuer ein physisches Geraet DEVELOPMENT_TEAM als Umgebungsvariable setzen.
# Mit einem kostenlosen Apple-Konto startet die App nach sieben Tagen nicht
# mehr und muss neu installiert werden; das ist kein Fehler.
set -euo pipefail

cd "$(dirname "$0")/../iOS"

# Immer erst generieren: das Projekt ist ein Generat. Nach einem Branch-
# Wechsel oder Merge fehlen sonst neue Quelldateien und der Build bricht mit
# "cannot find type ..." ab, was wie ein Codefehler aussieht und keiner ist.
xcodegen generate --quiet

MODE="${1:-}"

case "$MODE" in
--device)
    if [[ -z "${DEVELOPMENT_TEAM:-}" ]]; then
        echo "Fuer ein physisches Geraet DEVELOPMENT_TEAM setzen." >&2
        exit 1
    fi
    # Zweites Argument gewinnt, sonst das erste verfuegbare iPhone oder iPad.
    # Auf Modell gefiltert, weil eine gekoppelte Apple Watch ebenfalls als
    # "available" gelistet wird und in der Liste vor dem Telefon stehen kann.
    # Die UUID per Muster statt per Spalte: "available (paired)" enthaelt ein
    # Leerzeichen und verschiebt jede feldbasierte Zaehlung.
    DEVICE="${2:-}"
    if [[ -z "$DEVICE" ]]; then
        DEVICE=$(xcrun devicectl list devices 2>/dev/null \
            | grep available \
            | grep -E 'iPhone|iPad' \
            | grep -oE '[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}' \
            | head -1)
    fi
    if [[ -z "$DEVICE" ]]; then
        echo "Kein verfuegbares Geraet. iPhone entsperren, im selben Netz." >&2
        exit 1
    fi
    xcodebuild -project StenoiOS.xcodeproj -scheme Steno \
        -destination "platform=iOS,id=$DEVICE" \
        -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
        DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
        -derivedDataPath build build | tail -3
    xcrun devicectl device install app --device "$DEVICE" \
        "$PWD/build/Build/Products/Debug-iphoneos/Steno.app"
    ;;
--simulator)
    SIM=$(xcrun simctl list devices booted -j \
        | python3 -c 'import json,sys; d=json.load(sys.stdin)["devices"]; print(next((x["udid"] for v in d.values() for x in v), ""))')
    if [[ -z "$SIM" ]]; then
        echo "Kein gebooteter Simulator. Simulator.app starten." >&2
        exit 1
    fi
    xcodebuild -project StenoiOS.xcodeproj -scheme Steno \
        -destination "platform=iOS Simulator,id=$SIM" \
        -derivedDataPath build build | tail -3
    APP="$PWD/build/Build/Products/Debug-iphonesimulator/Steno.app"
    xcrun simctl install "$SIM" "$APP"
    xcrun simctl launch "$SIM" org.steno.Steno
    ;;
*)
    xcodebuild -project StenoiOS.xcodeproj -scheme Steno \
        -destination 'generic/platform=iOS' \
        CODE_SIGNING_ALLOWED=NO \
        -derivedDataPath build build | tail -3
    ;;
esac
