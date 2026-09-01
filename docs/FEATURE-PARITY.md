# Feature parity: legacy stenoai and current Steno

Maintained checklist.
Status: 31 August 2026.
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
- [x] Resume recording or append to an existing meeting (`Continue Recording` appends sequenced immutable tracks on one absolute timeline); legacy flag: `--append-to`.
- [x] Automatic meeting detection and notification through an internal CoreAudio mic-monitor service (`MicrophoneActivityMonitor`, gated by `steno.meetingDetection.enabled`).
- [x] Silence-triggered automatic stop. Deliberately ships OFF by default (divergence from legacy default-on) so an unnoticed setting cannot truncate a recording.
- [x] Global recording shortcut Command-Shift-R (suppressed while Steno is frontmost).
- [x] Menu bar item with record controls, Open Steno, dock-icon visibility toggle.
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
- [x] Automatic language detection using an `auto` option (stopword-profile classifier over live text, one lane restart, detected locale pinned to the final run) plus unlimited mid-recording manual language switching.
- [x] Re-run transcription from the UI using "Transcribe Again". The old transcript remains a revision, and the dialog warns that speakers must be reconfirmed.
- [x] Fallback engine after an ASR crash: one automatic requeue with Parakeet (no Whisper download), provenance-linked runs, loop-proof; the live revision remains as a safety net.
- [x] iOS loads the new revision when the speaker-separation status flips `.unavailable` -> `.ready`/`.modelsRequired` without reopening: the derived diarization state is now part of the meeting-content observation identity (regression-tested in `MeetingPresentationTests`).
- Intentionally omitted: Parakeet or MLX as the primary engine. The provider boundary remains available and `BENCH-M2-ASR.md` defines reconsideration triggers.
- Intentionally omitted: Windows support. The new app is native to Apple platforms.

## Speakers: diarization and identity

- [x] Acoustic diarization per track using in-process Sortformer, behaviorally verified at legacy baseline DER 20.34.
- [x] Overlap-cleaned WeSpeaker centroid embeddings per cluster.
- [x] Word alignment from transcript to speaker segments using sentence midpoint, word-level splitting from five seconds, and no discarded text.
- [x] People registry with context-tagged prototypes and hard negatives, backed by the 13 legacy invariants as tests.
- [x] Suggestion engine with calibrated `confirmed`, `possible`, and `none` gates, meeting-wide exclusivity, and run provenance.
- [x] Speaker-review UI for confirm, many-to-one assignment, new person, multiple people, and generic labels; resolved names in transcripts; and quote-plus-audio samples from the same turn.
- [x] People management in Settings: rename, merge, undoable delete, provenance and audio per sample, exclusion instead of deletion, and visible, reversible hard negatives.
- [x] Self voiceprint for recognizing "Me": operator person with a "This was me" binding on unconfirmed mic clusters.
- [x] Manual voice enrollment outside a meeting: record-or-import clip in People settings computes a context-free prototype via the WeSpeaker extraction path.
- [x] Visible cross-meeting suggestions in the People settings (possible-gate matches per person with quote samples, confirm or dismiss with reversible suppression).
- [ ] More than four speakers per channel. The measured VBx path is unusable; see the risks in `ARCHITECTURE.md`.
      Candidate LS-EEND evaluated on paper: decision brief with sizes, estimates, and a
      further model evaluation remains separate benchmark work.
      Note: stenoai carries the identical Sortformer 4-slot ceiling, so this row is an
      improvement over both apps, not a parity regression.

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
- [x] (M4) Templates: builtin product-demo, sales-call, one-on-one, standup plus user-defined markdown templates, overrides with reset, and a default-template setting.
- [ ] Direct Gemma downloads on iOS.
- [x] Native Gemma inference on macOS is implemented and has generated a real Standup report with the exact pinned Gemma 4 E2B checkpoint.
      The bounded macOS 27 run imported and selected the checkpoint through Steno, measured 1,971,600 KiB peak helper RSS, and never reached critical memory pressure.
      Longer-template validation remains open because a Meeting Minutes run under the same 256-token response budget did not satisfy the strict JSON result contract.
      The Xcode 27 variant provides a mutually authenticated, signed, sandboxed XPC helper with incoming and outgoing network access disabled, strict IPC, distinct activation and request deadlines, server-side targeted cancellation and true task-and-reply quiescence, exact helper-exit proof, a global crash-releasing recording/model gate, protocol-v5 atomic binding of the execution-gate, verified model-root, and exact model-file descriptors, descriptor-rooted bind-time verification, session pin binding, a session-scoped client with automatic terminal retirement, and one app-process-wide recording coordinator.
      The helper's self-exit on byte 0 recording intent is an expected fail-closed safeguard, while local retirement remains best effort.
      The MLX-free import boundary now has one-shot explicit consent bound to the exact approved Gemma 4 E2B pin and source inode, descriptor-safe copying, content-addressed no-replace publication, exact checksums and license provenance, cancellation, and final inode-bound revalidation in a Steno-controlled read-only store.
      Same-process recording/import exclusion is implemented through the app-wide coordinator: recording intent rejects new imports, cancels the exact active import, and waits through its non-cancellable post-publication synchronization and verification before permission or capture.
      Across processes, store mutation and model execution share byte 1 exclusively on the same gate, while recording intent uses byte 0; source verification precedes the mutation lease, the importer observes recording intent at bounded checkpoints, removes only its own staging tree before commit, synchronizes the committed parent namespace, and releases the lease before final post-publication verification.
      A non-responsive operating-system import operation deliberately blocks recording for the remaining app-process lifetime rather than failing open; a user-facing explanation and safe restart path remain open.
      The exact MLX dependency snapshot builds with Xcode 27 Beta 6 and its matching Metal Toolchain component without loading a model.
      A one-shot child-file activation boundary now retains exact shard descriptors, verifies each shard into immutable bytes before a trusted consumer sees it, expires borrowed views, and revalidates the named tree before returning a result.
      The current whole-shard `Data` bridge has exact caller-provided bounds for the selected 3,550,670,554-byte shard, and the bounded real-model run remained below the documented 8 GiB helper RSS ceiling.
      The production loader materializes Gemma 4 only from those one-shot activation bytes, rejects ambiguous JSON and sanitizer-unsafe tensors, correlates MLX results with the strict parser, validates quantization, parameter dtypes, and the exact post-sanitization parameter set before structural update, performs preparation and checked evaluation synchronously, and publishes the stored adapter only after final descriptor-rooted revalidation.
      The helper now activates that loader only for one exact helper-controlled profile, atomically binds the resulting executor before acknowledging the session, uses the activation processor for prompt counting, creates a fresh Foundation Models session per generation, and rejects prompts beyond the fixed profile limit.
      The authenticated bind and all model materialization run under the distinct activation deadline before the first ordinary request deadline begins; activation failure trips a model-use breaker until a later recording cycle independently proves helper absence.
      The app can now resolve an exact app-approved installed digest without discovering models, creating a missing `Models/v1` hierarchy, repairing storage, or returning a path.
      Its native `TextModelProvider` keeps one exact helper session across every count, map, and reduce operation in a complete template render, and both counting and generation use the same strict JSON prompt contract.
      Import approval, app provider profiles, and helper activation are independent exact-pin allowlists.
      All three production catalogs pin the same immutable Gemma 4 E2B snapshot, while unapproved pins close their filesystem capability and remain model-free and the app process continues to link neither MLX nor Metal.
      The arm64 Release configuration now enables Hardened Runtime for the app and helper, gives the app only microphone and calendar resource entitlements, prevents injected debug entitlements, and rejects Release peers without the runtime flag, with `get-task-allow`, or with a Hardened Runtime exception entitlement.
      Its code-signing and entitlement profile has passed strict nested-signature inspection, while manual Release recording, system-audio, and calendar validation remains open.
      Native Gemma crash recovery is an explicit manually invoked engine, not startup or UI wiring and not model execution.
      Its monotone v2 owner, bound, and prepared documents are write-once, with the owner durable before staging, the bound root identity durable before any contents, the complete manifest durable before other model paths, all model files pre-created empty, and the prepared canonical inode ledger durable before payload.
      Recovery uses byte 1 of the same mutation lease and byte 0 recording intent, with descriptor-only no-follow operations, inode-aware cleanup, deterministic cleanup rename, and parent synchronization.
      Old v1, malformed, and suspicious entries are retained and reported, published 64-hex targets are never deleted, valid committed targets are only synchronized and verified, and corrupt published targets remain retained and separate from future user-authorized repair.
      Recovery never auto-publishes, and an explicit user-authorized repair flow for retained corrupt targets remains open alongside final checkpoint license review and negative signed abuse or multiprocess XPC coverage.
- [x] Multiple immutable report versions per meeting, pinned to a revision, with quarantine restoration.
- [x] (M4) Title generation suggestion with apply/dismiss persistence.
- [x] (M5) Optional external LLM providers with native dialects for Ollama, LM Studio, OpenAI, Anthropic, and Bedrock, plus a conservative OpenAI-compatible fallback. Providers are never contacted automatically, selection is pinned to the job, and the provider remains visible on the report. Real tests passed with LM Studio/MLX Gemma 4 and Ollama/Gemma 4 on Mac and iPad Simulator. Cloud contracts were verified locally with HTTP fixtures, without paid cloud requests.
- [x] Ask bar during recording (chat over finalized segments only, bounded single-query transport) and title suggestions from Apple Foundation Models.
- [ ] Legacy parity for optional automatic report generation after successful final transcription remains open and must retain the explicitly pinned model choice and external-disclosure consent.
- [ ] Legacy parity for Whisper fallback outside the locally available Apple Speech language set remains open and requires explicit installation, provenance, and bounded Apple Silicon evaluation.
- [x] Global chat across all notes: Library Chat window over every meeting's latest report + notes (bounded newest-first context, persisted sessions, OutboundDisclosure consent for external endpoints).
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
- [x] Search across meetings: derived rebuildable SQLite FTS5 index (transcript + notes + latest report) with Titles/All-content scope in the sidebar.
- [x] User-selectable storage location (`steno.library.customPath`, applied next launch; env override keeps priority; moving an existing library stays a manual step while the app is closed - deliberate divergence from legacy auto-relocation).
- Intentionally omitted: deleting recordings after processing by default. Originals are immutable.

## Export and exchange

- [x] (M6) Non-destructive legacy Steno import deduplicated by `legacy:<stem>`. A real import including people, voice samples, reports, notes, and folder metadata passed. Chat sessions are intentionally excluded.
- [x] Obsidian export: one-way non-destructive vault mirror behind an explicit approval dialog naming the target folder; identity-based updates never duplicate or delete.
- [x] Markdown export for individual meetings with title, date, participants, note, reports, and timestamped transcript. Unconfirmed speakers retain technical labels instead of guessed names.
- [x] Share menu and PDF export plus Copy Notes (payload identical to the Markdown export). Documented divergence: system-font PDF instead of legacy embedded-font branding.
- [x] Export individual original audio tracks from the UI without conversion, preserving the audio to which every timestamp refers.
- [x] Granola API importer (in-app mirror of the granola-to-steno skill: tolerant JSON fixture parsing, provenance key `granola:<noteId>`, idempotent re-import, notes = summary, participants as persons).

## Platform and operation

- [x] Native SwiftUI macOS app generated with XcodeGen; the legacy app used Electron, PyInstaller Python, and sidecars.
- [x] App Nap prevention during recording and free-space checks.
- [x] Best-effort long iOS background completion via `beginBackgroundTask` with graceful job pause and an honest deferral notice when iOS expires the window (iOS has no guaranteed-completion API for this workload).
- [x] (M7) Library-encryption beta: staged copy, full verify-before-switch, atomic rename with kept backup, Keychain KEK plus recovery-code unwrap, interrupted-switch rollback at startup. Settings surface ships behind an explicit beta row.
- [x] First-run onboarding with legal notice, profile, transcription language, model status, and separate checks for microphone and system-audio permission; available again from Help.
- [x] Calendar reminders via local EventKit read-only access: pre-meeting notification inside a configurable look-ahead window (default-off, privacy-conservative divergence from legacy default-on; event data never leaves the device).
- [x] Notifications for completed notes/transcripts, failures, and detected external capture (`steno.notifications.enabled`). Silence-stop itself is silent by design; the stop is visible in the UI.
- [x] Launch at Login (SMAppService) and Dock icon preference applied before first activation.
- [x] Deep links for Shortcuts: `steno://` plus legacy-scheme compatibility (`stenoai://`), routes record/start?name=... and record/stop.
- [ ] Signed distribution and updates, deferred in `ARCHITECTURE.md` section 11.
- Intentionally omitted: telemetry. Any future telemetry must be opt-in and content-free.
- Intentionally omitted: legacy organization adapters and cloud backup. Reconsider no earlier than M8.

## Interface additions beyond the legacy checklist

- [x] Command palette (Cmd-K): commands, recent meetings, settings tabs.
- [x] Undo-delete toast after trashing a meeting (8 s window).
- [x] Status-driven home header (recording clock, processing count, speakers needing review).
- [x] My Notes overview window (read-only reverse-chronological list of every note).
- [x] Folder colors and icons (fixed palettes, Codable-compatible).
- [x] Ask bar floating above the recording controls (Cmd-Shift-A).

## Performance budgets

Budgets, evidence pointers, and the checker script live in [`PERF-BUDGETS.md`](PERF-BUDGETS.md)
(`scripts/benchmark/perf_budgets.py`). A 2 h two-track soak test asserts constant memory
(`LongSessionSoakTests`: measured footprint delta 2 MB, 0.0001x realtime processing).

## feat/parity wave (26 August 2026, second pass)

- [x] Local MCP server: JSON-RPC 2.0 over HTTP on 127.0.0.1 (default port 27127),
  Bearer key in Keychain with constant-time compare, origin-before-auth anti-DNS-rebinding
  checks, protocol-version negotiation, six tools (`list_meetings`, `get_meeting`,
  `get_meeting_transcript`, `search_meetings`, `list_folders`, `ask_meetings` with 60 s
  timeout), default OFF behind Settings > Integrations.
- [x] Pre-meeting brief on the home header: prior meetings selected by title containment
  or shared attendees, streamed 2-3 bullets, cancel-on-collapse, fixed empty state,
  attendee email cleaning.
- [x] Chat recipes: builtin + saved prompt presets with slash-menu and save/delete flows
  in both chat composers; validation caps 200/8000 chars.
- [x] Chat scoping chip in Library Chat: all notes / folder / specific meetings, forwarded
  every turn, self-healing on deletions.
- [x] Saved-note ask trim: newest-tail-preserving budget cut with `[earlier transcript
  omitted]` marker; Apple window aligned to the measured 8192-token reality
  (15,769-char local budget).
- [x] Bulk export: every meeting as Markdown into a chosen directory or one CSV with the
  exact legacy header, formula guard, and library-folder containment rule.
- [x] Per-recording template pinning with mid-recording switch and one-shot reset;
  resolution order pinned > catalog default > Meeting Minutes.
- [x] People directory derived from meeting participants (CJK-safe normalization,
  deterministic ordering) with person-scoped chat handoff.
- [x] Transcript citations: deterministic bullet-to-transcript resolver (stopwords, CJK
  bigrams, sliding windows, anti-guessing nil) with jump-and-highlight from report bullets.

## Deliberate design divergences (parity decisions, not omissions)

- Visual language: stenoai's paper-and-ink web design system is intentionally not
  cloned pixel-for-pixel. Steno uses native SwiftUI/AppKit styling (system materials,
  controls, light/dark appearance QA'd in `docs/benchmarks/2026-08-24-cross-platform-ui-qa.md`);
  interaction parity - flows, shortcuts, empty states, status surfaces - is the contract.
- Org features that require stenoai's backend (org session JWT, S3 presign share,
  cloud calendar token storage): replaced by local-only equivalents (local EventKit
  reminders, on-device library). No org backend exists to talk to.
- Chat slash-command presets: Library Chat and the ask bar accept free-form questions;
  presets were a legacy UI affordance over the same transport.

## Intentional divergences

## Maintenance

When a milestone completes, update the affected boxes and status date.
Add legacy features discovered during import work here instead of ignoring them silently.
