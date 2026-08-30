#!/bin/bash
# Generates the checksum manifest from a locally available, verified model
# installation.
#
# Boundary: this freezes the bytes that are currently on this disk. It does
# not prove their authenticity. Verify the installation source before use.
#
# The directory must come from exactly one installer run. A grown model
# directory can contain files that the installer never downloads, such as
# Embedding, Segmentation, FBank, or PldaRho directories from a benchmark run.
# Including those files would make verification fail for every other user.
# The reliable workflow starts with an empty STENO_MODEL_DIR and installs the
# model through the app.
#
# This script writes only the diarization manifest. Parakeet has a separate
# manifest at StenoTranscription/Resources/parakeet-model-checksums.json.
# That manifest once came from a grown directory and incorrectly required
# config.json and parakeet_vocab.json, which FluidAudio v3 never downloads.
# ParakeetModelInstallerTests defines the allowed manifest contents.
#
# Usage: scripts/generate-model-checksums.sh <model-directory>
set -euo pipefail

DIR="${1:?Specify a model directory}"
OUT="StenoKit/Sources/StenoDiarization/Resources/model-checksums.json"

cd "$(dirname "$0")/.."
ROOT="$PWD"

cd "$DIR"
{
    echo '{'
    echo '  "entries": {'
    find . -type f ! -name '.DS_Store' | sort | while read -r f; do
        rel="${f#./}"
        hash=$(shasum -a 256 "$f" | cut -d' ' -f1)
        echo "    \"$rel\": \"$hash\","
    done | sed '$ s/,$//'
    echo '  }'
    echo '}'
} > "$ROOT/$OUT"

echo "Wrote: $OUT"
