import AudioToolbox
import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import StenoExchange

@Suite("Stereo M4A exporter")
struct StereoM4AExporterTests {
    @Test("microphone stays left, system stays right, and the shorter track ends in silence")
    func preservesChannelMeaningAndPadsTheShorterTrack() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let microphoneURL = directory.appending(path: "microphone.caf")
        let systemURL = directory.appending(path: "system.caf")
        let destinationURL = directory.appending(path: "combined.m4a")
        try writeFixture(
            to: microphoneURL,
            sampleRate: 44_100,
            channelCount: 1,
            duration: 1,
            frequency: 440
        )
        try writeFixture(
            to: systemURL,
            sampleRate: 48_000,
            channelCount: 2,
            duration: 2,
            frequency: 880
        )

        try StereoM4AExporter().export(
            microphoneURL: microphoneURL,
            systemURL: systemURL,
            destinationURL: destinationURL
        )

        let decoded = try decode(destinationURL)
        let encoded = try AVAudioFile(forReading: destinationURL)
        #expect(encoded.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC)
        #expect(decoded.sampleRate == 48_000)
        #expect(decoded.channels.count == 2)
        #expect(abs(decoded.duration - 2) < 0.08)
        #expect(detects(440, in: decoded.channels[0], sampleRate: decoded.sampleRate, until: 0.9))
        #expect(!detects(440, in: decoded.channels[1], sampleRate: decoded.sampleRate, until: 0.9))
        #expect(detects(880, in: decoded.channels[1], sampleRate: decoded.sampleRate, until: 1.9))
        #expect(rms(decoded.channels[0], sampleRate: decoded.sampleRate, from: 1.2, to: 1.8) < 0.01)
    }

    @Test("a failed export keeps an existing destination byte-identical")
    func failureDoesNotReplaceDestination() throws {
        let fixture = try makeExportFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let original = Data("existing export".utf8)
        try original.write(to: fixture.destinationURL)
        let exporter = StereoM4AExporter(afterEncodedBlock: { block in
            if block == 1 { throw StereoM4ATestError.injectedFailure }
        })

        #expect(throws: StereoM4ATestError.injectedFailure) {
            try exporter.export(
                microphoneURL: fixture.microphoneURL,
                systemURL: fixture.systemURL,
                destinationURL: fixture.destinationURL
            )
        }

        #expect(try Data(contentsOf: fixture.destinationURL) == original)
        #expect(try partialFiles(in: fixture.directory).isEmpty)
    }

    @Test("cancellation removes the temporary sibling and keeps the destination")
    func cancellationDoesNotPublishPartialOutput() throws {
        let fixture = try makeExportFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let original = Data("existing export".utf8)
        try original.write(to: fixture.destinationURL)
        let exporter = StereoM4AExporter(afterEncodedBlock: { block in
            if block == 1 { throw CancellationError() }
        })

        #expect(throws: CancellationError.self) {
            try exporter.export(
                microphoneURL: fixture.microphoneURL,
                systemURL: fixture.systemURL,
                destinationURL: fixture.destinationURL
            )
        }

        #expect(try Data(contentsOf: fixture.destinationURL) == original)
        #expect(try partialFiles(in: fixture.directory).isEmpty)
    }

    @Test(
        "task cancellation at every late export phase preserves the destination",
        arguments: [
            StereoM4AExporter.Checkpoint.convertedBlock(1),
            StereoM4AExporter.Checkpoint.encodedBlock(1),
            StereoM4AExporter.Checkpoint.validatedBlock(1),
            StereoM4AExporter.Checkpoint.beforePublication,
        ]
    )
    func taskCancellationNeverPublishes(
        checkpointToCancel: StereoM4AExporter.Checkpoint
    ) async throws {
        let fixture = try makeExportFixture(duration: 0.4)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let original = Data("existing export".utf8)
        try original.write(to: fixture.destinationURL)
        let exporter = StereoM4AExporter(afterCheckpoint: { checkpoint in
            guard checkpoint == checkpointToCancel else { return }
            withUnsafeCurrentTask { $0?.cancel() }
        })

        let export = Task.detached {
            try exporter.export(
                microphoneURL: fixture.microphoneURL,
                systemURL: fixture.systemURL,
                destinationURL: fixture.destinationURL
            )
        }

        await #expect(throws: CancellationError.self) {
            try await export.value
        }
        #expect(try Data(contentsOf: fixture.destinationURL) == original)
        #expect(try partialFiles(in: fixture.directory).isEmpty)
    }

    @Test("task cancellation before publication never creates a destination")
    func taskCancellationNeverCreatesDestination() async throws {
        let fixture = try makeExportFixture(duration: 0.4)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let exporter = StereoM4AExporter(afterCheckpoint: { checkpoint in
            guard checkpoint == .beforePublication else { return }
            withUnsafeCurrentTask { $0?.cancel() }
        })

        let export = Task.detached {
            try exporter.export(
                microphoneURL: fixture.microphoneURL,
                systemURL: fixture.systemURL,
                destinationURL: fixture.destinationURL
            )
        }

        await #expect(throws: CancellationError.self) {
            try await export.value
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.destinationURL.path))
        #expect(try partialFiles(in: fixture.directory).isEmpty)
    }

    @Test("progress is monotonic and finishes at one")
    func progressIsMonotonic() throws {
        let fixture = try makeExportFixture(duration: 0.4)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let fractions = Mutex<[Double]>([])

        try StereoM4AExporter().export(
            microphoneURL: fixture.microphoneURL,
            systemURL: fixture.systemURL,
            destinationURL: fixture.destinationURL
        ) { update in
            fractions.withLock { $0.append(update.fraction) }
        }

        let values = fractions.withLock { $0 }
        #expect(values.first == 0)
        #expect(values.last == 1)
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
    }

    @Test("a long export processes repeated blocks with buffers bounded to 4096 frames")
    func longExportUsesBoundedBuffers() throws {
        let fixture = try makeExportFixture(duration: 12)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let checkpoints = Mutex<[StereoM4AExporter.Checkpoint]>([])
        let exporter = StereoM4AExporter(afterCheckpoint: { checkpoint in
            checkpoints.withLock { $0.append(checkpoint) }
        })

        try exporter.export(
            microphoneURL: fixture.microphoneURL,
            systemURL: fixture.systemURL,
            destinationURL: fixture.destinationURL
        )

        let observed = checkpoints.withLock { $0 }
        let bufferCapacities: [AVAudioFrameCount] = observed.compactMap { checkpoint in
            guard case let .allocatedBuffer(capacity) = checkpoint else { return nil }
            return capacity
        }
        #expect(observed.count(where: { $0.isConvertedBlock }) > 2)
        #expect(observed.count(where: { $0.isEncodedBlock }) > 2)
        #expect(observed.count(where: { $0.isValidatedBlock }) > 2)
        #expect(bufferCapacities.count > 10)
        #expect(bufferCapacities.max() == 4_096)
    }

    @Test(
        "every destination alias is rejected exactly without modifying the source",
        arguments: DestinationAliasKind.allCases
    )
    func rejectsAliasedDestinationWithoutModifyingSource(
        aliasKind: DestinationAliasKind
    ) throws {
        let fixture = try makeExportFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let original = try Data(contentsOf: fixture.microphoneURL)
        let destinationAlias: URL
        switch aliasKind {
        case .direct:
            destinationAlias = fixture.microphoneURL
        case .symbolicLink:
            destinationAlias = fixture.directory.appending(path: "microphone-symlink.caf")
            try FileManager.default.createSymbolicLink(
                at: destinationAlias,
                withDestinationURL: fixture.microphoneURL
            )
        case .hardLink:
            destinationAlias = fixture.directory.appending(path: "microphone-hardlink.caf")
            try FileManager.default.linkItem(
                at: fixture.microphoneURL,
                to: destinationAlias
            )
        }

        #expect(throws: StereoM4AExportError.sourceDestinationConflict) {
            try StereoM4AExporter().export(
                microphoneURL: fixture.microphoneURL,
                systemURL: fixture.systemURL,
                destinationURL: destinationAlias
            )
        }

        #expect(try Data(contentsOf: fixture.microphoneURL) == original)
        #expect(try partialFiles(in: fixture.directory).isEmpty)
    }

    @Test(
        "successful publication leaves a readable final file and no partial",
        arguments: PublicationDestinationState.allCases
    )
    func publishesReadableFinalFile(
        destinationState: PublicationDestinationState
    ) throws {
        let fixture = try makeExportFixture(duration: 0.4)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        if destinationState == .existing {
            try Data("existing destination".utf8).write(to: fixture.destinationURL)
        }

        try StereoM4AExporter().export(
            microphoneURL: fixture.microphoneURL,
            systemURL: fixture.systemURL,
            destinationURL: fixture.destinationURL
        )

        let published = try AVAudioFile(forReading: fixture.destinationURL)
        #expect(published.length > 0)
        #expect(try partialFiles(in: fixture.directory).isEmpty)
    }

    @Test("corrupted AAC packets are rejected before publication")
    func rejectsCorruptedAACPacketsBeforePublication() throws {
        let fixture = try makeExportFixture(duration: 0.4)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let exporter = StereoM4AExporter(afterEncodedBlock: { block in
            guard block == 5 else { return }
            let partialURL = try #require(partialFiles(in: fixture.directory).first)
            var data = try Data(contentsOf: partialURL)
            data[data.index(before: data.endIndex)] ^= 0xFF
            try data.write(to: partialURL)
        })

        #expect(throws: (any Error).self) {
            try exporter.export(
                microphoneURL: fixture.microphoneURL,
                systemURL: fixture.systemURL,
                destinationURL: fixture.destinationURL
            )
        }

        #expect(!FileManager.default.fileExists(atPath: fixture.destinationURL.path))
        #expect(try partialFiles(in: fixture.directory).isEmpty)
    }
}

private struct ExportFixture {
    let directory: URL
    let microphoneURL: URL
    let systemURL: URL
    let destinationURL: URL
}

private func makeExportFixture(duration: Double = 1) throws -> ExportFixture {
    let directory = try makeTemporaryDirectory()
    let microphoneURL = directory.appending(path: "microphone.caf")
    let systemURL = directory.appending(path: "system.caf")
    let destinationURL = directory.appending(path: "combined.m4a")
    try writeFixture(
        to: microphoneURL,
        sampleRate: 44_100,
        channelCount: 1,
        duration: duration,
        frequency: 440
    )
    try writeFixture(
        to: systemURL,
        sampleRate: 48_000,
        channelCount: 2,
        duration: duration,
        frequency: 880
    )
    return ExportFixture(
        directory: directory,
        microphoneURL: microphoneURL,
        systemURL: systemURL,
        destinationURL: destinationURL
    )
}

private func partialFiles(in directory: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    ).filter { $0.lastPathComponent.contains(".partial.m4a") }
}

private enum StereoM4ATestError: Error {
    case injectedFailure
}

enum DestinationAliasKind: CaseIterable, Sendable {
    case direct
    case symbolicLink
    case hardLink
}

enum PublicationDestinationState: CaseIterable, Sendable {
    case missing
    case existing
}

private extension StereoM4AExporter.Checkpoint {
    var isConvertedBlock: Bool {
        if case .convertedBlock = self { true } else { false }
    }

    var isEncodedBlock: Bool {
        if case .encodedBlock = self { true } else { false }
    }

    var isValidatedBlock: Bool {
        if case .validatedBlock = self { true } else { false }
    }
}

private struct DecodedAudio {
    let sampleRate: Double
    let channels: [[Float]]

    var duration: Double {
        Double(channels.first?.count ?? 0) / sampleRate
    }
}

private func writeFixture(
    to url: URL,
    sampleRate: Double,
    channelCount: AVAudioChannelCount,
    duration: Double,
    frequency: Double
) throws {
    let format = try #require(AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: channelCount,
        interleaved: false
    ))
    let totalFrames = AVAudioFramePosition((sampleRate * duration).rounded())
    let file = try AVAudioFile(
        forWriting: url,
        settings: format.settings,
        commonFormat: .pcmFormatFloat32,
        interleaved: false
    )
    var writtenFrames: AVAudioFramePosition = 0
    while writtenFrames < totalFrames {
        let frameCount = AVAudioFrameCount(min(
            4_096,
            totalFrames - writtenFrames
        ))
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCount
        ))
        buffer.frameLength = frameCount
        let channels = try #require(buffer.floatChannelData)
        for channel in 0..<Int(channelCount) {
            for frame in 0..<Int(frameCount) {
                let absoluteFrame = writtenFrames + AVAudioFramePosition(frame)
                let phase = 2 * Double.pi * frequency * Double(absoluteFrame) / sampleRate
                channels[channel][frame] = Float(sin(phase) * 0.25)
            }
        }
        try file.write(from: buffer)
        writtenFrames += AVAudioFramePosition(frameCount)
    }
}

private func decode(_ url: URL) throws -> DecodedAudio {
    let file = try AVAudioFile(
        forReading: url,
        commonFormat: .pcmFormatFloat32,
        interleaved: false
    )
    let capacity = AVAudioFrameCount(file.length)
    let buffer = try #require(AVAudioPCMBuffer(
        pcmFormat: file.processingFormat,
        frameCapacity: capacity
    ))
    try file.read(into: buffer)
    let data = try #require(buffer.floatChannelData)
    let channels = (0..<Int(file.processingFormat.channelCount)).map { channel in
        Array(UnsafeBufferPointer(start: data[channel], count: Int(buffer.frameLength)))
    }
    return DecodedAudio(sampleRate: file.processingFormat.sampleRate, channels: channels)
}

private func detects(
    _ frequency: Double,
    in samples: [Float],
    sampleRate: Double,
    until: Double
) -> Bool {
    let count = min(samples.count, Int(sampleRate * until))
    guard count > 0 else { return false }
    var sine: Double = 0
    var cosine: Double = 0
    for frame in 0..<count {
        let phase = 2 * Double.pi * frequency * Double(frame) / sampleRate
        let sample = Double(samples[frame])
        sine += sample * sin(phase)
        cosine += sample * cos(phase)
    }
    return 2 * hypot(sine, cosine) / Double(count) > 0.05
}

private func rms(
    _ samples: [Float],
    sampleRate: Double,
    from start: Double,
    to end: Double
) -> Double {
    let lower = min(samples.count, max(0, Int(start * sampleRate)))
    let upper = min(samples.count, max(lower, Int(end * sampleRate)))
    guard upper > lower else { return 0 }
    let energy = samples[lower..<upper].reduce(0.0) { sum, sample in
        sum + Double(sample * sample)
    }
    return sqrt(energy / Double(upper - lower))
}
