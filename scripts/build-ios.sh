#!/bin/bash
# Baut die iOS-App aus iOS/project.yml + StenoKit.
#
# Nutzung:
#   scripts/build-ios.sh                 # generisch, nur bauen
#   scripts/build-ios.sh --simulator [UDID] # bauen und im Simulator starten
#   scripts/build-ios.sh --ipad-simulator # bauen und im iPad-Simulator starten
#   scripts/build-ios.sh --print-destination --simulator [UDID]
#   scripts/build-ios.sh --print-destination --ipad-simulator
#   scripts/build-ios.sh --device [UUID]  # bauen und aufs iPhone; ohne UUID das erste
#
# Signieren laeuft automatisch ueber DEVELOPMENT_TEAM aus der ignorierten
# lokalen .steno-signing.xcconfig an der Repository-Wurzel.
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=require-native-apple-silicon.sh
source "$SCRIPT_DIRECTORY/require-native-apple-silicon.sh"
require_native_apple_silicon

resolve_simulator_destination() {
    local requested="${1:-}"
    local only_ipad="${2:-false}"
    if [[ -n "$requested" ]]; then
        printf 'platform=iOS Simulator,id=%s\n' "$requested"
        return
    fi

    local json="${SIMCTL_DEVICES_JSON:-$(xcrun simctl list devices booted -j)}"
    local udid
    udid="$(printf '%s' "$json" | python3 -c 'import json,sys; only_ipad=sys.argv[1] == "true"; devices=[device for runtime in json.load(sys.stdin)["devices"].values() for device in runtime if device.get("isAvailable", True) and device.get("state") == "Booted" and (not only_ipad or device.get("name", "").startswith("iPad"))]; devices.sort(key=lambda device: (device.get("name", ""), device["udid"])); print(devices[0]["udid"] if devices else "")' "$only_ipad")"
    [[ -n "$udid" ]] || return 1
    printf 'platform=iOS Simulator,id=%s\n' "$udid"
}

create_or_boot_ipad_simulator() {
    local devices_json simulator runtime device_type
    devices_json="$(xcrun simctl list devices -j)"
    simulator="$(printf '%s' "$devices_json" | python3 -c 'import json,sys; devices=[device for runtime in json.load(sys.stdin)["devices"].values() for device in runtime if device.get("isAvailable", True) and device.get("name", "").startswith("iPad")]; devices.sort(key=lambda device: (device.get("name", ""), device["udid"])); print(devices[0]["udid"] if devices else "")')"

    if [[ -z "$simulator" ]]; then
        runtime="$(xcrun simctl list runtimes -j | python3 -c 'import json,re,sys; runtimes=[runtime for runtime in json.load(sys.stdin)["runtimes"] if runtime.get("isAvailable", True) and ".iOS-" in runtime["identifier"]]; runtimes.sort(key=lambda runtime: (tuple(int(number) for number in re.findall(r"\d+", runtime.get("version", runtime["identifier"]))), runtime["identifier"]), reverse=True); print(runtimes[0]["identifier"] if runtimes else "")')"
        device_type="$(xcrun simctl list devicetypes -j | python3 -c 'import json,sys; device_types=[device_type for device_type in json.load(sys.stdin)["devicetypes"] if device_type.get("isAvailable", True) and device_type.get("name") == "iPad Pro 13-inch (M5)"]; print(device_types[0]["identifier"] if device_types else "")')"
        if [[ -z "$runtime" || -z "$device_type" ]]; then
            echo "Kein installierter iPad-Simulator zur Erstellung verfuegbar." >&2
            return 1
        fi
        simulator="$(xcrun simctl create "Steno iPad" "$device_type" "$runtime")"
    fi

    xcrun simctl boot "$simulator" 2>/dev/null || true
    # Fortschritt nach stderr: stdout dieser Funktion ist die UDID.
    xcrun simctl bootstatus "$simulator" -b >&2
    printf '%s\n' "$simulator"
}

PRINT_DESTINATION=false
ARGUMENTS=()
for argument in "$@"; do
    if [[ "$argument" == "--print-destination" ]]; then
        PRINT_DESTINATION=true
    else
        ARGUMENTS+=("$argument")
    fi
done
if (( ${#ARGUMENTS[@]} > 0 )); then
    set -- "${ARGUMENTS[@]}"
else
    set --
fi

MODE="${1:-}"
SIMULATOR_REQUESTED="${2:-}"
if [[ "$SIMULATOR_REQUESTED" == --* ]]; then
    SIMULATOR_REQUESTED=""
fi

if [[ "$PRINT_DESTINATION" == true ]]; then
    case "$MODE" in
    --simulator)
        resolve_simulator_destination "$SIMULATOR_REQUESTED"
        ;;
    --ipad-simulator)
        if ! resolve_simulator_destination "" true; then
            echo "Kein gebootetes iPad fuer --print-destination." >&2
            exit 1
        fi
        ;;
    *)
        echo "--print-destination erwartet --simulator oder --ipad-simulator." >&2
        exit 1
        ;;
    esac
    exit 0
fi

cd "$SCRIPT_DIRECTORY/../iOS"

# Immer erst generieren: das Projekt ist ein Generat. Nach einem Branch-
# Wechsel oder Merge fehlen sonst neue Quelldateien und der Build bricht mit
# "cannot find type ..." ab, was wie ein Codefehler aussieht und keiner ist.
xcodegen generate --quiet

case "$MODE" in
--device)
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
        ARCHS=arm64 ONLY_ACTIVE_ARCH=YES EXCLUDED_ARCHS=x86_64 \
        -destination "platform=iOS,id=$DEVICE" \
        -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
        -derivedDataPath build build | tail -3
    xcrun devicectl device install app --device "$DEVICE" \
        "$PWD/build/Build/Products/Debug-iphoneos/Steno.app"
    ;;
--simulator)
    if ! DESTINATION="$(resolve_simulator_destination "$SIMULATOR_REQUESTED")"; then
        echo "Kein gebooteter Simulator. Simulator.app starten." >&2
        exit 1
    fi
    SIM="${DESTINATION#platform=iOS Simulator,id=}"
    xcodebuild -project StenoiOS.xcodeproj -scheme Steno \
        ARCHS=arm64 ONLY_ACTIVE_ARCH=YES EXCLUDED_ARCHS=x86_64 \
        -destination "platform=iOS Simulator,id=$SIM" \
        -derivedDataPath build build | tail -3
    APP="$PWD/build/Build/Products/Debug-iphonesimulator/Steno.app"
    xcrun simctl install "$SIM" "$APP"
    xcrun simctl launch "$SIM" org.steno.Steno
    ;;
--ipad-simulator)
    if DESTINATION="$(resolve_simulator_destination "" true)"; then
        SIM="${DESTINATION#platform=iOS Simulator,id=}"
    else
        SIM="$(create_or_boot_ipad_simulator)"
    fi
    xcodebuild -project StenoiOS.xcodeproj -scheme Steno \
        ARCHS=arm64 ONLY_ACTIVE_ARCH=YES EXCLUDED_ARCHS=x86_64 \
        -destination "platform=iOS Simulator,id=$SIM" \
        -derivedDataPath build build | tail -3
    APP="$PWD/build/Build/Products/Debug-iphonesimulator/Steno.app"
    xcrun simctl install "$SIM" "$APP"
    xcrun simctl launch "$SIM" org.steno.Steno
    ;;
*)
    xcodebuild -project StenoiOS.xcodeproj -scheme Steno \
        ARCHS=arm64 ONLY_ACTIVE_ARCH=YES EXCLUDED_ARCHS=x86_64 \
        -destination 'generic/platform=iOS' \
        -allowProvisioningUpdates \
        -derivedDataPath build build | tail -3
    ;;
esac
