#!/bin/zsh
# Safety and download primitives for render-demo-audio.sh.

umask 077

typeset -gr STENO_DEMO_CACHE_MARKER_NAME='.steno-demo-generator-cache'
typeset -gr STENO_DEMO_CACHE_MARKER_CONTENT='steno-demo-generator-cache-v1'
typeset -gr STENO_DEMO_RUN_MARKER_NAME='.steno-demo-generator-run'
typeset -gr STENO_DEMO_PUBLICATION_MARKER_NAME='.steno-demo-publication-stage'
typeset -gr STENO_DEMO_PUBLICATION_MARKER_CONTENT='steno-demo-publication-stage-v1'
typeset -g STENO_DEMO_DOWNLOAD_LOCK=''
typeset -g STENO_DEMO_LAST_PUBLICATION_STAGING=''
typeset -g STENO_DEMO_LAST_PUBLICATION_DESTINATION=''
typeset -g STENO_DEMO_LAST_PUBLICATION_DEVICE=''
typeset -g STENO_DEMO_LAST_PUBLICATION_INODE=''

demo_error() {
  print -u2 -- "$1"
  return 1
}

validate_cache_root_candidate() {
  local candidate="$1"
  local suffix

  [[ "$candidate" == /private/tmp/steno-demo-generator-* ]] ||
    demo_error 'Cache root must be an absolute /private/tmp/steno-demo-generator-* path.' || return
  suffix="${candidate#/private/tmp/steno-demo-generator-}"
  [[ -n "$suffix" && "$suffix" != *'/'* && "$suffix" != *'..'* ]] ||
    demo_error 'Cache root has an invalid task suffix.' || return
  case "$suffix" in
    *[!A-Za-z0-9._-]*) demo_error 'Cache root suffix contains unsupported characters.' || return ;;
  esac
  [[ "$candidate" != "$HOME" && "$candidate" != / ]] ||
    demo_error 'Cache root may not be the home or filesystem root.' || return
}

reject_existing_symlink_components() {
  local target="$1"
  local current=''
  local component
  local -a components

  [[ "$target" == /* ]] || demo_error "Path is not absolute: $target" || return
  components=("${(@s:/:)target}")
  for component in "${components[@]}"; do
    [[ -n "$component" ]] || continue
    current="$current/$component"
    if [[ -e "$current" || -L "$current" ]]; then
      [[ ! -L "$current" ]] || demo_error "Symbolic-link path component is forbidden: $current" || return
    else
      break
    fi
  done
}

assert_owned_directory() {
  local target="$1"
  local expected_uid="$2"
  local expected_mode="$3"
  local label="$4"
  local actual_uid actual_mode

  [[ -d "$target" && ! -L "$target" ]] || demo_error "$label is not a real directory: $target" || return
  actual_uid="$(/usr/bin/stat -f '%u' "$target")" || return
  actual_mode="$(/usr/bin/stat -f '%Lp' "$target")" || return
  [[ "$actual_uid" == "$expected_uid" ]] || demo_error "$label has a foreign owner: $target" || return
  [[ "$actual_mode" == "$expected_mode" ]] || demo_error "$label has unsafe mode $actual_mode: $target" || return
}

assert_owned_regular_file() {
  local target="$1"
  local expected_uid="$2"
  local expected_mode="$3"
  local label="$4"
  local actual_uid actual_mode

  [[ -f "$target" && ! -L "$target" ]] || demo_error "$label is not a regular file: $target" || return
  actual_uid="$(/usr/bin/stat -f '%u' "$target")" || return
  actual_mode="$(/usr/bin/stat -f '%Lp' "$target")" || return
  [[ "$actual_uid" == "$expected_uid" ]] || demo_error "$label has a foreign owner: $target" || return
  [[ "$actual_mode" == "$expected_mode" ]] || demo_error "$label has unsafe mode $actual_mode: $target" || return
}

assert_cache_root_owned_for_uid() {
  local root="$1"
  local expected_uid="$2"
  local marker="$root/$STENO_DEMO_CACHE_MARKER_NAME"

  [[ "$expected_uid" == <-> ]] || demo_error 'Expected cache UID is not numeric.' || return
  validate_cache_root_candidate "$root" || return
  reject_existing_symlink_components "$root" || return
  assert_owned_directory "$root" "$expected_uid" 700 'Cache root' || return
  assert_owned_regular_file "$marker" "$expected_uid" 600 'Cache ownership marker' || return
  [[ "$(< "$marker")" == "$STENO_DEMO_CACHE_MARKER_CONTENT" ]] ||
    demo_error "Cache ownership marker does not match: $root" || return
}

assert_cache_root_owned() {
  local root="$1"
  assert_cache_root_owned_for_uid "$root" "$(/usr/bin/id -u)"
}

prepare_cache_root() {
  local root="$1"
  local marker="$root/$STENO_DEMO_CACHE_MARKER_NAME"

  validate_cache_root_candidate "$root" || return
  reject_existing_symlink_components "$root" || return
  if [[ -e "$root" || -L "$root" ]]; then
    assert_cache_root_owned "$root"
    return
  fi

  /bin/mkdir -m 700 "$root" || return
  if ! (set -o noclobber; print -rn -- "$STENO_DEMO_CACHE_MARKER_CONTENT" > "$marker"); then
    demo_error "Could not create cache ownership marker: $marker"
    return
  fi
  /bin/chmod 600 "$marker" || return
  assert_cache_root_owned "$root"
}

ensure_cache_directory() {
  local root="$1"
  local directory="$2"
  local expected_uid

  assert_cache_root_owned "$root" || return
  expected_uid="$(/usr/bin/id -u)" || return
  [[ "$directory" == "$root/runs" || "$directory" == "$root/downloads" ]] ||
    demo_error "Unexpected cache directory: $directory" || return
  if [[ -e "$directory" || -L "$directory" ]]; then
    reject_existing_symlink_components "$directory" || return
  else
    /bin/mkdir -m 700 "$directory" || return
  fi
  assert_owned_directory "$directory" "$expected_uid" 700 'Cache directory'
}

assert_owned_descendant() {
  local root="$1"
  local descendant="$2"
  local root_real descendant_real

  assert_cache_root_owned "$root" || return
  [[ "$descendant" == "$root/"* && "$descendant" != *'/../'* && "$descendant" != *'/..' ]] ||
    demo_error "Path is not a lexical cache descendant: $descendant" || return
  reject_existing_symlink_components "$descendant" || return
  [[ -e "$descendant" ]] || demo_error "Cache descendant does not exist: $descendant" || return
  root_real="$(cd "$root" && pwd -P)" || return
  if [[ -d "$descendant" ]]; then
    descendant_real="$(cd "$descendant" && pwd -P)" || return
  else
    descendant_real="$(cd "$(dirname "$descendant")" && pwd -P)/$(basename "$descendant")" || return
  fi
  [[ "$descendant_real" == "$root_real/"* ]] || demo_error "Path escapes cache root: $descendant" || return
}

create_run_directory() {
  local root="$1"
  local runs="$root/runs"
  local run
  local expected_uid

  assert_cache_root_owned "$root" || return
  expected_uid="$(/usr/bin/id -u)" || return
  ensure_cache_directory "$root" "$runs" || return
  run="$(/usr/bin/mktemp -d "$runs/run.XXXXXX")" || return
  assert_owned_directory "$run" "$expected_uid" 700 'Run directory' || return
  print -rn -- "$STENO_DEMO_CACHE_MARKER_CONTENT" > "$run/$STENO_DEMO_RUN_MARKER_NAME"
  /bin/chmod 600 "$run/$STENO_DEMO_RUN_MARKER_NAME" || return
  assert_owned_regular_file "$run/$STENO_DEMO_RUN_MARKER_NAME" "$expected_uid" 600 \
    'Run ownership marker' || return
  print -r -- "$run"
}

cleanup_run_directory() {
  local root="$1"
  local run="$2"
  local marker="$run/$STENO_DEMO_RUN_MARKER_NAME"
  local expected_uid

  [[ -n "$run" && -e "$run" ]] || return 0
  assert_owned_descendant "$root" "$run" || return
  expected_uid="$(/usr/bin/id -u)" || return
  [[ "$run" == "$root/runs/run."* ]] || demo_error "Unexpected run directory name: $run" || return
  assert_owned_directory "$root/runs" "$expected_uid" 700 'Run parent' || return
  assert_owned_directory "$run" "$expected_uid" 700 'Run directory' || return
  assert_owned_regular_file "$marker" "$expected_uid" 600 'Run ownership marker' || return
  [[ "$(< "$marker")" == "$STENO_DEMO_CACHE_MARKER_CONTENT" ]] ||
    demo_error "Run ownership marker does not match: $run" || return
  /bin/rm -rf -- "$run"
}

verify_file() {
  local target="$1"
  local expected_bytes="$2"
  local expected_sha="$3"
  local actual_bytes actual_sha

  [[ -f "$target" && ! -L "$target" ]] || demo_error "Missing regular artifact: $target" || return
  actual_bytes="$(/usr/bin/stat -f '%z' "$target")" || return
  [[ "$actual_bytes" == "$expected_bytes" ]] || demo_error "Byte count mismatch: $target" || return
  actual_sha="$(/usr/bin/shasum -a 256 "$target" | /usr/bin/awk '{print $1}')" || return
  [[ "$actual_sha" == "$expected_sha" ]] || demo_error "SHA-256 mismatch: $target" || return
}

steno_native_curl() {
  /usr/bin/arch -arm64 /usr/bin/curl "$@"
}

atomic_download_using() {
  local downloader="$1"
  local root="$2"
  local url="$3"
  local target="$4"
  local expected_bytes="$5"
  local expected_sha="$6"
  shift 6
  local parent partial expected_uid

  assert_cache_root_owned "$root" || return
  expected_uid="$(/usr/bin/id -u)" || return
  parent="$(dirname "$target")"
  [[ "$parent" == "$root/downloads" ]] || demo_error "Download target is outside the cache: $target" || return
  ensure_cache_directory "$root" "$parent" || return
  if [[ -e "$target" || -L "$target" ]]; then
    assert_owned_regular_file "$target" "$expected_uid" 600 'Cached download' || return
    verify_file "$target" "$expected_bytes" "$expected_sha"
    return
  fi

  partial="$(/usr/bin/mktemp "$parent/.$(basename "$target").partial.XXXXXX")" || return
  assert_owned_regular_file "$partial" "$expected_uid" 600 'Download partial' || return
  if ! "$downloader" -L --fail --silent --show-error --output "$partial" "$@" "$url"; then
    /bin/rm -f -- "$partial"
    return 1
  fi
  if ! verify_file "$partial" "$expected_bytes" "$expected_sha"; then
    /bin/rm -f -- "$partial"
    return 1
  fi
  if ! /bin/mv -n -- "$partial" "$target"; then
    /bin/rm -f -- "$partial"
    return 1
  fi
  if [[ -e "$partial" ]]; then
    /bin/rm -f -- "$partial"
  fi
  assert_owned_regular_file "$target" "$expected_uid" 600 'Cached download' || return
  verify_file "$target" "$expected_bytes" "$expected_sha"
}

atomic_download() {
  if (( ${+STENO_DEMO_CURL} )); then
    demo_error 'STENO_DEMO_CURL is unsupported; production always uses native system curl.'
    return
  fi
  atomic_download_using steno_native_curl "$@"
}

acquire_download_lock() {
  local root="$1"
  local lock="$root/.downloads.lock"
  local attempt
  local expected_uid

  assert_cache_root_owned "$root" || return
  expected_uid="$(/usr/bin/id -u)" || return
  ensure_cache_directory "$root" "$root/downloads" || return
  if [[ -e "$lock" || -L "$lock" ]]; then
    assert_owned_regular_file "$lock" "$expected_uid" 600 'Download lock' || return
  fi
  for attempt in {1..120}; do
    if /usr/bin/arch -arm64 /usr/bin/shlock -f "$lock" -p $$; then
      /bin/chmod 600 "$lock" || return
      assert_owned_regular_file "$lock" "$expected_uid" 600 'Download lock' || return
      STENO_DEMO_DOWNLOAD_LOCK="$lock"
      return 0
    fi
    /bin/sleep 0.25
  done
  demo_error "Timed out waiting for download lock: $lock"
}

release_download_lock() {
  local root="$1"
  local expected_uid
  [[ -n "$STENO_DEMO_DOWNLOAD_LOCK" ]] || return 0
  assert_cache_root_owned "$root" || return
  expected_uid="$(/usr/bin/id -u)" || return
  [[ "$STENO_DEMO_DOWNLOAD_LOCK" == "$root/.downloads.lock" ]] ||
    demo_error 'Download lock is outside the owned cache.' || return
  if [[ -e "$STENO_DEMO_DOWNLOAD_LOCK" || -L "$STENO_DEMO_DOWNLOAD_LOCK" ]]; then
    assert_owned_regular_file "$STENO_DEMO_DOWNLOAD_LOCK" "$expected_uid" 600 \
      'Download lock' || return
  fi
  if [[ -f "$STENO_DEMO_DOWNLOAD_LOCK" && "$(< "$STENO_DEMO_DOWNLOAD_LOCK")" == "$$" ]]; then
    /bin/rm -f -- "$STENO_DEMO_DOWNLOAD_LOCK"
  fi
  STENO_DEMO_DOWNLOAD_LOCK=''
}

validate_new_publication_destination() {
  local destination="$1"
  local parent

  [[ ! -e "$destination" && ! -L "$destination" ]] ||
    demo_error "Publication destination already exists: $destination" || return
  parent="$(dirname "$destination")"
  reject_existing_symlink_components "$parent" || return
  [[ -d "$parent" && ! -L "$parent" ]] ||
    demo_error "Publication parent is not a real directory: $parent" || return
}

cleanup_publication_stage() {
  local staging="$1"
  local parent="$2"
  local base="$3"
  local expected_uid marker

  [[ -n "$staging" && ( -e "$staging" || -L "$staging" ) ]] || return 0
  expected_uid="$(/usr/bin/id -u)" || return
  marker="$staging/$STENO_DEMO_PUBLICATION_MARKER_NAME"
  [[ "$staging" == "$parent/.$base.staging."* ]] ||
    demo_error "Unexpected publication staging path: $staging" || return
  reject_existing_symlink_components "$staging" || return
  assert_owned_directory "$staging" "$expected_uid" 700 'Publication staging directory' || return
  assert_owned_regular_file "$marker" "$expected_uid" 600 'Publication staging marker' || return
  [[ "$(< "$marker")" == "$STENO_DEMO_PUBLICATION_MARKER_CONTENT" ]] ||
    demo_error "Publication staging marker does not match: $staging" || return
  /bin/rm -rf -- "$staging"
}

assert_directory_identity() {
  local target="$1"
  local expected_device="$2"
  local expected_inode="$3"
  local label="$4"
  local expected_uid actual_device actual_inode

  expected_uid="$(/usr/bin/id -u)" || return
  assert_owned_directory "$target" "$expected_uid" 700 "$label" || return
  actual_device="$(/usr/bin/stat -f '%d' "$target")" || return
  actual_inode="$(/usr/bin/stat -f '%i' "$target")" || return
  [[ "$actual_device" == "$expected_device" && "$actual_inode" == "$expected_inode" ]] ||
    demo_error "$label identity changed: $target" || return
}

restore_marker_and_cleanup_publication_stage() {
  local staging="$1"
  local parent="$2"
  local base="$3"
  local expected_device="$4"
  local expected_inode="$5"
  local marker="$staging/$STENO_DEMO_PUBLICATION_MARKER_NAME"

  assert_directory_identity "$staging" "$expected_device" "$expected_inode" \
    'Publication staging directory' || return
  [[ ! -e "$marker" && ! -L "$marker" ]] ||
    demo_error "Publication staging marker path is unexpectedly occupied: $marker" || return
  if ! (set -o noclobber; print -rn -- "$STENO_DEMO_PUBLICATION_MARKER_CONTENT" > "$marker"); then
    demo_error "Could not restore publication staging marker: $marker"
    return
  fi
  /bin/chmod 600 "$marker" || return
  cleanup_publication_stage "$staging" "$parent" "$base"
}

stage_and_publish_directory_using() {
  local renamer="$1"
  local source="$2"
  local destination="$3"
  local parent base staging=''
  local staging_device staging_inode

  STENO_DEMO_LAST_PUBLICATION_STAGING=''
  STENO_DEMO_LAST_PUBLICATION_DESTINATION=''
  STENO_DEMO_LAST_PUBLICATION_DEVICE=''
  STENO_DEMO_LAST_PUBLICATION_INODE=''

  [[ -d "$source" && ! -L "$source" ]] || demo_error "Publication source is not a real directory: $source" || return
  [[ ! -e "$source/$STENO_DEMO_PUBLICATION_MARKER_NAME" &&
     ! -L "$source/$STENO_DEMO_PUBLICATION_MARKER_NAME" ]] ||
    demo_error "Publication source contains the reserved staging marker." || return
  validate_new_publication_destination "$destination" || return
  parent="$(dirname "$destination")"
  base="$(basename "$destination")"
  staging="$(/usr/bin/mktemp -d "$parent/.$base.staging.XXXXXX")" || return
  if ! print -rn -- "$STENO_DEMO_PUBLICATION_MARKER_CONTENT" > \
      "$staging/$STENO_DEMO_PUBLICATION_MARKER_NAME"; then
    /bin/rmdir -- "$staging"
    return 1
  fi
  if ! /bin/chmod 600 "$staging/$STENO_DEMO_PUBLICATION_MARKER_NAME"; then
    /bin/rm -f -- "$staging/$STENO_DEMO_PUBLICATION_MARKER_NAME"
    /bin/rmdir -- "$staging"
    return 1
  fi
  if ! /bin/cp -R "$source/." "$staging/"; then
    cleanup_publication_stage "$staging" "$parent" "$base"
    return 1
  fi
  if [[ -e "$destination" || -L "$destination" ]]; then
    cleanup_publication_stage "$staging" "$parent" "$base"
    demo_error "Publication destination appeared while staging: $destination"
    return
  fi
  staging_device="$(/usr/bin/stat -f '%d' "$staging")" || return
  staging_inode="$(/usr/bin/stat -f '%i' "$staging")" || return
  /bin/rm -f -- "$staging/$STENO_DEMO_PUBLICATION_MARKER_NAME"
  if ! "$renamer" "$staging" "$destination"; then
    restore_marker_and_cleanup_publication_stage \
      "$staging" "$parent" "$base" "$staging_device" "$staging_inode" || return
    return 1
  fi
  assert_directory_identity "$destination" "$staging_device" "$staging_inode" \
    'Published directory' || return
  STENO_DEMO_LAST_PUBLICATION_STAGING="$staging"
  STENO_DEMO_LAST_PUBLICATION_DESTINATION="$destination"
  STENO_DEMO_LAST_PUBLICATION_DEVICE="$staging_device"
  STENO_DEMO_LAST_PUBLICATION_INODE="$staging_inode"
}

rollback_published_directory_using() {
  local renamer="$1"
  local destination="$2"
  local staging="$3"
  local expected_device="$4"
  local expected_inode="$5"
  local parent base

  parent="$(dirname "$destination")"
  base="$(basename "$destination")"
  [[ "$staging" == "$parent/.$base.staging."* ]] ||
    demo_error "Rollback staging path is not the original sibling: $staging" || return
  [[ ! -e "$staging" && ! -L "$staging" ]] ||
    demo_error "Rollback staging path is occupied: $staging" || return
  assert_directory_identity "$destination" "$expected_device" "$expected_inode" \
    'Published rollback directory' || return
  if ! "$renamer" "$destination" "$staging"; then
    demo_error "Could not exclusively rename published directory back to staging: $destination"
    return
  fi
  if ! assert_directory_identity "$staging" "$expected_device" "$expected_inode" \
      'Rolled-back publication staging directory'; then
    restore_mismatched_rollback_tree_using "$renamer" "$staging" "$destination" || return
    return 1
  fi
  restore_marker_and_cleanup_publication_stage \
    "$staging" "$parent" "$base" "$expected_device" "$expected_inode"
}

restore_mismatched_rollback_tree_using() {
  local renamer="$1"
  local staging="$2"
  local destination="$3"
  local expected_uid actual_device actual_inode

  expected_uid="$(/usr/bin/id -u)" || return
  assert_owned_directory "$staging" "$expected_uid" 700 \
    'Unexpected rollback staging directory' || {
      demo_error "Unexpected rollback tree was left intact at: $staging"
      return 1
    }
  actual_device="$(/usr/bin/stat -f '%d' "$staging")" || return
  actual_inode="$(/usr/bin/stat -f '%i' "$staging")" || return
  if [[ -e "$destination" || -L "$destination" ]]; then
    demo_error "Cannot restore unexpected rollback tree because its destination is occupied; tree remains at: $staging"
    return 1
  fi
  if ! "$renamer" "$staging" "$destination"; then
    demo_error "Could not restore unexpected rollback tree; tree remains at: $staging"
    return 1
  fi
  if ! assert_directory_identity "$destination" "$actual_device" "$actual_inode" \
      'Restored unexpected rollback directory'; then
    demo_error "Could not verify restored unexpected rollback tree at: $destination"
    return 1
  fi
  demo_error "Rollback identity changed; unexpected tree was restored intact to: $destination"
  return 1
}

publish_evidence_then_output_using() {
  local renamer="$1"
  local evidence_source="$2"
  local evidence_destination="$3"
  local output_source="$4"
  local output_destination="$5"
  local evidence_staging evidence_device evidence_inode
  local output_status rollback_status

  validate_new_publication_destination "$evidence_destination" || return
  validate_new_publication_destination "$output_destination" || return
  [[ "$evidence_destination" != "$output_destination" ]] ||
    demo_error 'Evidence and output destinations must differ.' || return
  stage_and_publish_directory_using \
    "$renamer" "$evidence_source" "$evidence_destination" || return
  evidence_staging="$STENO_DEMO_LAST_PUBLICATION_STAGING"
  evidence_device="$STENO_DEMO_LAST_PUBLICATION_DEVICE"
  evidence_inode="$STENO_DEMO_LAST_PUBLICATION_INODE"
  if stage_and_publish_directory_using \
      "$renamer" "$output_source" "$output_destination"; then
    return 0
  else
    output_status=$?
  fi
  if rollback_published_directory_using \
      "$renamer" "$evidence_destination" "$evidence_staging" \
      "$evidence_device" "$evidence_inode"; then
    return "$output_status"
  else
    rollback_status=$?
    demo_error "Output publication failed and evidence rollback failed with status $rollback_status."
    return 1
  fi
}

resolve_native_tool() {
  local name="$1"
  local tool
  local archs

  tool="$(whence -p "$name")" || demo_error "Required tool is missing: $name" || return
  [[ -x "$tool" ]] || demo_error "Required tool is not executable: $tool" || return
  archs="$(/usr/bin/lipo -archs "$tool" 2>/dev/null)" ||
    demo_error "Required tool is not a Mach-O executable: $tool" || return
  [[ " $archs " == *' arm64 '* || " $archs " == *' arm64e '* ]] ||
    demo_error "Required tool has no arm64 or arm64e slice: $tool" || return
  print -r -- "$tool"
}

require_arm64_only() {
  local target="$1"
  local archs

  [[ -f "$target" && ! -L "$target" ]] || demo_error "Missing architecture target: $target" || return
  archs="$(/usr/bin/lipo -archs "$target" 2>/dev/null)" || demo_error "Not a Mach-O file: $target" || return
  [[ "$archs" == 'arm64' ]] || demo_error "Private toolchain artifact is not arm64-only: $target ($archs)" || return
}
