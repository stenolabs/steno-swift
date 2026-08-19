@preconcurrency import AVFAudio
import Foundation
import Testing
@testable import StenoAudioCore

@Suite("TrackContinuity")
struct TrackContinuityTests {
    @Test("the first buffer preserves silence since the shared session start")
    func firstBufferKeepsTrackAlignment() async throws {
        let fixture = makeFixture(alignFirstBufferToSessionStart: true)

        await fixture.timeline.receive(
            syntheticBuffer(),
            at: fixture.start.advanced(by: .seconds(1))
        )
        await fixture.timeline.finish(
            at: fixture.start.advanced(by: .milliseconds(1_500))
        )

        let writer = await fixture.writer.value
        #expect(writer.frameCount == 12_000)
        #expect(writer.nonSilentBufferCount == 1)
        #expect(writer.leadingSilentFrames == 8_000)
    }

    @Test("a manual pause fills only the writer timeline with silence")
    func manualPauseFillsWriterOnly() async throws {
        let fixture = makeFixture()
        await fixture.timeline.receive(syntheticBuffer(), at: fixture.start)
        await fixture.timeline.setUserPaused(
            true,
            at: fixture.start.advanced(by: .milliseconds(500))
        )
        await fixture.timeline.tick(
            at: fixture.start.advanced(by: .milliseconds(1_500))
        )
        await fixture.timeline.setUserPaused(
            false,
            at: fixture.start.advanced(by: .milliseconds(1_500))
        )
        await fixture.timeline.finish(
            at: fixture.start.advanced(by: .seconds(2))
        )

        let writer = await fixture.writer.value
        let live = await fixture.live.value
        #expect(writer.frameCount == 16_000)
        #expect(writer.nonSilentBufferCount == 1)
        #expect(live.bufferCount == 1)
        #expect(live.gapReasons == [.userPaused])
        #expect(live.gapEndCount == 1)
    }

    @Test("device loss and user pause remain independent")
    func overlappingReasonsDoNotResumeUserPause() async throws {
        let fixture = makeFixture()
        await fixture.timeline.receive(syntheticBuffer(), at: fixture.start)
        await fixture.timeline.setDeviceAvailable(
            false,
            deviceName: "AirPods",
            at: fixture.start.advanced(by: .milliseconds(500))
        )
        await fixture.timeline.setUserPaused(
            true,
            at: fixture.start.advanced(by: .milliseconds(750))
        )
        await fixture.timeline.setDeviceAvailable(
            true,
            deviceName: "AirPods",
            at: fixture.start.advanced(by: .seconds(1))
        )

        let stillPaused = await fixture.timeline.status
        #expect(stillPaused.deviceAvailable)
        #expect(stillPaused.userPaused)
        await fixture.timeline.tick(
            at: fixture.start.advanced(by: .milliseconds(1_500))
        )
        await fixture.timeline.setUserPaused(
            false,
            at: fixture.start.advanced(by: .milliseconds(1_500))
        )
        await fixture.timeline.receive(
            syntheticBuffer(),
            at: fixture.start.advanced(by: .milliseconds(1_500))
        )
        await fixture.timeline.finish(
            at: fixture.start.advanced(by: .seconds(2))
        )

        let writer = await fixture.writer.value
        let live = await fixture.live.value
        #expect(writer.frameCount == 16_000)
        #expect(writer.nonSilentBufferCount == 2)
        #expect(live.bufferCount == 2)
        #expect(live.gapReasons == [.deviceUnavailable])
        #expect(live.gapEndCount == 1)
    }

    @Test("a silent source stall is backfilled from the last buffer end")
    func watchdogStallBackfillsWriterOnly() async throws {
        let fixture = makeFixture(stallTimeout: .seconds(2))
        await fixture.timeline.receive(syntheticBuffer(), at: fixture.start)
        await fixture.timeline.tick(
            at: fixture.start.advanced(by: .milliseconds(2_500))
        )
        let stalled = await fixture.timeline.status
        #expect(stalled.sourceStalled)
        await fixture.timeline.receive(
            syntheticBuffer(),
            at: fixture.start.advanced(by: .milliseconds(2_500))
        )
        await fixture.timeline.finish(
            at: fixture.start.advanced(by: .seconds(3))
        )

        let writer = await fixture.writer.value
        let live = await fixture.live.value
        #expect(writer.frameCount == 24_000)
        #expect(writer.nonSilentBufferCount == 2)
        #expect(live.bufferCount == 2)
        #expect(live.gapReasons == [.sourceStalled])
    }

    @Test("long gaps use bounded silence buffers")
    func boundsSilenceChunks() async throws {
        let fixture = makeFixture(maximumSilenceDuration: .milliseconds(250))
        await fixture.timeline.setUserPaused(true, at: fixture.start)
        await fixture.timeline.tick(
            at: fixture.start.advanced(by: .seconds(5))
        )
        await fixture.timeline.finish(
            at: fixture.start.advanced(by: .seconds(5))
        )

        let writer = await fixture.writer.value
        #expect(writer.frameCount == 40_000)
        #expect(writer.bufferLengths.allSatisfy { $0 <= 2_000 })
        #expect(writer.bufferLengths.count == 20)
    }

    @Test("stopping during a gap fills exactly to the stop instant")
    func stopDuringGap() async throws {
        let fixture = makeFixture()
        await fixture.timeline.receive(syntheticBuffer(), at: fixture.start)
        await fixture.timeline.setDeviceAvailable(
            false,
            deviceName: "AirPods",
            at: fixture.start.advanced(by: .milliseconds(500))
        )
        await fixture.timeline.finish(
            at: fixture.start.advanced(by: .milliseconds(1_750))
        )

        let writer = await fixture.writer.value
        #expect(writer.frameCount == 14_000)
        #expect(writer.nonSilentBufferCount == 1)
    }

    @Test("a returned buffer cannot overwrite silence already written")
    func trimsOverlappingReturnedBuffer() async throws {
        let fixture = makeFixture()
        await fixture.timeline.receive(syntheticBuffer(), at: fixture.start)
        await fixture.timeline.setDeviceAvailable(
            false,
            deviceName: "AirPods",
            at: fixture.start.advanced(by: .milliseconds(500))
        )
        await fixture.timeline.tick(
            at: fixture.start.advanced(by: .milliseconds(1_600))
        )
        await fixture.timeline.setDeviceAvailable(
            true,
            deviceName: "AirPods",
            at: fixture.start.advanced(by: .milliseconds(1_600))
        )
        await fixture.timeline.receive(
            syntheticBuffer(),
            at: fixture.start.advanced(by: .milliseconds(1_500))
        )
        await fixture.timeline.finish(
            at: fixture.start.advanced(by: .seconds(2))
        )

        let writer = await fixture.writer.value
        #expect(writer.frameCount == 16_000)
        #expect(writer.bufferLengths.last == 3_200)
    }
}

private struct ContinuityFixture: Sendable {
    let start: ContinuousClock.Instant
    let timeline: TrackContinuity
    let writer: Task<WriterCapture, Never>
    let live: Task<LiveCapture, Never>
}

private struct WriterCapture: Sendable {
    let frameCount: Int
    let nonSilentBufferCount: Int
    let bufferLengths: [Int]
    let leadingSilentFrames: Int
}

private struct LiveCapture: Sendable {
    let bufferCount: Int
    let gapReasons: [TrackGapReason]
    let gapEndCount: Int
}

private func makeFixture(
    stallTimeout: Duration = .seconds(10),
    maximumSilenceDuration: Duration = .milliseconds(250),
    alignFirstBufferToSessionStart: Bool = false
) -> ContinuityFixture {
    let writerPair = AsyncStream.makeStream(of: AVAudioPCMBuffer.self)
    let livePair = AsyncStream.makeStream(of: LiveAudioEvent.self)
    let start = ContinuousClock.now
    let timeline = TrackContinuity(
        format: syntheticBuffer().format,
        sessionStart: start,
        writerContinuation: writerPair.continuation,
        liveContinuation: livePair.continuation,
        stallTimeout: stallTimeout,
        maximumSilenceDuration: maximumSilenceDuration,
        alignFirstBufferToSessionStart: alignFirstBufferToSessionStart,
        writerOverflowHandler: {}
    )
    let writerStream = writerPair.stream
    let writer = Task {
        var frameCount = 0
        var nonSilentBufferCount = 0
        var bufferLengths: [Int] = []
        var leadingSilentFrames = 0
        var receivedNonSilence = false
        for await buffer in writerStream {
            frameCount += Int(buffer.frameLength)
            bufferLengths.append(Int(buffer.frameLength))
            if AudioLevelMeter.measure(buffer).peak > 0 {
                nonSilentBufferCount += 1
                receivedNonSilence = true
            } else if !receivedNonSilence {
                leadingSilentFrames += Int(buffer.frameLength)
            }
        }
        return WriterCapture(
            frameCount: frameCount,
            nonSilentBufferCount: nonSilentBufferCount,
            bufferLengths: bufferLengths,
            leadingSilentFrames: leadingSilentFrames
        )
    }
    let liveStream = livePair.stream
    let live = Task {
        var bufferCount = 0
        var gapReasons: [TrackGapReason] = []
        var gapEndCount = 0
        for await event in liveStream {
            switch event {
            case .buffer:
                bufferCount += 1
            case let .gapStarted(_, reason):
                gapReasons.append(reason)
            case .gapEnded:
                gapEndCount += 1
            }
        }
        return LiveCapture(
            bufferCount: bufferCount,
            gapReasons: gapReasons,
            gapEndCount: gapEndCount
        )
    }
    return ContinuityFixture(
        start: start,
        timeline: timeline,
        writer: writer,
        live: live
    )
}
