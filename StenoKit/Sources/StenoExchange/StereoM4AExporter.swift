@preconcurrency import AVFAudio
import AudioToolbox
import Darwin
import Foundation

public struct StereoM4AExportProgress: Equatable, Sendable {
    public let completedFrames: AVAudioFramePosition
    public let totalFrames: AVAudioFramePosition

    public init(
        completedFrames: AVAudioFramePosition,
        totalFrames: AVAudioFramePosition
    ) {
        self.completedFrames = completedFrames
        self.totalFrames = totalFrames
    }

    public var fraction: Double {
        guard totalFrames > 0 else { return 1 }
        return min(1, Double(completedFrames) / Double(totalFrames))
    }
}

public struct StereoM4AExporter: Sendable {
    enum Checkpoint: Equatable, Sendable {
        case convertedBlock(Int)
        case encodedBlock(Int)
        case validatedBlock(Int)
        case allocatedBuffer(AVAudioFrameCount)
        case beforePublication
    }

    private static let sampleRate: Double = 48_000
    private static let blockFrames: AVAudioFrameCount = 4_096
    private let afterCheckpoint: @Sendable (Checkpoint) throws -> Void

    public init() {
        afterCheckpoint = { _ in }
    }

    init(afterEncodedBlock: @escaping @Sendable (Int) throws -> Void) {
        afterCheckpoint = { checkpoint in
            guard case let .encodedBlock(block) = checkpoint else { return }
            try afterEncodedBlock(block)
        }
    }

    init(afterCheckpoint: @escaping @Sendable (Checkpoint) throws -> Void) {
        self.afterCheckpoint = afterCheckpoint
    }

    public func export(
        microphoneURL: URL,
        systemURL: URL,
        destinationURL: URL,
        progress: @escaping @Sendable (StereoM4AExportProgress) -> Void = { _ in }
    ) throws {
        guard !sourcesAliasDestination(
            microphoneURL: microphoneURL,
            systemURL: systemURL,
            destinationURL: destinationURL
        ) else {
            throw StereoM4AExportError.sourceDestinationConflict
        }
        let partialURL = destinationURL
            .deletingLastPathComponent()
            .appending(path: ".\(destinationURL.lastPathComponent).\(UUID().uuidString).partial.m4a")
        var published = false
        defer {
            if !published {
                try? FileManager.default.removeItem(at: partialURL)
            }
        }

        try encode(
            microphoneURL: microphoneURL,
            systemURL: systemURL,
            destinationURL: partialURL,
            progress: progress
        )
        try Task.checkCancellation()
        try synchronize(partialURL)
        try Task.checkCancellation()
        try validate(partialURL)
        try publish(partialURL, to: destinationURL)
        published = true
    }

    private func encode(
        microphoneURL: URL,
        systemURL: URL,
        destinationURL: URL,
        progress: @escaping @Sendable (StereoM4AExportProgress) -> Void
    ) throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appending(path: "steno-stereo-export-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let microphoneMonoURL = temporaryDirectory.appending(path: "microphone.caf")
        let systemMonoURL = temporaryDirectory.appending(path: "system.caf")
        try convertToMono48k(sourceURL: microphoneURL, destinationURL: microphoneMonoURL)
        try convertToMono48k(sourceURL: systemURL, destinationURL: systemMonoURL)

        let microphone = try AVAudioFile(forReading: microphoneMonoURL)
        let system = try AVAudioFile(forReading: systemMonoURL)
        let totalFrames = max(microphone.length, system.length)
        guard totalFrames > 0 else { throw StereoM4AExportError.emptySources }
        let stereoFormat = try requiredFormat(channels: 2)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ]
        let output = try AVAudioFile(forWriting: destinationURL, settings: outputSettings)

        progress(.init(completedFrames: 0, totalFrames: totalFrames))
        var completedFrames: AVAudioFramePosition = 0
        var encodedBlocks = 0
        while completedFrames < totalFrames {
            try Task.checkCancellation()
            let requestedFrames = AVAudioFrameCount(min(
                AVAudioFramePosition(Self.blockFrames),
                totalFrames - completedFrames
            ))
            let microphoneBuffer = try read(
                from: microphone,
                maximumFrames: requestedFrames
            )
            let systemBuffer = try read(from: system, maximumFrames: requestedFrames)
            let stereoBuffer = try makeStereoBuffer(
                format: stereoFormat,
                frameCount: requestedFrames,
                microphone: microphoneBuffer,
                system: systemBuffer
            )
            try output.write(from: stereoBuffer)
            encodedBlocks += 1
            try afterCheckpoint(.encodedBlock(encodedBlocks))
            try Task.checkCancellation()
            completedFrames += AVAudioFramePosition(requestedFrames)
            progress(.init(
                completedFrames: completedFrames,
                totalFrames: totalFrames
            ))
        }
    }

    private func synchronize(_ url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    private func validate(_ url: URL) throws {
        do {
            let file = try AVAudioFile(
                forReading: url,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            guard
                file.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC,
                file.processingFormat.channelCount == 2,
                abs(file.processingFormat.sampleRate - Self.sampleRate) < 0.5,
                file.length > 0
            else {
                throw StereoM4AExportError.invalidEncodedFile
            }

            var decodedFrames: AVAudioFramePosition = 0
            var decodedBlocks = 0
            while decodedFrames < file.length {
                try Task.checkCancellation()
                let frameCount = AVAudioFrameCount(min(
                    AVAudioFramePosition(Self.blockFrames),
                    file.length - decodedFrames
                ))
                let buffer = try requiredBuffer(
                    format: file.processingFormat,
                    capacity: frameCount
                )
                try file.read(into: buffer)
                guard buffer.frameLength > 0 else {
                    throw StereoM4AExportError.invalidEncodedFile
                }
                decodedFrames += AVAudioFramePosition(buffer.frameLength)
                decodedBlocks += 1
                try afterCheckpoint(.validatedBlock(decodedBlocks))
                try Task.checkCancellation()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch StereoM4AExportError.invalidEncodedFile {
            throw StereoM4AExportError.invalidEncodedFile
        } catch {
            throw StereoM4AExportError.invalidEncodedFile
        }
    }

    private func sourcesAliasDestination(
        microphoneURL: URL,
        systemURL: URL,
        destinationURL: URL
    ) -> Bool {
        sameFile(microphoneURL, destinationURL) || sameFile(systemURL, destinationURL)
    }

    private func sameFile(_ first: URL, _ second: URL) -> Bool {
        let resolvedFirst = first.resolvingSymlinksInPath().standardizedFileURL
        let resolvedSecond = second.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedFirst != resolvedSecond else { return true }

        var firstStatus = stat()
        var secondStatus = stat()
        let firstExists = resolvedFirst.withUnsafeFileSystemRepresentation {
            $0.map { stat($0, &firstStatus) == 0 } ?? false
        }
        let secondExists = resolvedSecond.withUnsafeFileSystemRepresentation {
            $0.map { stat($0, &secondStatus) == 0 } ?? false
        }
        return firstExists && secondExists
            && firstStatus.st_dev == secondStatus.st_dev
            && firstStatus.st_ino == secondStatus.st_ino
    }

    private func publish(_ partialURL: URL, to destinationURL: URL) throws {
        let destinationExists = FileManager.default.fileExists(atPath: destinationURL.path)
        try afterCheckpoint(.beforePublication)
        try Task.checkCancellation()
        if destinationExists {
            _ = try FileManager.default.replaceItemAt(
                destinationURL,
                withItemAt: partialURL,
                backupItemName: nil,
                options: []
            )
        } else {
            try FileManager.default.moveItem(at: partialURL, to: destinationURL)
        }
    }

    private func convertToMono48k(sourceURL: URL, destinationURL: URL) throws {
        let source = try AVAudioFile(forReading: sourceURL)
        let targetFormat = try requiredFormat(channels: 1)
        guard let converter = AVAudioConverter(
            from: source.processingFormat,
            to: targetFormat
        ) else {
            throw StereoM4AExportError.cannotCreateAudioConverter
        }
        converter.downmix = true
        let destination = try AVAudioFile(
            forWriting: destinationURL,
            settings: targetFormat.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        let framesThatFitOutputBuffer = max(
            1,
            AVAudioFramePosition(floor(
                Double(Self.blockFrames) * source.processingFormat.sampleRate
                    / Self.sampleRate
            ))
        )
        var convertedBlocks = 0
        while source.framePosition < source.length {
            try Task.checkCancellation()
            let remainingFrames = source.length - source.framePosition
            let sourceFrameCount = AVAudioFrameCount(min(
                AVAudioFramePosition(Self.blockFrames),
                framesThatFitOutputBuffer,
                remainingFrames
            ))
            let input = try requiredBuffer(
                format: source.processingFormat,
                capacity: sourceFrameCount
            )
            try source.read(into: input)
            guard input.frameLength > 0 else { break }

            let output = try requiredBuffer(
                format: targetFormat,
                capacity: Self.blockFrames
            )
            let suppliedInput = OneShotConverterInputGate()
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) {
                _, inputStatus in
                let shouldSupply = suppliedInput.claim()
                if shouldSupply {
                    inputStatus.pointee = .haveData
                    return input
                }
                inputStatus.pointee = .noDataNow
                return nil
            }
            if let conversionError {
                throw StereoM4AExportError.conversionFailed(
                    conversionError.localizedDescription
                )
            }
            guard status != .error else {
                throw StereoM4AExportError.conversionFailed("unknown conversion error")
            }
            if output.frameLength > 0 {
                try destination.write(from: output)
                convertedBlocks += 1
                try afterCheckpoint(.convertedBlock(convertedBlocks))
                try Task.checkCancellation()
            }
        }

        while true {
            try Task.checkCancellation()
            let output = try requiredBuffer(
                format: targetFormat,
                capacity: Self.blockFrames
            )
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) {
                _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }
            if let conversionError {
                throw StereoM4AExportError.conversionFailed(
                    conversionError.localizedDescription
                )
            }
            if output.frameLength > 0 {
                try destination.write(from: output)
                convertedBlocks += 1
                try afterCheckpoint(.convertedBlock(convertedBlocks))
                try Task.checkCancellation()
            }
            if status == .endOfStream || output.frameLength == 0 { break }
            if status == .error {
                throw StereoM4AExportError.conversionFailed("could not flush converter")
            }
        }
    }

    private func read(
        from file: AVAudioFile,
        maximumFrames: AVAudioFrameCount
    ) throws -> AVAudioPCMBuffer? {
        guard file.framePosition < file.length else { return nil }
        let remaining = file.length - file.framePosition
        let capacity = AVAudioFrameCount(min(
            AVAudioFramePosition(maximumFrames),
            remaining
        ))
        let buffer = try requiredBuffer(format: file.processingFormat, capacity: capacity)
        try file.read(into: buffer)
        return buffer.frameLength > 0 ? buffer : nil
    }

    private func makeStereoBuffer(
        format: AVAudioFormat,
        frameCount: AVAudioFrameCount,
        microphone: AVAudioPCMBuffer?,
        system: AVAudioPCMBuffer?
    ) throws -> AVAudioPCMBuffer {
        let output = try requiredBuffer(format: format, capacity: frameCount)
        output.frameLength = frameCount
        guard let channels = output.floatChannelData else {
            throw StereoM4AExportError.cannotAllocateRenderBuffer
        }
        channels[0].initialize(repeating: 0, count: Int(frameCount))
        channels[1].initialize(repeating: 0, count: Int(frameCount))
        copy(microphone, to: channels[0])
        copy(system, to: channels[1])
        return output
    }

    private func copy(_ source: AVAudioPCMBuffer?, to destination: UnsafeMutablePointer<Float>) {
        guard
            let source,
            let samples = source.floatChannelData?[0],
            source.frameLength > 0
        else { return }
        destination.update(from: samples, count: Int(source.frameLength))
    }

    private func requiredFormat(channels: AVAudioChannelCount) throws -> AVAudioFormat {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: channels,
            interleaved: false
        ) else {
            throw StereoM4AExportError.cannotCreateAudioFormat
        }
        return format
    }

    private func requiredBuffer(
        format: AVAudioFormat,
        capacity: AVAudioFrameCount
    ) throws -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: capacity
        ) else {
            throw StereoM4AExportError.cannotAllocateRenderBuffer
        }
        try afterCheckpoint(.allocatedBuffer(capacity))
        return buffer
    }
}

public enum StereoM4AExportError: Error, Equatable, LocalizedError {
    case cannotCreateAudioFormat
    case cannotCreateAudioConverter
    case cannotAllocateRenderBuffer
    case emptySources
    case sourceDestinationConflict
    case conversionFailed(String)
    case invalidEncodedFile

    public var errorDescription: String? {
        switch self {
        case .cannotCreateAudioFormat:
            "Steno could not create the stereo export format."
        case .cannotCreateAudioConverter:
            "Steno could not create an audio converter."
        case .cannotAllocateRenderBuffer:
            "Steno could not allocate an audio export buffer."
        case .emptySources:
            "The selected audio tracks are empty."
        case .sourceDestinationConflict:
            "The export destination must not be one of the source files."
        case let .conversionFailed(message):
            "Audio conversion failed: \(message)"
        case .invalidEncodedFile:
            "The encoded M4A file could not be validated."
        }
    }
}

/// One-shot flag for an ``AVAudioConverter`` input block.
///
/// Works around a Swift 6.4 frontend crash ("copy of noncopyable typed
/// value") triggered by `Mutex.withLock` inside converter input closures;
/// semantics are identical to the previous `Mutex(false)`.
private final class OneShotConverterInputGate: @unchecked Sendable {
    private let lock = NSLock()
    private var supplied = false

    /// Returns true exactly once; every later call returns false.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if supplied { return false }
        supplied = true
        return true
    }
}
