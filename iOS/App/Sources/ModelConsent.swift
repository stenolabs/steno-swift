import Foundation
import Observation
import StenoDomain

@MainActor
@Observable
final class ModelConsent {
    static let speechKey = "org.steno.ios.modelConsent"
    static let diarizationKey = "org.steno.ios.diarizationModelConsent"

    struct Record: Codable, Equatable {
        let grantedAt: Date
        let sources: [String]
    }

    private let defaults: UserDefaults
    private let key: String
    private(set) var record: Record?

    init(
        defaults: UserDefaults = .standard,
        key: String = ModelConsent.speechKey
    ) {
        self.defaults = defaults
        self.key = key
        if let data = defaults.data(forKey: key) {
            record = try? JSONDecoder().decode(Record.self, from: data)
        }
    }

    static func speech(defaults: UserDefaults = .standard) -> ModelConsent {
        ModelConsent(defaults: defaults, key: speechKey)
    }

    static func diarization(defaults: UserDefaults = .standard) -> ModelConsent {
        ModelConsent(defaults: defaults, key: diarizationKey)
    }

    var isGranted: Bool { record != nil }

    func grant(sources: [ModelSource]) {
        let value = Record(
            grantedAt: record?.grantedAt ?? Date(),
            sources: sources.map(\.displayHost)
        )
        record = value
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }

    func revoke() {
        record = nil
        defaults.removeObject(forKey: key)
    }
}
