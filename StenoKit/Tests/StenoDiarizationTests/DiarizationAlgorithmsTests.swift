import Foundation
import Testing
@testable import StenoDiarization

@Suite("Diarization algorithms")
struct DiarizationAlgorithmsTests {
    @Test("overlap exclusion keeps only frames with exactly one active slot")
    func excludesOverlapFromEverySpeakerMask() {
        let predictions: [Float] = [
            0.9, 0.1, 0.0, 0.0,
            0.8, 0.7, 0.0, 0.0,
            0.1, 0.2, 0.6, 0.0,
            0.1, 0.2, 0.3, 0.4,
        ]

        let masks = buildOverlapExcludedMasks(
            predictions: predictions,
            numSpeakers: 4,
            threshold: 0.5
        )

        #expect(masks == [
            [1, 0, 0, 0],
            [0, 0, 0, 0],
            [0, 0, 1, 0],
            [0, 0, 0, 0],
        ])
    }

    @Test("nearest-neighbour mask resampling preserves discrete activity")
    func resamplesMasksWithNearestNeighbour() {
        #expect(resampleMask([0, 1, 0], to: 6) == [0, 0, 1, 1, 0, 0])
        #expect(resampleMask([1, 0, 0, 1], to: 2) == [1, 0])
        #expect(resampleMask([], to: 3) == [0, 0, 0])
    }

    @Test("the final embedding window pads audio and mask on the same time axis")
    func padsFinalEmbeddingWindowInSync() {
        let window = prepareSortformerEmbeddingWindow(
            audio: [1, 2, 3, 4, 5],
            masks: [[0, 0, 1]],
            samplesPerWindow: 10,
            framesPerWindow: 6
        )

        #expect(window.audio == [1, 2, 3, 4, 5, 0, 0, 0, 0, 0])
        #expect(window.masks == [[0, 0, 1, 0, 0, 0]])
        #expect(resampleMask(window.masks[0], to: 12) == [
            0, 0, 0, 0, 1, 1,
            0, 0, 0, 0, 0, 0,
        ])
    }

    @Test("centroid aggregation averages every chunk and L2 normalizes the result")
    func aggregatesNormalizedCentroids() throws {
        let centroids = aggregateCentroids(
            sums: [
                "SPEAKER_0": [2, 0],
                "SPEAKER_1": [2, 2],
            ],
            counts: [
                "SPEAKER_0": 2,
                "SPEAKER_1": 1,
            ]
        )

        #expect(centroids["SPEAKER_0"] == [1, 0])
        let second = try #require(centroids["SPEAKER_1"])
        #expect(abs(second[0] - 0.707_106_77) < 0.000_001)
        #expect(abs(second[1] - 0.707_106_77) < 0.000_001)
    }

    @Test("segment filtering removes sub-250ms noise and sorts surviving turns")
    func filtersShortSegments() {
        let segments = [
            DiarizationSegment(clusterID: "SPEAKER_1", start: 3, end: 3.25),
            DiarizationSegment(clusterID: "SPEAKER_0", start: 1, end: 1.249),
            DiarizationSegment(clusterID: "SPEAKER_0", start: 0, end: 0.5),
        ]

        #expect(filterDiarizationSegments(segments) == [
            DiarizationSegment(clusterID: "SPEAKER_0", start: 0, end: 0.5),
            DiarizationSegment(clusterID: "SPEAKER_1", start: 3, end: 3.25),
        ])
    }

    @Test("high-context Sortformer starts at 90 seconds")
    func selectsSortformerConfigurationByDuration() {
        #expect(sortformerConfiguration(forDuration: 89.999) == .default)
        #expect(sortformerConfiguration(forDuration: 90) == .highContextV2)
        #expect(sortformerConfiguration(forDuration: 9_000) == .highContextV2)
    }
}
