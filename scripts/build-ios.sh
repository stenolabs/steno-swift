#!/bin/bash
# Builds the iOS app from iOS/project.yml and StenoKit.
#
# Usage:
#   scripts/build-ios.sh                 # generic build only
#   scripts/build-ios.sh --simulator [UDID] # build and launch in a simulator
#   scripts/build-ios.sh --ipad-simulator # build and launch in an iPad simulator
#   scripts/build-ios.sh --print-destination --simulator [UDID]
#   scripts/build-ios.sh --print-destination --ipad-simulator
#   scripts/build-ios.sh --device [UUID]  # build and install on a device; first available by default
#
# Signing uses DEVELOPMENT_TEAM from the ignored local
# .steno-signing.xcconfig at the repository root.
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
            echo "No installed iPad simulator is available to create." >&2
            return 1
        fi
        simulator="$(xcrun simctl create "Steno iPad" "$device_type" "$runtime")"
    fi

    xcrun simctl boot "$simulator" 2>/dev/null || true
    # Send progress to stderr because stdout is the returned UDID.
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
            echo "No booted iPad is available for --print-destination." >&2
            exit 1
        fi
        ;;
    *)
        echo "--print-destination requires --simulator or --ipad-simulator." >&2
        exit 1
        ;;
    esac
    exit 0
fi

cd "$SCRIPT_DIRECTORY/../iOS"

# Always regenerate first. After a branch switch or merge, a stale generated
# project can omit new source files and fail with "cannot find type ..." even
# though the source itself is valid.
xcodegen generate --quiet

case "$MODE" in
--device)
    # The second argument wins; otherwise use the first available iPhone or iPad.
    # Filter by model because a paired Apple Watch is also listed as available
    # and may appear before the phone. Match the UUID pattern instead of a
    # column because "available (paired)" shifts whitespace-delimited fields.
    DEVICE="${2:-}"
    if [[ -z "$DEVICE" ]]; then
        DEVICE=$(xcrun devicectl list devices 2>/dev/null \
            | grep available \
            | grep -E 'iPhone|iPad' \
            | grep -oE '[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}' \
            | head -1)
    fi
    if [[ -z "$DEVICE" ]]; then
        echo "No available device. Unlock the iPhone or iPad and keep it on the same network." >&2
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
        echo "No booted simulator. Start Simulator.app first." >&2
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
