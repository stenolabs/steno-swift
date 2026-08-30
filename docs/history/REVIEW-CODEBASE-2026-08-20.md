# Historical Codebase Review - 2026-08-20

This document summarizes a static review of StenoKit, the macOS app, and the iOS app at commit `03193e5` on `main`.
It is a historical snapshot, not a current issue tracker or a statement that these findings remain unresolved.
Check the current code and project history before acting on any finding.

## Method

Eight subsystem reviews examined the codebase, followed by an independent adversarial pass that attempted to disprove every reported finding.
The two most severe findings were additionally spot-checked against the code.
A finding was classified as confirmed only when its failure path could be traced in source.
The confirmed findings were not reproduced through builds or runtime tests, so confirmation here means source-level confirmation rather than end-to-end reproduction.

## Results

The review recorded 39 confirmed findings: 1 critical, 11 high, and 27 medium.
It also recorded 3 inconclusive findings and rejected 1 proposed finding after further inspection.

The main risk themes were:

- recording continuity and preservation of the original audio;
- concurrency, locking, and atomic persistence;
- explicit transcription-language handling;
- privacy boundaries for external text-model endpoints;
- identity evidence and run provenance; and
- recovery from corrupted data, cancellation, and partial failures.

## Confirmed findings

| ID | Severity | Area | Summary |
|---:|---|---|---|
| 1 | Critical | iOS audio | An audio-engine configuration change was not observed, so a route change could leave the UI recording while only silence was written. |
| 2 | High | Audio core | One failed meeting could abort capture recovery for every remaining interrupted meeting. |
| 3 | High | Intelligence | Unchecked HTTP redirects could send a transcript and API key to a host other than the endpoint selected by the user. |
| 4 | High | Intelligence | The macOS app derived the transcription language from `Locale.current` and could not distinguish an inferred language from an explicit choice. |
| 5 | High | iOS | A model installation completed during recording could permanently miss requeuing failed ASR jobs. |
| 6 | High | Library | Person-document read-modify-write operations occurred outside the shared lock and could silently lose voice evidence. |
| 7 | High | macOS | Changing language during recording startup could restart the pipeline and truncate the recording being created. |
| 8 | High | macOS | After a failed stop, live transcript tasks from the previous recording could be written into the next meeting. |
| 9 | High | Pipeline | A cancellation race could use a stale queued status and bypass the `cancellationTooLate` protection for an active job. |
| 10 | High | Transcription | An explicitly selected transcription language could silently fall back to `Locale.current`. |
| 11 | High | Identity | The review flow deleted voice evidence instead of excluding it and could present excluded samples as belonging to a person. |
| 12 | High | Identity | Hard negatives could be rebuilt from evidence that had already been excluded. |
| 13 | Medium | Audio core | A capture original could be deleted before the library copy was durably persisted. |
| 14 | Medium | Audio core | A completely full disk could be treated as unknown capacity and silently ignored by disk monitoring. |
| 15 | Medium | Audio core | Unbounded silence insertion into a fixed-size ring could overflow it and terminate the recording. |
| 16 | Medium | Exchange | Duplicate or missing identifiers in legacy folder configuration could crash the importer. |
| 17 | Medium | Exchange | One corrupt legacy sidecar file could permanently block the entire import. |
| 18 | Medium | Exchange | Snapshot validation could swallow an error without returning a cleanup handle. |
| 19 | Medium | Exchange | Ambiguous cluster keys in legacy speaker data could crash the import. |
| 20 | Medium | Intelligence | The `response_format` fallback could run for any 4xx response and send the complete transcript a second time. |
| 21 | Medium | iOS audio | The cached input format was not invalidated, so a later metering session could install a tap with the previous device format. |
| 22 | Medium | iOS | Metering could continue after leaving the screen, leaving an active audio session and causing a second input-node tap later. |
| 23 | Medium | iOS | Interruptions during the preparing state could be discarded while the app continued to report an active recording. |
| 24 | Medium | Library | Meeting mutations read outside the shared lock and rewrote the complete meeting document. |
| 25 | Medium | Library | After notes failed to load, the first edit could overwrite the existing note. |
| 26 | Medium | Library | `FolderStore` wrote the complete folders document without the library lock. |
| 27 | Medium | Library | Job claiming and transitions ran without the library lock, so the same job could be claimed twice. |
| 28 | Medium | Library | Revision recovery could replay a stale intent over a newer revision pointer. |
| 29 | Medium | macOS | A failed stop could leave a meeting permanently marked as recording and without a final ASR job. |
| 30 | Medium | macOS | A temporary audio clip could remain on disk when player initialization failed. |
| 31 | Medium | macOS | Playback errors from the transcript view were not reported to the user. |
| 32 | Medium | macOS | The pipeline could run with a different transcription language from the one shown in the interface, without a correction path. |
| 33 | Medium | Pipeline | Cancellation could wait indefinitely when the job handler failed to persist a status transition. |
| 34 | Medium | Pipeline | A review action was persisted through separate transactions and could remain partially applied. |
| 35 | Medium | Pipeline | A listening sample selected a track by media kind rather than by the asset used by the originating run. |
| 36 | Medium | Pipeline | Run-chain traversal had unbounded recursion and could overflow the stack when a corrupted or manipulated artifact contained a cycle. |
| 37 | Medium | Diarization | A failed or cancelled installation could disable an otherwise complete and verified model installation. |
| 38 | Medium | Diarization | The mask for the final, shorter audio window was shifted in time relative to the audio. |
| 39 | Medium | Identity | Single-linkage clustering could merge two voices into an unmarked multi-speaker cluster that could later receive a person's name. |

## Inconclusive findings

The source review could neither confirm nor disprove these concerns:

- File synchronization might omit the parent-directory synchronization needed to preserve a new directory entry after sudden power loss.
- A media-clone cleanup error might obscure the original inference error when both inference and cleanup failed.
- Failure of a second `leaseSource()` call might release the exclusivity established by the first lease.

These require a focused code review or runtime reproduction before being treated as defects.

## Rejected finding

The review rejected the claim that revoking model consent allowed all remaining model downloads to continue.
Although the loop had no explicit cancellation check before each download, its asynchronous network operations observed task cancellation and the error path converted that state to `CancellationError` before the remaining downloads continued.

## Review coverage

The review covered the recording core and macOS audio integration, pipeline and artifact handling, transcription, diarization, speaker identity, library persistence, legacy and meeting exchange, external text-model integration, and the macOS and iOS application layers.
It also inspected targeted call sites across subsystem boundaries where needed to trace a failure path.

The review did not exhaustively evaluate third-party dependencies, every test target, or purely visual presentation code.
Detailed file-by-file coverage, code excerpts, correction sketches, and adversarial-review notes were intentionally removed from this summary.
