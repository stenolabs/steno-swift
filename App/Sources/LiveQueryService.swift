import Foundation
import StenoDomain
import StenoIntelligence
import StenoTranscription

/// Everything one live query may see, snapshotted at ask time.
///
/// Built from the recording view's observable state so the service itself
/// stays free of UI dependencies and testable with plain values.
struct LiveQueryContext: Equatable, Sendable {
    var rows: [LiveTranscriptFeed.Row]
    var meetingTitle: String?
    var participantNames: [String]

    /// A query is only offered once at least one finalized row carries real
    /// content; provisional hypotheses never qualify.
    var hasFinalizedContent: Bool {
        rows.contains {
            $0.kind == .final && LiveQueryPromptAssembler.isMeaningful($0.block.text)
        }
    }

    /// Finalized rows only, oldest first; the assembler filters again as a
    /// structural backstop.
    var finalizedSegments: [LiveQueryTranscriptSegment] {
        rows
            .filter { $0.kind == .final }
            .sorted { $0.block.start < $1.block.start }
            .map { row in
                LiveQueryTranscriptSegment(
                    speaker: ChannelLabel.speakerLabel(row.block.channel.speakerLabel),
                    start: row.block.start,
                    end: row.block.end,
                    text: row.block.text,
                    isFinal: true
                )
            }
    }
}

/// Runs live Ask-bar questions against the selected text model.
///
/// Transport guarantees ported from the Electron predecessor:
/// - exactly one query in flight; a new question or an explicit cancel owns
///   and cancels the previous run,
/// - the prompt comes from `LiveQueryPromptAssembler` (finalized segments
///   only, capped context),
/// - errors surface as fixed, sanitized messages; question, transcript and
///   answer text are never logged anywhere.
///
/// A monotonically increasing generation guards every phase write: a run that
/// was just displaced by a newer question must never clobber the newer run's
/// state when its cancellation lands.
@MainActor
@Observable
final class LiveQueryService {
    enum Phase: Equatable {
        case idle
        case asking
        /// The answer accumulated so far; each chunk is appended verbatim.
        case answering(String)
        case failed(String)
    }

    private(set) var phase: Phase = .idle

    private var task: Task<Void, Never>?
    private var generation = 0

    private let assembler = LiveQueryPromptAssembler()
    private let makeAnswerer: @MainActor () throws -> any LiveQueryAnswering
    private let contextProvider: @MainActor () -> LiveQueryContext

    init(
        makeAnswerer: @escaping @MainActor () throws -> any LiveQueryAnswering,
        contextProvider: @escaping @MainActor () -> LiveQueryContext
    ) {
        self.makeAnswerer = makeAnswerer
        self.contextProvider = contextProvider
    }

    /// True while a question is being answered or streamed.
    var isActive: Bool { task != nil }

    /// A finished answer stays visible in `.answering`, so "can ask" cannot
    /// key off the phase alone: the single in-flight bound (`isActive`) is
    /// the real gate. Asking again replaces the displayed answer.
    var canAsk: Bool {
        !isActive
    }

    /// Starts a new query. Any running query is cancelled first: single
    /// in-flight by construction.
    func ask(question: String) {
        cancel()

        let snapshot = contextProvider()
        guard snapshot.hasFinalizedContent else {
            phase = .failed(LiveQueryPromptError.noFinalizedTranscript.errorDescription ?? "")
            return
        }
        let prompt: LiveQueryPrompt
        do {
            prompt = try assembler.assemble(
                question: question,
                meetingTitle: snapshot.meetingTitle,
                participants: snapshot.participantNames,
                segments: snapshot.finalizedSegments
            )
        } catch let error as LiveQueryPromptError {
            phase = .failed(error.errorDescription ?? "The question could not be prepared.")
            return
        } catch {
            phase = .failed("The question could not be prepared.")
            return
        }
        let answerer: any LiveQueryAnswering
        do {
            answerer = try makeAnswerer()
        } catch {
            phase = .failed(fixedMessage(for: error))
            return
        }

        generation += 1
        let currentGeneration = generation
        phase = .asking
        task = Task { [weak self] in
            await self?.run(
                answerer: answerer,
                prompt: prompt,
                generation: currentGeneration
            )
        }
    }

    /// Owner-bound cancellation: the bar closing or the recording stopping
    /// cancels the in-flight request without leaving an error behind.
    func cancel() {
        let wasActive = task != nil
        task?.cancel()
        task = nil
        if wasActive {
            generation += 1
            phase = .idle
        }
    }

    private func setPhase(_ newValue: Phase, generation runGeneration: Int) {
        guard runGeneration == generation else { return }
        phase = newValue
    }

    private func finishRun(generation runGeneration: Int) {
        guard runGeneration == generation else { return }
        task = nil
    }

    private func run(
        answerer: any LiveQueryAnswering,
        prompt: LiveQueryPrompt,
        generation runGeneration: Int
    ) async {
        var answer = ""
        setPhase(.answering(answer), generation: runGeneration)
        let stream = answerer.stream(
            systemInstructions: prompt.systemInstructions,
            userPrompt: prompt.userPrompt
        )
        do {
            for try await chunk in stream {
                try Task.checkCancellation()
                answer += chunk
                setPhase(.answering(answer), generation: runGeneration)
            }
            finishRun(generation: runGeneration)
            if answer.isEmpty {
                setPhase(
                    .failed(LiveQueryTransportError.invalidResponse.errorDescription ?? ""),
                    generation: runGeneration
                )
            } else {
                setPhase(.answering(answer), generation: runGeneration)
            }
        } catch is CancellationError {
            setPhase(.idle, generation: runGeneration)
        } catch {
            setPhase(.failed(fixedMessage(for: error)), generation: runGeneration)
        }
    }

    /// Maps every failure to a fixed sentence. Deliberately loses error
    /// detail: provider messages can echo request content, and prompt or
    /// answer text must never reach the UI log.
    private func fixedMessage(for error: Error) -> String {
        switch error as? LiveQueryTransportError {
        case .some(let known):
            known.errorDescription ?? "The model could not answer right now."
        case .none:
            "The model could not answer right now."
        }
    }
}
