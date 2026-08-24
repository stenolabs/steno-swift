#!/bin/bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1

KIT_ROOT="$(cd "$(dirname "$0")" && pwd)"
PACKAGE_ROOT="$(cd "$KIT_ROOT/.." && pwd)"

python3 "$KIT_ROOT/tools/run_live_asr_matrix.py" \
  --manifest "$PACKAGE_ROOT/live-ready-manifest.json" \
  --corpus-root "$PACKAGE_ROOT/corpus" \
  --steno-runner "$KIT_ROOT/bin/steno-live-transcribe" \
  --nemotron-runner "$KIT_ROOT/bin/steno-nemotron-live-bench" \
  --parakeet-model-dir "$KIT_ROOT/models/parakeet-tdt-0.6b-v3" \
  --nemotron-cache "$KIT_ROOT/models/nemotron-cache" \
  --output-root "$PACKAGE_ROOT/live-results" \
  --mode fast
