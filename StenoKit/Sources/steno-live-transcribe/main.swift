@preconcurrency import AVFAudio
import Foundation
import StenoLiveBenchmarkSupport
import StenoTranscription

private enum Engine: String {
    case apple
    case parakeet
}

private struct Options {
    var engine: Engine?
    var input: URL?
    var locale = Locale(identifier: "de-DE")
    var modelDirectory: URL?
    var mode = LiveBenchmarkMode.fast
    var chunkMilliseconds = 20
    var output: URL?
}

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("steno-live-transcribe: \(message)\n".utf8))
    exit(2)
}

private func usage() -> Never {
    fail(
        "usage: steno-live-transcribe --engine apple|parakeet --input <audio> "
            + "[--locale de-DE] [--model-dir <parakeet>] [--mode fast|realtime] "
            + "[--chunk-ms 20] [--output result.json]"
    )
}

private func parseOptions(_ arguments: [String]) -> Options {
    var options = Options()
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        func nextValue() -> String {
            guard index + 1 < arguments.count else { usage() }
            index += 1
            return arguments[index]
        }
        switch argument {
        case "--engine":
            guard let engine = Engine(rawValue: nextValue()) else { usage() }
            options.engine = engine
        case "--input":
            options.input = URL(fileURLWithPath: nextValue())
        case "--locale":
            options.locale = Locale(identifier: nextValue())
        case "--model-dir":
            options.modelDirectory = URL(fileURLWithPath: nextValue())
        case "--mode":
            guard let mode = LiveBenchmarkMode(rawValue: nextValue()) else { usage() }
            options.mode = mode
        case "--chunk-ms":
            guard let value = Int(nextValue()), value > 0 else { usage() }
            options.chunkMilliseconds = value
        case "--output":
            options.output = URL(fileURLWithPath: nextValue())
        case "--help", "-h":
            usage()
        default:
            usage()
        }
        index += 1
    }
    return options
}

private func transcriptText(_ output: TranscriptOutput) -> String {
    output.blocks.map(\.text).joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func write(_ result: LiveBenchmarkResult, to output: URL?) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(result) + Data("\n".utf8)
    if let output {
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: output, options: .atomic)
    } else {
        FileHandle.standardOutput.write(data)
    }
}

private func run(_ options: Options) async throws {
    guard let engine = options.engine, let input = options.input else { usage() }
    guard FileManager.default.fileExists(atPath: input.path) else {
        fail("input file does not exist: \(input.path)")
    }

    let provider: any TranscriptionProvider
    switch engine {
    case .apple:
        provider = SpeechAnalyzerProvider(channel: .system)
    case .parakeet:
        guard let modelDirectory = options.modelDirectory else {
            fail("--model-dir is required for parakeet")
        }
        provider = ParakeetTranscriptionProvider(
            channel: .system,
            modelDirectory: modelDirectory,
            experimentalFeatures: TranscriptionExperimentalFeatures(
                parakeetLiveEnabled: true
            )
        )
    }

    let audioFile = try AVAudioFile(forReading: input)
    let format = audioFile.processingFormat
    let audioDuration = Double(audioFile.length) / format.sampleRate
    let session = try await provider.liveSession(
        format: AudioFormat(format),
        locale: options.locale
    )
    let recorder = LiveBenchmarkRecorder(now: monotonicSeconds)
    let eventTask = Task {
        for await event in session.events {
            switch event {
            case .volatile(let output):
                await recorder.record(kind: .volatile, text: transcriptText(output))
            case .final(let output):
                await recorder.record(kind: .final, text: transcriptText(output))
            }
        }
    }

    let framesPerChunk = max(
        1,
        AVAudioFrameCount(
            format.sampleRate * Double(options.chunkMilliseconds) / 1_000
        )
    )
    let feedStart = ContinuousClock.now
    while audioFile.framePosition < audioFile.length {
        let remaining = AVAudioFrameCount(audioFile.length - audioFile.framePosition)
        let count = min(framesPerChunk, remaining)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: count
        ) else {
            throw TranscriptionError.audioConversionFailed(
                "cannot allocate benchmark input buffer"
            )
        }
        try audioFile.read(into: buffer, frameCount: count)
        guard buffer.frameLength > 0 else { break }
        let audioSecondsFed = Double(audioFile.framePosition) / format.sampleRate
        await recorder.setAudioSecondsFed(audioSecondsFed)
        await session.append(try AudioBuffer(copying: buffer))

        if options.mode == .realtime {
            let target = feedStart.advanced(by: .seconds(audioSecondsFed))
            if ContinuousClock.now < target {
                try await ContinuousClock().sleep(until: target)
            }
        }
    }

    let finalOutput = try await session.finish()
    await eventTask.value
    let descriptor = provider.descriptor
    let result = await recorder.result(
        engine: LiveBenchmarkEngine(
            id: engine.rawValue,
            version: descriptor.version,
            model: descriptor.modelVersion ?? descriptor.name
        ),
        locale: options.locale.identifier,
        mode: options.mode,
        chunkMilliseconds: options.chunkMilliseconds,
        audioDurationSeconds: audioDuration,
        finalText: transcriptText(finalOutput)
    )
    try write(result, to: options.output)
}

do {
    try await run(parseOptions(Array(CommandLine.arguments.dropFirst())))
} catch {
    fail(String(describing: error))
}
