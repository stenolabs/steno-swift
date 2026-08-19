@preconcurrency import AVFAudio
import Foundation
import Speech

actor SpeechLiveTranscriptionSession: LiveTranscriptionSession {
    private static let inputCapacity = 64
    nonisolated let events: AsyncStream<TranscriptionEvent>

    private let analyzer: SpeechAnalyzer
    private let converter: PCMBufferConverter
    private let inputBuffer: BoundedAsyncBuffer<AnalyzerInput>
    private let eventContinuation: AsyncStream<TranscriptionEvent>.Continuation
    private let analysisTask: Task<Void, any Error>
    private var resultTask: Task<Void, any Error>?
    private var accumulator: TranscriptionAccumulator
    private var inputFinished = false
    private var terminalError: (any Error)?
    private var completedOutput: TranscriptOutput?
    private var finishTask: Task<TranscriptOutput, any Error>?

    init(
        analyzer: SpeechAnalyzer,
        analyzerFormat: AVAudioFormat,
        locale: Locale
    ) {
        let inputBuffer = BoundedAsyncBuffer<AnalyzerInput>(
            capacity: Self.inputCapacity
        )
        let eventPair = AsyncStream.makeStream(
            of: TranscriptionEvent.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        events = eventPair.stream
        self.inputBuffer = inputBuffer
        eventContinuation = eventPair.continuation
        self.analyzer = analyzer
        converter = PCMBufferConverter(targetFormat: analyzerFormat)
        accumulator = TranscriptionAccumulator(localeIdentifier: locale.identifier)
        analysisTask = Task {
            let lastSampleTime = try await analyzer.analyzeSequence(inputBuffer.stream)
            if let lastSampleTime {
                try await analyzer.finalizeAndFinish(through: lastSampleTime)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        }
    }

    func startResultConsumption(
        transcriber: SpeechTranscriber,
        channel: TranscriptionChannel
    ) {
        precondition(resultTask == nil)
        resultTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let block = SpeechResultConverter.block(
                        text: result.text,
                        range: result.range,
                        channel: channel
                    )
                    await self?.record(block, isFinal: result.isFinal)
                }
            } catch {
                await self?.fail(error)
                throw error
            }
        }
    }

    func append(_ buffer: AudioBuffer) async {
        guard !inputFinished, terminalError == nil else { return }
        do {
            for converted in try converter.convert(buffer.avAudioPCMBuffer) {
                guard inputBuffer.yield(AnalyzerInput(buffer: converted)) else {
                    await fail(TranscriptionError.audioInputOverflow(
                        capacity: Self.inputCapacity
                    ))
                    return
                }
            }
        } catch {
            await fail(error)
        }
    }

    func finish() async throws -> TranscriptOutput {
        if let completedOutput { return completedOutput }
        if let finishTask { return try await finishTask.value }
        let task = Task { try await self.performFinish() }
        finishTask = task
        return try await task.value
    }

    private func performFinish() async throws -> TranscriptOutput {
        if terminalError == nil, !inputFinished {
            do {
                for converted in try converter.flush() {
                    guard inputBuffer.yield(AnalyzerInput(buffer: converted)) else {
                        throw TranscriptionError.audioInputOverflow(
                            capacity: Self.inputCapacity
                        )
                    }
                }
            } catch {
                await fail(error)
            }
        }
        finishInput()

        do {
            try await analysisTask.value
            if let resultTask {
                try await resultTask.value
            }
        } catch {
            await fail(error)
        }
        eventContinuation.finish()
        if let terminalError { throw terminalError }
        let output = accumulator.output
        completedOutput = output
        return output
    }

    private func finishInput() {
        guard !inputFinished else { return }
        inputFinished = true
        inputBuffer.finish()
    }

    private func record(
        _ block: TranscriptionBlock,
        isFinal: Bool
    ) {
        let event = accumulator.record(block, isFinal: isFinal)
        eventContinuation.yield(event)
    }

    private func fail(_ error: any Error) async {
        guard terminalError == nil else { return }
        terminalError = error
        finishInput()
        eventContinuation.finish()
        await analyzer.cancelAndFinishNow()
    }
}
