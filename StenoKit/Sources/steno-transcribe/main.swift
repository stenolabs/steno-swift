// steno-transcribe: transkribiert eine Audiodatei über den
// SpeechAnalyzerProvider und schreibt JSON auf stdout.
// Nutzung: steno-transcribe <audio-datei> <locale>
// Ausgabe: {"locale":..., "wall_s":..., "text":..., "segments":[{start,end}],
//           "words": <Anzahl Wörter mit Zeitstempeln>}
// Für Benchmarks: wall_s misst ausschließlich transcribeFile, ohne
// Prozessstart und ohne JSON-Aufbereitung.

import Foundation
import StenoTranscription

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("steno-transcribe: \(message)\n".utf8))
    exit(1)
}

guard CommandLine.arguments.count == 3 else {
    fail("usage: steno-transcribe <audio-file> <locale>")
}
let audioURL = URL(fileURLWithPath: CommandLine.arguments[1])
let locale = Locale(identifier: CommandLine.arguments[2])

struct Segment: Encodable {
    let start: Double
    let end: Double
}
struct Output: Encodable {
    let locale: String
    let wall_s: Double
    let text: String
    let segments: [Segment]
    let words: Int
}

do {
    let provider = SpeechAnalyzerProvider(channel: .system)
    let t0 = ContinuousClock.now
    let result = try await provider.transcribeFile(audioURL, locale: locale)
    let wall = Double((ContinuousClock.now - t0).components.seconds)
        + Double((ContinuousClock.now - t0).components.attoseconds) / 1e18

    let output = Output(
        locale: result.localeIdentifier,
        wall_s: wall,
        text: result.blocks.map(\.text).joined(separator: " "),
        segments: result.blocks.map { Segment(start: $0.start, end: $0.end) },
        words: result.blocks.reduce(0) { $0 + $1.words.count }
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    print(String(data: try encoder.encode(output), encoding: .utf8)!)
    exit(0)
} catch {
    fail(String(describing: error))
}
