import Foundation

/// Binds an asynchronous endpoint probe result to the endpoint revision that
/// started it. Saving the endpoint invalidates both a visible result and any
/// in-flight result that still carries an older generation.
public struct TextModelProbeState: Equatable, Sendable {
    public struct Generation: Equatable, Sendable {
        fileprivate let value: UInt64
    }

    private var results: [UUID: String] = [:]
    private var generations: [UUID: UInt64] = [:]

    public init() {}

    public func result(for endpointID: UUID) -> String? {
        results[endpointID]
    }

    @discardableResult
    public mutating func beginProbe(for endpointID: UUID) -> Generation {
        let generation = nextGeneration(for: endpointID)
        results[endpointID] = nil
        return Generation(value: generation)
    }

    public mutating func setResult(
        _ result: String,
        for endpointID: UUID,
        generation: Generation
    ) {
        guard generations[endpointID] == generation.value else { return }
        results[endpointID] = result
    }

    public mutating func endpointWasSaved(_ endpointID: UUID) {
        _ = nextGeneration(for: endpointID)
        results[endpointID] = nil
    }

    private mutating func nextGeneration(for endpointID: UUID) -> UInt64 {
        let generation = generations[endpointID, default: 0] &+ 1
        generations[endpointID] = generation
        return generation
    }
}
