# Mikrofonkontinuität und Pause Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eine laufende Aufnahme behält bei Mikrofonverlust und manueller Mikrofonpause eine synchrone, stille Mikrofonspur und setzt nur dasselbe zurückgekehrte Gerät automatisch fort.

**Architecture:** Eine neue `TrackContinuity`-Instanz pro Spur serialisiert Echtdaten, stille Zeitachsenfüllung und Live-Lückenereignisse gegen eine monotone Sessionuhr.
`MicRecorder` pinnt die beim Start verwendete CoreAudio-UID, meldet Verfügbarkeit und baut nur dieses Gerät neu auf.
Die macOS-App zeigt den Zustand, steuert die Benutzerpause und segmentiert das Livetranskript an Lückengrenzen.

**Tech Stack:** Swift 6.3, Swift Concurrency, AVFAudio, CoreAudio, Swift Testing, SwiftUI, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-08-15-mikrofonkontinuitaet-und-pause-design.md`

## Global Constraints

- Aufnahmepräfixe und registrierte Originale werden niemals überschrieben.
- Ein fehlendes Sprachmodell oder ein Live-ASR-Fehler beendet keine Aufnahme.
- Nur dieselbe persistente CoreAudio-Geräte-UID darf automatisch fortgesetzt werden.
- Ein anderes Standardmikrofon wird während einer Aufnahme niemals automatisch verwendet.
- Manuelle Pause wird nur durch eine ausdrückliche Benutzeraktion aufgehoben.
- Synthetische Stille geht ausschließlich zum Writer, nie zum Speech-Provider.
- Die iOS-Unterbrechungspolitik bleibt bis zu einem eigenen Hardwaretest unverändert.
- Nach jeder Änderung im gemeinsamen Kern laufen macOS-Build, iOS-Build und die vollständigen StenoKit-Tests.
- Keine neue Abhängigkeit.

---

### Task 1: Kontinuitätsverträge und stille Spurzeitachse

**Files:**
- Create: `StenoKit/Sources/StenoAudioCore/TrackContinuity.swift`
- Create: `StenoKit/Sources/StenoAudioCore/LiveAudioEvent.swift`
- Create: `StenoKit/Tests/StenoAudioCoreTests/TrackContinuityTests.swift`
- Modify: `StenoKit/Sources/StenoAudioCore/AudioBufferTransfer.swift`

**Interfaces:**
- Consumes: `AudioBufferTransfer.copy(_:)`, `AudioTrack`, `AudioLevels`.
- Produces: `TrackContinuity`, `TrackGapReason`, `RecordingTrackStatus`, `LiveAudioEvent`, `LiveAudioEventStream`, `OwnedAudioBuffer`.

- [ ] **Step 1: Write failing continuity tests**

Add tests with a fixed `ContinuousClock.Instant` and an 8-kHz mono fixture.
The first test sends 4,000 real frames at `t = 0`, pauses at `t = 0.5`, ticks at `t = 1.5`, resumes and finishes at `t = 2.0`.
Assert literal totals: 4,000 real frames plus 12,000 silent frames equals 16,000 writer frames, while the live stream contains one real buffer and gap events but no silent buffer.

```swift
@Test("a manual pause fills only the writer timeline with silence")
func manualPauseFillsWriterOnly() async throws {
    let fixture = ContinuityFixture(sampleRate: 8_000)
    await fixture.timeline.receive(
        syntheticBuffer(frames: 4_000, amplitude: 0.5),
        at: fixture.start
    )
    await fixture.timeline.setUserPaused(true, at: fixture.start + .milliseconds(500))
    await fixture.timeline.tick(at: fixture.start + .milliseconds(1_500))
    await fixture.timeline.setUserPaused(false, at: fixture.start + .milliseconds(1_500))
    await fixture.timeline.finish(at: fixture.start + .seconds(2))

    #expect(await fixture.writerFrameCount() == 16_000)
    #expect(await fixture.liveBufferCount() == 1)
    #expect(await fixture.gapReasons() == [.userPaused])
}
```

Add separate tests for overlapping user pause and device loss, a silent watchdog stall, bounded silence chunks, stop during a gap and no automatic clearing of `userPaused`.

- [ ] **Step 2: Run the new test suite and verify RED**

Run:

```bash
swift test --package-path StenoKit --filter TrackContinuityTests
```

Expected: compilation fails because `TrackContinuity` and its contracts do not exist.

- [ ] **Step 3: Implement the minimal contracts**

Define an owned buffer wrapper and event stream.

```swift
public struct OwnedAudioBuffer: @unchecked Sendable {
    public let buffer: AVAudioPCMBuffer
}

public enum TrackGapReason: Equatable, Sendable {
    case deviceUnavailable
    case userPaused
    case sourceStalled
}

public enum LiveAudioEvent: Sendable {
    case buffer(OwnedAudioBuffer)
    case gapStarted(at: TimeInterval, reason: TrackGapReason)
    case gapEnded(at: TimeInterval)
}

public struct LiveAudioEventStream: @unchecked Sendable {
    public let stream: AsyncStream<LiveAudioEvent>
}
```

Implement `RecordingTrackStatus` with independent `deviceAvailable`, `userPaused` and `sourceStalled` fields.

Implement `TrackContinuity` as an actor.
It stores the fixed format, the session start instant, writer and live continuations, written frame count, last source callback instant and a maximum silence block of 250 milliseconds.
`fillSilence(until:)` converts elapsed host duration to a literal target frame count, creates zeroed `AVAudioPCMBuffer` blocks and yields them only to the writer continuation.
Every yield result of `.dropped` invokes the supplied overflow callback.

`receive(_:at:)` updates source liveness even while paused, discards real input while any gap reason is active, ends a watchdog gap on the first healthy buffer and copies only real input to the live continuation.
`finish(at:)` fills to the stop instant, finishes both continuations once and ignores later input.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run:

```bash
swift test --package-path StenoKit --filter TrackContinuityTests
```

Expected: every `TrackContinuityTests` test passes with no warning introduced by these files.

- [ ] **Step 5: Commit Task 1**

```bash
git add StenoKit/Sources/StenoAudioCore/TrackContinuity.swift \
  StenoKit/Sources/StenoAudioCore/LiveAudioEvent.swift \
  StenoKit/Sources/StenoAudioCore/AudioBufferTransfer.swift \
  StenoKit/Tests/StenoAudioCoreTests/TrackContinuityTests.swift
git commit -m "feat(core): Audio-Zeitachsen kontinuierlich halten"
```

### Task 2: Quellenereignisse und RecordingSession integrieren

**Files:**
- Modify: `StenoKit/Sources/StenoAudioCore/AudioSource.swift`
- Modify: `StenoKit/Sources/StenoAudioCore/RecordingSession.swift`
- Modify: `StenoKit/Tests/StenoAudioCoreTests/RecordingSessionTests.swift`

**Interfaces:**
- Consumes: `TrackContinuity`, `RecordingTrackStatus`, `LiveAudioEventStream` from Task 1.
- Produces: `AudioSourceEvent`, event-aware `AudioSource.start`, `RecordingSession.setPaused(_:for:)`, `RecordingSession.status(for:)`, `RecordingSession.liveAudioEvents(for:)`.

- [ ] **Step 1: Write failing session tests**

Extend `FakeAudioSource` with an event handler and an `emit(_:)` method for source events.
Add one test that records both sources with a 5-millisecond injected continuity tick interval, emits `.unavailable` for the microphone, waits until the status reflects the transition, emits `.available`, writes another microphone buffer and stops.
Assert that both media assets differ by at most one test-buffer duration and that the live microphone stream has no buffer between gap start and gap end.
The exact silent-frame arithmetic remains covered deterministically by `TrackContinuityTests` with explicit clock instants.

Add a second test proving that `setPaused(true, for: .microphone)` leaves system buffers untouched and that `.available` cannot clear the pause.

- [ ] **Step 2: Run RecordingSession tests and verify RED**

Run:

```bash
swift test --package-path StenoKit --filter RecordingSessionTests
```

Expected: compilation fails on missing `AudioSourceEvent`, `setPaused` and `liveAudioEvents`.

- [ ] **Step 3: Extend the source contract compatibly**

```swift
public enum AudioSourceEvent: Equatable, Sendable {
    case unavailable(deviceName: String?)
    case available(deviceName: String?)
}

public typealias AudioSourceEventHandler = @Sendable (AudioSourceEvent) -> Void

public protocol AudioSource: Sendable {
    var track: AudioTrack { get }
    func prepare() async throws -> AVAudioFormat
    func start(bufferHandler: @escaping AudioBufferHandler) async throws
    func start(
        bufferHandler: @escaping AudioBufferHandler,
        eventHandler: @escaping AudioSourceEventHandler
    ) async throws
    func stop() async
}

extension AudioSource {
    public func start(
        bufferHandler: @escaping AudioBufferHandler,
        eventHandler: @escaping AudioSourceEventHandler
    ) async throws {
        try await start(bufferHandler: bufferHandler)
    }
}
```

The default implementation preserves iOS and simple fake sources until they need events.

- [ ] **Step 4: Route every session track through TrackContinuity**

Replace the direct writer and live continuations in `TrackPipeline` with a `TrackContinuity` reference plus its two bounded streams.
Capture one `ContinuousClock.Instant` immediately before source startup.
Stamp each source callback with `ContinuousClock.now` and call `timeline.receive` through a per-track serial ingestion task.

Add an internal `continuityTickInterval` initializer parameter with a production default of 100 milliseconds.
Tests pass 5 milliseconds and wait on observable status instead of asserting scheduler timing as an exact sample count.

Start one 100-millisecond continuity task for the session.
It calls `tick(at:)` for every track and is cancelled before finalization.
Source events call `setDeviceAvailable(_:deviceName:at:)` on the matching timeline.

Expose:

```swift
public func setPaused(_ paused: Bool, for track: AudioTrack) async
public func status(for track: AudioTrack) async -> RecordingTrackStatus?
public func liveAudioEvents(for track: AudioTrack) throws -> LiveAudioEventStream
```

Keep `liveAudio(for:)` only until both apps are migrated in Task 3, then remove it and its old `AudioBufferStream` wrapper.

- [ ] **Step 5: Run core session tests and verify GREEN**

Run:

```bash
swift test --package-path StenoKit --filter 'TrackContinuityTests|RecordingSessionTests'
```

Expected: continuity and recording-session suites pass.

- [ ] **Step 6: Commit Task 2**

```bash
git add StenoKit/Sources/StenoAudioCore/AudioSource.swift \
  StenoKit/Sources/StenoAudioCore/RecordingSession.swift \
  StenoKit/Tests/StenoAudioCoreTests/RecordingSessionTests.swift
git commit -m "feat(core): Quellenlücken in Aufnahmespuren füllen"
```

### Task 3: Livetranskription an Lücken segmentieren

**Files:**
- Modify: `StenoKit/Sources/StenoTranscription/TranscriptionModels.swift`
- Modify: `StenoKit/Tests/StenoTranscriptionTests/LiveTranscriptionTests.swift`
- Modify: `App/Sources/AppModel.swift`
- Modify: `iOS/App/Sources/RecordingModel.swift`
- Modify: `iOS/App/Tests/RecordingFinalizerTests.swift`

**Interfaces:**
- Consumes: `LiveAudioEventStream` and `TrackGapReason` from Task 1.
- Produces: `TranscriptOutput.shifted(by:)` and gap-aware live-session loops in both apps.

- [ ] **Step 1: Write failing timestamp-shift and segmentation tests**

Add a literal `TranscriptOutput` with one block and two words at 0.5, 1.0 and 1.5 seconds.
Assert that `shifted(by: 20)` produces 20.5, 21.0 and 21.5 without changing text, locale or channel.

Extend the iOS recording finalizer fixture with a live event sequence containing a buffer segment, a gap from 1 to 11 seconds and a second segment.
Assert that no buffer is appended while the gap is active and the second output starts at 11 seconds or later.

- [ ] **Step 2: Run focused tests and verify RED**

Run:

```bash
swift test --package-path StenoKit --filter LiveTranscriptionTests
cd iOS && xcodegen generate --quiet && xcodebuild -project StenoiOS.xcodeproj \
  -scheme Steno -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:StenoTests/RecordingFinalizerTests test
```

Expected: missing `shifted(by:)` and unhandled live-event cases fail.

- [ ] **Step 3: Implement immutable output shifting**

Add `TranscriptOutput.shifted(by:)` that reconstructs every block and word with the same text and adds a nonnegative offset to all times.
Never mutate stored revisions.

- [ ] **Step 4: Replace both app live loops with event-aware segmentation**

For each track, keep one optional live provider session, one optional event task, a segment offset and an array of finished outputs.

- On `.buffer`, lazily create the provider session and append the real buffer.
- On `.gapStarted`, finish the current provider session, await its event task, shift its output and clear volatile text.
- On `.gapEnded(at:)`, store that meeting-time offset for the next provider session.
- At end-of-stream, finish the last segment and return all shifted outputs.

Shift volatile and final `TranscriptionEvent` values before publishing them to the UI.
Do not create a provider session from a gap event.

- [ ] **Step 5: Remove the obsolete raw AudioBufferStream API**

Delete `AudioBufferStream` after macOS, iOS and tests use `LiveAudioEventStream` exclusively.
Keep `AudioBufferTransfer.copy(_:)` as the one ownership boundary for AVFoundation buffers.

- [ ] **Step 6: Run core and focused app tests and verify GREEN**

Run:

```bash
swift test --package-path StenoKit --filter 'LiveTranscriptionTests|RecordingSessionTests|TrackContinuityTests'
cd iOS && xcodebuild -project StenoiOS.xcodeproj -scheme Steno \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:StenoTests/RecordingFinalizerTests test
```

Expected: all selected tests pass and no silence reaches a live provider fixture.

- [ ] **Step 7: Commit Task 3**

```bash
git add StenoKit/Sources/StenoTranscription/TranscriptionModels.swift \
  StenoKit/Sources/StenoAudioCore/AudioBufferTransfer.swift \
  StenoKit/Tests/StenoTranscriptionTests/LiveTranscriptionTests.swift \
  App/Sources/AppModel.swift iOS/App/Sources/RecordingModel.swift \
  iOS/App/Tests/RecordingFinalizerTests.swift
git commit -m "feat: Livetranskripte über Aufnahmelücken segmentieren"
```

### Task 4: macOS-Mikrofon an eine persistente Geräte-UID pinnen

**Files:**
- Create: `StenoKit/Sources/StenoMacAudio/CoreAudioInputDevice.swift`
- Create: `StenoKit/Sources/StenoMacAudio/AudioBufferConverter.swift`
- Modify: `StenoKit/Sources/StenoMacAudio/MicRecorder.swift`
- Modify: `StenoKit/Sources/StenoMacAudio/SystemAudioRecorder.swift`
- Modify: `StenoKit/Tests/StenoMacAudioTests/PermissionsAndSourcesTests.swift`

**Interfaces:**
- Consumes: event-aware `AudioSource.start` from Task 2.
- Produces: `CoreAudioInputDevice`, `PinnedInputDeviceState`, `InputLivenessState`, shared `AudioBufferConverter`, UID-basiertes `MicRecorder`-Rebuild.

- [ ] **Step 1: Write failing UID lifecycle tests**

Use literal devices `airpods(uid: "airpods", id: 41)` and `camera(uid: "camera", id: 7)`.

```swift
@Test("a new default device cannot replace the pinned input")
func ignoresAnotherDefault() {
    var state = PinnedInputDeviceState(device: airpods)
    #expect(state.observe([airpods, camera]) == nil)
    #expect(state.currentDeviceID == 41)
}

@Test("only the same UID resumes a missing input")
func resumesOnlyTheSameUID() {
    var state = PinnedInputDeviceState(device: airpods)
    #expect(state.observe([camera]) == .unavailable(deviceName: airpods.name))
    #expect(state.observe([camera]) == nil)
    let returned = CoreAudioInputDevice(id: 99, uid: "airpods", name: airpods.name)
    #expect(state.observe([camera, returned]) == .available(deviceName: airpods.name))
    #expect(state.currentDeviceID == 99)
}
```

Add a pure liveness test with literal monotonic instants.
It asserts that a healthy callback clears the stall, two seconds without a callback emits one unavailable transition and further watchdog polls remain quiet until the next real buffer or rebuild.

Add a converter test that feeds a 24-kHz mono fixture into a fixed 48-kHz mono output format and asserts that the output format remains fixed and the frame duration is preserved within one frame.

- [ ] **Step 2: Run StenoMacAudio tests and verify RED**

Run:

```bash
swift test --package-path StenoKit --filter PermissionsAndSourcesTests
```

Expected: compilation fails because the input-device types do not exist.

- [ ] **Step 3: Implement CoreAudio device lookup and pure lifecycle state**

Read the default input with `kAudioHardwarePropertyDefaultInputDevice`.
Read persistent UID with `kAudioDevicePropertyDeviceUID`, visible name with `kAudioObjectPropertyName` and current devices with `kAudioHardwarePropertyDevices`.

`PinnedInputDeviceState.observe(_:)` compares only UID.
It emits each unavailable or available transition once and adopts a new transient `AudioDeviceID` only when the UID matches.

`InputLivenessState` owns only monotonic callback and transition bookkeeping.
It is independent of CoreAudio so the one-shot watchdog behavior can be tested without hardware.

Extract the existing converter logic from `SystemAudioRecorder` into `AudioBufferConverter` and reuse it for both system and microphone sources.

- [ ] **Step 4: Pin and rebuild MicRecorder**

Before reading `inputNode.outputFormat`, set `kAudioOutputUnitProperty_CurrentDevice` on the input node audio unit to the pinned device ID.
Store the first successful native format as the immutable handler format.

Install a global device-list listener while running.
When `PinnedInputDeviceState` becomes unavailable, stop and discard the current engine tap, emit `.unavailable` and retry lookup without switching UID.
When the same UID returns, construct a fresh engine, pin it, install a native-format tap and convert buffers into the immutable handler format before invoking the buffer handler.

Add a one-second watchdog that treats a running engine without callbacks as unavailable and retries the same UID.
Cancel the watchdog and remove CoreAudio listeners in every stop and failed-start path.

- [ ] **Step 5: Run StenoMacAudio and core recording tests and verify GREEN**

Run:

```bash
swift test --package-path StenoKit --filter 'PermissionsAndSourcesTests|RecordingSessionTests|TrackContinuityTests'
```

Expected: selected suites pass.

- [ ] **Step 6: Commit Task 4**

```bash
git add StenoKit/Sources/StenoMacAudio/CoreAudioInputDevice.swift \
  StenoKit/Sources/StenoMacAudio/AudioBufferConverter.swift \
  StenoKit/Sources/StenoMacAudio/MicRecorder.swift \
  StenoKit/Sources/StenoMacAudio/SystemAudioRecorder.swift \
  StenoKit/Tests/StenoMacAudioTests/PermissionsAndSourcesTests.swift
git commit -m "fix(mac): Aufnahmemikrofon an Geräte-UID binden"
```

### Task 5: macOS-Pause, Status und sicherer Sessionnachlauf

**Files:**
- Modify: `App/Sources/AppModel.swift`
- Modify: `App/Sources/RecordingView.swift`
- Create: `App/Tests/RecordingTrackPresentationTests.swift`

**Interfaces:**
- Consumes: `RecordingSession.setPaused`, `RecordingSession.status`, `RecordingTrackStatus`.
- Produces: `AppModel.microphoneStatus`, `AppModel.setMicrophonePaused(_:)`, sichtbare Pause- und Recovery-Steuerung.

- [ ] **Step 1: Write failing presentation tests**

Add pure presentation tests for these literal states:

- Healthy and not paused returns action title `Pause microphone` and no warning.
- User-paused returns `Resume microphone` and `Microphone paused. System audio continues.`.
- Device missing returns no resume action and `AirPods disconnected. The microphone track is paused; system audio continues.`.
- Device returned while user-paused remains paused.

- [ ] **Step 2: Generate the macOS project and verify RED**

Run:

```bash
xcodegen generate
xcodebuild -project Steno.xcodeproj -scheme Steno -destination 'platform=macOS' \
  -only-testing:StenoTests/RecordingTrackPresentationTests test
```

Expected: missing presentation API fails compilation.

- [ ] **Step 3: Observe session and track state in AppModel**

Extend `startLevelPolling` to fetch `session.state`, levels and microphone status on every tick.
If the exact current session becomes terminal, call the existing complete `stopRecording()` path once.

Compare old and new microphone status.
Report one global notice on transition to device unavailable and one on automatic recovery.
Do not report automatic recovery while `userPaused` remains true.

Expose:

```swift
func setMicrophonePaused(_ paused: Bool) async {
    guard let session, isRecording else { return }
    await session.setPaused(paused, for: .microphone)
}
```

- [ ] **Step 4: Add the pause control to RecordingView**

Place the control beside the microphone meter without moving or hiding the stop action.
Use `pause.circle` while healthy and `play.circle` while manually paused.
Disable resume while the device is unavailable.
Show the device-loss or manual-pause explanation directly below the header.

- [ ] **Step 5: Run macOS tests and build**

Run:

```bash
xcodegen generate
xcodebuild -project Steno.xcodeproj -scheme Steno -destination 'platform=macOS' test
scripts/build-app.sh
```

Expected: macOS app tests pass and the app build succeeds.

- [ ] **Step 6: Commit Task 5**

```bash
git add App/Sources/AppModel.swift App/Sources/RecordingView.swift \
  App/Tests/RecordingTrackPresentationTests.swift
git commit -m "feat(mac): Mikrofonspur pausieren und automatisch heilen"
```

### Task 6: Vollständige plattformübergreifende Abnahme

**Files:**
- Modify only files required by failures caused by Tasks 1 through 5.
- Do not modify `CHANGELOG.md`.

**Interfaces:**
- Consumes: all preceding task deliverables.
- Produces: verified macOS and iOS builds, complete test evidence and a runnable isolated macOS build for the hardware retest.

- [ ] **Step 1: Run formatting and diff checks**

```bash
git diff --check
git status --short
```

Expected: no whitespace error and only task files plus the untouched `UEBERGABE-sprecher-erkenntnisse.md` are present.

- [ ] **Step 2: Run the complete required core chain**

```bash
swift test --package-path StenoKit
xcodegen generate
scripts/build-app.sh
scripts/build-ios.sh
```

Expected: all StenoKit tests and both app builds pass.

- [ ] **Step 3: Run complete app and iOS-kit suites**

```bash
xcodebuild -project Steno.xcodeproj -scheme Steno -destination 'platform=macOS' test
cd iOS && xcodegen generate --quiet && xcodebuild -project StenoiOS.xcodeproj \
  -scheme Steno -destination 'platform=iOS Simulator,name=iPhone 17' test
cd iOS/StenoiOSKit && xcodebuild -scheme StenoiOSKit \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
```

Expected: every suite passes.

- [ ] **Step 4: Review requirements and implementation range**

Compare the complete diff against the spec invariants.
Verify specifically that silence has no route into a live provider, another default UID cannot replace the pinned input, manual pause survives device return and both apps still finalize a live revision plus one final ASR job.

- [ ] **Step 5: Build the isolated hardware-retest bundle**

Retain one current `.build/DerivedData/Build/Products/Debug/steno-macos.app`.
Prepare a fresh `/private/tmp/steno-airpods-continuity.*` library only when the operator is available for the physical reconnect steps.
Do not claim hardware success before that run.

- [ ] **Step 6: Commit final verified corrections if any**

Stage only files changed to correct failures caused by this plan.

```bash
git commit -m "test: Mikrofonkontinuität plattformübergreifend absichern"
```

Skip this commit when verification required no correction.
