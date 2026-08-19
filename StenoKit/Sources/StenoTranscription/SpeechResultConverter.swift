import CoreMedia
import Foundation
import Speech

enum SpeechResultConverter {
    static func block(
        text: AttributedString,
        range: CMTimeRange,
        channel: TranscriptionChannel
    ) -> TranscriptionBlock {
        let blockStart = seconds(range.start)
        let blockEnd = max(blockStart, seconds(CMTimeRangeGetEnd(range)))
        var words: [TranscriptionWord] = []

        for run in text.runs {
            guard let audioRange = run.audioTimeRange else { continue }
            let rawText = String(text[run.range].characters)
            let tokens = rawText.split(whereSeparator: { $0.isWhitespace })
            let start = seconds(audioRange.start)
            let end = max(start, seconds(CMTimeRangeGetEnd(audioRange)))
            for token in tokens {
                words.append(TranscriptionWord(
                    text: String(token),
                    start: start,
                    end: end
                ))
            }
        }

        return TranscriptionBlock(
            channel: channel,
            text: String(text.characters),
            start: blockStart,
            end: blockEnd,
            words: words
        )
    }

    private static func seconds(_ time: CMTime) -> TimeInterval {
        let value = CMTimeGetSeconds(time)
        return value.isFinite ? max(0, value) : 0
    }
}
