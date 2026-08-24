@preconcurrency import AVFAudio
import Foundation
import StenoDomain
import StenoLibrary

public enum RecordingSessionState: Equatable, Sendable {
    case idle
    case starting
    case recording
    case stopping
    case stopped
    case failed

    public var isTerminal: Bool {
        self == .stopped || self == .failed
    }
}

public enum RecordingStopReason: Equatable, Sendable {
    case requested
    case lowDiskSpace
    case writerFailure(AudioTrack)
    case ringBufferOverflow(AudioTrack)
    case diskSpaceMonitoringFailure
}

public struct RecordingResult: Sendable {
    public let assets: [AudioTrack: MediaAsset]
    public let stopReason: RecordingStopReason

    public init(
        assets: [AudioTrack: MediaAsset],
        stopReason: RecordingStopReason
    ) {
        self.assets = assets
        self.stopReason = stopReason
    }
}

public typealias TrackWriterFactory = @Sendable (
    _ url: URL,
    _ sourceFormat: AVAudioFormat
) throws -> any AudioTrackWriting

public actor RecordingSession {
    public private(set) var state: RecordingSessionState = .idle

    private enum TrackIngressEvent: Sendable {
        case buffer(OwnedAudioBuffer, at: ContinuousClock.Instant)
        case source(AudioSourceEvent, at: ContinuousClock.Instant)
    }

    private struct TrackPipeline {
        let timeline: TrackContinuity
        let ingressContinuation: AsyncStream<TrackIngressEvent>.Continuation
    }

    private let meetingID: MeetingID
    private let library: Library
    private let outputDirectory: URL
    private let sources: [AudioTrack: any AudioSource]
    private let sourceOrder: [AudioTrack]
    private let activityManager: any RecordingActivityManaging
    private let availableDiskBytes: @Sendable (URL) throws -> Int64
    private let writerFactory: TrackWriterFactory
    private let ringCapacity: Int
    private let diskCheckInterval: Duration
    private let continuityTickInterval: Duration
    private let maximumConsecutiveDiskProbeFailures = 30

    private var pipelines: [AudioTrack: TrackPipeline] = [:]
    private var availableLiveStreams: [AudioTrack: LiveAudioEventStream] = [:]
    private var writers: [AudioTrack: any AudioTrackWriting] = [:]
    private var writerTasks: [AudioTrack: Task<Void, Never>] = [:]
    private var ingressTasks: [AudioTrack: Task<Void, Never>] = [:]
    private var formats: [AudioTrack: AVAudioFormat] = [:]
    private var levelValues: [AudioTrack: AudioLevels] = [:]
    private var diskMonitorTask: Task<Void, Never>?
    private var continuityMonitorTask: Task<Void, Never>?
    private var pendingStopReason: RecordingStopReason = .requested
    private var terminalError: AudioRecordingError?
    private var result: RecordingResult?
    private var stopTask: Task<RecordingResult, any Error>?
    private var activityIsActive = false

    /// Records whichever tracks it is handed.
    ///
    /// The source list is variable because iOS has no system audio: there is
    /// the microphone and nothing else, while the Mac always has both. `start()`
    /// already skipped absent tracks (`guard let source = sources[track]`);
    /// only this initializer insisted on two. Each source must sit under its
    /// own track, otherwise the writer files the audio under the wrong name.
    public init(
        meetingID: MeetingID,
        library: Library,
        outputDirectory: URL,
        sources: [AudioTrack: any AudioSource],
        sourceOrder: [AudioTrack]? = nil,
        activityManager: any RecordingActivityManaging,
        ringCapacity: Int = 64,
        diskCheckInterval: Duration = .seconds(1),
        continuityTickInterval: Duration = .milliseconds(100),
        availableDiskBytes: @escaping @Sendable (URL) throws -> Int64 = {
            try DiskSpaceChecker().availableBytes(at: $0)
        },
        writerFactory: @escaping TrackWriterFactory = {
            try TrackWriter(url: $0, sourceFormat: $1)
        }
    ) {
        precondition(ringCapacity > 0)
        precondition(continuityTickInterval > .zero)
        precondition(!sources.isEmpty)
        precondition(sources.allSatisfy { $0.key == $0.value.track })
        let resolvedSourceOrder = sourceOrder
            ?? AudioTrack.allCases.filter { sources[$0] != nil }
        precondition(resolvedSourceOrder.count == sources.count)
        precondition(Set(resolvedSourceOrder) == Set(sources.keys))
        self.meetingID = meetingID
        self.library = library
        self.outputDirectory = outputDirectory
        self.sources = sources
        self.sourceOrder = resolvedSourceOrder
        self.activityManager = activityManager
        self.ringCapacity = ringCapacity
        self.diskCheckInterval = diskCheckInterval
        self.continuityTickInterval = continuityTickInterval
        self.availableDiskBytes = availableDiskBytes
        self.writerFactory = writerFactory
    }

    public func start() async throws {
        guard state == .idle else { throw AudioRecordingError.alreadyRecording }
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        let available = try availableDiskBytes(outputDirectory)
        try DiskSpaceChecker.validate(availableBytes: available)
        state = .starting

        do {
            var sessionStart: ContinuousClock.Instant?
            await activityManager.begin()
            activityIsActive = true
            for track in sourceOrder {
                guard let source = sources[track] else { continue }
                let format = try await source.prepare()
                formats[track] = format
                let url = outputDirectory.appendingPathComponent(
                    "\(meetingID)-\(track.rawValue)-\(UUID()).caf"
                )
                let writer = try writerFactory(url, format)
                writers[track] = writer
                let alignsFirstBuffer = sessionStart != nil
                let sharedSessionStart = sessionStart ?? .now
                sessionStart = sharedSessionStart
                let writerPair = AsyncStream.makeStream(
                    of: AVAudioPCMBuffer.self,
                    bufferingPolicy: .bufferingOldest(ringCapacity)
                )
                let livePair = AsyncStream.makeStream(
                    of: LiveAudioEvent.self,
                    bufferingPolicy: .bufferingNewest(ringCapacity)
                )
                let timeline = TrackContinuity(
                    format: format,
                    sessionStart: sharedSessionStart,
                    writerContinuation: writerPair.continuation,
                    liveContinuation: livePair.continuation,
                    alignFirstBufferToSessionStart: alignsFirstBuffer,
                    writerOverflowHandler: { [weak self] in
                        Task {
                            await self?.writerRingDidOverflow(track: track)
                        }
                    }
                )
                let ingressPair = AsyncStream.makeStream(
                    of: TrackIngressEvent.self,
                    bufferingPolicy: .bufferingOldest(ringCapacity)
                )
                let pipeline = TrackPipeline(
                    timeline: timeline,
                    ingressContinuation: ingressPair.continuation
                )
                pipelines[track] = pipeline
                availableLiveStreams[track] = LiveAudioEventStream(
                    stream: livePair.stream
                )
                writerTasks[track] = makeWriterTask(
                    track: track,
                    stream: writerPair.stream,
                    writer: writer
                )
                ingressTasks[track] = makeIngressTask(
                    stream: ingressPair.stream,
                    timeline: timeline
                )
                try await source.start(
                    bufferHandler: { [weak self] buffer in
                        let event = TrackIngressEvent.buffer(
                            OwnedAudioBuffer(buffer: buffer),
                            at: .now
                        )
                        if case .dropped = pipeline.ingressContinuation.yield(event) {
                            Task {
                                await self?.writerRingDidOverflow(track: track)
                            }
                        }
                    },
                    eventHandler: { [weak self] event in
                        if case .dropped = pipeline.ingressContinuation.yield(
                            .source(event, at: .now)
                        ) {
                            Task {
                                await self?.writerRingDidOverflow(track: track)
                            }
                        }
                    }
                )
                if let terminalError { throw terminalError }
            }
            state = .recording
            startContinuityMonitor()
            startDiskMonitor()
        } catch {
            await discardPreparedRecording()
            state = .failed
            throw error
        }
    }

    public func liveAudioEvents(
        for track: AudioTrack
    ) throws -> LiveAudioEventStream {
        try takeLiveAudioEvents(for: track)
    }

    public func setPaused(_ paused: Bool, for track: AudioTrack) async {
        guard state == .recording,
              let timeline = pipelines[track]?.timeline else { return }
        await timeline.setUserPaused(paused, at: .now)
    }

    public func status(for track: AudioTrack) async -> RecordingTrackStatus? {
        guard let timeline = pipelines[track]?.timeline else { return nil }
        return await timeline.status
    }

    private func takeLiveAudioEvents(
        for track: AudioTrack
    ) throws -> LiveAudioEventStream {
        guard state == .recording,
              let stream = availableLiveStreams.removeValue(forKey: track) else {
            throw AudioRecordingError.notRecording
        }
        return stream
    }

    public func levels(for track: AudioTrack) -> AudioLevels {
        levelValues[track] ?? .silence
    }

    public func lastError() -> AudioRecordingError? {
        terminalError
    }

    public func lastResult() -> RecordingResult? {
        result
    }

    @discardableResult
    public func stop() async throws -> RecordingResult {
        if let result { return result }
        if let stopTask { return try await stopTask.value }
        guard state == .recording || state == .stopping else {
            throw AudioRecordingError.notRecording
        }
        state = .stopping
        let task = Task { try await self.finalizeStop() }
        stopTask = task
        return try await task.value
    }

    private func finalizeStop() async throws -> RecordingResult {
        diskMonitorTask?.cancel()
        diskMonitorTask = nil

        for track in AudioTrack.allCases {
            await sources[track]?.stop()
        }
        for pipeline in pipelines.values {
            pipeline.ingressContinuation.finish()
        }
        for track in AudioTrack.allCases {
            await ingressTasks[track]?.value
        }
        continuityMonitorTask?.cancel()
        continuityMonitorTask = nil
        let stopInstant = ContinuousClock.now
        for pipeline in pipelines.values {
            await pipeline.timeline.finish(at: stopInstant)
        }
        for track in AudioTrack.allCases {
            await writerTasks[track]?.value
        }

        var assets: [AudioTrack: MediaAsset] = [:]
        do {
            for track in AudioTrack.allCases {
                guard let writer = writers[track],
                      let format = formats[track] else { continue }
                let summary = try await writer.close()
                let asset = try await library.registerCapturedMediaAsset(
                    for: meetingID,
                    sourceURL: writer.url,
                    kind: track == .microphone ? .micTrack : .systemTrack,
                    sampleRate: format.sampleRate,
                    duration: summary.duration
                )
                assets[track] = asset
            }
            _ = try await library.updateMeetingStatus(meetingID, to: .ready)
            await endActivityIfNeeded()
            let completed = RecordingResult(
                assets: assets,
                stopReason: pendingStopReason
            )
            result = completed
            state = pendingStopReason == .requested ? .stopped : .failed
            return completed
        } catch {
            await endActivityIfNeeded()
            state = .failed
            throw error
        }
    }

    private func writerRingDidOverflow(track: AudioTrack) {
        if state == .starting {
            pendingStopReason = .ringBufferOverflow(track)
            terminalError = .ringBufferOverflow(track: track)
            return
        }
        guard state == .recording else { return }
        requestAutomaticStop(
            reason: .ringBufferOverflow(track),
            error: .ringBufferOverflow(track: track)
        )
    }

    private func makeWriterTask(
        track: AudioTrack,
        stream: sending AsyncStream<AVAudioPCMBuffer>,
        writer: any AudioTrackWriting
    ) -> Task<Void, Never> {
        Task { [weak self] in
            do {
                for await buffer in stream {
                    let levels = AudioLevelMeter.measure(buffer)
                    try await writer.write(buffer)
                    await self?.updateLevels(levels, for: track)
                }
            } catch {
                await self?.writerDidFail(track: track, error: error)
            }
        }
    }

    private func makeIngressTask(
        stream: sending AsyncStream<TrackIngressEvent>,
        timeline: TrackContinuity
    ) -> Task<Void, Never> {
        Task {
            for await event in stream {
                switch event {
                case let .buffer(owned, instant):
                    await timeline.receive(owned.buffer, at: instant)
                case let .source(event, instant):
                    switch event {
                    case let .unavailable(deviceName):
                        await timeline.setDeviceAvailable(
                            false,
                            deviceName: deviceName,
                            at: instant
                        )
                    case let .available(deviceName):
                        await timeline.setDeviceAvailable(
                            true,
                            deviceName: deviceName,
                            at: instant
                        )
                    }
                }
            }
        }
    }

    private func updateLevels(_ levels: AudioLevels, for track: AudioTrack) {
        guard state == .recording else { return }
        levelValues[track] = levels
    }

    private func writerDidFail(track: AudioTrack, error: any Error) {
        if state == .starting {
            pendingStopReason = .writerFailure(track)
            terminalError = .writerFailed(
                track: track,
                message: error.localizedDescription
            )
            return
        }
        if state == .stopping {
            pendingStopReason = .writerFailure(track)
            terminalError = .writerFailed(
                track: track,
                message: error.localizedDescription
            )
            return
        }
        requestAutomaticStop(
            reason: .writerFailure(track),
            error: .writerFailed(track: track, message: error.localizedDescription)
        )
    }

    private func requestAutomaticStop(
        reason: RecordingStopReason,
        error: AudioRecordingError
    ) {
        guard state == .recording else { return }
        pendingStopReason = reason
        terminalError = error
        state = .stopping
        Task { [weak self] in
            _ = try? await self?.stop()
        }
    }

    private func startDiskMonitor() {
        diskMonitorTask = Task { [weak self] in
            guard let self else { return }
            var consecutiveFailures = 0
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: self.diskCheckInterval)
                    guard !Task.isCancelled else { return }
                    let available = try self.availableDiskBytes(self.outputDirectory)
                    consecutiveFailures = 0
                    if available < DiskSpaceChecker.minimumRecordingBytes {
                        await self.diskSpaceDidRunLow(availableBytes: available)
                        return
                    }
                } catch is CancellationError {
                    return
                } catch {
                    consecutiveFailures += 1
                    guard consecutiveFailures
                        >= self.maximumConsecutiveDiskProbeFailures else {
                        continue
                    }
                    await self.diskSpaceMonitorDidFail(error)
                    return
                }
            }
        }
    }

    private func startContinuityMonitor() {
        continuityMonitorTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: self.continuityTickInterval)
                    guard !Task.isCancelled else { return }
                    await self.tickContinuity(at: .now)
                } catch is CancellationError {
                    return
                } catch {
                    continue
                }
            }
        }
    }

    private func tickContinuity(at instant: ContinuousClock.Instant) async {
        guard state == .recording else { return }
        for pipeline in pipelines.values {
            await pipeline.timeline.tick(at: instant)
        }
    }

    private func diskSpaceDidRunLow(availableBytes: Int64) {
        requestAutomaticStop(
            reason: .lowDiskSpace,
            error: .insufficientDiskSpace(
                requiredBytes: DiskSpaceChecker.minimumRecordingBytes,
                availableBytes: availableBytes
            )
        )
    }

    private func diskSpaceMonitorDidFail(_ error: any Error) {
        requestAutomaticStop(
            reason: .diskSpaceMonitoringFailure,
            error: .diskSpaceMonitoringFailed(
                message: error.localizedDescription
            )
        )
    }

    private func discardPreparedRecording() async {
        diskMonitorTask?.cancel()
        diskMonitorTask = nil
        for track in AudioTrack.allCases {
            await sources[track]?.stop()
        }
        for pipeline in pipelines.values {
            pipeline.ingressContinuation.finish()
        }
        for track in AudioTrack.allCases {
            await ingressTasks[track]?.value
        }
        continuityMonitorTask?.cancel()
        continuityMonitorTask = nil
        let stopInstant = ContinuousClock.now
        for pipeline in pipelines.values {
            await pipeline.timeline.finish(at: stopInstant)
        }
        for track in AudioTrack.allCases {
            await writerTasks[track]?.value
        }
        for writer in writers.values {
            _ = try? await writer.close()
        }
        await endActivityIfNeeded()
    }

    private func endActivityIfNeeded() async {
        guard activityIsActive else { return }
        await activityManager.end()
        activityIsActive = false
    }
}
