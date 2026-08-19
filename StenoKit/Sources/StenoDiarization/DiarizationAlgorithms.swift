import Foundation

// Segments shorter than 250 ms are dropped. Real meeting recordings showed
// roughly 80 ms noise blips that otherwise appeared as phantom speaker turns.
let minimumSegmentDuration: TimeInterval = 0.25

// highContextV2 needs a complete 340 + 40 frame input window before emitting
// anything. A 12.25 second clip empirically produced no segments, so 90 seconds
// keeps a deliberate margin above the roughly 30.4 second hard minimum. On a
// three hour recording its larger windows also cut CoreML invocations from
// roughly 22,500 to 400. V2 is used for high context because FluidAudio warns
// that V2.1 may degrade when many speakers overlap, a real meeting-audio risk.
let highContextMinimumDuration: TimeInterval = 90

enum SortformerConfigurationChoice: Equatable, Sendable {
    case `default`
    case highContextV2
}

func sortformerConfiguration(forDuration duration: TimeInterval) -> SortformerConfigurationChoice {
    duration >= highContextMinimumDuration ? .highContextV2 : .default
}

/// Builds one mask per speaker slot. Every frame with two or more active
/// speakers is zeroed for all slots so crosstalk cannot contaminate embeddings.
/// A separate runner-up margin was measured on AMI same-room audio and did not
/// improve discrimination, so this keeps the simpler DiariZen-style rule.
func buildOverlapExcludedMasks(
    predictions: [Float],
    numSpeakers: Int,
    threshold: Float
) -> [[Float]] {
    guard numSpeakers > 0, !predictions.isEmpty else { return [] }
    let frameCount = predictions.count / numSpeakers
    guard frameCount > 0 else { return [] }

    var masks = Array(
        repeating: Array(repeating: Float(0), count: frameCount),
        count: numSpeakers
    )
    for frame in 0..<frameCount {
        let offset = frame * numSpeakers
        var activeSlot = -1
        var activeCount = 0
        for slot in 0..<numSpeakers where predictions[offset + slot] >= threshold {
            activeSlot = slot
            activeCount += 1
            if activeCount > 1 { break }
        }
        if activeCount == 1 {
            masks[activeSlot][frame] = 1
        }
    }
    return masks
}

/// Nearest-neighbour mapping keeps activity masks discrete while bridging
/// Sortformer's roughly 12.5 Hz frames to WeSpeaker's denser frame grid.
func resampleMask(_ mask: [Float], to targetCount: Int) -> [Float] {
    guard !mask.isEmpty, targetCount > 0 else {
        return Array(repeating: 0, count: max(0, targetCount))
    }
    return (0..<targetCount).map { index in
        mask[min(index * mask.count / targetCount, mask.count - 1)]
    }
}

/// Averages all successful chunk embeddings for each Sortformer slot and
/// L2-normalizes the mean into a stable voiceprint centroid.
func aggregateCentroids(
    sums: [String: [Float]],
    counts: [String: Int]
) -> [String: [Float]] {
    var result: [String: [Float]] = [:]
    result.reserveCapacity(sums.count)
    for (clusterID, sum) in sums {
        let count = Float(counts[clusterID] ?? 1)
        var mean = sum.map { $0 / count }
        let norm = mean.reduce(into: Float(0)) { partial, value in
            partial += value * value
        }.squareRoot()
        if norm > 1e-9 {
            mean = mean.map { $0 / norm }
        }
        result[clusterID] = mean
    }
    return result
}

func filterDiarizationSegments(
    _ segments: [DiarizationSegment]
) -> [DiarizationSegment] {
    segments
        .filter { $0.duration >= minimumSegmentDuration }
        .sorted {
            if $0.start == $1.start { return $0.clusterID < $1.clusterID }
            return $0.start < $1.start
        }
}
