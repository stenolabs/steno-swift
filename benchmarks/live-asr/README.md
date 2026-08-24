# Live-ASR-Benchmark auf Apple Silicon

Dieser Benchmark vergleicht drei lokale Live-Pfade mit denselben deutschen Audiodateien:

- Apple `SpeechAnalyzer` aus Stenos produktivem Provider.
- FluidAudio Parakeet TDT aus Stenos noch verborgenem Liveadapter.
- FluidAudio Nemotron 3.5 ASR Streaming Multilingual aus einem getrennten, exakt gepinnten Paket.

Die Benchmarkwerkzeuge ändern keine Einstellung der Steno-App und installieren kein Modell in Stenos Bibliothek.
Audio, Referenzen, Modellgewichte und Ergebnisse bleiben außerhalb von Git.

## Voraussetzungen

- Apple Silicon mit macOS 26 oder neuer.
- Für Apple muss das deutsche `SpeechTranscriber`-Asset bereits über Steno installiert sein.
- Das offizielle FluidAudio-Parakeet-Modell muss als lokaler Modellordner vorliegen.
- Der erste Nemotron-Lauf braucht Internetzugang und lädt die Variante `de-DE/2240ms` in den angegebenen Cache.
- Das Corpus-Manifest muss `ready` sein und ausschließlich explizite deutsche `de-DE`-Samples enthalten.

Apple und Nemotron erhalten explizit `de-DE`, und Nemotron läuft zusätzlich mit erzwungenem deutschen Präfix.
FluidAudio 0.15.5 reicht im vorhandenen Parakeet-Sliding-Window-API keine Sprache an den Decoder weiter.
Der Parakeet-Lauf misst damit bewusst den echten aktuellen Steno-Livepfad, dessen Ergebnis nur als `de-DE` gekennzeichnet wird, während die Decodierung im Modellstandard bleibt.

## Runner bauen

```sh
swift build -c release --package-path StenoKit --product steno-live-transcribe
swift build -c release \
  --package-path benchmarks/live-asr/NemotronRunner \
  --product steno-nemotron-live-bench
```

`NemotronRunner/Package.resolved` pinnt FluidAudio auf Commit `667181a368da13b3a9178e310414e9dcbe8f23ce`.
Damit verändert dieser Versuch weder Stenos produktive FluidAudio-Version noch dessen Diarisierung.

## Schneller Qualitätslauf

Der schnelle Modus verwendet fuer Parakeet und Nemotron 250-ms-Eingabebloecke.
Apple bekommt 4-Sekunden-Bloecke, damit auch der laengste Corpus-Ausschnitt in seine auf 64 Bloecke begrenzte Live-Eingabewarteschlange passt.
Ein Hardwarevergleich auf dem M5 Air ergab fuer denselben Ausschnitt mit 20-ms-Echtzeit- und 4-Sekunden-Schnellzufuhr identische WER- und CER-Werte.
Latenzwerte dieses Modus sind nicht als Nutzerlatenz zu interpretieren.

```sh
python3 scripts/benchmark/run_live_asr_matrix.py \
  --manifest /private/tmp/steno-oocc-benchmark/live-ready-manifest.json \
  --corpus-root /private/tmp/steno-oocc-benchmark/corpus \
  --steno-runner StenoKit/.build/release/steno-live-transcribe \
  --nemotron-runner benchmarks/live-asr/NemotronRunner/.build/release/steno-nemotron-live-bench \
  --parakeet-model-dir "$HOME/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3" \
  --nemotron-cache /private/tmp/steno-oocc-benchmark/nemotron-cache \
  --output-root /private/tmp/steno-oocc-benchmark/live-results \
  --mode fast
```

## Echtzeit-Latenzlauf

Der Echtzeitmodus verwendet 20-ms-Eingabeblöcke und verlangt genau einen expliziten Ausschnitt.
Nur hier sind `timeToFirstTextSeconds` und die Folge der Liveupdates als sichtbare Nutzerlatenz aussagekräftig.

```sh
python3 scripts/benchmark/run_live_asr_matrix.py \
  --manifest /private/tmp/steno-oocc-benchmark/live-ready-manifest.json \
  --corpus-root /private/tmp/steno-oocc-benchmark/corpus \
  --steno-runner StenoKit/.build/release/steno-live-transcribe \
  --nemotron-runner benchmarks/live-asr/NemotronRunner/.build/release/steno-nemotron-live-bench \
  --parakeet-model-dir "$HOME/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3" \
  --nemotron-cache /private/tmp/steno-oocc-benchmark/nemotron-cache \
  --output-root /private/tmp/steno-oocc-benchmark/live-results \
  --mode realtime \
  --sample oocc-v2-free-conversation-03
```

## Ergebnisse

Jede Engine schreibt eine JSON-Hypothese mit Endtext, vorläufigen und bestätigten Updates, Audiozeit, Wanduhrzeit und Zeit bis zum ersten Text.
Der vorhandene `score_asr.py` erzeugt daraus WER, CER, Auslassungsrate und Recall der registrierten Eigennamen.
`run-fast.json` beziehungsweise `run-realtime.json` pinnt zusätzlich Manifest- und Runner-Prüfsummen sowie Host und Betriebssystem.

Ein fehlendes Apple-Sprachasset, ein nicht regulärer Modellpfad oder ein nicht passendes Manifest beendet den Lauf sichtbar.
Der Benchmark lädt keine Apple- oder Parakeet-Modelle selbstständig nach.
