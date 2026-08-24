#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ARCHITECTURE_GUARD="$ROOT/scripts/require-native-apple-silicon.sh"
MAC_BUILD_SCRIPT="$ROOT/scripts/build-app.sh"

test "$(grep -c '^[[:space:]]*ARCHS: arm64$' "$ROOT/project.yml")" -eq 2
test "$(grep -c '^[[:space:]]*ARCHS: arm64$' "$ROOT/iOS/project.yml")" -eq 2

# shellcheck source=../require-native-apple-silicon.sh
source "$ARCHITECTURE_GUARD"
require_native_apple_silicon arm64

if message="$(require_native_apple_silicon x86_64 2>&1)"; then
    echo "x86_64 unexpectedly passed the Apple-Silicon guard" >&2
    exit 1
fi
test "$message" = "Steno supports native Apple Silicon only; found x86_64."

FAKE_BIN="$(mktemp -d)"
cleanup() {
    local test_exit=$?
    rm -rf "$FAKE_BIN"
    exit "$test_exit"
}
trap cleanup EXIT

CALL_LOG="$FAKE_BIN/calls.log"
: > "$CALL_LOG"
for command in xcodegen xcodebuild; do
    printf '%s\n' \
        '#!/bin/bash' \
        'set -euo pipefail' \
        'printf "%s" "$(basename "$0")" >> "$CALL_LOG"' \
        'printf " %s" "$@" >> "$CALL_LOG"' \
        'printf "\n" >> "$CALL_LOG"' \
        > "$FAKE_BIN/$command"
    chmod +x "$FAKE_BIN/$command"
done

PATH="$FAKE_BIN:$PATH" CALL_LOG="$CALL_LOG" "$MAC_BUILD_SCRIPT" >/dev/null
actual="$(< "$CALL_LOG")"
expected="$(printf '%s\n' \
    'xcodegen generate --quiet' \
    'xcodebuild -project Steno.xcodeproj -scheme Steno -arch arm64 -configuration Debug -derivedDataPath .build/DerivedData build')"
test "$actual" = "$expected"
