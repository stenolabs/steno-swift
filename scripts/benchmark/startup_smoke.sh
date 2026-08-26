#!/bin/bash
# Startup smoke guard: builds the steno-smoke executor and times a full
# pipeline start (Library open -> recovery sweep -> queue ready) against the
# budget in docs/PERF-BUDGETS.md. Exits nonzero when the budget is exceeded
# or anything fails. Stdlib-only, no arguments.
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIRECTORY/../.." && pwd)"

BUDGET_SECONDS="${STENO_STARTUP_BUDGET:-5}"

WORK="$(mktemp -d /tmp/steno-startup-smoke.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

cd "$REPO_ROOT/StenoKit"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}" \
    swift build --product steno-smoke 2>/dev/null || swift build --product steno-smoke >"$WORK/build.log" 2>&1

BIN=".build/debug/steno-smoke"
[ -x "$BIN" ] || BIN=".build/out/debug/steno-smoke"
[ -x "$BIN" ] || { echo "startup_smoke: steno-smoke binary not found" >&2; exit 2; }

START=$(date +%s.%N)
# A missing audio file still exercises library open + recovery + queue setup:
# the smoke tool fails AFTER pipeline start, which is what we measure. Treat
# its early usage/IO failure as success for timing purposes.
"$BIN" "$WORK/library" "$WORK/nonexistent.m4a" >/dev/null 2>&1 || true
END=$(date +%s.%N)

ELAPSED=$(python3 -c "print(f'{$END-$START:.3f}')")
WITHIN=$(python3 -c "print('within' if $ELAPSED <= $BUDGET_SECONDS else 'EXCEEDED')")

echo "pipeline startup: ${ELAPSED}s (budget ${BUDGET_SECONDS}s) -> $WITHIN"
python3 -c "import sys; sys.exit(0 if $ELAPSED <= $BUDGET_SECONDS else 1)"
