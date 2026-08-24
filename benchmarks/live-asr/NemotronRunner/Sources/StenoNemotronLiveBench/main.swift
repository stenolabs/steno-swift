@preconcurrency import AVFAudio
import FluidAudio
import Foundation
import NemotronBenchmarkSupport

private let fluidAudioRevision = "667181a368da13b3a9178e310414e9dcbe8f23ce"

private struct Options {
    var input: URL?
    var output: URL?
    var modelDirectory: URL?
    var modelCache: URL?
    var language: String?
    var chunkMilliseconds = 2_240
    var feedChunkMilliseconds = 20
    var realtime = false
}

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("steno-nemotron-live-bench: \(message)\n".utf8))
    exit(2)
}

private func usage() -> Never {
    fail(
        "usage: steno-nemotron-live-bench --input <audio> --language de-DE "
            + "[--chunk-ms 2240] [--feed-chunk-ms 20] [--mode fast|realtime] "
            + "[--model-dir <variant>] [--model-cache <root>] [--output result.json]"
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
        case "--input":
            options.input = URL(fileURLWithPath: nextValue())
        case "--output":
            options.output = URL(fileURLWithPath: nextValue())
        case "--model-dir":
            options.modelDirectory = URL(fileURLWithPath: nextValue())
        case "--model-cache":
            options.modelCache = URL(fileURLWithPath: nextValue())
        case "--language":
            options.language = nextValue()
        case "--chunk-ms":
            guard let value = Int(nextValue()) else { usage() }
            options.chunkMilliseconds = value
        case "--feed-chunk-ms":
            guard let value = Int(nextValue()) else { usage() }
            options.feedChunkMilliseconds = value
        case "--mode":
            switch nextValue() {
            case "fast": options.realtime = false
            case "realtime": options.realtime = true
            default: usage()
            }
        case "--help", "-h":
            usage()
        default:
            usage()
        }
        index += 1
    }
    return options
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
    guard let input = options.input, let language = options.language else { usage() }
    guard FileManager.default.fileExists(atPath: input.path) else {
        fail("input file does not exist: \(input.path)")
    }
    let configuration = try NemotronBenchmarkConfiguration(
        language: language,
        chunkMilliseconds: options.chunkMilliseconds,
        feedChunkMilliseconds: options.feedChunkMilliseconds,
        realtime: options.realtime
    )

    let modelDirectory: URL
    if let explicit = options.modelDirectory {
        modelDirectory = explicit
    } else {
        modelDirectory = try await StreamingNemotronMultilingualAsrManager.downloadVariant(
            languageCode: configuration.language,
            chunkMs: configuration.chunkMilliseconds,
            to: options.modelCache
        )
    }

    let manager = StreamingNemotronMultilingualAsrManager()
    try await manager.loadModels(from: modelDirectory)
    await manager.setLanguage(configuration.language)
    await manager.setForcedPrefix(true)

    let audioFile = try AVAudioFile(forReading: input)
    let format = audioFile.processingFormat
    let audioDuration = Double(audioFile.length) / format.sampleRate
    let benchmarkStartedAt = ProcessInfo.processInfo.systemUptime
    let recorder = LiveBenchmarkRecorder(startedAt: benchmarkStartedAt)
    let partials = AsyncStream.makeStream(
        of: String.self,
        bufferingPolicy: .unbounded
    )
    await manager.setPartialCallback { text in
        partials.continuation.yield(text)
    }
    let eventTask = Task {
        for await text in partials.stream {
            await recorder.record(kind: .volatile, text: text)
        }
    }

    let framesPerFeed = max(
        1,
        AVAudioFrameCount(
            format.sampleRate * Double(configuration.feedChunkMilliseconds) / 1_000
        )
    )
    let feedStart = ContinuousClock.now
    while audioFile.framePosition < audioFile.length {
        let remaining = AVAudioFrameCount(audioFile.length - audioFile.framePosition)
        let count = min(framesPerFeed, remaining)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: count
        ) else {
            fail("cannot allocate benchmark input buffer")
        }
        try audioFile.read(into: buffer, frameCount: count)
        guard buffer.frameLength > 0 else { break }
        let audioSecondsFed = Double(audioFile.framePosition) / format.sampleRate
        await recorder.setAudioSecondsFed(audioSecondsFed)
        _ = try await manager.process(audioBuffer: buffer)

        if configuration.realtime {
            let target = feedStart.advanced(by: .seconds(audioSecondsFed))
            if ContinuousClock.now < target {
                try await ContinuousClock().sleep(until: target)
            }
        }
    }

    let text = try await manager.finish()
    partials.continuation.finish()
    await eventTask.value
    await recorder.record(kind: .final, text: text)
    let updates = await recorder.updates()
    let wallSeconds = max(0, ProcessInfo.processInfo.systemUptime - benchmarkStartedAt)
    let result = LiveBenchmarkResult(
        engine: LiveBenchmarkEngine(
            id: "nemotron-multilingual",
            version: fluidAudioRevision,
            model: "Nemotron-3.5-ASR-Streaming-Multilingual-0.6B/\(configuration.language)/\(configuration.chunkMilliseconds)ms"
        ),
        locale: configuration.language,
        mode: configuration.realtime ? "realtime" : "fast",
        chunkMilliseconds: configuration.feedChunkMilliseconds,
        audioDurationSeconds: audioDuration,
        wallSeconds: wallSeconds,
        text: text.trimmingCharacters(in: .whitespacesAndNewlines),
        updates: updates
    )
    try write(result, to: options.output)
}

do {
    try await run(parseOptions(Array(CommandLine.arguments.dropFirst())))
} catch {
    fail(String(describing: error))
}
