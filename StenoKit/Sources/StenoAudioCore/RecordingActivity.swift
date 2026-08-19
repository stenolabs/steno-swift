import Foundation

/// Keeps the machine awake for the length of a recording.
///
/// Only the contract lives here. Every platform prevents sleep differently
/// (`ProcessInfo.beginActivity` on the Mac, the idle timer on iOS), and
/// `RecordingSession` must not care which one it is.
public protocol RecordingActivityManaging: Sendable {
    func begin() async
    func end() async
}
