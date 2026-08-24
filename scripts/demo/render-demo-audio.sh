#!/bin/zsh
# Render the committed demo WAVs with an isolated, verified arm64-only toolchain.
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/render-demo-audio-lib.zsh"

readonly INPUT="$SCRIPT_DIR/demo-script.json"
readonly CACHE_ROOT="${STENO_DEMO_CACHE_DIR:-/private/tmp/steno-demo-generator-20260823}"
readonly BUNDLED_MANIFEST="$SCRIPT_DIR/../../StenoKit/Sources/StenoDemo/Resources/DemoDataset/manifest.json"
typeset FREEZE_OUTPUT=0
typeset EVIDENCE_DIR=''
if [[ "${1:-}" == '--freeze-output' ]]; then
  FREEZE_OUTPUT=1
  shift
fi
if [[ "${1:-}" == '--evidence-dir' ]]; then
  EVIDENCE_DIR="${2:?Pass a directory after --evidence-dir}"
  shift 2
fi
readonly OUTPUT_DIR="${${1:?Pass the unbundled output directory as the final argument}:A}"
if [[ -n "$EVIDENCE_DIR" ]]; then
  EVIDENCE_DIR="${EVIDENCE_DIR:A}"
fi
readonly EVIDENCE_DIR
typeset RUN_DIR=''

if [[ "$(/usr/bin/uname -m)" != 'arm64' ]]; then
  print -u2 'This generator deliberately supports native Apple Silicon only.'
  exit 1
fi
translated="$(/usr/sbin/sysctl -in sysctl.proc_translated 2>/dev/null || true)"
if [[ "$translated" == '1' ]]; then
  print -u2 'This generator refuses Rosetta translation.'
  exit 1
fi

readonly JQ="$(resolve_native_tool jq)"
readonly PYTHON="$(resolve_native_tool python3)"

jq_native() {
  /usr/bin/arch -arm64 "$JQ" "$@"
}

python_native() {
  /usr/bin/arch -arm64 "$PYTHON" "$@"
}

exclusive_rename_directory() {
  python_native "$SCRIPT_DIR/exclusive_rename.py" "$1" "$2"
}

validate_new_publication_destination "$OUTPUT_DIR"
if [[ -n "$EVIDENCE_DIR" ]]; then
  validate_new_publication_destination "$EVIDENCE_DIR"
  [[ "$EVIDENCE_DIR" != "$OUTPUT_DIR" ]] || {
    print -u2 'Output and evidence destinations must differ.'
    exit 1
  }
fi

readonly EXPECTED_ITEM_IDS='["produktinterview","projektauftakt","wochenrunde"]'
script_item_ids="$(jq_native -cer '[.meetings[].itemID] | sort' "$INPUT")"
[[ "$script_item_ids" == "$EXPECTED_ITEM_IDS" ]] || {
  print -u2 'demo-script.json does not contain the exact three meeting IDs.'
  exit 1
}
jq_native -e 'all(.meetings[]; (.segments | type == "array") and (.segments | length > 0))' \
  "$INPUT" >/dev/null || {
  print -u2 'demo-script.json contains an empty or invalid segment set.'
  exit 1
}
if (( ! FREEZE_OUTPUT )); then
  manifest_item_ids="$(jq_native -cer '[.meetings[].itemID] | sort' "$BUNDLED_MANIFEST")"
  [[ "$manifest_item_ids" == "$script_item_ids" ]] || {
    print -u2 'Manifest and demo script meeting sets disagree.'
    exit 1
  }
  actual_script_sha="$(/usr/bin/shasum -a 256 "$INPUT" | /usr/bin/awk '{print $1}')"
  expected_script_sha="$(jq_native -er '.generator.inputScriptSHA256' "$BUNDLED_MANIFEST")"
  [[ "$actual_script_sha" == "$expected_script_sha" ]] || {
    print -u2 'demo-script.json does not match the frozen manifest input hash.'
    exit 1
  }
fi

cleanup() {
  local exit_code=$?
  trap - EXIT INT TERM HUP
  release_download_lock "$CACHE_ROOT" || exit_code=$?
  if [[ -n "$RUN_DIR" ]]; then
    cleanup_run_directory "$CACHE_ROOT" "$RUN_DIR" || exit_code=$?
  fi
  exit "$exit_code"
}
trap cleanup EXIT INT TERM HUP

prepare_cache_root "$CACHE_ROOT"
RUN_DIR="$(create_run_directory "$CACHE_ROOT")"
readonly RUN_DIR
readonly DOWNLOAD_DIR="$CACHE_ROOT/downloads"
readonly SOURCE_DIR="$RUN_DIR/src"
readonly BUILD_DIR="$RUN_DIR/build"
readonly INSTALL_DIR="$RUN_DIR/install"
readonly TOOL_DIR="$RUN_DIR/tooling"
readonly RENDER_DIR="$RUN_DIR/render"
readonly CANDIDATE_ROOT="$RUN_DIR/candidates"
readonly CANDIDATE_OUTPUT_DIR="$CANDIDATE_ROOT/output"
readonly CANDIDATE_EVIDENCE_DIR="$CANDIDATE_ROOT/evidence"
/bin/mkdir "$SOURCE_DIR" "$BUILD_DIR" "$INSTALL_DIR" "$TOOL_DIR" "$RENDER_DIR" \
  "$CANDIDATE_ROOT" "$CANDIDATE_OUTPUT_DIR" "$CANDIDATE_EVIDENCE_DIR"

artifact() {
  local name="$1"
  local field="$2"
  jq_native -er --arg name "$name" --arg field "$field" \
    '.artifacts[] | select(.name == $name) | .[$field]' "$INPUT"
}

download_named_artifact() {
  local name="$1"
  atomic_download \
    "$CACHE_ROOT" \
    "$(artifact "$name" url)" \
    "$DOWNLOAD_DIR/$name" \
    "$(artifact "$name" bytes)" \
    "$(artifact "$name" sha256)"
}

download_cmake_bottle() {
  local name='cmake-4.4.2-arm64_tahoe.bottle.tar.gz'
  local token
  token="$(
    /usr/bin/arch -arm64 /usr/bin/curl -L --fail --silent --show-error \
      'https://ghcr.io/token?service=ghcr.io&scope=repository:homebrew/core/cmake:pull' |
      jq_native -er '.token'
  )"
  [[ -n "$token" ]] || { print -u2 'GHCR did not return an anonymous pull token.'; return 1; }
  atomic_download \
    "$CACHE_ROOT" \
    "$(artifact "$name" url)" \
    "$DOWNLOAD_DIR/$name" \
    "$(artifact "$name" bytes)" \
    "$(artifact "$name" sha256)" \
    --header "Authorization: Bearer $token"
}

extract_archive() {
  local name="$1"
  local destination="$2"
  local strip_components="${3:-1}"

  verify_file "$DOWNLOAD_DIR/$name" "$(artifact "$name" bytes)" "$(artifact "$name" sha256)"
  [[ "$destination" == "$RUN_DIR/"* && ! -e "$destination" ]] || {
    print -u2 "Extraction destination is not a new run descendant: $destination"
    return 1
  }
  /bin/mkdir "$destination"
  /usr/bin/arch -arm64 /usr/bin/tar -xzf "$DOWNLOAD_DIR/$name" \
    -C "$destination" --strip-components="$strip_components"
}

acquire_download_lock "$CACHE_ROOT"
for name in \
  espeak-ng-2023.9.7-4.tar.gz \
  onnxruntime-osx-arm64-1.14.1.tgz \
  piper-phonemize-2023.11.14-2.tar.gz \
  fmt-10.0.0.tar.gz \
  spdlog-1.12.0.tar.gz \
  piper-2023.11.14-2.tar.gz \
  de_DE-mls-medium.onnx \
  de_DE-mls-medium.onnx.json; do
  download_named_artifact "$name"
done
download_cmake_bottle
release_download_lock "$CACHE_ROOT"

extract_archive cmake-4.4.2-arm64_tahoe.bottle.tar.gz "$TOOL_DIR/cmake" 2
extract_archive espeak-ng-2023.9.7-4.tar.gz "$SOURCE_DIR/espeak-ng"
extract_archive onnxruntime-osx-arm64-1.14.1.tgz "$SOURCE_DIR/onnxruntime"
extract_archive piper-phonemize-2023.11.14-2.tar.gz "$SOURCE_DIR/piper-phonemize"
extract_archive fmt-10.0.0.tar.gz "$SOURCE_DIR/fmt"
extract_archive spdlog-1.12.0.tar.gz "$SOURCE_DIR/spdlog"
extract_archive piper-2023.11.14-2.tar.gz "$SOURCE_DIR/piper"

readonly ESPEAK_NO_SONIC_PATCH="$SCRIPT_DIR/espeak-ng-no-sonic.patch"
[[ "$(/usr/bin/shasum -a 256 "$ESPEAK_NO_SONIC_PATCH" | /usr/bin/awk '{print $1}')" == \
  "$(jq_native -er '.rendering.sourcePatchSHA256' "$INPUT")" ]] || {
  print -u2 'The eSpeak no-Sonic source patch does not match demo-script.json.'
  exit 1
}
/usr/bin/patch --silent -p1 -d "$SOURCE_DIR/espeak-ng" < "$ESPEAK_NO_SONIC_PATCH"
! /usr/bin/grep -E 'FetchContent|GIT_REPOSITORY|sonic-git' "$SOURCE_DIR/espeak-ng/cmake/deps.cmake" >/dev/null || {
  print -u2 'The patched eSpeak dependency file can still fetch Sonic.'
  exit 1
}

readonly CMAKE="$TOOL_DIR/cmake/bin/cmake"
require_arm64_only "$CMAKE"

cmake_native() {
  /usr/bin/arch -arm64 "$CMAKE" "$@"
}

cmake_native -S "$SOURCE_DIR/espeak-ng" -B "$BUILD_DIR/espeak-ng" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR/espeak-ng" \
  -DFETCHCONTENT_FULLY_DISCONNECTED=ON \
  -DBUILD_SHARED_LIBS=ON \
  -DUSE_ASYNC=OFF \
  -DUSE_MBROLA=OFF \
  -DUSE_LIBSONIC=OFF \
  -DUSE_LIBPCAUDIO=OFF \
  -DUSE_KLATT=OFF \
  -DUSE_SPEECHPLAYER=OFF \
  -DEXTRA_cmn=ON \
  -DEXTRA_ru=ON \
  '-DCMAKE_C_FLAGS=-D_FILE_OFFSET_BITS=64 -Wno-error=implicit-function-declaration'
cmake_native --build "$BUILD_DIR/espeak-ng" --parallel 4
cmake_native --install "$BUILD_DIR/espeak-ng"

cmake_native -S "$SOURCE_DIR/fmt" -B "$BUILD_DIR/fmt" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR/fmt" \
  -DFETCHCONTENT_FULLY_DISCONNECTED=ON \
  -DFMT_TEST=OFF
cmake_native --build "$BUILD_DIR/fmt" --parallel 4
cmake_native --install "$BUILD_DIR/fmt"

cmake_native -S "$SOURCE_DIR/spdlog" -B "$BUILD_DIR/spdlog" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR/spdlog" \
  -DFETCHCONTENT_FULLY_DISCONNECTED=ON \
  -DSPDLOG_FMT_EXTERNAL=OFF
cmake_native --build "$BUILD_DIR/spdlog" --parallel 4
cmake_native --install "$BUILD_DIR/spdlog"

cmake_native -S "$SOURCE_DIR/piper-phonemize" -B "$BUILD_DIR/piper-phonemize" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR/piper-phonemize" \
  -DFETCHCONTENT_FULLY_DISCONNECTED=ON \
  -DESPEAK_NG_DIR="$INSTALL_DIR/espeak-ng" \
  -DONNXRUNTIME_DIR="$SOURCE_DIR/onnxruntime"
DYLD_LIBRARY_PATH="$INSTALL_DIR/espeak-ng/lib:$SOURCE_DIR/onnxruntime/lib" \
  cmake_native --build "$BUILD_DIR/piper-phonemize" --parallel 4
DYLD_LIBRARY_PATH="$INSTALL_DIR/espeak-ng/lib:$SOURCE_DIR/onnxruntime/lib" \
  cmake_native --install "$BUILD_DIR/piper-phonemize"

cmake_native -S "$SOURCE_DIR/piper" -B "$BUILD_DIR/piper" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR/piper" \
  -DFETCHCONTENT_FULLY_DISCONNECTED=ON \
  -DFMT_DIR="$INSTALL_DIR/fmt" \
  -DSPDLOG_DIR="$INSTALL_DIR/spdlog" \
  -DPIPER_PHONEMIZE_DIR="$INSTALL_DIR/piper-phonemize"
DYLD_LIBRARY_PATH="$INSTALL_DIR/piper-phonemize/lib" \
  cmake_native --build "$BUILD_DIR/piper" --target piper --parallel 4
DYLD_LIBRARY_PATH="$INSTALL_DIR/piper-phonemize/lib" \
  cmake_native --install "$BUILD_DIR/piper"

typeset -a private_targets=(
  "$INSTALL_DIR/espeak-ng/bin/espeak-ng"
  "$INSTALL_DIR/espeak-ng/lib/libespeak-ng.1.52.0.1.dylib"
  "$SOURCE_DIR/onnxruntime/lib/libonnxruntime.1.14.1.dylib"
  "$INSTALL_DIR/piper-phonemize/bin/espeak-ng"
  "$INSTALL_DIR/piper-phonemize/bin/piper_phonemize"
  "$INSTALL_DIR/piper-phonemize/lib/libpiper_phonemize.1.2.0.dylib"
  "$INSTALL_DIR/piper-phonemize/lib/libespeak-ng.1.52.0.1.dylib"
  "$INSTALL_DIR/piper-phonemize/lib/libonnxruntime.1.14.1.dylib"
  "$INSTALL_DIR/piper/piper"
)

for target in "${private_targets[@]}"; do
  require_arm64_only "$target"
done
while IFS= read -r private_dylib; do
  require_arm64_only "$private_dylib"
done < <(/usr/bin/find "$RUN_DIR" -type f -name '*.dylib' -print)

verify_private_dependency_closure() {
  local target="$1"
  local dependency dependency_name matches match resolved
  local -a match_paths

  while IFS= read -r dependency; do
    [[ -n "$dependency" ]] || continue
    case "$dependency" in
      /System/Library/*|/usr/lib/*) ;;
      @rpath/*|@loader_path/*|@executable_path/*)
        dependency_name="${dependency:t}"
        matches="$(/usr/bin/find "$RUN_DIR" \( -type f -o -type l \) -name "$dependency_name" -print)"
        match_paths=("${(@f)matches}")
        (( ${#match_paths[@]} > 0 )) || {
          print -u2 "Unresolved private dependency $dependency from $target"
          return 1
        }
        for match in "${match_paths[@]}"; do
          resolved="$(python_native -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$match")"
          [[ "$resolved" == "$RUN_DIR/"* ]] || {
            print -u2 "Private dependency escapes the run: $match"
            return 1
          }
          require_arm64_only "$resolved"
        done
        ;;
      "$RUN_DIR"/*) require_arm64_only "$dependency" ;;
      *)
        print -u2 "Unexpected non-system dependency $dependency from $target"
        return 1
        ;;
    esac
  done < <(/usr/bin/otool -L "$target" | /usr/bin/tail -n +2 | /usr/bin/awk '{print $1}')
}

for target in "${private_targets[@]}"; do
  verify_private_dependency_closure "$target"
done

cmake_native --version >/dev/null
/usr/bin/arch -arm64 /usr/bin/env \
  DYLD_LIBRARY_PATH="$INSTALL_DIR/espeak-ng/lib" \
  "$INSTALL_DIR/espeak-ng/bin/espeak-ng" \
  --path="$INSTALL_DIR/espeak-ng/share" --version >/dev/null
/usr/bin/arch -arm64 /usr/bin/env \
  DYLD_LIBRARY_PATH="$INSTALL_DIR/piper-phonemize/lib:$SOURCE_DIR/onnxruntime/lib" \
  "$INSTALL_DIR/piper/piper" --help >/dev/null

for item_id in $(jq_native -r '.meetings[].itemID' "$INPUT"); do
  local_dir="$RENDER_DIR/$item_id"
  /bin/mkdir "$local_dir"
  index=0
  while IFS= read -r segment; do
    text="$(jq_native -r '.text' <<< "$segment")"
    model_index="$(jq_native -r '.modelIndex' <<< "$segment")"
    clip="$local_dir/$index.wav"
    print -r -- "$text" | /usr/bin/arch -arm64 /usr/bin/env \
      DYLD_LIBRARY_PATH="$INSTALL_DIR/piper-phonemize/lib:$SOURCE_DIR/onnxruntime/lib" \
      "$INSTALL_DIR/piper/piper" \
      --model "$DOWNLOAD_DIR/de_DE-mls-medium.onnx" \
      --config "$DOWNLOAD_DIR/de_DE-mls-medium.onnx.json" \
      --speaker "$model_index" \
      --noise_scale 0 \
      --noise_w 0 \
      --espeak_data "$INSTALL_DIR/piper/espeak-ng-data" \
      --output_file "$clip"
    (( index += 1 ))
  done < <(jq_native -c --arg item "$item_id" \
    '.meetings[] | select(.itemID == $item) | .segments[]' "$INPUT")
  /bin/mkdir "$CANDIDATE_OUTPUT_DIR/$item_id" "$CANDIDATE_EVIDENCE_DIR/$item_id"
  timeline_output="$CANDIDATE_EVIDENCE_DIR/$item_id/timeline.json"
  metrics_output="$CANDIDATE_EVIDENCE_DIR/$item_id/metrics.json"
  python_native "$SCRIPT_DIR/mix_demo_audio.py" \
    --script "$INPUT" \
    --item-id "$item_id" \
    --clip-root "$local_dir" \
    --output "$CANDIDATE_OUTPUT_DIR/$item_id/audio.wav" \
    --timeline-output "$timeline_output" \
    --metrics-output "$metrics_output"
  [[ "$(jq_native -r '.clippedSampleCount' "$metrics_output")" == '0' ]] || {
    print -u2 "Unexpected clipping in $item_id"
    exit 1
  }

  audio="$CANDIDATE_OUTPUT_DIR/$item_id/audio.wav"
  actual_bytes="$(/usr/bin/stat -f '%z' "$audio")"
  actual_sha="$(/usr/bin/shasum -a 256 "$audio" | /usr/bin/awk '{print $1}')"
  frame_count="$(jq_native -r '.outputFrameCount' "$metrics_output")"
  duration="$(python_native -c 'import sys; print(int(sys.argv[1]) / int(sys.argv[2]))' \
    "$frame_count" "$(jq_native -r '.rendering.sampleRate' "$INPUT")")"
  if (( FREEZE_OUTPUT )); then
    print -r -- "FREEZE $item_id bytes=$actual_bytes sha256=$actual_sha frames=$frame_count duration=$duration"
  else
    resource_path="$item_id/audio.wav"
    expected_bytes="$(jq_native -er --arg path "$resource_path" \
      '.resources[] | select(.relativePath == $path) | .byteCount' "$BUNDLED_MANIFEST")"
    expected_sha="$(jq_native -er --arg path "$resource_path" \
      '.resources[] | select(.relativePath == $path) | .sha256' "$BUNDLED_MANIFEST")"
    [[ "$actual_bytes" == "$expected_bytes" && "$actual_sha" == "$expected_sha" ]] || {
      print -u2 "Rendered WAV does not match the frozen manifest: $item_id"
      exit 1
    }
  fi
done

actual_output_set="$(cd "$CANDIDATE_OUTPUT_DIR" && /usr/bin/find . ! -type d -print | /usr/bin/sort)"
readonly EXPECTED_OUTPUT_SET=$'./produktinterview/audio.wav\n./projektauftakt/audio.wav\n./wochenrunde/audio.wav'
[[ "$actual_output_set" == "$EXPECTED_OUTPUT_SET" ]] || {
  print -u2 'Candidate output tree is incomplete or contains extra files.'
  exit 1
}
actual_output_directories="$(cd "$CANDIDATE_OUTPUT_DIR" && /usr/bin/find . -type d -print | /usr/bin/sort)"
readonly EXPECTED_DIRECTORIES=$'.\n./produktinterview\n./projektauftakt\n./wochenrunde'
[[ "$actual_output_directories" == "$EXPECTED_DIRECTORIES" ]] || {
  print -u2 'Candidate output tree has an unexpected directory set.'
  exit 1
}
actual_evidence_set="$(cd "$CANDIDATE_EVIDENCE_DIR" && /usr/bin/find . ! -type d -print | /usr/bin/sort)"
readonly EXPECTED_EVIDENCE_SET=$'./produktinterview/metrics.json\n./produktinterview/timeline.json\n./projektauftakt/metrics.json\n./projektauftakt/timeline.json\n./wochenrunde/metrics.json\n./wochenrunde/timeline.json'
[[ "$actual_evidence_set" == "$EXPECTED_EVIDENCE_SET" ]] || {
  print -u2 'Candidate evidence tree is incomplete or contains extra files.'
  exit 1
}
actual_evidence_directories="$(cd "$CANDIDATE_EVIDENCE_DIR" && /usr/bin/find . -type d -print | /usr/bin/sort)"
[[ "$actual_evidence_directories" == "$EXPECTED_DIRECTORIES" ]] || {
  print -u2 'Candidate evidence tree has an unexpected directory set.'
  exit 1
}
for metrics_output in "$CANDIDATE_EVIDENCE_DIR"/*/metrics.json; do
  [[ "$(jq_native -er '.clippedSampleCount' "$metrics_output")" == '0' ]] || {
    print -u2 "Candidate metrics exceed the zero-clipping budget: $metrics_output"
    exit 1
  }
done

if [[ -n "$EVIDENCE_DIR" ]]; then
  publish_evidence_then_output_using exclusive_rename_directory \
    "$CANDIDATE_EVIDENCE_DIR" "$EVIDENCE_DIR" \
    "$CANDIDATE_OUTPUT_DIR" "$OUTPUT_DIR"
else
  stage_and_publish_directory_using \
    exclusive_rename_directory "$CANDIDATE_OUTPUT_DIR" "$OUTPUT_DIR"
fi
