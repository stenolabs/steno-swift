import FluidAudio
import Foundation

/// Extracts one centroid per active Sortformer slot from the frame-level
/// predictions. Any model or chunk failure returns partial or empty embeddings;
/// segments remain the load-bearing result of the provider.
func extractSortformerEmbeddings(
    audio: [Float],
    timeline: DiarizerTimeline,
    models: DiarizerModels
) -> [String: [Float]] {
    guard
        let shape = models.segmentationModel.modelDescription
            .outputDescriptionsByName["segments"]?
            .multiArrayConstraint?
            .shape,
        shape.count >= 2
    else {
        return [:]
    }
    let weSpeakerFrameCount = shape[1].intValue
    guard weSpeakerFrameCount > 0 else { return [:] }

    let masks = buildOverlapExcludedMasks(
        predictions: timeline.finalizedPredictions,
        numSpeakers: timeline.config.numSpeakers,
        threshold: timeline.config.onsetThreshold
    )
    guard masks.first?.isEmpty == false else { return [:] }

    let extractor = EmbeddingExtractor(embeddingModel: models.embeddingModel)
    let accumulated = accumulateChunkEmbeddings(
        audio: audio,
        masks: masks,
        frameDuration: Double(timeline.config.frameDurationSeconds),
        weSpeakerFrameCount: weSpeakerFrameCount,
        extractor: extractor
    )
    return aggregateCentroids(sums: accumulated.sums, counts: accumulated.counts)
}

/// Runs WeSpeaker over 10 second windows because its waveform input is fixed
/// at 160,000 samples. Only the three most active slots fit its mask tensor;
/// Sortformer's fourth slot is still covered whenever it enters a window's top
/// three. A transient failure skips one window instead of erasing a long run's
/// already accumulated voiceprints, matching the real 3.5 hour failure mode
/// observed in the sidecar.
private func accumulateChunkEmbeddings(
    audio: [Float],
    masks: [[Float]],
    frameDuration: Double,
    weSpeakerFrameCount: Int,
    extractor: EmbeddingExtractor
) -> (sums: [String: [Float]], counts: [String: Int]) {
    let chunkSamples = 160_000
    let framesPerChunk = max(1, Int(10 / frameDuration))
    let speakerCount = masks.count
    let maskFrameCount = masks.first?.count ?? 0
    var sums: [String: [Float]] = [:]
    var counts: [String: Int] = [:]

    var sampleStart = 0
    var frameStart = 0
    while sampleStart < audio.count, frameStart < maskFrameCount {
        let sampleEnd = min(sampleStart + chunkSamples, audio.count)
        let frameEnd = min(frameStart + framesPerChunk, maskFrameCount)
        let window = prepareSortformerEmbeddingWindow(
            audio: Array(audio[sampleStart..<sampleEnd]),
            masks: (0..<speakerCount).map {
                Array(masks[$0][frameStart..<frameEnd])
            },
            samplesPerWindow: chunkSamples,
            framesPerWindow: framesPerChunk
        )
        let chunk = window.audio
        let chunkMasks = window.masks
        let topSlots = (0..<speakerCount)
            .map { slot in
                (slot: slot, activity: chunkMasks[slot].reduce(0, +))
            }
            .sorted {
                if $0.activity == $1.activity { return $0.slot < $1.slot }
                return $0.activity > $1.activity
            }
            .prefix(3)
            .map(\.slot)
        let embeddingMasks = topSlots.map {
            resampleMask(chunkMasks[$0], to: weSpeakerFrameCount)
        }

        do {
            let embeddings = try extractor.getEmbeddings(
                audio: chunk,
                masks: embeddingMasks
            )
            for (index, slot) in topSlots.enumerated() where index < embeddings.count {
                let embedding = embeddings[index]
                guard
                    embedding.count == 256,
                    !embedding.allSatisfy({ $0 == 0 })
                else { continue }
                let clusterID = "SPEAKER_\(slot)"
                if let existing = sums[clusterID] {
                    sums[clusterID] = zip(existing, embedding).map(+)
                } else {
                    sums[clusterID] = embedding
                }
                counts[clusterID, default: 0] += 1
            }
        } catch {
            // Best effort by design. The next chunk remains independent.
        }

        sampleStart = sampleEnd
        frameStart = frameEnd
    }
    return (sums, counts)
}

struct SortformerEmbeddingWindow: Equatable, Sendable {
    let audio: [Float]
    let masks: [[Float]]
}

/// WeSpeaker interprets both inputs on a fixed ten-second time axis. Padding
/// only one side would make the final, shorter window select audio from a
/// different point in time than its activity mask.
func prepareSortformerEmbeddingWindow(
    audio: [Float],
    masks: [[Float]],
    samplesPerWindow: Int,
    framesPerWindow: Int
) -> SortformerEmbeddingWindow {
    SortformerEmbeddingWindow(
        audio: padWithZeros(audio, to: samplesPerWindow),
        masks: masks.map { padWithZeros($0, to: framesPerWindow) }
    )
}

private func padWithZeros(_ values: [Float], to count: Int) -> [Float] {
    let targetCount = max(0, count)
    let retained = Array(values.prefix(targetCount))
    guard retained.count < targetCount else { return retained }
    return retained + Array(repeating: 0, count: targetCount - retained.count)
}
