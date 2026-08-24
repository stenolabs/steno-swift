# Feature parity: legacy stenoai and current Steno

Maintained checklist.
Status: 19 August 2026.
Legend: `[x]` means implemented and verified in the new app, `[ ]` means open, `(M4)/(M5)/...` is a planned milestone from `ARCHITECTURE.md` section 10, and "intentionally omitted" records a reasoned decision not to carry a feature forward.

A checked item means built and tested.
Any outstanding hardware or visual verification is stated on the item or in its associated handoff.

## Recording and import

- [x] Microphone recording with a separate immutable track instead of a stereo mix.
- [x] System-audio recording using an in-process CoreAudio Process Tap that survives device changes; the legacy app used Electron loopback.
- [x] Separate original tracks; the legacy app split a stereo WebM only after recording.
- [x] External audio import with SHA-256 provenance-key duplicate protection.
- [x] Crash-safe recording with lossless `kill -9` recovery and automatic adoption; legacy recordings could become orphaned.
- [x] Manually pause and resume only the microphone track while writing time-correct silence during the pause.
- [x] Preserve an active microphone track through device loss by binding to the starting device UID, writing silence during the gap, and resuming only with that same device. Verified automatically and with AirPods hardware.
- [ ] Resume recording or append to an existing note; legacy flag: `--append-to`.
- [ ] Automatic meeting detection and notification through an internal mic-monitor service.
- [ ] Silence-triggered automatic stop.
- [ ] Global recording shortcut, formerly Command-Shift-R.
- [ ] Menu bar item and tray controls.
- [x] Microphone selection.
  Automatic selection recognizes a uniquely resolved input device used by a known browser or meeting app.
  No match, multiple matches, unknown matches, or incomplete resolution requires deliberate manual selection.
  The selected UID is persisted and bound at start without falling back to another device.
  Automated tests pass; visual and real meeting-app verification remain open.

## Transcription

- [x] Live transcript during recording using SpeechAnalyzer streaming instead of 400-millisecond re-decoding, with provisional and final results distinguished.
- [x] Final transcription with per-word timestamps.
- [x] Persistent language selection from the languages supported by SpeechTranscriber.
- [x] ASR benchmark and recorded engine decision in `docs/BENCH-M2-ASR.md`: WER 21.3 versus Parakeet 18.31 and 2.3 times faster RTF.
- [ ] Complete the reproducible local ASR and diarization benchmark setup. Manifest, hashing, WER/CER, named-term, RTTM, and dscore tools exist and preserve the verified legacy scoring contract. Immutable audio excerpts, manually checked references, and M5 Air runs for reverberation, crosstalk, timestamps, and speaker assignment remain open.
- [ ] Complete the two-tier benchmark corpus. The CC BY 4.0 `Kölner Korpus des Kiezdeutschen` is registered as a stress test with DOI and source checksums but still needs alignment and manual excerpt review. OOCC has strong manual timestamps for standard German but its CC BY-NC-ND 4.0 license does not meet the freely usable product-reference requirement, so the final main source remains open.
- [ ] Automatic language detection using an `auto` option.
- [x] Re-run transcription from the UI using "Transcribe Again". The old transcript remains a revision, and the dialog warns that speakers must be reconfirmed.
- [ ] Fallback engine after an ASR crash; the live revision currently remains as a safety net.
- [ ] iOS does not always load the new revision without reopening when an existing status changes from `.unavailable` to `.ready` or `.modelsRequired`.
- Intentionally omitted: Parakeet or MLX as the primary engine. The provider boundary remains available and `BENCH-M2-ASR.md` defines reconsideration triggers.
- Intentionally omitted: Windows support. The new app is native to Apple platforms.

## Speakers: diarization and identity

- [x] Acoustic diarization per track using in-process Sortformer, behaviorally verified at legacy baseline DER 20.34.
- [x] Overlap-cleaned WeSpeaker centroid embeddings per cluster.
- [x] Word alignment from transcript to speaker segments using sentence midpoint, word-level splitting from five seconds, and no discarded text.
- [x] People registry with context-tagged prototypes and hard negatives, backed by the 13 legacy invariants as tests.
- [x] Suggestion engine with calibrated `confirmed`, `possible`, and `none` gates, meeting-wide exclusivity, and run provenance.
- [x] Speaker-review UI for confirm, many-to-one assignment, new person, multiple people, and generic labels; resolved names in transcripts; and quote-plus-audio samples from the same turn.
- [x] People management in Settings: rename, merge, undoable delete, provenance and audio per sample, exclusion instead of deletion, and visible, reversible hard negatives. See `docs/PLAN-PEOPLE.md`.
- [ ] Self voiceprint for recognizing "Me" across meetings.
- [ ] Manual voice enrollment outside a meeting. `manualEnrollment` exists in the data model but no capture path exists.
- [ ] Visible cross-meeting suggestions in the UI.
- [ ] More than four speakers per channel. The measured VBx path is unusable; see the risks in `ARCHITECTURE.md`.

## Intelligence: summaries, templates, and chat

- [x] On-device summary and meeting minutes using Foundation Models, turn-boundary MapReduce, and guided generation. A real-meeting hardware test remains open.
- [x] iOS report flow with Apple as the cold-start default, optional OpenAI-compatible endpoints, pinned revision and input, immutable versions, progress, errors, cancellation, copy, and share.
  Builds, complete app suites, and all ten StenoKit test targets pass.
  The simulator does not prove `SystemLanguageModel` behavior or real network permissions.
- [ ] Verify Apple Foundation Models on Apple Intelligence-capable iPhone or iPad hardware in airplane mode with a harmless German fixture, including Generate, Regenerate, Copy, Share, and Cancel.
- [ ] Verify iOS with LM Studio after selecting a specific local endpoint and non-sensitive synthetic fixture, including real `/models` and `/chat/completions` requests.
- [ ] Visually verify the report view on iPhone portrait and iPad portrait and landscape, with sidebar shown and hidden, a long report, two versions, and version selection.
- [ ] Visually verify external-model selection with the host and exact data classes visible.
- [ ] Visually verify that the old version remains visible during `Pending` and `Failed` states.
- [ ] Visually verify Copy for the selected version.
- [ ] Visually verify the open share sheet and its contents.
- [ ] Visually verify that Settings does not test endpoints automatically.
- [ ] (M4) Templates for results, sales notes, municipal meetings, and user-defined formats.
- [ ] Direct Gemma downloads on iOS.
- [x] Multiple immutable report versions per meeting, pinned to a revision, with quarantine restoration.
- [ ] (M4) Title generation.
- [x] (M5) Optional external LLM providers with native dialects for Ollama, LM Studio, OpenAI, Anthropic, and Bedrock, plus a conservative OpenAI-compatible fallback. Providers are never contacted automatically, selection is pinned to the job, and the provider remains visible on the report. Real tests passed with LM Studio/MLX Gemma 4 and Ollama/Gemma 4 on Mac and iPad Simulator. Cloud contracts were verified locally with HTTP fixtures, without paid cloud requests.
- [ ] Transcript query and global chat across notes.
- Intentionally omitted: bundling and managing an Ollama process.

## Library and management

- [x] Meeting list with status.
- [x] Persistent job queue with crash recovery.
- [x] Versioned transcript revisions that never silently replace user edits.
- [x] Delete meetings through Trash with confirmation and job cancellation.
- [x] Rename meetings through the context menu.
- [x] Age-based sidebar groups: Today, Yesterday, last 7 and 30 days, then month, with future items separate.
- [x] Folder organization with exactly one assignment per meeting.
  macOS and iOS share one persistent tree with root folders and one child level.
  iOS uses a stable native sidebar with disclosure, indentation, and unfiled meetings in date sections.
  Create, rename, delete, move, and promote are available from context menus, with typed drag as an additional touch interaction.
  A known iPad hardware bug is tracked as issue 1; the complete context-menu path is the workaround.
  Legacy folder assignments are imported and adopted once for existing data.
- [x] Native `.searchable` title filter above the meeting list, insensitive to diacritics. Full-text search remains deferred.
  On iOS, a search result temporarily opens its ancestor folders without overwriting persistent disclosure state.
- [x] Reorder folders with Move Up and Move Down on macOS and iOS; iOS additionally supports nesting and promotion by drag.
- Intentionally omitted on iOS: multi-selection and batch movement remain macOS-specific.
- Intentionally omitted: a custom sidebar header with the app name and a switcher chevron. The system navigation title already supplies the name, there is only one library, and "New meeting" already exists in the toolbar.
- [x] User notes during recording and in meeting details, with Command-M timestamps.
- [x] Per-line transcript editor. Every correction becomes a `userEdit` revision and preserves the recognized version. Re-transcription parks a candidate instead of replacing an edit, and a banner can activate that candidate.
- [x] Transcript search with Command-F. It intentionally avoids a second `.searchable` because the sidebar owns the window search field.
- [ ] Search across meetings, deferred with the search-index decision in `ARCHITECTURE.md` section 11.
- [ ] User-selectable storage location; only `STENO_LIBRARY_DIR` currently exists.
- Intentionally omitted: deleting recordings after processing by default. Originals are immutable.

## Export and exchange

- [x] (M6) Non-destructive legacy Steno import deduplicated by `legacy:<stem>`. A real import including people, voice samples, reports, notes, and folder metadata passed. Chat sessions are intentionally excluded.
- [ ] Obsidian export, only after active approval and a plaintext warning; deferred as a product decision.
- [x] Markdown export for individual meetings with title, date, participants, note, reports, and timestamped transcript. Unconfirmed speakers retain technical labels instead of guessed names.
- [ ] Share menu and PDF export.
- [x] Export individual original audio tracks from the UI without conversion, preserving the audio to which every timestamp refers.
- [ ] Granola API importer, a new feature inspired by OpenOats rather than legacy parity.

## Platform and operation

- [x] Native SwiftUI macOS app generated with XcodeGen; the legacy app used Electron, PyInstaller Python, and sidecars.
- [x] App Nap prevention during recording and free-space checks.
- [ ] Guaranteed completion of long iOS background processing.
- [ ] (M7) Library-encryption beta using copy, verify, switch, and a recovery code.
- [x] First-run onboarding with legal notice, profile, transcription language, model status, and separate checks for microphone and system-audio permission; available again from Help.
- [ ] Calendar integration and pre-meeting notifications.
- [ ] Notifications for completed notes and detected silence.
- [ ] Launch at Login and Dock icon preference.
- [ ] Deep links for Shortcuts, formerly `stenoai://`.
- [ ] Signed distribution and updates, deferred in `ARCHITECTURE.md` section 11.
- Intentionally omitted: telemetry. Any future telemetry must be opt-in and content-free.
- Intentionally omitted: legacy organization adapters and cloud backup. Reconsider no earlier than M8.

## Maintenance

When a milestone completes, update the affected boxes and status date.
Add legacy features discovered during import work here instead of ignoring them silently.
