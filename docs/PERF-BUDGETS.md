# Performance budgets

Codified budgets adopted from the stenoai legacy harness (`e2e/specs/live-transcript-perf.t1.spec.ts`
measurement philosophy) and the steno-swift architecture. Each budget is a regression
guard: when a row's evidence goes stale or a change lands without a measurement,
that is a defect, not an optimization opportunity.

Nothing here is wired into CI by design. Run the checker manually:

```
# Scrape committed evidence (currently docs/BENCH-M2-ASR.md) and check budgets:
python3 scripts/benchmark/perf_budgets.py

# Check an explicit payload instead (stdin works too):
python3 scripts/benchmark/perf_budgets.py --json measurements.json

# Built-in sanity checks:
python3 scripts/benchmark/perf_budgets.py --self-test
```

Exit code is nonzero only on a violation; rows without evidence are reported as
`NO EVIDENCE` and skipped so new budgets can be codified before their first
measurement exists. The checker accepts these JSON keys:
`live_partial_latency_ms`, `final_asr_rtf`, `diarization_rtfx`,
`diarization_first_progress_s`, `soak_memory_delta_mb`,
`cold_start_to_interactive_s`, `search_query_ms_100_meetings`,
`index_incremental_update_s_per_batch`.

## Budgets

| Budget | Current evidence | Measurement command / harness | Owner file |
|---|---|---|---|
| Live partial latency: provisional transcript visible < 150 ms of speech | Measured 16.32 ms worst burst (M5 Max, 26 Aug 2026): bursts of 10 paced ticks at 0/250/750/1500 finals cost 0.43/4.72/8.82/16.32 ms; 1500-final < 4x 250-final (sublinear). Budget holds. | `swift test --package-path StenoKit --filter LivePartialLatencyTests`; pass the printed `LIVE_PARTIAL_LATENCY_JSON:` line to `perf_budgets.py --json`. Heavy 1500 case drops only with `STENO_PERF_FULL=0`. | `StenoKit/Sources/StenoTranscription/LiveTranscriptFeed.swift`, harness `StenoKit/Tests/StenoTranscriptionTests/LivePartialLatencyTests.swift` |
| Final ASR real-time factor <= 0.05 RTF | Measured 0.0116 RTF (SpeechAnalyzer on macOS 26, 5 Aug 2026, six AMI-dev meetings). See `docs/BENCH-M2-ASR.md`. | `python3 scripts/benchmark/perf_budgets.py` reads the BENCH-M2 table directly; explicit payloads use key `final_asr_rtf`. Repeat the documented protocol after any ASR provider change. | `StenoKit/Sources/StenoPipeline/PipelineCoordinator.swift` (final ASR stage) |
| Diarization speed-up >= 20 RTFx | Not yet measured on this engine. | Score quality with `python3 scripts/benchmark/score_diarization.py`; RTFx = corpus audio duration / processing wall time from the same run harness used in the steno-diar-bench sandbox. Key `diarization_rtfx`. | `StenoKit/Sources/StenoDiarization/FluidSortformerProvider.swift` |
| Diarization first-progress heartbeat <= 2 s into the silent segmentation window | Enforced at the provider level by the heartbeat interval constant (default 2.0 s) added post-W5Heartbeat; end-to-end elapsed not yet measured. | Unit test with a fake clock asserts the first `.segmenting` progress event arrives within budget (elapsed measured from diarization start). Key `diarization_first_progress_s`. | `StenoKit/Sources/StenoDiarization/DiarizationModels.swift`, `FluidSortformerProvider.swift` |
| Two-hour two-track session retained-memory delta < 250 MB | Pass/fail guard landed with W5 (`LongSessionSoakTests` asserts exactly this ceiling); the measured number lives in that wave's report until a bench doc records it. | `swift test --filter LongSessionSoakTests` (guard), Instruments Allocations template for the actual delta over a >= 2 h simulated two-track session (~2000 final-equivalent ticks). Key `soak_memory_delta_mb`. | `StenoKit/Tests/StenoAudioCoreTests/LongSessionSoakTests.swift` |
| Cold start to interactive UI < 2.5 s on Apple Silicon (M-series) | To be measured. | Launch-time measurement (os_signpost around app activation to first interactive frame; equivalent of XCTest `XCTApplicationLaunchMetric`) on a release build. Key `cold_start_to_interactive_s`. | `App/Sources/StenoApp.swift` |
| Library search query < 50 ms at 100 meetings | Measured p50 0.68 ms / p95 0.82 ms over 30 representative queries at 100 meetings (M5 Max, 26 Aug 2026) via `SearchIndexBenchmarkTests`; budget holds. | Benchmark extension of the search-index tests: build a 100-meeting FTS index from fixtures, time representative queries p50/p95. Key `search_query_ms_100_meetings`. | `StenoKit/Sources/StenoLibrary/MeetingSearchIndex.swift` |
| Search index incremental update < 2 s per meeting batch | Measured worst 0.0004 s over 10 append-then-update cycles on a warm 100-meeting index (M5 Max, 26 Aug 2026) via `SearchIndexBenchmarkTests`; budget holds. | Same harness as above: append one meeting's worth of segments to a warm 100-meeting index and assert the update completes inside budget. Key `index_incremental_update_s_per_batch`. | `StenoKit/Sources/StenoLibrary/MeetingSearchIndex.swift` |
| Pipeline startup (Library open + recovery + queue ready) < 5 s | Measured 0.395 s on the reference M5 Max (26 Aug 2026) via `scripts/benchmark/startup_smoke.sh`. | `scripts/benchmark/startup_smoke.sh` (builds `steno-smoke`, times a fresh-library pipeline start; override with `STENO_STARTUP_BUDGET`). Key `pipeline_startup_s`. | `App/Sources/AppModel.swift` (bootstrap), `StenoKit/Sources/steno-smoke` |

## Conventions

- Every budget must be falsifiable by one number produced by the named harness;
  a budget that cannot name its harness does not belong in this table.
- When a measurement lands, record it here (Current evidence column) *and* keep
  the checker able to scrape it: either extend `scripts/benchmark/perf_budgets.py`
  with a parser for the new bench doc, or pass the number explicitly via `--json`.
- Latency budgets are stated against user-perceptible events (first provisional
  paint, heartbeat progress, interactive UI), never internal step timings alone.
