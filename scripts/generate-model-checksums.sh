#!/bin/bash
# Erzeugt das Pruefsummen-Manifest aus einer lokal vorhandenen, geprueften
# Modellinstallation.
#
# Grenze: Das friert die Bytes ein, die JETZT auf dieser Platte liegen. Es
# beweist nicht ihre Echtheit. Vor dem Ausfuehren pruefen, woher sie stammen.
#
# Das Verzeichnis muss aus genau einem Lauf des Installers stammen. Ein
# gewachsener Modellordner enthaelt Verzeichnisse, die der Installer nie
# laedt - etwa Embedding, Segmentation, FBank oder PldaRho aus einem
# Benchmarklauf. Landen die im Manifest, scheitert die Pruefung bei jedem
# anderen Nutzer. Der verlaessliche Weg ist ein leeres Verzeichnis, auf das
# STENO_MODEL_DIR zeigt, und ein Download ueber die App.
#
# Das Skript schreibt NUR das Diarisierungs-Manifest. Parakeet hat ein
# eigenes unter StenoTranscription/Resources/parakeet-model-checksums.json,
# und genau dort ist der Fehler schon einmal passiert: es entstand aus einem
# gewachsenen Ordner und verlangte danach config.json und parakeet_vocab.json,
# die FluidAudio fuer v3 nie laedt. Auf jedem frischen Geraet brach die
# Installation ab. Ein Test in ParakeetModelInstallerTests haelt jetzt fest,
# was das Manifest enthalten darf.
#
# Nutzung: scripts/generate-model-checksums.sh <modellverzeichnis>
set -euo pipefail

DIR="${1:?Modellverzeichnis angeben}"
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

echo "Geschrieben: $OUT"
