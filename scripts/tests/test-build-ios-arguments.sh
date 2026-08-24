#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/build-ios.sh"
FIXTURE='{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-26-0":[{"name":"iPhone 17","udid":"11111111-1111-1111-1111-111111111111","state":"Booted","isAvailable":true},{"name":"iPad Pro 13-inch (M5)","udid":"BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB","state":"Booted","isAvailable":true},{"name":"iPad Pro 13-inch (M5)","udid":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","state":"Booted","isAvailable":true}]}}'
EMPTY_FIXTURE='{"devices":{}}'

FAKE_BIN="$(mktemp -d)"
FALLBACK_BIN="$(mktemp -d)"
cleanup() {
    local status=$?
    rm -rf "$FAKE_BIN" "$FALLBACK_BIN"
    exit "$status"
}
trap cleanup EXIT
for command in xcodegen xcodebuild xcrun; do
    printf '%s\n' \
        '#!/bin/bash' \
        'echo "$0 must not run for --print-destination" >&2' \
        'exit 99' \
        > "$FAKE_BIN/$command"
    chmod +x "$FAKE_BIN/$command"
done

actual="$(PATH="$FAKE_BIN:$PATH" "$SCRIPT" --print-destination --simulator CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC)"
test "$actual" = "platform=iOS Simulator,id=CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"

actual="$(PATH="$FAKE_BIN:$PATH" SIMCTL_DEVICES_JSON="$FIXTURE" "$SCRIPT" --print-destination --ipad-simulator)"
test "$actual" = "platform=iOS Simulator,id=AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"

actual="$(PATH="$FAKE_BIN:$PATH" SIMCTL_DEVICES_JSON="$FIXTURE" "$SCRIPT" --print-destination --ipad-simulator)"
test "$actual" = "platform=iOS Simulator,id=AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"

if output="$(PATH="$FAKE_BIN:$PATH" SIMCTL_DEVICES_JSON="$EMPTY_FIXTURE" "$SCRIPT" --print-destination --ipad-simulator 2>&1)"; then
    echo "--ipad-simulator without a booted iPad unexpectedly resolved" >&2
    exit 1
fi
test "$output" = "Kein gebootetes iPad fuer --print-destination."

printf '%s\n' \
    '#!/bin/bash' \
    'set -euo pipefail' \
    'printf "xcodegen" >> "$CALL_LOG"' \
    'printf " %s" "$@" >> "$CALL_LOG"' \
    'printf "\n" >> "$CALL_LOG"' \
    > "$FALLBACK_BIN/xcodegen"
chmod +x "$FALLBACK_BIN/xcodegen"

printf '%s\n' \
    '#!/bin/bash' \
    'set -euo pipefail' \
    'printf "xcodebuild" >> "$CALL_LOG"' \
    'printf " %s" "$@" >> "$CALL_LOG"' \
    'printf "\n" >> "$CALL_LOG"' \
    > "$FALLBACK_BIN/xcodebuild"
chmod +x "$FALLBACK_BIN/xcodebuild"

printf '%s\n' \
    '#!/bin/bash' \
    'set -euo pipefail' \
    'printf "xcrun" >> "$CALL_LOG"' \
    'printf " %s" "$@" >> "$CALL_LOG"' \
    'printf "\n" >> "$CALL_LOG"' \
    'case "${SIMCTL_FIXTURE_CASE:-}:$*" in' \
    'existing:simctl\ list\ devices\ booted\ -j)' \
    '    printf "%s\n" '\''{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-26-0":[{"name":"iPhone 17","udid":"11111111-1111-1111-1111-111111111111","state":"Booted","isAvailable":true},{"name":"iPad Pro 11-inch (M5)","udid":"CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC","state":"Shutdown","isAvailable":true},{"name":"iPad Pro 11-inch (M5)","udid":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","state":"Shutdown","isAvailable":true}]}}'\''' \
    '    ;;' \
    'existing:simctl\ list\ devices\ -j)' \
    '    printf "%s\n" '\''{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-26-0":[{"name":"iPhone 17","udid":"11111111-1111-1111-1111-111111111111","state":"Booted","isAvailable":true},{"name":"iPad Pro 11-inch (M5)","udid":"CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC","state":"Shutdown","isAvailable":true},{"name":"iPad Pro 11-inch (M5)","udid":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","state":"Shutdown","isAvailable":true}]}}'\''' \
    '    ;;' \
    'create:simctl\ list\ devices\ booted\ -j|create:simctl\ list\ devices\ -j)' \
    '    printf "%s\n" '\''{"devices":{}}'\''' \
    '    ;;' \
    'create:simctl\ list\ runtimes\ -j)' \
    '    printf "%s\n" '\''{"runtimes":[{"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-9-9","version":"9.9","isAvailable":true},{"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-10-0","version":"10.0","isAvailable":true},{"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-99-0","version":"99.0","isAvailable":false}]}'\''' \
    '    ;;' \
    'create:simctl\ list\ devicetypes\ -j)' \
    '    printf "%s\n" '\''{"devicetypes":[{"name":"iPad Pro 13-inch (M5)","identifier":"com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5","isAvailable":true}]}'\''' \
    '    ;;' \
    'create:simctl\ create*)' \
    '    printf "%s\n" "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD"' \
    '    ;;' \
    '*:simctl\ bootstatus*)' \
    '    printf "%s\n" "Monitoring boot status for fake device." "Finished"' \
    '    ;;' \
    '*:simctl\ boot*|*:simctl\ install*|*:simctl\ launch*)' \
    '    ;;' \
    '*)' \
    '    echo "Unexpected xcrun call: $*" >&2' \
    '    exit 1' \
    '    ;;' \
    'esac' \
    > "$FALLBACK_BIN/xcrun"
chmod +x "$FALLBACK_BIN/xcrun"

run_fallback_case() {
    local fixture_case="$1"
    local call_log="$FALLBACK_BIN/$fixture_case.log"
    local expected="$2"

    : > "$call_log"
    env -u SIMCTL_DEVICES_JSON \
        PATH="$FALLBACK_BIN:$PATH" \
        CALL_LOG="$call_log" \
        SIMCTL_FIXTURE_CASE="$fixture_case" \
        "$SCRIPT" --ipad-simulator
    actual="$(< "$call_log")"
    if [[ "$actual" != "$expected" ]]; then
        printf 'Unexpected call log for %s:\n%s\n' "$fixture_case" "$actual" >&2
        exit 1
    fi
}

run_fallback_case existing "$(printf '%s\n' \
    'xcodegen generate --quiet' \
    'xcrun simctl list devices booted -j' \
    'xcrun simctl list devices -j' \
    'xcrun simctl boot AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA' \
    'xcrun simctl bootstatus AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA -b' \
    'xcodebuild -project StenoiOS.xcodeproj -scheme Steno ARCHS=arm64 ONLY_ACTIVE_ARCH=YES EXCLUDED_ARCHS=x86_64 -destination platform=iOS Simulator,id=AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA -derivedDataPath build build' \
    "xcrun simctl install AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA $ROOT/iOS/build/Build/Products/Debug-iphonesimulator/Steno.app" \
    'xcrun simctl launch AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA org.steno.Steno')"

run_fallback_case create "$(printf '%s\n' \
    'xcodegen generate --quiet' \
    'xcrun simctl list devices booted -j' \
    'xcrun simctl list devices -j' \
    'xcrun simctl list runtimes -j' \
    'xcrun simctl list devicetypes -j' \
    'xcrun simctl create Steno iPad com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5 com.apple.CoreSimulator.SimRuntime.iOS-10-0' \
    'xcrun simctl boot DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD' \
    'xcrun simctl bootstatus DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD -b' \
    'xcodebuild -project StenoiOS.xcodeproj -scheme Steno ARCHS=arm64 ONLY_ACTIVE_ARCH=YES EXCLUDED_ARCHS=x86_64 -destination platform=iOS Simulator,id=DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD -derivedDataPath build build' \
    "xcrun simctl install DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD $ROOT/iOS/build/Build/Products/Debug-iphonesimulator/Steno.app" \
    'xcrun simctl launch DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD org.steno.Steno')"

NULL_ARGUMENTS_LOG="$FALLBACK_BIN/null-arguments.log"
: > "$NULL_ARGUMENTS_LOG"
env -u SIMCTL_DEVICES_JSON \
    PATH="$FALLBACK_BIN:$PATH" \
    CALL_LOG="$NULL_ARGUMENTS_LOG" \
    "$SCRIPT"
actual="$(< "$NULL_ARGUMENTS_LOG")"
expected="$(printf '%s\n' \
    'xcodegen generate --quiet' \
    'xcodebuild -project StenoiOS.xcodeproj -scheme Steno ARCHS=arm64 ONLY_ACTIVE_ARCH=YES EXCLUDED_ARCHS=x86_64 -destination generic/platform=iOS -allowProvisioningUpdates -derivedDataPath build build')"
if [[ "$actual" != "$expected" ]]; then
    printf 'Unexpected call log for null arguments:\n%s\n' "$actual" >&2
    exit 1
fi
