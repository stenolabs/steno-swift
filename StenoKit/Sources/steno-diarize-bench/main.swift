// steno-diarize-bench runs FluidSortformerProvider over an audio file and
// emits dscore-compatible RTTM for comparison with the documented historical
// baseline.
// Usage: steno-diarize-bench <wav> <rttm-out> [--gpu]

import Foundation
import StenoDiarization

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("steno-diarize-bench: \(message)\n".utf8))
    exit(1)
}

let args = CommandLine.arguments
guard args.count >= 3 else {
    fail("usage: steno-diarize-bench <wav> <rttm-out> [--gpu]")
}
let audioURL = URL(fileURLWithPath: args[1])
let rttmURL = URL(fileURLWithPath: args[2])
let computeUnits: DiarizationComputeUnits = args.contains("--gpu") ? .all : .cpuAndNeuralEngine
let meeting = audioURL.deletingPathExtension().lastPathComponent

do {
    let provider = FluidSortformerProvider(computeUnits: computeUnits)
    let clock = ContinuousClock()
    let start = clock.now
    let output = try await provider.diarize(audioURL, hints: DiarizationHints())
    let elapsed = clock.now - start

    var lines: [String] = []
    for segment in output.segments.sorted(by: { $0.start < $1.start }) {
        let duration = segment.end - segment.start
        guard duration > 0 else { continue }
        lines.append(String(
            format: "SPEAKER %@ 1 %.3f %.3f <NA> <NA> %@ <NA> <NA>",
            meeting, segment.start, duration, segment.clusterID
        ))
    }
    guard !lines.isEmpty else { fail("keine Segmente für \(meeting)") }
    try (lines.joined(separator: "\n") + "\n")
        .write(to: rttmURL, atomically: true, encoding: .utf8)

    let seconds = Double(elapsed.components.seconds)
        + Double(elapsed.components.attoseconds) / 1e18
    let clusters = Set(output.segments.map(\.clusterID))
    FileHandle.standardError.write(Data(
        "\(meeting): \(lines.count) Segmente, \(clusters.count) Cluster, \(output.embeddings.count) Embeddings, \(String(format: "%.1f", seconds)) s\n".utf8
    ))
    exit(0)
} catch {
    fail(String(describing: error))
}
