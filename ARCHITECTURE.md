# Steno for macOS - Architecture

Status: 30 August 2026.
Labels in this document: **[Fact]** was verified against a local source, **[Assumption]** is plausible but unmeasured, and **[Recommendation]** is a decision made by this design.

## 1. Overall decision

Steno is a native Swift app in a single repository, with a local SwiftPM package named `StenoKit`, clearly separated targets, and a thin macOS app target.
The experimental `GemmaService` package is a separate macOS 27 build boundary and is not part of the application dependency graph.
Its dependency-free strict-concurrency IPC module is used by the separate Xcode 27 project variant, which embeds a signed, sandboxed, model-free XPC helper with incoming and outgoing network access disabled.
Its core is a **file-based, versioned library** with immutable originals, append-only processing runs, and explicit revisions, without a database dependency in the initial implementation.
Transcription primarily uses Apple's `SpeechAnalyzer` and `SpeechTranscriber` APIs, verified in the macOS 26 SDK, including `audioTimeRange` for word timestamps and `volatileResults` for provisional live results.
Diarization uses the existing Sortformer and WeSpeaker code from the sidecar as an internal Swift target, in process rather than as a subprocess.
The speaker-identity logic from `speaker_suggestions.py` is reshaped as a Swift domain model while preserving its 13 measurement-backed invariants.

### Corrections to earlier design assumptions

1. **"Microphone and system audio remain separate local original tracks" describes a new implementation, not a port.**
   [Fact] The current app records one stereo WebM/Opus file, with microphone on the left and system audio on the right at 48 kHz (`useSystemAudioCapture.ts:318-461`), and only later splits it into 16 kHz mono files with ffmpeg (`transcriber.py:1877`).
   The new recording architecture writes two separate, immutable tracks from the start.
2. **"The live path decodes a growing window about every 400 ms" is only partly correct.**
   [Fact] The interval is 0.4 seconds, but the window is capped at 15 seconds and then slides (`simple_recorder.py:2202-2203, 2576`); a keep-pace guard stretches the interval to as much as eight seconds under load.
   The real problems are duplicate decoding for partial and final output, one synchronous consumer thread with backpressure on the stdin pipe, and the obsolete `ScriptProcessorNode` in the renderer.
   The target remains valid: a streaming-native pipeline without repeated decoding, which `SpeechAnalyzer` provides natively.
3. **The earlier experimental offline diarizer is measurably not ready to ship.**
   [Fact] Across 18 AMI development meetings, VBx/AHC produced DER 40.01 compared with Sortformer's 20.34; without constraints DER was 52.70; and the constrained path is nondeterministic because FluidAudio's `KMeansClustering.swift:64` uses unseeded K-means.
   The actual more-than-four-speaker comparison, the eight-speaker concatenation in `work/eightspk/`, was started but never scored.
   Consequently, the domain model must not impose a slot limit, but the engine choice for more than four speakers remains open behind the provider boundary.
4. **The four-slot limit applies per channel, not per meeting.**
   [Fact] With microphone and system tracks, as many as eight clusters are currently possible; cross-channel identity matching does not exist (`transcriber.py:1281`).
5. **LM Studio is not currently supported anywhere.**
   [Fact] `ai_provider` knows `local` for bundled Ollama, `remote` for an Ollama URL, `cloud`, and `adapter` (`config.py:1781`); LM Studio does not appear in the repository.
   The new app's OpenAI-compatible provider boundary covers LM Studio, external Ollama instances, and cloud APIs under one contract.
6. **Protecting originals conflicts with the current default.**
   [Fact] `keep_recordings: false` deletes audio after processing (`config.py:693-763`).
   In the new app, originals are immutable and are never deleted automatically.
7. **The largest current recovery gap is the lack of a persistent job queue.**
   [Fact] `processingQueue` is in memory; after a crash between stopping and processing, the recording remains orphaned (`app/main.js`, `live-snapshot-sweep.js:12-20`).
   The new app persists processing runs as part of its data model.
8. **Further alignment tuning is not worthwhile on the measured conference material.**
   [Fact] Earlier measurements found that overlap voting, island smoothing, and A-B-A collapse affected between 0 and 0.3 percent of the evaluated material.
   Only the word-level split of long sentences starting at five seconds (`transcriber.py:570`), overlap clamping, and the distance limit for nearest fallback are retained.
   The case of multiple people sharing one microphone remains unmeasured; it is a benchmark task, not an architecture assumption.

## 2. Modules and dependencies

The shipping application contains one local SwiftPM package, `StenoKit`, with several targets and one Xcode app target.
The separate experimental `GemmaService` package remains outside that graph.
The separate Xcode 27 project variant adds only the dependency-free IPC module and embeds the model-free XPC helper; it does not activate the MLX model runtime in the app.
[Recommendation] Use one package with multiple targets instead of many packages: target dependencies provide real boundaries without versioning and release overhead between artificial packages.

```text
                        ┌─────────────────────┐
                        │      Steno.app       │  macOS-only (SwiftUI, AppKit when needed)
                        └──────────┬──────────┘
              ┌───────────────┬────┴─────┬────────────────┐
     ┌────────▼───────┐ ┌────▼─────┐ ┌──▼───────────┐ ┌──▼──────────┐
     │ StenoMacAudio  │ │StenoPipe-│ │StenoIntelli- │ │StenoExchange│
     │ (macOS-only)   │ │line      │ │gence         │ │             │
     └────────┬───────┘ └────┬─────┘ └──┬───────────┘ └──┬──────────┘
              │         ┌────┴──────────┴─────┐          │
              │         │  StenoTranscription │          │
              │         │  StenoDiarization   │          │
              │         │  StenoIdentity      │          │
              │         └────┬────────────────┘          │
              │              │                           │
     ┌────────▼──────────────▼───────────────────────────▼──┐
     │                    StenoLibrary                       │
     └───────────────────────────┬──────────────────────────┘
                        ┌────────▼────────┐
                        │   StenoDomain   │
                        └─────────────────┘
```

| Target | Contents | Reusable on iOS |
|---|---|---|
| `StenoDomain` | Pure value types: Meeting, MediaAsset, Transcript, Revision, ProcessingRun, Person, Prototype, and IDs. No I/O and no platform frameworks. | Yes, fully |
| `StenoLibrary` | On-disk library layout, atomic writes, schema versioning and migration, persistent run queue, and integrity checks. | Yes, based on FileManager |
| `StenoTranscription` | ASR provider contract, `SpeechAnalyzerProvider`, and word-alignment rules such as word-level splitting and clamping. | Yes, Speech is available on iOS 26 |
| `StenoDiarization` | Diarization provider contract, `FluidSortformerProvider` using ported sidecar code, and embedding extraction. | Yes, Core ML and FluidAudio run on iOS, but only when needed |
| `StenoIdentity` | Speaker identity: prototypes, hard negatives, suggestion gates, run provenance, and merge logic. | Yes, fully |
| `StenoIntelligence` | Templates, `FoundationModelsProvider`, and `OpenAICompatibleProvider` for LM Studio, Ollama, and cloud services; strictly optional. | Yes |
| `StenoExchange` | Non-destructive legacy Steno import, Obsidian export, and generic exports such as Markdown and JSON. | Yes |
| `StenoPipeline` | Processing-run orchestration: state machine, crash recovery, and progress. | Yes |
| `StenoMacAudio` | Intentionally macOS-specific: AVAudioEngine microphone capture, CoreAudio Process Tap for system audio, the mic monitor ported from `mic_monitor.swift`, permissions, and device management. | Intentionally no |
| `Steno.app` | SwiftUI interface, menu bar, settings, and onboarding. | Intentionally no |

Dependency rules:
`StenoDomain` depends on nothing.
Everything depends on `StenoDomain`, and nothing depends on the app.
Provider targets know `StenoLibrary` only through narrow read-only protocols; the pipeline performs writes.
The only external dependency of `StenoKit` in the initial implementation is FluidAudio 0.15.6, pinned exactly.

## 3. Data model

The library is a directory with a defined, versioned layout.
[Recommendation] Prefer files over SQLite or SwiftData initially: atomic writes are proven in the legacy project, the encryption beta naturally works by creating, verifying, and activating a copy, Obsidian export is file-oriented, and no additional dependency is introduced.
A purely derived search index, later using SQLite FTS or Spotlight, may be deleted and rebuilt at any time.

```text
StenoLibrary/
  library.json                     # {schemaVersion, libraryId, createdAt}
  meetings/<meetingID>/
    meeting.json                   # title, date, status, meeting-scoped participants
    media/<assetID>.caf            # immutable originals, one file per track
    media/<assetID>.json           # MediaAsset metadata including provenanceKey
    runs/<runID>/
      run.json                     # kind, engine and version, parameters, status, times
      transcript.json              # ASR output with word timestamps for ASR runs
      diarization.json             # speaker segments and cluster embeddings for diarization runs
    transcript/
      revisions/<revisionID>.json  # append-only, never overwritten
      current.json                 # pointer to the current revision
    notes/…, reports/…             # template results and user notes
  identity/
    persons.json                   # people with prototypes and hard negatives
  jobs/
    <jobID>.json                   # persistent processing queue
  exports/                         # export records, not the exported files themselves
```

Core entities, all `Codable` and each document carrying a `schemaVersion`:

- **Meeting**: Groups media, runs, transcript, and results. It carries the meeting-scoped participant list, preserving the legacy-system invariant that attendance survives re-diarization.
- **MediaAsset**: Immutable original. Stores `kind` such as micTrack, systemTrack, or imported, plus recording device, sample rate, duration, and `provenanceKey`.
- **ProcessingRun**: One engine run over defined inputs. Stores `kind`, engine and model versions, parameters, status, input IDs, and error details. Runs are never deleted, although storage for large derived artifacts may be compacted.
- **TranscriptRevision**: A complete transcript state consisting of turns, segments, and words with `text`, `start`, and `end` per word; a speaker assignment per turn; and `origin` as liveProvisional, finalRun(runID), or userEdit(parentRevisionID).
- **SpeakerCluster**, scoped to a diarization run: `clusterID`, channel, segments, a 256-float embedding, speaking duration, `containsMultipleSpeakers`, and `reviewState`.
- **Person / SpeakerPrototype / HardNegative**: As in the legacy system, tagged by context using `recordingType`, `channel`, `meetingID`, and `runID`, and never averaged across contexts.
- **UserCorrection**: A separate revision with `origin: userEdit`, never an in-place mutation.
- **TemplateResult**: The result of a template run, referencing a transcript revision and model.
- **ExportRecord**: Records what was exported, when, and where, with a revision reference.

## 4. IDs, provenance, and revision rules

- All IDs are UUIDv7 values, time-sortable and collision-resistant, created once and never reused.
- **provenanceKey** for each MediaAsset: SHA-256 of the audio bytes on import; for native recordings, `meetingID/trackKind`. Legacy Steno imports additionally map `legacy:<stem>`. An import with a known provenanceKey is rejected or reported as a duplicate.
- **Immutable originals**: `media/*.caf` is never written after recording completes; all processing reads originals but writes only under `runs/`.
- **Revision rules**: Revisions are append-only and `current.json` is an atomic pointer. A final ASR run creates a new revision and never silently replaces a user correction. If user edits exist on an older base, the new state is stored as a candidate and offered in the UI instead of being activated automatically.
- **Run provenance** for identity: every confirmation references `runID` and `clusterID`; after re-diarization, old confirmations are marked stale instead of being displayed falsely as confirmed. This preserves the legacy invariant represented by `prototype_run_matches`.
- Store separately what is created separately: immutable originals, reproducible and compactable run artifacts, and small, valuable user decisions that are never changed automatically.

## 5. Data flows

**Live recording.**
`StenoMacAudio` starts an AVAudioEngine tap for microphone audio and a CoreAudio Process Tap for system audio.
Each track enters a ring buffer with an incremental, crash-tolerant CAF writer and the live pipeline as consumers.
The live pipeline feeds each track to its own `SpeechTranscriber` with `volatileResults`; provisional results appear immediately and are visibly marked.
Initial live speaker assignment is channel-only, "Me" and "Others", as it is today.
The streaming API fully replaces the legacy 400-millisecond re-decode path.

**External import.**
Select a file, decode it through AVFoundation, calculate its provenanceKey, copy it as a MediaAsset without moving it, create a meeting, and enqueue a final processing job.

**Final ASR run.**
After stop or import, `StenoPipeline` creates a persistent job: one full-file `SpeechTranscriber` run per track with `audioTimeRange` for every word, output at `runs/<id>/transcript.json`, followed by a new TranscriptRevision according to section 4.

**Diarization.**
`FluidSortformerProvider` runs per track over the original file using overlap-cleaned masks, ten-second windows, and WeSpeaker centroids.
Its output consists of speaker segments plus one embedding per cluster.
Alignment assigns sentences to the segment at their midpoint; sentences of at least five seconds spanning multiple speakers are assigned word by word; anything unplaceable retains its channel label and is never discarded.

**Speaker identification.**
`StenoIdentity` merges fragments per channel when distance is at most 0.10, calculates candidates using minimum distance to context-compatible prototypes, applies the gates of distance 0.40, margin 0.10, 20 seconds, three segments, mean turn length 1.55 seconds, and at least two confirmed meetings, then returns `confirmed`, `possible`, or `none`.
Nothing is named automatically.
Only a person confirms a suggestion; confirmations create prototypes and mutual hard negatives, and reassignment removes old evidence scoped to the run.

**Manual correction.**
Every correction to text, speaker, or segment boundaries creates a new revision with `origin: userEdit`; undo moves a pointer and overwrites nothing.

**Template evaluation.**
`StenoIntelligence` renders a template against the current revision, primarily using on-device Foundation Models and optionally a deliberately configured OpenAI-compatible endpoint.
Transcript, speaker features, and export remain fully usable without an LLM.

**Export.**
`StenoExchange` writes Markdown with frontmatter to a user-selected destination.
Obsidian export requires active approval and a clear plaintext warning, and every export creates an ExportRecord.

## 6. Provider contracts

Keep contracts small and concrete, without generic abstractions.

```swift
protocol TranscriptionProvider {
    var descriptor: EngineDescriptor { get }   // name, version, model revision
    func liveSession(format: AudioFormat, locale: Locale) async throws -> LiveTranscriptionSession
    func transcribeFile(_ url: URL, locale: Locale) async throws -> TranscriptOutput  // includes word timestamps
}

protocol LiveTranscriptionSession {
    func append(_ buffer: AudioBuffer) async
    var events: AsyncStream<TranscriptionEvent> { get }  // .volatile(...), .final(...)
    func finish() async throws -> TranscriptOutput
}

protocol DiarizationProvider {
    var descriptor: EngineDescriptor { get }
    func diarize(_ url: URL, hints: DiarizationHints) async throws -> DiarizationOutput
    // DiarizationHints: optional minimum speaker count; output: segments and embeddings per cluster
}

protocol SpeakerSuggestionEngine {   // pure domain logic, not an ML provider
    func suggestions(for run: DiarizationOutput, in context: IdentityContext) -> [ClusterSuggestion]
}

protocol TextModelProvider {
    var descriptor: EngineDescriptor { get }
    func render(template: Template, transcript: TranscriptRevision) async throws -> TemplateResult
}

protocol Exporter {
    func export(_ meeting: MeetingSnapshot, to destination: ExportDestination) async throws -> ExportRecord
}
```

Benchmark candidates such as Nemotron or a future VBx path implement `TranscriptionProvider` or `DiarizationProvider` and are enabled in production only after dedicated measurements.
The `EngineDescriptor` is stored in every `run.json` so each artifact remains attributable to its producer.

## 7. Failure behavior

- **Crash during recording**: CAF is written incrementally. On the next launch, recovery finds a meeting in `recording` state without a running process, closes the files, marks the recording as interrupted, and enqueues the final run. Nothing is discarded.
- **Crash during processing**: Jobs under `jobs/` carry status and retry count. On launch, `running` jobs are reset to `queued` and rerun idempotently. Runs write to temporary files before an atomic move.
- **User cancellation**: The job receives status `cancelled`, partial artifacts are deleted, and the meeting remains usable with its live revision.
- **Low-power state**: Recording uses `ProcessInfo.beginActivity` to prevent App Nap and idle sleep. Processing jobs are interruptible and resume after wake.
- **Model failure**: A failed run never damages the previous state. The last valid revision stays current, and a visible `failed` run stores the error details. If final ASR fails, the live revision remains usable as the final result, following the legacy safety-net principle from issue #207.
- **Low disk space**: Free space is checked before recording and large runs. Crossing a threshold during recording produces a warning and a clean stop with an intact original instead of silent loss.
- **Corrupt artifacts**: Every JSON document carries `schemaVersion`; parsers reject invalid data instead of guessing. A corrupt run artifact is quarantined with a `.corrupt` suffix, the reproducible run is marked `failed`, and corrupt originals are reported but never overwritten.
- **Relaunch**: Startup validates the library, migrates if needed using copy then switch for structural changes, runs recovery, and resumes the queue.

## 8. Privacy, logging, and encryption

- **Logging**: Use only `os.Logger` with privacy annotations. Conversation content, file names, transcript text, and model output are `.private` or not logged. The initial implementation has no telemetry; any future telemetry must be opt-in and content-free.
- **Network boundary**: `StenoIntelligence` is the only component with network access, and only when an external provider is configured explicitly. An in-app switch enforces local-only operation. Model downloads through SpeechAnalyzer `AssetInventory` and FluidAudio are visible system or one-time downloads that carry no conversation content.
- **Encryption beta**, initially disabled: Enabling it creates a complete encrypted copy of the library at file level, with a key in Keychain and a recovery code for the user, fully decrypts that copy for verification, compares it, and only then switches atomically. The old library remains until the user deletes it explicitly. Encryption is never in place.
  [Fact] Voice embeddings as biometric data provide the strongest reason for protection, as described by `encryption-at-rest.md` in the legacy project.
- **Recovery limits**: Encrypted data is lost without both the key and recovery code. Activation states this unambiguously and requires confirmation of the recovery code.
- iCloud sync and automatic cloud imports remain excluded until encryption and recovery are dependable.

## 9. Test and benchmark strategy

- **Unit level**, fast and deterministic: domain invariants in `StenoDomain` and `StenoIdentity`, including the 13 legacy invariants as a test catalog, storage migrations, revision rules, and alignment rules using synthetic word timestamps.
- **Integration level**: Pipeline runs against small real audio fixtures, including speech created with `say`; crash-recovery tests that terminate the process, relaunch, and inspect state; and storage round trips.
- **Benchmark kit**: Continue the documented AMI and CCC protocol with dscore and three-way DER/JER reporting. The app's benchmark CLI emits the same RTTM format so historical and new measurements remain comparable.
- **Open measurement questions, in priority order**:
  1. Compare SpeechAnalyzer with Parakeet in German and English for WER, word-timestamp quality, latency, and energy. [Assumption] SpeechAnalyzer is good enough; this is unmeasured.
  2. Obtain real, time-aligned reference material with multiple people sharing one microphone. Do no further alignment tuning without this material.
  3. Finish scoring the eight-speaker case in `work/eightspk/` before building any more-than-four-speaker engine.
  4. Profile memory and energy for four-hour sessions. The streaming pipeline must use constant memory rather than growing windows.
- **Real-time capability**: Measure the live path using synthetic real-time feeding based on the legacy `@perf` spec. The pipeline must remain faster than real time indefinitely, including with two active tracks.

## 10. Vertical milestones

The order follows the handoff with one correction: milestone 1 already needs minimal SpeechAnalyzer integration because a visible transcript without ASR would be empty; milestone 2 then deepens final processing and benchmarks.

1. **App shell, library, recording, import, and live transcript.**
   Acceptance: recording creates two separate CAF originals; import copies with provenanceKey; live transcript appears during recording; `kill -9` during recording loses no audio; the library survives relaunch and recovery.
2. **Final ASR run and benchmarks.**
   Acceptance: the final run replaces the live revision according to the rules and includes timestamps for every word; a WER comparison of SpeechAnalyzer against Parakeet reference values is documented; the ASR reference decision is recorded.
3. **Diarization and speaker identity as internal modules.**
   Acceptance: the Sortformer port stays within the legacy AMI-fixture DER baseline, 20.3 on development Array1-01 and 8.98 on IS1008a/b; identity suggestions reproduce the gates; confirmation, renaming, many-to-one assignment, and mixed marking work with run provenance.
4. **Templates with Foundation Models.**
   Acceptance: an on-device meeting-minutes template; everything else remains usable without the model.
5. **Optional external LLM providers.**
   Acceptance: LM Studio and a custom Ollama instance use one OpenAI-compatible contract, are never contacted automatically, and the producing provider is visible on each result.
6. **Legacy Steno import and Obsidian export.**
   Acceptance: import copies and never changes the old installation, deduplicates using provenanceKey and legacy stems; export occurs only after approval and shows a plaintext warning.
7. **Encryption beta.**
   Acceptance: the copy, verify, and switch sequence is demonstrated; recovery code is mandatory; the old library remains until explicit deletion.
8. **Later: iCloud and automatic imports.** Only after milestone 7.

## 11. Risks and deferred decisions

**Risks:**

- SpeechAnalyzer quality, especially for German, specialist vocabulary, and long sessions, is unmeasured. Mitigation is the early milestone 2 benchmark and the narrow provider boundary.
- More than four speakers per channel remains unresolved. The measured VBx path is worse and nondeterministic. The product claim of distinguishing more than four participants is currently supportable only across microphone and system channels, not within one channel.
- FluidAudio downloads models from Hugging Face. Model-asset management, including bundling, pinning, and offline availability, requires an explicit solution or the app will inherit the legacy system's fragile download-and-delete behavior.
- Multiple people sharing one microphone remain unmeasured, so every claim about that case is an assumption.
- CoreAudio Process Taps for system audio require permissions and have app-specific behavior. Test them against real conferencing apps early in milestone 1.

**Deliberately deferred product decisions:**

1. Original-track codec, initially 16-bit PCM in CAF, with ALAC as a later space-saving option.
2. Whether to add a SQLite search index in milestone 2 or later.
3. Nemotron or other ASR alternatives, to be considered only after the SpeechAnalyzer benchmark.
4. UI design language and branding for the new app.
5. Distribution through Developer ID signing, notarization, and updates; the initial implementation is a local build.
6. iOS: keep the domain and contracts portable, but write no iOS-specific code before the macOS core is stable.
7. Detailed encryption design, including key format and recovery-code UX, before milestone 7.
8. Native Gemma 4 app integration: `GemmaService` establishes a macOS 27 compile and local-verification boundary around an MLX runtime that conforms to Apple's Foundation Models `LanguageModel` API.
   Apple's framework does not load the external checkpoint.
   The separate Xcode 27 project variant now embeds a signed App Sandbox XPC helper with incoming and outgoing network access disabled.
   Mutual caller authentication, strict IPC correlation, bounded client deadlines, exact helper-process exit proof, and one app-process-wide recording coordinator are implemented and covered by signed model-free integration tests.
   A crash-releasing cross-process recording and helper gate with a two-process integration test, a server-side inference task registry with real cancellation and quiescence, production Hardened Runtime validation, the consented immutable model importer, a buildable matched MLX dependency snapshot, and verified model-runtime activation remain unresolved.
9. Whether a speaker-count field should ever exist. If it does, ask "how many people spoke?", not "how many people attended?".
