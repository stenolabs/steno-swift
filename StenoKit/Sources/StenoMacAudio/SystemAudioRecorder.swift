@preconcurrency import AVFAudio
@preconcurrency import CoreAudio
import Dispatch
import Foundation
import StenoAudioCore
import StenoDomain

public actor SystemAudioRecorder: AudioSource {
    public nonisolated let track: AudioTrack = .system

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var format: AVAudioFormat?
    private var currentTapFormat: AVAudioFormat?
    private var bufferHandler: AudioBufferHandler?
    private var converter: AudioBufferConverter?
    private var isRunning = false
    private var deviceListenerInstalled = false
    private var deviceListenerBlock: AudioObjectPropertyListenerBlock?
    private var rebuildTask: Task<Void, Never>?
    private var reconnectWatchdogTask: Task<Void, Never>?
    private var rebuildGeneration = SystemAudioTaskGeneration()
    private var watchdogGeneration = SystemAudioTaskGeneration()
    private var reconnectHealth = SystemAudioReconnectHealthState()
    private let frameReceipt = SystemAudioFrameReceipt()
    private let ioQueue = DispatchQueue(
        label: "org.steno.system-audio-tap",
        qos: .userInteractive
    )

    public init() {}

    public func prepare() throws -> AVAudioFormat {
        guard !isRunning else { throw AudioRecordingError.alreadyRecording }
        cleanup()
        let created = try Self.createTapAndAggregate()
        tapID = created.tapID
        aggregateDeviceID = created.aggregateID
        format = created.format
        currentTapFormat = created.format
        return created.format
    }

    public func start(
        bufferHandler: @escaping AudioBufferHandler
    ) throws {
        guard !isRunning else { throw AudioRecordingError.alreadyRecording }
        guard aggregateDeviceID != kAudioObjectUnknown, format != nil else {
            throw AudioRecordingError.audioSourceUnavailable(
                "system audio was not prepared"
            )
        }
        self.bufferHandler = bufferHandler
        try startIO()
        isRunning = true
        installDefaultOutputDeviceListener()
        scheduleReconnectWatchdog()
    }

    public func stop() {
        cleanup()
    }

    // MARK: - Aufbau

    private static func createTapAndAggregate() throws -> (
        tapID: AudioObjectID,
        aggregateID: AudioObjectID,
        format: AVAudioFormat
    ) {
        let tapUUID = UUID()
        let tapDescription = makeTapDescription(uuid: tapUUID)
        var createdTapID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(
            tapDescription,
            &createdTapID
        )
        try check(tapStatus, operation: "create process tap")

        do {
            var streamDescription = try tapFormat(tapID: createdTapID)
            guard let nativeFormat = AVAudioFormat(
                streamDescription: &streamDescription
            ) else {
                throw AudioRecordingError.audioSourceUnavailable(
                    "the system audio tap reported an invalid format"
                )
            }
            let aggregateUID = "org.steno.system-audio.\(UUID().uuidString)"
            let aggregateDescription = makeAggregateDescription(
                tapUUID: tapUUID,
                aggregateUID: aggregateUID
            )
            var createdAggregateID = AudioObjectID(kAudioObjectUnknown)
            let aggregateStatus = AudioHardwareCreateAggregateDevice(
                aggregateDescription as CFDictionary,
                &createdAggregateID
            )
            try check(aggregateStatus, operation: "create aggregate tap device")
            return (createdTapID, createdAggregateID, nativeFormat)
        } catch {
            AudioHardwareDestroyProcessTap(createdTapID)
            throw error
        }
    }

    private func startIO() throws {
        guard let handlerFormat = format,
              let tapFormat = currentTapFormat,
              let bufferHandler else {
            throw AudioRecordingError.audioSourceUnavailable(
                "system audio was not prepared"
            )
        }
        // Nach einem Geräte-Neuaufbau kann der Tap ein anderes Format
        // liefern als das, worauf der TrackWriter eingeschworen ist; dann
        // wird im IO-Pfad konvertiert statt die Aufnahme abzubrechen.
        let converter = try AudioBufferConverter(
            sourceFormat: tapFormat,
            targetFormat: handlerFormat
        )
        self.converter = converter
        frameReceipt.reset()
        let frameReceipt = frameReceipt

        var createdIOProcID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcIDWithBlock(
            &createdIOProcID,
            aggregateDeviceID,
            ioQueue
        ) { _, inputData, _, _, _ in
            let borrowed = AVAudioPCMBuffer(
                pcmFormat: tapFormat,
                bufferListNoCopy: inputData,
                deallocator: nil
            )
            guard let borrowed else { return }
            borrowed.frameLength = borrowed.frameCapacity
            guard let converted = converter.convert(borrowed) else { return }
            guard converted.frameLength > 0 else { return }
            bufferHandler(converted)
            frameReceipt.noteForwarded(frameLength: converted.frameLength)
        }
        try Self.check(createStatus, operation: "create aggregate IO callback")
        ioProcID = createdIOProcID

        do {
            let startStatus = AudioDeviceStart(aggregateDeviceID, ioProcID)
            try Self.check(startStatus, operation: "start aggregate tap device")
        } catch {
            if let ioProcID {
                AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            }
            self.ioProcID = nil
            throw error
        }
    }

    // MARK: - Gerätewechsel

    /// Der globale Mixdown-Tap liefert nur zuverlässig, was zur beim Aufbau
    /// aktiven Geräte-Situation gehört. Ein Wechsel des Standard-Ausgabegeräts
    /// baut ihn deshalb neu auf. Die gesamte Geräteliste wird absichtlich nicht
    /// beobachtet: Stenos privates Aggregat und Mikrofon-Routenwechsel verändern
    /// sie ebenfalls und würden zwei CoreAudio-Regelkreise miteinander koppeln.
    static let watchedHardwareSelectors: [AudioObjectPropertySelector] = [
        kAudioHardwarePropertyDefaultOutputDevice,
    ]

    private func installDefaultOutputDeviceListener() {
        guard !deviceListenerInstalled else { return }
        let block: AudioObjectPropertyListenerBlock = {
            [weak self] count, addresses in
            let selectors = (0..<Int(count)).map {
                addresses[$0].mSelector
            }
            Task { await self?.hardwarePropertiesDidChange(selectors) }
        }
        var installed = false
        for selector in Self.watchedHardwareSelectors {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            if AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                ioQueue,
                block
            ) == noErr {
                installed = true
            }
        }
        if installed {
            deviceListenerInstalled = true
            deviceListenerBlock = block
        }
    }

    private func removeDefaultOutputDeviceListener() {
        guard deviceListenerInstalled, let deviceListenerBlock else { return }
        for selector in Self.watchedHardwareSelectors {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                ioQueue,
                deviceListenerBlock
            )
        }
        deviceListenerInstalled = false
        self.deviceListenerBlock = nil
    }

    private func hardwarePropertiesDidChange(
        _ selectors: [AudioObjectPropertySelector]
    ) {
        guard isRunning else { return }
        guard Self.shouldRebuild(after: selectors) else { return }
        reconnectHealth.beginDeviceChange()
        scheduleRebuild()
    }

    static func shouldRebuild(
        after selectors: [AudioObjectPropertySelector]
    ) -> Bool {
        selectors.contains(kAudioHardwarePropertyDefaultOutputDevice)
    }

    private func scheduleRebuild() {
        cancelReconnectWatchdog()
        rebuildTask?.cancel()
        let generation = rebuildGeneration.advance()
        rebuildTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                await self?.performRebuild(
                    attemptsRemaining: 3,
                    generation: generation
                )
            } catch {
                return
            }
        }
    }

    private func performRebuild(
        attemptsRemaining: Int,
        generation: UInt64
    ) {
        guard isRunning,
              attemptsRemaining > 0,
              rebuildGeneration.isCurrent(generation) else { return }
        teardownIOAndTap()
        do {
            let created = try Self.createTapAndAggregate()
            tapID = created.tapID
            aggregateDeviceID = created.aggregateID
            currentTapFormat = created.format
            try startIO()
            rebuildTask = nil
            scheduleReconnectWatchdog()
        } catch {
            teardownIOAndTap()
            guard attemptsRemaining > 1 else {
                rebuildTask = nil
                return
            }
            rebuildTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    await self?.performRebuild(
                        attemptsRemaining: attemptsRemaining - 1,
                        generation: generation
                    )
                } catch {
                    return
                }
            }
        }
    }

    private func scheduleReconnectWatchdog() {
        reconnectWatchdogTask?.cancel()
        let generation = watchdogGeneration.advance()
        reconnectWatchdogTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                await self?.evaluateReconnectHealth(generation: generation)
            } catch {
                return
            }
        }
    }

    private func evaluateReconnectHealth(generation: UInt64) {
        guard isRunning,
              watchdogGeneration.isCurrent(generation) else { return }
        reconnectWatchdogTask = nil
        switch reconnectHealth.evaluate(
            hasReceivedFrames: frameReceipt.hasReceivedFrames
        ) {
        case .healthy, .exhausted:
            frameReceipt.reset()
            scheduleReconnectWatchdog()
        case .retry:
            rebuildTask?.cancel()
            let generation = rebuildGeneration.advance()
            performRebuild(
                attemptsRemaining: 3,
                generation: generation
            )
        }
    }

    private func cancelReconnectWatchdog() {
        reconnectWatchdogTask?.cancel()
        reconnectWatchdogTask = nil
        watchdogGeneration.invalidate()
    }

    // MARK: - Abbau

    private func teardownIOAndTap() {
        if aggregateDeviceID != kAudioObjectUnknown, ioProcID != nil {
            AudioDeviceStop(aggregateDeviceID, ioProcID)
        }
        if let ioProcID, aggregateDeviceID != kAudioObjectUnknown {
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
        }
        ioProcID = nil
        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
        converter = nil
    }

    private func cleanup() {
        rebuildTask?.cancel()
        rebuildTask = nil
        rebuildGeneration.invalidate()
        cancelReconnectWatchdog()
        removeDefaultOutputDeviceListener()
        teardownIOAndTap()
        isRunning = false
        bufferHandler = nil
        format = nil
        currentTapFormat = nil
        reconnectHealth = SystemAudioReconnectHealthState()
        frameReceipt.reset()
    }

    // MARK: - Beschreibungen und Hilfen

    static func makeTapDescription(uuid: UUID) -> CATapDescription {
        let description = CATapDescription(
            stereoGlobalTapButExcludeProcesses: []
        )
        description.name = "Steno System Audio"
        description.uuid = uuid
        description.isPrivate = true
        description.muteBehavior = .unmuted
        return description
    }

    static func makeAggregateDescription(
        tapUUID: UUID,
        aggregateUID: String
    ) -> [String: Any] {
        [
            kAudioAggregateDeviceNameKey: "Steno System Audio",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapUUID.uuidString],
            ],
        ]
    }

    private static func tapFormat(
        tapID: AudioObjectID
    ) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(
            tapID,
            &address,
            0,
            nil,
            &size,
            &format
        )
        try check(status, operation: "read process tap format")
        return format
    }

    private static func check(_ status: OSStatus, operation: String) throws {
        guard status != noErr else { return }
        if status == kAudioDevicePermissionsError {
            throw AudioRecordingError.systemAudioPermissionDenied
        }
        throw AudioRecordingError.coreAudio(
            operation: operation,
            status: status
        )
    }
}

enum SystemAudioReconnectHealthAction: Equatable, Sendable {
    case healthy
    case retry
    case exhausted
}

struct SystemAudioReconnectHealthState: Sendable {
    private static let maximumRetries = 2
    private var retryCount = 0

    mutating func beginDeviceChange() {
        retryCount = 0
    }

    mutating func evaluate(
        hasReceivedFrames: Bool
    ) -> SystemAudioReconnectHealthAction {
        if hasReceivedFrames {
            retryCount = 0
            return .healthy
        }
        guard retryCount < Self.maximumRetries else { return .exhausted }
        retryCount += 1
        return .retry
    }
}

struct SystemAudioTaskGeneration: Sendable {
    private var value: UInt64 = 0

    mutating func advance() -> UInt64 {
        value &+= 1
        return value
    }

    mutating func invalidate() {
        value &+= 1
    }

    func isCurrent(_ candidate: UInt64) -> Bool {
        candidate == value
    }
}

final class SystemAudioFrameReceipt: @unchecked Sendable {
    private let lock = NSLock()
    private var received = false

    var hasReceivedFrames: Bool {
        lock.withLock { received }
    }

    func noteForwarded(frameLength: AVAudioFrameCount) {
        guard frameLength > 0 else { return }
        lock.withLock { received = true }
    }

    func reset() {
        lock.withLock { received = false }
    }
}
