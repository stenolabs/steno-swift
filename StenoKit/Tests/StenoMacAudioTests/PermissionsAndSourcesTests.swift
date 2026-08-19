@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import StenoAudioCore
import Testing
@testable import StenoMacAudio

@Suite("Permissions and source configuration")
struct PermissionsAndSourcesTests {
    @Test("maps every microphone authorization state without losing restricted")
    func mapsMicrophonePermission() {
        #expect(AudioPermissions.microphoneStatus(from: .notDetermined) == .notDetermined)
        #expect(AudioPermissions.microphoneStatus(from: .restricted) == .restricted)
        #expect(AudioPermissions.microphoneStatus(from: .denied) == .denied)
        #expect(AudioPermissions.microphoneStatus(from: .authorized) == .authorized)
    }

    @Test("several meeting processes using the same microphone produce one automatic match")
    func detectsOneSharedMeetingMicrophone() {
        let airPods = CoreAudioInputDevice(id: 41, uid: "airpods", name: "AirPods")
        let camera = CoreAudioInputDevice(id: 7, uid: "camera", name: "Camera")
        let snapshot = MicrophoneDiscoverySnapshot.make(
            availableDevices: [airPods, camera],
            activeClients: [
                CoreAudioInputClient(
                    processID: 42,
                    bundleIdentifier: "org.steno.Steno",
                    deviceIDs: [7]
                ),
                CoreAudioInputClient(
                    processID: 43,
                    bundleIdentifier: "org.steno.Steno",
                    deviceIDs: [7]
                ),
                CoreAudioInputClient(
                    processID: 100,
                    bundleIdentifier: "com.google.Chrome.helper",
                    deviceIDs: [41]
                ),
                CoreAudioInputClient(
                    processID: 101,
                    bundleIdentifier: "com.google.Chrome",
                    deviceIDs: [41]
                ),
            ],
            excludingProcessID: 42,
            excludingBundleIdentifier: "org.steno.Steno"
        )

        #expect(snapshot.activeDevices == [
            MicrophoneDevice(uid: "airpods", name: "AirPods"),
        ])
        #expect(snapshot.automaticDevice?.uid == "airpods")
        #expect(snapshot.activeClients.count == 2)
        #expect(!snapshot.hasUnresolvedActiveDevices)
    }

    @Test("an unreadable active process route prevents a false automatic match")
    func rejectsUnresolvedMeetingMicrophone() {
        let airPods = CoreAudioInputDevice(id: 41, uid: "airpods", name: "AirPods")
        let snapshot = MicrophoneDiscoverySnapshot.make(
            availableDevices: [airPods],
            activeClients: [
                CoreAudioInputClient(
                    processID: 100,
                    bundleIdentifier: "com.hnc.Discord",
                    deviceIDs: [41],
                    hasUnresolvedDevices: true
                ),
            ]
        )

        #expect(snapshot.activeDevices.map(\.uid) == ["airpods"])
        #expect(snapshot.automaticDevice == nil)
        #expect(snapshot.hasUnresolvedActiveDevices)
    }

    @Test("an active aggregate resolves to its sole physical input")
    func resolvesAggregateMeetingMicrophone() {
        let airPods = CoreAudioInputDevice(id: 41, uid: "airpods", name: "AirPods")
        let aggregate = CoreAudioInputDevice(
            id: 70,
            uid: "default-aggregate",
            name: "Default Device Aggregate",
            isAggregate: true,
            activeInputSubdeviceUIDs: ["airpods"]
        )
        let snapshot = MicrophoneDiscoverySnapshot.make(
            availableDevices: [aggregate, airPods],
            activeClients: [
                CoreAudioInputClient(
                    processID: 100,
                    bundleIdentifier: "com.google.Chrome",
                    deviceIDs: [70]
                ),
            ]
        )

        #expect(snapshot.availableDevices == [
            MicrophoneDevice(uid: "airpods", name: "AirPods"),
        ])
        #expect(snapshot.automaticDevice?.uid == "airpods")
        #expect(!snapshot.hasUnresolvedActiveDevices)
    }

    @Test("an aggregate with several physical inputs is never guessed")
    func rejectsAmbiguousAggregateMeetingMicrophone() {
        let airPods = CoreAudioInputDevice(id: 41, uid: "airpods", name: "AirPods")
        let camera = CoreAudioInputDevice(id: 7, uid: "camera", name: "Camera")
        let aggregate = CoreAudioInputDevice(
            id: 70,
            uid: "default-aggregate",
            name: "Default Device Aggregate",
            isAggregate: true,
            activeInputSubdeviceUIDs: ["airpods", "camera"]
        )
        let snapshot = MicrophoneDiscoverySnapshot.make(
            availableDevices: [aggregate, airPods, camera],
            activeClients: [
                CoreAudioInputClient(
                    processID: 100,
                    bundleIdentifier: "com.google.Chrome",
                    deviceIDs: [70]
                ),
            ]
        )

        #expect(snapshot.automaticDevice == nil)
        #expect(snapshot.hasUnresolvedActiveDevices)
    }

    @Test("a failed client scan never exposes aggregates for manual selection")
    func filtersAggregatesAfterClientScanFailure() {
        let airPods = CoreAudioInputDevice(id: 41, uid: "airpods", name: "AirPods")
        let aggregate = CoreAudioInputDevice(
            id: 70,
            uid: "default-aggregate",
            name: "Default Device Aggregate",
            isAggregate: true,
            activeInputSubdeviceUIDs: ["airpods"]
        )

        let snapshot = MicrophoneDiscoverySnapshot.makeUnresolved(
            availableDevices: [aggregate, airPods]
        )

        #expect(snapshot.availableDevices == [
            MicrophoneDevice(uid: "airpods", name: "AirPods"),
        ])
        #expect(snapshot.hasUnresolvedActiveDevices)
    }

    @Test("unknown active audio clients prevent a meeting microphone guess")
    func rejectsUnknownActiveAudioClients() {
        let airPods = CoreAudioInputDevice(id: 41, uid: "airpods", name: "AirPods")
        let camera = CoreAudioInputDevice(id: 7, uid: "camera", name: "Camera")
        let snapshot = MicrophoneDiscoverySnapshot.make(
            availableDevices: [airPods, camera],
            activeClients: [
                CoreAudioInputClient(
                    processID: 100,
                    bundleIdentifier: "com.google.Chrome",
                    deviceIDs: [41]
                ),
                CoreAudioInputClient(
                    processID: 101,
                    bundleIdentifier: nil,
                    deviceIDs: [7]
                ),
            ]
        )

        #expect(snapshot.automaticDevice == nil)
        #expect(snapshot.hasUnresolvedActiveDevices)
    }

    @Test("a reconnecting physical UID appears only once in the chooser")
    func deduplicatesTransientDeviceIDs() {
        let oldAirPods = CoreAudioInputDevice(
            id: 41,
            uid: "airpods",
            name: "AirPods"
        )
        let newAirPods = CoreAudioInputDevice(
            id: 42,
            uid: "airpods",
            name: "AirPods"
        )
        let snapshot = MicrophoneDiscoverySnapshot.make(
            availableDevices: [oldAirPods, newAirPods],
            activeClients: [
                CoreAudioInputClient(
                    processID: 100,
                    bundleIdentifier: "com.hnc.Discord",
                    deviceIDs: [42]
                ),
            ]
        )

        #expect(snapshot.availableDevices.count == 1)
        #expect(snapshot.automaticDevice?.uid == "airpods")
    }

    @Test("recognizes Core Audio's permission error as denied system audio")
    func recognizesSystemPermissionError() {
        #expect(
            AudioPermissions.systemAudioStatus(forCaptureStatus: nil)
                == .notDetermined
        )
        #expect(
            AudioPermissions.systemAudioStatus(forCaptureStatus: noErr)
                == .authorized
        )
        #expect(
            AudioPermissions.systemAudioStatus(
                forCaptureStatus: kAudioDevicePermissionsError
            ) == .denied
        )
    }

    @Test("the startup permission check resolves microphone and system audio")
    func resolvesRecordingPermissionsAtStartup() async {
        let result = await AudioPermissions.requestRecordingAccess(
            microphone: { .authorized },
            systemAudio: { .status(.denied) }
        )

        #expect(result.microphone == .authorized)
        #expect(result.systemAudio == .denied)
        #expect(result.systemAudioError == nil)
    }

    @Test("an unrelated system audio failure is not presented as a denial")
    func preservesUnknownSystemAudioFailure() async {
        let result = await AudioPermissions.requestRecordingAccess(
            microphone: { .authorized },
            systemAudio: { .failed("device is still changing") }
        )

        #expect(result.systemAudio == .notDetermined)
        #expect(result.systemAudioError == "device is still changing")
    }

    @Test("the system audio permission probe really starts and always stops capture")
    func startsSystemAudioPermissionProbe() async {
        let source = PermissionProbeSource()

        let result = await AudioPermissions.requestSystemAudio(using: source)

        #expect(result == .status(.authorized))
        #expect(await source.calls() == [.prepare, .start, .stop])
    }

    @Test("system audio rebuilds only for a default output change")
    func rebuildsSystemAudioOnlyForDefaultOutput() {
        #expect(SystemAudioRecorder.shouldRebuild(
            after: [kAudioHardwarePropertyDefaultOutputDevice]
        ))
        #expect(!SystemAudioRecorder.shouldRebuild(
            after: [kAudioHardwarePropertyDevices]
        ))
    }

    @Test("a silent system audio reconnect gets two bounded retries")
    func retriesSilentSystemAudioReconnectTwice() {
        var state = SystemAudioReconnectHealthState()

        state.beginDeviceChange()
        #expect(state.evaluate(hasReceivedFrames: false) == .retry)
        #expect(state.evaluate(hasReceivedFrames: false) == .retry)
        #expect(state.evaluate(hasReceivedFrames: false) == .exhausted)

        state.beginDeviceChange()
        #expect(state.evaluate(hasReceivedFrames: true) == .healthy)
        #expect(state.evaluate(hasReceivedFrames: false) == .retry)
    }

    @Test("only a forwarded nonempty system buffer proves capture health")
    func countsOnlyForwardedSystemAudioFrames() {
        let receipt = SystemAudioFrameReceipt()

        #expect(!receipt.hasReceivedFrames)
        receipt.noteForwarded(frameLength: 0)
        #expect(!receipt.hasReceivedFrames)
        receipt.noteForwarded(frameLength: 1)
        #expect(receipt.hasReceivedFrames)
    }

    @Test("a newer system audio task invalidates an already queued task")
    func invalidatesStaleSystemAudioTasks() {
        var generation = SystemAudioTaskGeneration()

        let first = generation.advance()
        let second = generation.advance()

        #expect(!generation.isCurrent(first))
        #expect(generation.isCurrent(second))
        generation.invalidate()
        #expect(!generation.isCurrent(second))
    }

    @Test("initial capture reuses the prepared microphone binding")
    func reusesPreparedMicrophoneBinding() throws {
        let expected = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 24_000,
            channels: 1,
            interleaved: false
        ))
        var bindingCount = 0
        var state = PreparedMicEngineState()

        _ = state.prepare(deviceID: 41) { deviceID in
            #expect(deviceID == 41)
            bindingCount += 1
            return expected
        }
        let startFormat = try state.nativeFormatForStart(deviceID: 41)

        #expect(bindingCount == 1)
        #expect(startFormat.sampleRate == 24_000)
        #expect(startFormat.channelCount == 1)
    }

    @Test("the physical pinned microphone route is accepted directly")
    func acceptsPinnedPhysicalRoute() {
        let route = PinnedEngineInputRoute(
            deviceID: 41,
            deviceUID: "airpods"
        )

        #expect(route.accepts(reportedDeviceID: 41, activeInputUIDs: nil))
    }

    @Test("an aggregate is accepted only when its sole input is the pinned microphone")
    func acceptsOnlyUnambiguousPinnedAggregate() {
        let route = PinnedEngineInputRoute(
            deviceID: 41,
            deviceUID: "airpods"
        )

        #expect(route.accepts(
            reportedDeviceID: 900,
            activeInputUIDs: ["airpods"]
        ))
        #expect(!route.accepts(
            reportedDeviceID: 900,
            activeInputUIDs: ["camera"]
        ))
        #expect(!route.accepts(
            reportedDeviceID: 900,
            activeInputUIDs: ["airpods", "camera"]
        ))
        #expect(!route.accepts(
            reportedDeviceID: 900,
            activeInputUIDs: nil
        ))
    }

    @Test("a running aggregate becomes invalid when Core Audio switches its input")
    func rejectsAggregateInputSwapDuringRecording() {
        let route = PinnedEngineInputRoute(
            deviceID: 41,
            deviceUID: "airpods"
        )

        #expect(route.accepts(
            reportedDeviceID: 900,
            activeInputUIDs: ["airpods"]
        ))
        #expect(!route.accepts(
            reportedDeviceID: 900,
            activeInputUIDs: ["camera"]
        ))
    }

    @Test("the process tap captures the global stereo mix without muting playback")
    func configuresGlobalTap() {
        let uuid = UUID()
        let description = SystemAudioRecorder.makeTapDescription(uuid: uuid)

        #expect(description.uuid == uuid)
        #expect(description.isExclusive)
        #expect(description.isMixdown)
        #expect(!description.isMono)
        #expect(description.isPrivate)
        #expect(description.muteBehavior == .unmuted)
        #expect(description.processes.isEmpty)
    }

    @Test("the private aggregate device includes and auto-starts the tap")
    func configuresAggregateDevice() throws {
        let uuid = UUID()
        let configuration = SystemAudioRecorder.makeAggregateDescription(
            tapUUID: uuid,
            aggregateUID: "org.steno.test.aggregate"
        )

        #expect(configuration[kAudioAggregateDeviceIsPrivateKey] as? Bool == true)
        #expect(configuration[kAudioAggregateDeviceTapAutoStartKey] as? Bool == true)
        let taps = try #require(
            configuration[kAudioAggregateDeviceTapListKey] as? [[String: Any]]
        )
        #expect(taps.count == 1)
        #expect(taps[0][kAudioSubTapUIDKey] as? String == uuid.uuidString)
    }

    @Test("a new default device cannot replace the pinned input")
    func ignoresAnotherDefault() {
        let airPods = CoreAudioInputDevice(id: 41, uid: "airpods", name: "AirPods")
        let camera = CoreAudioInputDevice(id: 7, uid: "camera", name: "Camera")
        var state = PinnedInputDeviceState(device: airPods)

        #expect(state.observe([airPods, camera]) == nil)
        #expect(state.currentDeviceID == 41)
        #expect(state.pinnedUID == "airpods")
    }

    @Test("a protected microphone UID never falls back to the webcam")
    func selectsProtectedMicrophoneOnly() throws {
        let airPods = CoreAudioInputDevice(id: 41, uid: "airpods", name: "AirPods")
        let camera = CoreAudioInputDevice(id: 7, uid: "camera", name: "Camera")

        #expect(try CoreAudioInputDevice.input(
            uid: "airpods",
            from: [camera, airPods]
        ) == airPods)
        #expect(throws: AudioRecordingError.self) {
            try CoreAudioInputDevice.input(uid: "airpods", from: [camera])
        }
    }

    @Test("a protected microphone must keep one device id for a full second")
    func waitsForStableProtectedMicrophone() {
        let start = ContinuousClock.now
        let first = CoreAudioInputDevice(id: 41, uid: "airpods", name: "AirPods")
        let second = CoreAudioInputDevice(id: 42, uid: "airpods", name: "AirPods")
        var state = PreferredInputStabilityState()

        state.observe(first, at: start)
        #expect(state.stableDevice(
            at: start.advanced(by: .milliseconds(999)),
            for: .seconds(1)
        ) == nil)
        state.observe(second, at: start.advanced(by: .seconds(1)))
        #expect(state.stableDevice(
            at: start.advanced(by: .milliseconds(1_999)),
            for: .seconds(1)
        ) == nil)
        #expect(state.stableDevice(
            at: start.advanced(by: .seconds(2)),
            for: .seconds(1)
        ) == second)
    }

    @Test("only the same UID resumes a missing input")
    func resumesOnlyTheSameUID() {
        let airPods = CoreAudioInputDevice(id: 41, uid: "airpods", name: "AirPods")
        let camera = CoreAudioInputDevice(id: 7, uid: "camera", name: "Camera")
        var state = PinnedInputDeviceState(device: airPods)

        #expect(
            state.observe([camera])
                == .unavailable(deviceName: "AirPods")
        )
        #expect(state.observe([camera]) == nil)
        let returned = CoreAudioInputDevice(
            id: 99,
            uid: "airpods",
            name: "AirPods"
        )
        #expect(
            state.observe([camera, returned])
                == .available(deviceName: "AirPods")
        )
        #expect(state.currentDeviceID == 99)
    }

    @Test("a returned input must keep the same device id before reconnect")
    func waitsForStableReturnedDevice() {
        let start = ContinuousClock.now
        let airPods = CoreAudioInputDevice(id: 41, uid: "airpods", name: "AirPods")
        let camera = CoreAudioInputDevice(id: 7, uid: "camera", name: "Camera")
        var state = PinnedInputDeviceState(device: airPods, observedAt: start)

        _ = state.observe([camera], at: start.advanced(by: .seconds(1)))
        let firstReturn = CoreAudioInputDevice(
            id: 99,
            uid: "airpods",
            name: "AirPods"
        )
        _ = state.observe(
            [camera, firstReturn],
            at: start.advanced(by: .seconds(2))
        )
        #expect(!state.isStable(
            at: start.advanced(by: .seconds(2.9)),
            for: .seconds(1)
        ))

        let settledReturn = CoreAudioInputDevice(
            id: 101,
            uid: "airpods",
            name: "AirPods"
        )
        _ = state.observe(
            [camera, settledReturn],
            at: start.advanced(by: .seconds(3))
        )
        #expect(!state.isStable(
            at: start.advanced(by: .seconds(3.9)),
            for: .seconds(1)
        ))
        #expect(state.isStable(
            at: start.advanced(by: .seconds(4)),
            for: .seconds(1)
        ))

        state.markUnstable(at: start.advanced(by: .seconds(5)))
        #expect(!state.isStable(
            at: start.advanced(by: .seconds(5.9)),
            for: .seconds(1)
        ))
        #expect(state.isStable(
            at: start.advanced(by: .seconds(6)),
            for: .seconds(1)
        ))
    }

    @Test("one device return permits three bounded reconnect attempts")
    func limitsReconnectAttempts() {
        var state = ReconnectAttemptState()

        let beforeArm = state.consumeAttempt()
        #expect(!beforeArm)
        state.arm()
        let firstAttempt = state.consumeAttempt()
        let secondAttempt = state.consumeAttempt()
        let thirdAttempt = state.consumeAttempt()
        let exhaustedAttempt = state.consumeAttempt()
        #expect(firstAttempt)
        #expect(secondAttempt)
        #expect(thirdAttempt)
        #expect(!exhaustedAttempt)
        state.arm()
        let newlyArmedAttempt = state.consumeAttempt()
        #expect(newlyArmedAttempt)
    }

    @Test("exhausted reconnect attempts rearm after a quiet cooldown")
    func rearmsReconnectAttemptsAfterCooldown() {
        let start = ContinuousClock.now
        var state = ReconnectAttemptState()

        state.arm()
        let firstAttempt = state.consumeAttempt(at: start)
        let secondAttempt = state.consumeAttempt(at: start)
        let thirdAttempt = state.consumeAttempt(at: start)
        let tooEarly = state.rearmIfExhausted(
            at: start.advanced(by: .seconds(9)),
            after: .seconds(10)
        )
        let afterCooldown = state.rearmIfExhausted(
            at: start.advanced(by: .seconds(10)),
            after: .seconds(10)
        )
        #expect(!tooEarly)
        #expect(afterCooldown)
        let retry = state.consumeAttempt(
            at: start.advanced(by: .seconds(10))
        )
        #expect(firstAttempt)
        #expect(secondAttempt)
        #expect(thirdAttempt)
        #expect(retry)
    }

    @Test("a newer microphone capture invalidates late hardware completion")
    func invalidatesStaleMicrophoneCapture() {
        var generation = MicCaptureGenerationState()

        let first = generation.advance()
        let second = generation.advance()

        #expect(!generation.isCurrent(first))
        #expect(generation.isCurrent(second))
        generation.invalidate()
        #expect(!generation.isCurrent(second))
    }

    @Test("a stale start completion cannot clear a newer start operation")
    func isolatesOverlappingMicrophoneOperations() throws {
        var state = MicRecorderOperationState()
        let oldCaptureID = UUID()
        let newCaptureID = UUID()

        let beganOldStart = state.beginStart(captureID: oldCaptureID)
        let rejectedOverlappingStart = state.beginStart(
            captureID: newCaptureID
        )
        #expect(beganOldStart)
        #expect(!rejectedOverlappingStart)
        state.reset()
        let beganNewStart = state.beginStart(captureID: newCaptureID)
        let staleCompletion = state.finishStart(captureID: oldCaptureID)
        let overlappingPreparation = state.beginPreparation()
        let newCompletion = state.finishStart(captureID: newCaptureID)
        #expect(beganNewStart)
        #expect(!staleCompletion)
        #expect(overlappingPreparation == nil)
        #expect(newCompletion)
        let begunPreparationID = state.beginPreparation()
        let preparationID = try #require(begunPreparationID)
        let preparationFinished = state.finishPreparation(preparationID)
        #expect(preparationFinished)
    }

    @Test("cancelling a superseded rebuild immediately permits another rebuild")
    func clearsSupersededMicrophoneRebuild() {
        var state = MicRebuildState()
        let oldCaptureID = UUID()
        let newCaptureID = UUID()

        let beganOldRebuild = state.begin(captureID: oldCaptureID)
        state.cancel()
        let beganNewRebuild = state.begin(captureID: newCaptureID)
        let staleFinish = state.finish(captureID: oldCaptureID)

        #expect(beganOldRebuild)
        #expect(beganNewRebuild)
        #expect(!staleFinish)
        #expect(state.isActive)
    }

    @Test("the input watchdog emits one transition per silent period")
    func detectsSilentEngineOnce() {
        let start = ContinuousClock.now
        var state = InputLivenessState(startedAt: start)

        #expect(
            state.poll(
                at: start.advanced(by: .seconds(1)),
                timeout: .seconds(2),
                deviceName: "AirPods"
            ) == nil
        )
        #expect(
            state.poll(
                at: start.advanced(by: .seconds(2)),
                timeout: .seconds(2),
                deviceName: "AirPods"
            ) == .unavailable(deviceName: "AirPods")
        )
        #expect(
            state.poll(
                at: start.advanced(by: .seconds(3)),
                timeout: .seconds(2),
                deviceName: "AirPods"
            ) == nil
        )
        #expect(
            state.noteBuffer(
                at: start.advanced(by: .seconds(4)),
                deviceName: "AirPods"
            ) == .available(deviceName: "AirPods")
        )
    }

    @Test("microphone conversion preserves duration in the fixed format")
    func convertsReturnedDeviceFormat() throws {
        let sourceFormat = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 24_000,
            channels: 1,
            interleaved: false
        ))
        let targetFormat = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ))
        let source = try #require(AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: 2_400
        ))
        source.frameLength = 2_400
        let converter = try AudioBufferConverter(
            sourceFormat: sourceFormat,
            targetFormat: targetFormat
        )

        let converted = try #require(converter.convert(source))

        #expect(converted.format == targetFormat)
        #expect(abs(Int(converted.frameLength) - 4_800) <= 1)
    }

    @Test("microphone conversion follows a changed hardware format")
    func convertsAfterHardwareFormatChange() throws {
        let fixedFormat = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 24_000,
            channels: 1,
            interleaved: false
        ))
        let changedHardwareFormat = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ))
        let changedBuffer = try #require(AVAudioPCMBuffer(
            pcmFormat: changedHardwareFormat,
            frameCapacity: 4_096
        ))
        changedBuffer.frameLength = 4_096
        let converter = try AudioBufferConverter(
            sourceFormat: fixedFormat,
            targetFormat: fixedFormat
        )

        let converted = try #require(converter.convert(changedBuffer))

        #expect(converted.format == fixedFormat)
        #expect(abs(Int(converted.frameLength) - 2_048) <= 1)
    }

    @Test("capture stays closed until the pinned input is verified")
    func blocksUnverifiedReplacementInput() {
        let gate = InputCaptureGate(announcesRecovery: true)

        #expect(gate.consume(frameLength: 1) == .drop)
        gate.open()
        #expect(gate.consume(frameLength: 0) == .drop)
        #expect(gate.consume(frameLength: 1) == .acceptAndAnnounceRecovery)
        #expect(gate.consume(frameLength: 1) == .accept)
        #expect(gate.closeIfOpen())
        #expect(!gate.closeIfOpen())
        #expect(gate.consume(frameLength: 1) == .drop)
    }

    @Test("a running capture resumes only the current configuration epoch")
    func resumesCurrentMicrophoneConfiguration() throws {
        let gate = InputCaptureGate(announcesRecovery: true)

        #expect(gate.open())
        let firstChange = gate.configurationChanged()
        let firstEpoch = try #require(firstChange.validationEpoch)
        #expect(gate.isAwaitingConfigurationValidation)
        #expect(gate.consume(frameLength: 1) == .drop)

        let secondChange = gate.configurationChanged()
        let secondEpoch = try #require(secondChange.validationEpoch)
        #expect(secondEpoch != firstEpoch)
        #expect(!gate.resume(configurationEpoch: firstEpoch))
        #expect(!gate.retireSuspension(configurationEpoch: firstEpoch))
        #expect(gate.consume(frameLength: 1) == .drop)
        #expect(gate.resume(configurationEpoch: secondEpoch))
        #expect(!gate.isAwaitingConfigurationValidation)
        #expect(gate.consume(frameLength: 0) == .drop)
        #expect(gate.consume(frameLength: 1) == .acceptAndAnnounceRecovery)
        #expect(gate.consume(frameLength: 1) == .accept)
    }

    @Test("capture opens only for the configuration that was verified")
    func opensOnlyVerifiedMicrophoneConfiguration() {
        let gate = InputCaptureGate(announcesRecovery: true)

        let staleEpoch = gate.configurationEpoch
        #expect(gate.configurationChanged() == .ignore)
        #expect(
            !gate.open(afterVerifyingConfigurationEpoch: staleEpoch)
        )
        let verifiedEpoch = gate.configurationEpoch
        #expect(
            gate.open(afterVerifyingConfigurationEpoch: verifiedEpoch)
        )
        #expect(gate.consume(frameLength: 1) == .acceptAndAnnounceRecovery)
    }

    @Test("retirement wins over a pending configuration validation")
    func preventsResumeAfterRetirement() throws {
        let gate = InputCaptureGate(announcesRecovery: false)

        #expect(gate.open())
        let epoch = try #require(gate.configurationChanged().validationEpoch)
        #expect(gate.retire())
        #expect(!gate.retire())
        #expect(!gate.resume(configurationEpoch: epoch))
        #expect(gate.consume(frameLength: 1) == .drop)
    }

    @Test("the resumed capture must deliver a buffer before its deadline")
    func requiresBufferAfterConfigurationResume() throws {
        let stalledGate = InputCaptureGate(announcesRecovery: false)
        #expect(stalledGate.open())
        let stalledEpoch = try #require(
            stalledGate.configurationChanged().validationEpoch
        )
        #expect(stalledGate.resume(configurationEpoch: stalledEpoch))
        #expect(stalledGate.retireIfNoBuffer(configurationEpoch: stalledEpoch))
        #expect(stalledGate.consume(frameLength: 1) == .drop)

        let liveGate = InputCaptureGate(announcesRecovery: false)
        #expect(liveGate.open())
        let liveEpoch = try #require(
            liveGate.configurationChanged().validationEpoch
        )
        #expect(liveGate.resume(configurationEpoch: liveEpoch))
        #expect(
            liveGate.consume(frameLength: 1) == .acceptAndAnnounceRecovery
        )
        #expect(!liveGate.retireIfNoBuffer(configurationEpoch: liveEpoch))
        #expect(liveGate.consume(frameLength: 1) == .accept)
    }

    @Test("a retired capture stays alive until its asynchronous teardown finishes")
    func retainsCaptureUntilTeardownCompletes() async throws {
        let pool = MicCaptureRetirementPool<FakeRetirementResource>()
        var resource: FakeRetirementResource? = FakeRetirementResource()
        weak let weakResource = resource

        pool.retire(try #require(resource))
        resource = nil

        try await waitUntil { weakResource?.hasStartedTeardown == true }
        #expect(pool.retainedCount == 1)
        #expect(weakResource != nil)

        weakResource?.finishTeardown()
        try await waitUntil { pool.retainedCount == 0 }
        try await waitUntil { weakResource == nil }
    }

    @Test("a late hardware completion cannot override a capture timeout")
    func keepsFirstCaptureResult() async throws {
        let result = MicCaptureResultLatch<Int>()

        result.resolve(.failure(
            AudioRecordingError.audioSourceUnavailable("capture timed out")
        ))
        result.resolve(.success(42))

        await #expect(throws: AudioRecordingError.self) {
            try await result.value()
        }
    }

    @Test("a silent hardware operation returns its timeout fallback")
    func timesOutSilentCaptureResult() async {
        let result = MicCaptureResultLatch<Bool>()

        let value = await result.value(
            timeout: .milliseconds(10),
            fallback: false
        )

        #expect(!value)
        result.resolve(.success(true))
        let settledValue = await result.value(
            timeout: .milliseconds(10),
            fallback: true
        )
        #expect(!settledValue)
    }
}

private final class FakeRetirementResource: MicCaptureRetirementResource,
    @unchecked Sendable {
    let retirementID = UUID()
    private let teardownMayFinish = DispatchSemaphore(value: 0)
    private let queue = DispatchQueue(label: "org.steno.test-mic-retirement")
    private let lock = NSLock()
    private var teardownStarted = false

    var hasStartedTeardown: Bool {
        lock.withLock { teardownStarted }
    }

    func beginRetirement(
        completion: @escaping @Sendable () -> Void
    ) {
        queue.async { [self] in
            lock.withLock { teardownStarted = true }
            teardownMayFinish.wait()
            completion()
        }
    }

    func finishTeardown() {
        teardownMayFinish.signal()
    }
}

private func waitUntil(
    timeout: Duration = .seconds(2),
    condition: @escaping @Sendable () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
        guard clock.now < deadline else {
            throw CocoaError(.coderReadCorrupt)
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

private actor PermissionProbeSource: AudioSource {
    enum Call: Equatable, Sendable {
        case prepare
        case start
        case stop
    }

    nonisolated let track: AudioTrack = .system
    private var recordedCalls: [Call] = []

    func prepare() throws -> AVAudioFormat {
        recordedCalls.append(.prepare)
        return try #require(
            AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)
        )
    }

    func start(bufferHandler: @escaping AudioBufferHandler) {
        recordedCalls.append(.start)
    }

    func stop() {
        recordedCalls.append(.stop)
    }

    func calls() -> [Call] {
        recordedCalls
    }
}
