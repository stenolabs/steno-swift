#!/bin/bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1

KIT_ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$KIT_ROOT"
if [[ ! -f bin/StenoKit_StenoTranscription.bundle/parakeet-model-checksums.json ]]; then
  echo "Missing Swift resource bundle: bin/StenoKit_StenoTranscription.bundle" >&2
  exit 2
fi
shasum -a 256 -c SHA256SUMS
python3 tools/manifest.py ready ../live-ready-manifest.json --corpus-root ../corpus
echo "Live-ASR-Paket ist vollständig."
