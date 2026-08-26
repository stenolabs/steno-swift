@preconcurrency import AVFAudio
import Darwin
import Foundation
import StenoTranscription
import Testing
@testable import StenoAudioCore

/// ARCHITECTURE s9 soak: a two-hour two-track meeting must process faster than
/// real time indefinitely, with constant memory.
///
/// The simulation pumps 7200 one-second stereo buffers through a TrackWriter
/// pair (temp CAF files) while feeding `LiveTranscriptFeed` with the cadence
/// the real sidecars produce: one finalised cumulative snapshot roughly every
/// five seconds per alternating channel (~1440 finals over two hours) and one
/// growing partial between finals, mirroring the legacy live-transcript-perf
/// harness's "same utterance growing" tick model.
///
/// Four guards, all documented relative bounds rather than absolute times:
///
/// 1. **Speed**: wall-clock processing stays under 0.25x of the simulated
///    audio duration. Relative so the guard survives faster machines; on this
///    reference hardware the run completes in seconds.
/// 2. **Feed retention**: rows stay capped by the latest cumulative snapshots
///    (~1440). The feed replaces channel state per event — pumping >8600
///    events must not accumulate beyond the transcript content itself, and
///    re-applying an identical snapshot must not duplicate anything.
/// 3. **Disk linearity**: CAF sizes grow linearly with written audio bytes
///    ONLY — exact frame counts from the writer summaries plus byte-size
///    formula checks mid-run and at the end.
/// 4. **Memory**: phys_footprint (the jetsam/Instruments metric) sampled at
///    start/mid/end grows less than 250 MB over the whole session, catching
///    unbounded buffering regressions in writer or feed paths.
@Suite("Long-session constant-memory soak", .serialized)
struct LongSessionSoakTests {
    // MARK: Simulation shape (documented constants)

    /// Two-hour meeting: 7200 ticks of one second each.
    private static let tickCount = 7200
    private static let sampleRate: Double = 48_000
    private static let channels: AVAudioChannelCount = 2
    /// One final every five ticks across both channels => ~1440 finals,
    /// matching the shape of a real two-hour two-channel meeting (~1500).
    private static let ticksPerFinal = 5
    /// 250 MB generous ceiling for footprint growth over the whole session.
    private static let footprintCeilingBytes: Int64 = 250 * 1_024 * 1_024
    /// Documented speed bound: processing must stay under a quarter of the
    /// simulated audio duration.
    private static let wallClockFactorBound = 0.25

    @Test(
        "two-hour two-track soak runs faster than real time with capped feed and flat footprint",
        .timeLimit(.minutes(3))
    )
    func twoHourTwoTrackSoak() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("soak-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: Self.channels,
            interleaved: false
        )!
        let microphoneWriter = try TrackWriter(
            url: tempDirectory.appendingPathComponent("microphone.caf"),
            sourceFormat: format
        )
        let systemWriter = try TrackWriter(
            url: tempDirectory.appendingPathComponent("system.caf"),
            sourceFormat: format
        )

        // One shared buffer reused for every write: the harness itself must be
        // constant-memory, otherwise its footprint assertion proves nothing.
        let buffer = Self.makeOneSecondBuffer(format: format)

        var feed = LiveTranscriptFeed()
        var histories: [TranscriptionChannel: [TranscriptionBlock]] = [
            .microphone: [], .system: [],
        ]
        var lastMicrophoneText: String?
        var lastOutputs: [TranscriptionChannel: TranscriptOutput] = [:]

        var rowCountsAtCheckpoints: [Int] = []
        var footprintStart: Int64?
        var footprintMid: Int64 = 0
        var bytesMid: Int64 = 0

        let clock = ContinuousClock()
        let processingStart = clock.now

        for tick in 0..<Self.tickCount {
            try await microphoneWriter.write(buffer)
            try await systemWriter.write(buffer)

            let isFinalBoundary = tick % Self.ticksPerFinal == 0
            if isFinalBoundary {
                let finalIndex = tick / Self.ticksPerFinal
                let owner: TranscriptionChannel = finalIndex % 2 == 0 ? .microphone : .system
                var text = Self.syntheticText(seed: finalIndex)
                // Every twentieth system final repeats the last mic utterance
                // verbatim: the echo path through the bleed filter must keep
                // working at scale (rows are marked, never removed).
                if owner == .system, finalIndex % 20 == 1, let echoed = lastMicrophoneText {
                    text = echoed
                }
                if owner == .microphone { lastMicrophoneText = text }
                let block = TranscriptionBlock(
                    channel: owner,
                    text: text,
                    start: Double(max(0, tick - Self.ticksPerFinal - 1)),
                    end: Double(tick),
                    words: []
                )
                let output = TranscriptOutput(
                    localeIdentifier: "en-US",
                    blocks: histories[owner]! + [block]
                )
                histories[owner]!.append(block)
                feed.apply(.final(output), for: owner)
                lastOutputs[owner] = output
            } else {
                // Growing partial: the same speaker's utterance extending, the
                // shape the recognisers actually emit between finals.
                let progress = tick % Self.ticksPerFinal
                let upcomingSeed = (tick + Self.ticksPerFinal - 1) / Self.ticksPerFinal
                let owner: TranscriptionChannel = upcomingSeed % 2 == 0 ? .microphone : .system
                let words = Self.syntheticText(seed: upcomingSeed).split(separator: " ")
                let partial = TranscriptionBlock(
                    channel: owner,
                    text: words.prefix(progress).joined(separator: " "),
                    start: Double(max(0, tick - progress)),
                    end: Double(tick + 1),
                    words: []
                )
                let output = TranscriptOutput(
                    localeIdentifier: "en-US",
                    blocks: histories[owner]! + [partial]
                )
                feed.apply(.volatile(output), for: owner)
            }

            if tick == 1 {
                footprintStart = Self.physFootprintBytes()
            }
            if tick == Self.tickCount / 2 {
                footprintMid = Self.physFootprintBytes()
                bytesMid = Self.fileSize(microphoneWriter.url)
                    + Self.fileSize(systemWriter.url)
            }
            if tick % 240 == 0 {
                // Checkpoint projection: pins the cap mid-run without paying a
                // full O(finals^2) bleed scan on every tick.
                rowCountsAtCheckpoints.append(feed.rows.count)
            }
        }

        let processingDuration = clock.now - processingStart
        let microphoneSummary = try await microphoneWriter.close()
        let systemSummary = try await systemWriter.close()

        // MARK: Guard 1 — faster than real time (relative bound)

        let processingSeconds = Double(processingDuration.components.seconds)
        let simulatedSeconds = Double(Self.tickCount)
        #expect(processingSeconds < simulatedSeconds * Self.wallClockFactorBound)

        // MARK: Guard 2 — feed rows capped by retention semantics

        let expectedFinals = Self.tickCount / Self.ticksPerFinal
        let rowsAfterRun = feed.rows
        let finalRows = rowsAfterRun.filter { $0.kind == .final }
        #expect(finalRows.count == expectedFinals)
        // At most one open partial per channel stays visible; the meeting
        // ends mid-utterance on one lane, so one volatile row is legitimate.
        let volatileRowCount = rowsAfterRun.count - finalRows.count
        #expect(volatileRowCount <= 2)
        // Volatile churn never accumulates: at every checkpoint the projected
        // rows stay within the finalized content plus at most one open
        // partial per channel.
        for (index, count) in rowCountsAtCheckpoints.enumerated() {
            let tick = index * 240
            let finalsSoFar = tick / Self.ticksPerFinal
            #expect(count <= finalsSoFar + 2)
        }
        // Re-applying identical snapshots is idempotent — no duplicate growth.
        // A replayed final legitimately supersedes its channel's open partial,
        // so the pinned quantity is the finalized row count.
        let finalCountBeforeReplay = finalRows.count
        for (channel, output) in lastOutputs {
            feed.apply(.final(output), for: channel)
        }
        #expect(feed.rows.filter { $0.kind == .final }.count == finalCountBeforeReplay)
        // Echo marking survives the full session: repeated mic text on the
        // system channel is flagged, not dropped and not duplicated.
        #expect(finalRows.contains { $0.excludedFromReports })

        // MARK: Guard 3 — file sizes grow linearly with audio bytes ONLY

        let expectedFrames = AVAudioFramePosition(Self.tickCount) * AVAudioFramePosition(Self.sampleRate)
        #expect(microphoneSummary.frameCount == expectedFrames)
        #expect(systemSummary.frameCount == expectedFrames)
        #expect(microphoneSummary.duration == Double(Self.tickCount))

        // 16-bit PCM: exactly four audio bytes per stereo frame; the container
        // may add a bounded constant header but nothing that scales with time.
        let audioBytesPerFrame: Int64 = 4
        let headerSlackBytes: Int64 = 128 * 1_024
        let microphoneBytes = Self.fileSize(microphoneWriter.url)
        let systemBytes = Self.fileSize(systemWriter.url)
        #expect(microphoneBytes == systemBytes)
        #expect(microphoneBytes >= expectedFrames * audioBytesPerFrame)
        #expect(
            microphoneBytes
                <= expectedFrames * audioBytesPerFrame + headerSlackBytes
        )
        // Mid-run ratio check: bytes-per-second of disk growth is identical
        // in the first and second hour, i.e. strictly linear in audio bytes.
        let framesMid = expectedFrames / 2
        let bytesPerSecondEnd = Double(microphoneBytes + systemBytes) / Double(expectedFrames)
        let bytesPerSecondMid = Double(bytesMid) / Double(framesMid)
        #expect(abs(bytesPerSecondMid - bytesPerSecondEnd) < 0.05 * bytesPerSecondEnd)

        // MARK: Guard 4 — footprint growth under the documented ceiling

        let start = try #require(footprintStart, "footprint baseline was not sampled")
        let deltaEnd = Self.physFootprintBytes() - start
        let deltaMid = footprintMid - start
        print("""
        [LongSessionSoak] simulated=\(simulatedSeconds)s \
        processing=\(String(format: "%.2f", processingSeconds))s \
        (\(String(format: "%.4f", processingSeconds / simulatedSeconds))x real time) \
        finals=\(finalRows.count) \
        footprint_delta_mid=\(Self.megabytes(deltaMid))MB \
        footprint_delta_end=\(Self.megabytes(deltaEnd))MB
        """)
        #expect(deltaMid < Self.footprintCeilingBytes)
        #expect(deltaEnd < Self.footprintCeilingBytes)
    }

    // MARK: Fixtures

    /// A single reusable one-second stereo Float32 PCM buffer.
    private static func makeOneSecondBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(format.sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(format.channelCount) {
            let samples = buffer.floatChannelData![channel]
            for frame in 0..<Int(frames) {
                samples[frame] = sin(Float(frame) * 0.01 + Float(channel)) * 0.2
            }
        }
        return buffer
    }

    /// Deterministic ~90-character utterance so block memory and bleed-filter
    /// work are realistic and reproducible.
    private static func syntheticText(seed: Int) -> String {
        let vocabulary = [
            "meeting", "budget", "timeline", "customer", "launch", "review",
            "signal", "latency", "memory", "track", "channel", "audio",
            "segment", "transcript", "speaker", "echo",
        ]
        var words: [String] = []
        for index in 0..<12 {
            words.append(vocabulary[(seed * 7 + index * 3) % vocabulary.count])
        }
        return words.joined(separator: " ")
    }

    private static func fileSize(_ url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.size] as? Int64 ?? 0
    }

    /// Physical footprint via `task_vm_info.phys_footprint` — the same metric
    /// Activity Monitor and the iOS jetsam accountant use, so the ceiling
    /// transfers to device constraints.
    private static func physFootprintBytes() -> Int64 {
        var info = task_vm_info_data_t()
        // TASK_VM_INFO_COUNT is marked unavailable in the macOS 27 SDK
        // ("structure not supported"), so derive the count from the layout.
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPointer in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPointer, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int64(info.phys_footprint)
    }

    private static func megabytes(_ bytes: Int64) -> Int64 {
        bytes / (1_024 * 1_024)
    }
}
