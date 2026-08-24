# Local speech benchmark

This directory is the versioned contract for Steno's ASR and speaker-diarization benchmarks.
Audio, reference copies, model weights, and results remain outside Git under an explicit corpus root.

## Why the manifest initially contains no samples

The source metadata has been verified, but no excerpt currently meets every requirement for a defensible product benchmark.
The readiness check therefore fails deliberately and visibly.
A plausible number derived from machine-generated subtitles would be more dangerous than an openly missing number.

The Kölner Korpus des Kiezdeutschen is published under CC BY 4.0 and was transcribed manually according to GAT2.
Its PDF transcripts distinguish speakers and overlaps but provide no directly usable timestamps for individual lines.
It remains the planned stress case until an exact excerpt has been aligned and then checked by hand.

The Open Oldenburg Conversation Corpus contains two-minute German dialogues with manually corrected segment and word timestamps.
Its bundled license is CC BY-NC-ND 4.0.
It is therefore a technically strong local candidate, but not a freely usable commercial product reference, and Steno does not silently present it as one.

## Directory structure outside Git

```text
<corpus-root>/
  samples/
    <sample-id>/
      audio.wav
      reference.json
      reference.rttm
      reference.uem
      hypotheses/
      scores/
```

Every ready sample entry in `manifest.json` refers to these files by relative path and pins their SHA-256 hashes.
The immutable source download remains traceable through its published MD5 checksum.

## ASR reference format

```json
{
  "schemaVersion": 1,
  "sampleID": "example-de-01",
  "locale": "de-DE",
  "segments": [
    {
      "speaker": "spk01",
      "start": 0.0,
      "end": 2.4,
      "text": "Die Stadt Musterstadt prueft das Verfahren."
    }
  ],
  "namedTerms": ["Musterstadt"]
}
```

Speaker identifiers are local to the file and contain no real names.
The diarization reference uses RTTM, and UEM defines the scored region.
A sample may contain exactly one recording and one channel; mismatched RTTM or UEM identities are rejected.

## Validation and scoring

Registered source metadata can be validated without local audio files:

```sh
python3 scripts/benchmark/manifest.py metadata benchmarks/local-speech/manifest.json
```

The strict check requires every local, manually verified reference and its pinned hash:

```sh
python3 scripts/benchmark/manifest.py ready benchmarks/local-speech/manifest.json \
  --corpus-root "$STENO_BENCH_CORPUS"
```

Steno's existing CLI produces an ASR hypothesis:

```sh
swift run --package-path StenoKit steno-transcribe \
  "$STENO_BENCH_CORPUS/samples/example-de-01/audio.wav" de-DE \
  > "$STENO_BENCH_CORPUS/samples/example-de-01/hypotheses/apple.json"
```

Calculate WER, CER, omission rate, and named-term recall as follows:

```sh
python3 scripts/benchmark/score_asr.py \
  "$STENO_BENCH_CORPUS/samples/example-de-01/reference.json" \
  "$STENO_BENCH_CORPUS/samples/example-de-01/hypotheses/apple.json" \
  --output "$STENO_BENCH_CORPUS/samples/example-de-01/scores/apple.json"
```

Steno writes diarization output as RTTM:

```sh
swift run --package-path StenoKit steno-diarize-bench \
  "$STENO_BENCH_CORPUS/samples/example-de-01/audio.wav" \
  "$STENO_BENCH_CORPUS/samples/example-de-01/hypotheses/sortformer.rttm"
```

The scorer preserves the contract established in Steno Legacy: a 0.25-second collar and separate all-speech, non-overlap, and overlap-only views.
When no overlap exists, or the collar consumes every overlap window completely, the scorer deliberately omits the overlap metric.
The exact dscore checkout and version must be stated explicitly:

```sh
python3 scripts/benchmark/score_diarization.py \
  "$STENO_BENCH_CORPUS/samples/example-de-01/reference.rttm" \
  "$STENO_BENCH_CORPUS/samples/example-de-01/hypotheses/sortformer.rttm" \
  --uem "$STENO_BENCH_CORPUS/samples/example-de-01/reference.uem" \
  --dscore "$STENO_DSCORE/score.py" \
  --dscore-version "$STENO_DSCORE_COMMIT" \
  --output "$STENO_BENCH_CORPUS/samples/example-de-01/scores/sortformer.json"
```

## Planned hardware run

The actual Apple, Parakeet, and Sortformer comparison runs on the M5 Air with the same audio excerpt and references.
Every report records the Steno commit, model identifier and weight digest, macOS build, hardware, compute units, cold or warm state, and run order.
The Mac mini deliberately remains unmeasured for this comparison so that results from two hardware platforms are not mixed.
