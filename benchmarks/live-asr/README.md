# Live ASR benchmark on Apple Silicon

This benchmark compares three local live paths against the same German audio files:

- Apple `SpeechAnalyzer` through Steno's production provider.
- FluidAudio Parakeet TDT through Steno's currently hidden live adapter.
- FluidAudio Nemotron 3.5 ASR Streaming Multilingual through a separate, exactly pinned package.

The benchmark tools do not change Steno app settings and do not install models into Steno's library.
Audio, references, model weights, and results remain outside Git.

## Requirements

- Apple Silicon running macOS 26 or newer.
- Apple's German `SpeechTranscriber` asset must already have been installed through Steno.
- The official FluidAudio Parakeet model must exist as a local model directory.
- The first Nemotron run requires network access and downloads the `de-DE/2240ms` variant into the specified cache.
- The corpus manifest must be `ready` and contain only explicit German `de-DE` samples.

Apple and Nemotron receive `de-DE` explicitly, and Nemotron additionally runs with a forced German prefix.
FluidAudio 0.15.5 does not pass a language to the decoder through its existing Parakeet sliding-window API.
The Parakeet run therefore measures Steno's real current live path: its output is labeled `de-DE`, while decoding uses the model default.

## Build the runners

```sh
swift build -c release --package-path StenoKit --product steno-live-transcribe
swift build -c release \
  --package-path benchmarks/live-asr/NemotronRunner \
  --product steno-nemotron-live-bench
```

`NemotronRunner/Package.resolved` pins FluidAudio to commit `667181a368da13b3a9178e310414e9dcbe8f23ce`.
This experiment therefore changes neither Steno's production FluidAudio version nor its diarization implementation.

## Fast quality run

Fast mode feeds Parakeet and Nemotron in 250-millisecond chunks.
Apple receives four-second chunks so that even the longest corpus excerpt fits into its live-input queue, which is limited to 64 chunks.
A hardware comparison on the M5 Air produced identical WER and CER for the same excerpt with 20-millisecond real-time feeding and four-second fast feeding.
Do not interpret this mode's latency values as user-visible latency.

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

## Real-time latency run

Real-time mode uses 20-millisecond input chunks and requires exactly one explicit excerpt.
Only this mode makes `timeToFirstTextSeconds` and the sequence of live updates meaningful as visible user latency.

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

## Results

Each engine writes a JSON hypothesis containing final text, provisional and confirmed updates, audio duration, wall-clock duration, and time to first text.
The existing `score_asr.py` derives WER, CER, omission rate, and registered named-term recall.
`run-fast.json` and `run-realtime.json` additionally pin the manifest and runner checksums, host, and operating system.

A missing Apple speech asset, non-regular model path, or incompatible manifest fails the run visibly.
The benchmark does not download Apple or Parakeet models automatically.
