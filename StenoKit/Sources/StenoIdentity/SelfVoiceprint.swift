import Foundation
import StenoDomain

/// Persists which person in the library is the operator themself.
///
/// The pointer is app state, not library state - exactly like the model
/// consents, StenoKit never reads `UserDefaults` itself; the app layer hands
/// an implementation of this protocol in. Keeping it out of `persons.json`
/// also means a library that travels to another machine does not silently
/// carry a "this is me" claim with it.
public protocol SelfVoiceprintPersonStoring: Sendable {
    func loadSelfPersonID() throws -> PersonID?
    func saveSelfPersonID(_ id: PersonID?) throws
}

/// The dedicated operator person ("Me") and how it comes into existence.
///
/// The person is auto-created from the operator profile on first use: the
/// stored pointer wins if it still resolves, otherwise a same-named existing
/// person is adopted (renames must not orphan the binding), and only when
/// neither exists is a fresh person created. Every path leaves behind at most
/// one self person because the pointer - not the name - is the identity.
public enum SelfVoiceprint {

    public static let fallbackDisplayName = "Me"

    public struct Resolution: Equatable, Sendable {
        /// The full person list after resolution. Persist it only when
        /// `mutated` is true.
        public let persons: [Person]
        public let selfPerson: Person
        public let mutated: Bool

        public init(persons: [Person], selfPerson: Person, mutated: Bool) {
            self.persons = persons
            self.selfPerson = selfPerson
            self.mutated = mutated
        }
    }

    /// Finds or creates the operator person among `persons`.
    ///
    /// - Parameters:
    ///   - persons: current library snapshot.
    ///   - operatorName: display name from the operator profile; blank falls
    ///     back to `fallbackDisplayName`.
    ///   - store: persisted pointer to the previously bound person, if any.
    public static func resolveOrCreate(
        persons: [Person],
        operatorName: String?,
        store: SelfVoiceprintPersonStoring
    ) throws -> Resolution {
        if let stored = try store.loadSelfPersonID(),
           let existing = persons.first(where: { $0.id == stored }) {
            return Resolution(persons: persons, selfPerson: existing, mutated: false)
        }
        let name = normalized(operatorName) ?? fallbackDisplayName
        let key = comparisonKey(name)
        // A person with the operator's own name is the operator. Adopting it
        // beats creating a duplicate that would then hard-negative against
        // itself on every shared meeting.
        if let namesake = persons.first(where: { comparisonKey($0.displayName) == key }) {
            try store.saveSelfPersonID(namesake.id)
            return Resolution(persons: persons, selfPerson: namesake, mutated: false)
        }
        let created = Person(displayName: name)
        try store.saveSelfPersonID(created.id)
        return Resolution(
            persons: persons + [created],
            selfPerson: created,
            mutated: true
        )
    }

    private static func normalized(_ name: String?) -> String? {
        guard let collapsed = name?.split(whereSeparator: \.isWhitespace)
            .joined(separator: " "), !collapsed.isEmpty else {
            return nil
        }
        return collapsed
    }

    /// Same folding rule as the store's uniqueness check: two people who
    /// differ only by case or accent spelling are one person everywhere else,
    /// so adopting a namesake must use the identical comparison.
    private static func comparisonKey(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.folding(
            options: [.caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }
}
