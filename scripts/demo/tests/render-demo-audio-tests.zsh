#!/bin/zsh
set -euo pipefail

readonly TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly DEMO_DIR="$(cd "$TEST_DIR/.." && pwd)"
source "$DEMO_DIR/render-demo-audio-lib.zsh"

typeset -i assertions=0

fail_test() {
  print -u2 -- "FAIL: $1"
  exit 1
}

expect_failure() {
  local description="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    fail_test "$description unexpectedly succeeded"
  fi
  (( assertions += 1 ))
}

expect_equal() {
  local description="$1"
  local expected="$2"
  local actual="$3"
  [[ "$actual" == "$expected" ]] || fail_test "$description: expected '$expected', got '$actual'"
  (( assertions += 1 ))
}

readonly TEST_SUFFIX="tests-$PPID-$$"
readonly VALID_ROOT="/private/tmp/steno-demo-generator-$TEST_SUFFIX"
readonly UNMARKED_ROOT="/private/tmp/steno-demo-generator-$TEST_SUFFIX-unmarked"
readonly LINK_ROOT="/private/tmp/steno-demo-generator-$TEST_SUFFIX-link"
readonly LINK_TARGET="/private/tmp/steno-demo-generator-$TEST_SUFFIX-link-target"
readonly PERMISSIVE_ROOT="/private/tmp/steno-demo-generator-$TEST_SUFFIX-permissive"
readonly PUBLISH_SOURCE="/private/tmp/steno-demo-generator-$TEST_SUFFIX-publish-source"
readonly PUBLISH_TARGET="/private/tmp/steno-demo-generator-$TEST_SUFFIX-published"
readonly EXISTING_TARGET="/private/tmp/steno-demo-generator-$TEST_SUFFIX-existing"
readonly RACE_TARGET="/private/tmp/steno-demo-generator-$TEST_SUFFIX-race"
readonly RACE_LINK="/private/tmp/steno-demo-generator-$TEST_SUFFIX-race-link"
readonly RACE_LINK_TARGET="/private/tmp/steno-demo-generator-$TEST_SUFFIX-race-link-target"
readonly ORCHESTRATION_EVIDENCE_SOURCE="/private/tmp/steno-demo-generator-$TEST_SUFFIX-orchestration-evidence-source"
readonly ORCHESTRATION_OUTPUT_SOURCE="/private/tmp/steno-demo-generator-$TEST_SUFFIX-orchestration-output-source"
readonly ORCHESTRATION_EVIDENCE="/private/tmp/steno-demo-generator-$TEST_SUFFIX-orchestration-evidence"
readonly ORCHESTRATION_OUTPUT="/private/tmp/steno-demo-generator-$TEST_SUFFIX-orchestration-output"
readonly MISMATCH_EVIDENCE="/private/tmp/steno-demo-generator-$TEST_SUFFIX-mismatch-evidence"
readonly MISMATCH_OUTPUT="/private/tmp/steno-demo-generator-$TEST_SUFFIX-mismatch-output"
readonly SAVED_OWNED_EVIDENCE="/private/tmp/steno-demo-generator-$TEST_SUFFIX-saved-owned-evidence"
readonly ROLLBACK_WINDOW_EVIDENCE="/private/tmp/steno-demo-generator-$TEST_SUFFIX-rollback-window-evidence"
readonly ROLLBACK_WINDOW_OUTPUT="/private/tmp/steno-demo-generator-$TEST_SUFFIX-rollback-window-output"
readonly ROLLBACK_WINDOW_SAVED_OWNED="/private/tmp/steno-demo-generator-$TEST_SUFFIX-rollback-window-saved-owned"

cleanup_test_paths() {
  /bin/rm -f -- "$LINK_ROOT"
  /bin/rm -f -- "$RACE_LINK"
  /bin/chmod 700 "$PERMISSIVE_ROOT" 2>/dev/null || true
  /bin/rm -rf -- "$VALID_ROOT" "$UNMARKED_ROOT" "$LINK_TARGET" "$PERMISSIVE_ROOT" \
    "$PUBLISH_SOURCE" "$PUBLISH_TARGET" "$EXISTING_TARGET" "$RACE_TARGET" \
    "$RACE_LINK_TARGET" "$ORCHESTRATION_EVIDENCE_SOURCE" "$ORCHESTRATION_OUTPUT_SOURCE" \
    "$ORCHESTRATION_EVIDENCE" "$ORCHESTRATION_OUTPUT" "$MISMATCH_EVIDENCE" \
    "$MISMATCH_OUTPUT" "$SAVED_OWNED_EVIDENCE" "$ROLLBACK_WINDOW_EVIDENCE" \
    "$ROLLBACK_WINDOW_OUTPUT" "$ROLLBACK_WINDOW_SAVED_OWNED"
}
trap cleanup_test_paths EXIT ZERR INT TERM HUP
cleanup_test_paths

if [[ "${STENO_DEMO_TEST_INJECT_UNEXPECTED_FAILURE:-0}" == '1' ]]; then
  /bin/mkdir -m 700 "$UNMARKED_ROOT" "$LINK_TARGET"
  /bin/ln -s "$LINK_TARGET" "$LINK_ROOT"
  injected_unexpected_failure() {
    return 86
  }
  injected_unexpected_failure
fi

expect_failure "filesystem root cache" validate_cache_root_candidate "/"
expect_failure "home cache" validate_cache_root_candidate "$HOME"
expect_failure "repository cache" validate_cache_root_candidate "$DEMO_DIR"

/bin/mkdir "$UNMARKED_ROOT"
expect_failure "unmarked existing cache" prepare_cache_root "$UNMARKED_ROOT"
[[ -d "$UNMARKED_ROOT" ]] || fail_test "unmarked cache was mutated"
(( assertions += 1 ))

/bin/mkdir "$LINK_TARGET"
/bin/ln -s "$LINK_TARGET" "$LINK_ROOT"
expect_failure "symlink cache component" prepare_cache_root "$LINK_ROOT"

/bin/mkdir -m 777 "$PERMISSIVE_ROOT"
/usr/bin/printf '%s' "$STENO_DEMO_CACHE_MARKER_CONTENT" > \
  "$PERMISSIVE_ROOT/$STENO_DEMO_CACHE_MARKER_NAME"
/bin/chmod 600 "$PERMISSIVE_ROOT/$STENO_DEMO_CACHE_MARKER_NAME"
expect_failure "permissive marked cache" assert_cache_root_owned "$PERMISSIVE_ROOT"

prepare_cache_root "$VALID_ROOT"
assert_cache_root_owned "$VALID_ROOT"
expect_equal "cache marker" "$STENO_DEMO_CACHE_MARKER_CONTENT" "$(< "$VALID_ROOT/$STENO_DEMO_CACHE_MARKER_NAME")"
expect_equal "cache mode" "700" "$(/usr/bin/stat -f '%Lp' "$VALID_ROOT")"
expect_equal "marker mode" "600" "$(/usr/bin/stat -f '%Lp' "$VALID_ROOT/$STENO_DEMO_CACHE_MARKER_NAME")"
expect_failure "foreign cache owner" assert_cache_root_owned_for_uid \
  "$VALID_ROOT" "$(( $(/usr/bin/id -u) + 1 ))"
/bin/chmod 660 "$VALID_ROOT/$STENO_DEMO_CACHE_MARKER_NAME"
expect_failure "group-writable cache marker" assert_cache_root_owned "$VALID_ROOT"
/bin/chmod 600 "$VALID_ROOT/$STENO_DEMO_CACHE_MARKER_NAME"

run_directory="$(create_run_directory "$VALID_ROOT")"
expect_equal "run directory mode" "700" "$(/usr/bin/stat -f '%Lp' "$run_directory")"
expect_equal "run marker mode" "600" \
  "$(/usr/bin/stat -f '%Lp' "$run_directory/$STENO_DEMO_RUN_MARKER_NAME")"
cleanup_run_directory "$VALID_ROOT" "$run_directory"
[[ ! -e "$run_directory" ]] || fail_test "run cleanup did not remove its owned directory"
(( assertions += 1 ))

readonly DOWNLOAD_DIR="$VALID_ROOT/downloads"
ensure_cache_directory "$VALID_ROOT" "$DOWNLOAD_DIR"
/bin/chmod 770 "$DOWNLOAD_DIR"
expect_failure "group-writable download directory" ensure_cache_directory "$VALID_ROOT" "$DOWNLOAD_DIR"
/bin/chmod 700 "$DOWNLOAD_DIR"
readonly UNSAFE_LOCK="$VALID_ROOT/.downloads.lock"
/usr/bin/printf '%s' "$$" > "$UNSAFE_LOCK"
/bin/chmod 660 "$UNSAFE_LOCK"
expect_failure "group-writable download lock" acquire_download_lock "$VALID_ROOT"
/bin/rm -f -- "$UNSAFE_LOCK"
acquire_download_lock "$VALID_ROOT"
expect_equal "download lock mode" "600" "$(/usr/bin/stat -f '%Lp' "$VALID_ROOT/.downloads.lock")"
release_download_lock "$VALID_ROOT"
[[ ! -e "$VALID_ROOT/.downloads.lock" ]] || fail_test "released download lock still exists"
(( assertions += 1 ))
readonly PAYLOAD="$VALID_ROOT/payload.bin"
/usr/bin/printf 'verified payload\n' > "$PAYLOAD"
readonly EXPECTED_BYTES="$(/usr/bin/stat -f '%z' "$PAYLOAD")"
readonly EXPECTED_SHA="$(/usr/bin/shasum -a 256 "$PAYLOAD" | /usr/bin/awk '{print $1}')"
readonly TARGET="$DOWNLOAD_DIR/artifact.bin"
readonly PREEXISTING_PARTIAL="$DOWNLOAD_DIR/.artifact.bin.partial.preexisting"
readonly FAKE_CURL="$VALID_ROOT/fake-curl.zsh"
readonly CURL_STATE="$VALID_ROOT/fake-curl-state"
/usr/bin/printf 'not owned by this attempt\n' > "$PREEXISTING_PARTIAL"

/usr/bin/printf '%s\n' \
  '#!/bin/zsh' \
  'set -euo pipefail' \
  'output=""' \
  'while (( $# > 0 )); do' \
  '  if [[ "$1" == "--output" ]]; then output="$2"; shift 2; else shift; fi' \
  'done' \
  '[[ -n "$output" ]]' \
  'if [[ ! -f "$STENO_DEMO_FAKE_CURL_STATE" ]]; then' \
  '  /usr/bin/printf corrupt > "$output"' \
  '  /usr/bin/touch "$STENO_DEMO_FAKE_CURL_STATE"' \
  '  exit 23' \
  'fi' \
  '/bin/cp "$STENO_DEMO_FAKE_CURL_PAYLOAD" "$output"' \
  > "$FAKE_CURL"
/bin/chmod 700 "$FAKE_CURL"

run_interrupted_download() {
  STENO_DEMO_FAKE_CURL_STATE="$CURL_STATE" \
  STENO_DEMO_FAKE_CURL_PAYLOAD="$PAYLOAD" \
    atomic_download_using "$FAKE_CURL" "$VALID_ROOT" \
      "https://example.invalid/artifact" "$TARGET" "$EXPECTED_BYTES" "$EXPECTED_SHA"
}

expect_failure "interrupted download" run_interrupted_download
[[ ! -e "$TARGET" ]] || fail_test "interrupted download published a final artifact"
(( assertions += 1 ))
expect_equal "unrelated partial survives interruption" "not owned by this attempt" "$(< "$PREEXISTING_PARTIAL")"
expect_equal "only unrelated partial remains after interruption" "1" "$(find "$DOWNLOAD_DIR" -name '.artifact.bin.partial.*' -print | /usr/bin/wc -l | /usr/bin/tr -d ' ')"

STENO_DEMO_FAKE_CURL_STATE="$CURL_STATE" \
STENO_DEMO_FAKE_CURL_PAYLOAD="$PAYLOAD" \
  atomic_download_using "$FAKE_CURL" "$VALID_ROOT" \
    "https://example.invalid/artifact" "$TARGET" "$EXPECTED_BYTES" "$EXPECTED_SHA"
verify_file "$TARGET" "$EXPECTED_BYTES" "$EXPECTED_SHA"
expect_equal "recovered download bytes" "$(< "$PAYLOAD")" "$(< "$TARGET")"
expect_equal "download directory mode" "700" "$(/usr/bin/stat -f '%Lp' "$DOWNLOAD_DIR")"
expect_equal "download mode" "600" "$(/usr/bin/stat -f '%Lp' "$TARGET")"

readonly LEGACY_OVERRIDE_STATE="$VALID_ROOT/legacy-override-executed"
run_legacy_override() {
  STENO_DEMO_CURL="$FAKE_CURL" \
  STENO_DEMO_FAKE_CURL_STATE="$LEGACY_OVERRIDE_STATE" \
  STENO_DEMO_FAKE_CURL_PAYLOAD="$PAYLOAD" \
    atomic_download "$VALID_ROOT" "https://example.invalid/legacy" \
      "$DOWNLOAD_DIR/legacy.bin" "$EXPECTED_BYTES" "$EXPECTED_SHA"
}
expect_failure "legacy production downloader override" run_legacy_override
[[ ! -e "$LEGACY_OVERRIDE_STATE" ]] || fail_test "legacy downloader override executed"
(( assertions += 1 ))

/bin/mkdir -m 700 "$PUBLISH_SOURCE"
/usr/bin/printf 'complete tree\n' > "$PUBLISH_SOURCE/result.txt"
readonly TEST_PYTHON="$(resolve_native_tool python3)"
test_exclusive_rename() {
  /usr/bin/arch -arm64 "$TEST_PYTHON" \
    "$DEMO_DIR/exclusive_rename.py" "$1" "$2"
}

stage_and_publish_directory_using test_exclusive_rename "$PUBLISH_SOURCE" "$PUBLISH_TARGET"
expect_equal "published staged tree" "complete tree" "$(< "$PUBLISH_TARGET/result.txt")"
[[ ! -e "$PUBLISH_TARGET/$STENO_DEMO_PUBLICATION_MARKER_NAME" ]] ||
  fail_test "publication marker leaked into final tree"
(( assertions += 1 ))
expect_equal "published tree mode" "700" "$(/usr/bin/stat -f '%Lp' "$PUBLISH_TARGET")"
expect_equal "publication staging cleanup" "0" \
  "$(/usr/bin/find /private/tmp -maxdepth 1 -name ".${PUBLISH_TARGET:t}.staging.*" -print | /usr/bin/wc -l | /usr/bin/tr -d ' ')"

/bin/mkdir -m 700 "$EXISTING_TARGET"
/usr/bin/printf 'preserve me\n' > "$EXISTING_TARGET/result.txt"
expect_failure "pre-existing publication destination" \
  stage_and_publish_directory_using test_exclusive_rename "$PUBLISH_SOURCE" "$EXISTING_TARGET"
expect_equal "existing publication preserved" "preserve me" "$(< "$EXISTING_TARGET/result.txt")"

race_directory_rename() {
  /bin/mkdir -m 700 "$2"
  /usr/bin/printf 'racing directory\n' > "$2/sentinel"
  test_exclusive_rename "$1" "$2"
}
expect_failure "directory appearing at exclusive rename" \
  stage_and_publish_directory_using race_directory_rename "$PUBLISH_SOURCE" "$RACE_TARGET"
expect_equal "racing directory untouched" "racing directory" "$(< "$RACE_TARGET/sentinel")"
expect_equal "racing directory has no nested staging" "0" \
  "$(/usr/bin/find "$RACE_TARGET" -mindepth 1 -type d -print | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
expect_equal "directory race staging cleanup" "0" \
  "$(/usr/bin/find /private/tmp -maxdepth 1 -name ".${RACE_TARGET:t}.staging.*" -print | /usr/bin/wc -l | /usr/bin/tr -d ' ')"

/bin/mkdir -m 700 "$RACE_LINK_TARGET"
/usr/bin/printf 'symlink target\n' > "$RACE_LINK_TARGET/sentinel"
race_symlink_rename() {
  /bin/ln -s "$RACE_LINK_TARGET" "$2"
  test_exclusive_rename "$1" "$2"
}
expect_failure "symlink appearing at exclusive rename" \
  stage_and_publish_directory_using race_symlink_rename "$PUBLISH_SOURCE" "$RACE_LINK"
[[ -L "$RACE_LINK" ]] || fail_test "racing symlink was replaced"
(( assertions += 1 ))
expect_equal "symlink target untouched" "symlink target" "$(< "$RACE_LINK_TARGET/sentinel")"
expect_equal "symlink target has no nested staging" "0" \
  "$(/usr/bin/find "$RACE_LINK_TARGET" -mindepth 1 -type d -print | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
expect_equal "symlink race staging cleanup" "0" \
  "$(/usr/bin/find /private/tmp -maxdepth 1 -name ".${RACE_LINK:t}.staging.*" -print | /usr/bin/wc -l | /usr/bin/tr -d ' ')"

/bin/mkdir -m 700 "$ORCHESTRATION_EVIDENCE_SOURCE" "$ORCHESTRATION_OUTPUT_SOURCE"
/usr/bin/printf 'evidence\n' > "$ORCHESTRATION_EVIDENCE_SOURCE/result.txt"
/usr/bin/printf 'output\n' > "$ORCHESTRATION_OUTPUT_SOURCE/result.txt"
typeset -i orchestration_rename_count=0
fail_second_publication() {
  (( orchestration_rename_count += 1 ))
  if (( orchestration_rename_count == 2 )); then
    return 1
  fi
  test_exclusive_rename "$1" "$2"
}
expect_failure "output failure rolls back evidence" \
  publish_evidence_then_output_using fail_second_publication \
    "$ORCHESTRATION_EVIDENCE_SOURCE" "$ORCHESTRATION_EVIDENCE" \
    "$ORCHESTRATION_OUTPUT_SOURCE" "$ORCHESTRATION_OUTPUT"
[[ ! -e "$ORCHESTRATION_EVIDENCE" && ! -L "$ORCHESTRATION_EVIDENCE" ]] ||
  fail_test "evidence remained visible after output failure"
[[ ! -e "$ORCHESTRATION_OUTPUT" && ! -L "$ORCHESTRATION_OUTPUT" ]] ||
  fail_test "output became visible after injected failure"
(( assertions += 2 ))
expect_equal "orchestration staging cleanup" "0" \
  "$(/usr/bin/find /private/tmp -maxdepth 1 \( -name ".${ORCHESTRATION_EVIDENCE:t}.staging.*" -o -name ".${ORCHESTRATION_OUTPUT:t}.staging.*" \) -print | /usr/bin/wc -l | /usr/bin/tr -d ' ')"

typeset -i mismatch_rename_count=0
create_identity_mismatch() {
  (( mismatch_rename_count += 1 ))
  if (( mismatch_rename_count == 2 )); then
    /bin/mv -- "$MISMATCH_EVIDENCE" "$SAVED_OWNED_EVIDENCE"
    /bin/mkdir -m 700 "$MISMATCH_EVIDENCE"
    /usr/bin/printf 'foreign tree\n' > "$MISMATCH_EVIDENCE/sentinel"
    return 1
  fi
  test_exclusive_rename "$1" "$2"
}
expect_failure "identity mismatch fails closed" \
  publish_evidence_then_output_using create_identity_mismatch \
    "$ORCHESTRATION_EVIDENCE_SOURCE" "$MISMATCH_EVIDENCE" \
    "$ORCHESTRATION_OUTPUT_SOURCE" "$MISMATCH_OUTPUT"
expect_equal "foreign evidence tree untouched" "foreign tree" "$(< "$MISMATCH_EVIDENCE/sentinel")"
[[ -d "$SAVED_OWNED_EVIDENCE" ]] || fail_test "owned evidence setup was not preserved for test cleanup"
(( assertions += 1 ))
[[ ! -e "$MISMATCH_OUTPUT" && ! -L "$MISMATCH_OUTPUT" ]] ||
  fail_test "mismatch output became visible"
(( assertions += 1 ))

typeset -i rollback_window_rename_count=0
swap_during_rollback_rename() {
  (( rollback_window_rename_count += 1 ))
  if (( rollback_window_rename_count == 2 )); then
    return 1
  fi
  if (( rollback_window_rename_count == 3 )); then
    test_exclusive_rename "$ROLLBACK_WINDOW_EVIDENCE" "$ROLLBACK_WINDOW_SAVED_OWNED"
    /bin/mkdir -m 700 "$ROLLBACK_WINDOW_EVIDENCE"
    /usr/bin/printf 'foreign rollback tree\n' > "$ROLLBACK_WINDOW_EVIDENCE/sentinel"
  fi
  test_exclusive_rename "$1" "$2"
}
expect_failure "rollback-window identity mismatch fails closed" \
  publish_evidence_then_output_using swap_during_rollback_rename \
    "$ORCHESTRATION_EVIDENCE_SOURCE" "$ROLLBACK_WINDOW_EVIDENCE" \
    "$ORCHESTRATION_OUTPUT_SOURCE" "$ROLLBACK_WINDOW_OUTPUT"
expect_equal "rollback-window foreign evidence restored" "foreign rollback tree" \
  "$(< "$ROLLBACK_WINDOW_EVIDENCE/sentinel")"
expect_equal "rollback-window owned evidence preserved" "evidence" \
  "$(< "$ROLLBACK_WINDOW_SAVED_OWNED/result.txt")"
[[ ! -e "$ROLLBACK_WINDOW_OUTPUT" && ! -L "$ROLLBACK_WINDOW_OUTPUT" ]] ||
  fail_test "rollback-window output became visible"
(( assertions += 1 ))
expect_equal "rollback-window staging cleanup" "0" \
  "$(/usr/bin/find /private/tmp -maxdepth 1 \( -name ".${ROLLBACK_WINDOW_EVIDENCE:t}.staging.*" -o -name ".${ROLLBACK_WINDOW_OUTPUT:t}.staging.*" \) -print | /usr/bin/wc -l | /usr/bin/tr -d ' ')"

print -- "PASS: $assertions assertions"
