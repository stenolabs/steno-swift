import Foundation
import StenoDomain

private struct PersonsDocument: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    var persons: [Person]

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        persons: [Person]
    ) {
        self.schemaVersion = schemaVersion
        self.persons = persons
    }
}

/// Alles, was ein Loeschvorgang aus der Bibliothek genommen hat. Die
/// Ruecknahme braucht beides: die Person selbst und die Negatives, die aus
/// ihren Prototypen abgeleitet waren und deshalb in *fremden* Profilen
/// mitgeloescht wurden. Ohne den zweiten Teil kaeme die Person zurueck, aber
/// die Gegen-Evidenz, die sie von anderen Stimmen trennt, waere still weg.
public struct DeletedPerson: Equatable, Sendable {
    public let person: Person
    public let removedNegatives: [PersonID: [HardNegative]]

    public init(person: Person, removedNegatives: [PersonID: [HardNegative]]) {
        self.person = person
        self.removedNegatives = removedNegatives
    }
}

public actor IdentityStore {
    public nonisolated let layout: LibraryLayout

    public init(layout: LibraryLayout) throws {
        self.layout = layout
        try FileManager.default.createDirectory(
            at: layout.identityDirectory,
            withIntermediateDirectories: true
        )
    }

    public func listPersons() throws -> [Person] {
        guard FileManager.default.fileExists(atPath: layout.persons.path) else {
            return []
        }
        return try Self.readDocument(layout: layout).persons
    }

    package nonisolated static func listPersons(
        layout: LibraryLayout,
        transaction: LibraryMutationTransaction
    ) throws -> [Person] {
        try transaction.validate(layout: layout)
        guard FileManager.default.fileExists(atPath: layout.persons.path) else {
            return []
        }
        return try readDocument(layout: layout).persons
    }

    public func person(_ personID: PersonID) throws -> Person? {
        try listPersons().first { $0.id == personID }
    }

    @discardableResult
    public func createPerson(
        displayName: String,
        createdAt: Date = Date()
    ) throws -> Person {
        let name = try Self.normalizedDisplayName(displayName)
        var persons = try listPersons()
        try Self.validateUniqueName(name, among: persons)
        let person = Person(
            displayName: name,
            createdAt: createdAt
        )
        persons.append(person)
        try write(persons)
        return person
    }

    @discardableResult
    public func renamePerson(
        _ personID: PersonID,
        to displayName: String,
        updatedAt: Date = Date()
    ) throws -> Person {
        let name = try Self.normalizedDisplayName(displayName)
        var persons = try listPersons()
        guard let index = persons.firstIndex(where: { $0.id == personID }) else {
            throw LibraryError.personNotFound(personID)
        }
        try Self.validateUniqueName(
            name,
            among: persons,
            excluding: personID
        )
        persons[index].displayName = name
        persons[index].updatedAt = updatedAt
        try write(persons)
        return persons[index]
    }

    /// Setzt die Kontaktadresse; eine leere oder nur aus Leerraum bestehende
    /// Eingabe löscht sie. Die Adresse bleibt Bibliotheksdatei und geht nie in
    /// eine Prompt-Zusammenstellung.
    @discardableResult
    public func setPersonEmail(
        _ personID: PersonID,
        to email: String?,
        updatedAt: Date = Date()
    ) throws -> Person {
        let normalized = try Self.normalizedEmail(email)
        var persons = try listPersons()
        guard let index = persons.firstIndex(where: { $0.id == personID }) else {
            throw LibraryError.personNotFound(personID)
        }
        persons[index].email = normalized
        persons[index].updatedAt = updatedAt
        try write(persons)
        return persons[index]
    }

    /// Firma oder Organisation; leere Eingabe loescht sie. Anders als beim
    /// Namen gibt es keine Eindeutigkeitspruefung - mehrere Menschen derselben
    /// Firma sind der Normalfall, genau darum geht es.
    @discardableResult
    public func setPersonOrganization(
        _ personID: PersonID,
        to organization: String?,
        updatedAt: Date = Date()
    ) throws -> Person {
        let trimmed = organization?
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        var persons = try listPersons()
        guard let index = persons.firstIndex(where: { $0.id == personID }) else {
            throw LibraryError.personNotFound(personID)
        }
        persons[index].organization = (trimmed?.isEmpty ?? true) ? nil : trimmed
        persons[index].updatedAt = updatedAt
        try write(persons)
        return persons[index]
    }

    public func replacePersons(_ persons: [Person]) throws {
        try Self.validateUniqueNames(persons)
        try write(persons)
    }

    /// Nimmt eine Stimmprobe von der Erkennung aus oder wieder auf. Die Probe
    /// bleibt in jedem Fall gespeichert - sie ist echte Stimm-Evidenz einer
    /// echten Person, und Evidenz still zu zerstoeren ist der schlimmere
    /// Fehler als eine, die gerade nicht zaehlt.
    @discardableResult
    public func setPrototypeExcluded(
        _ evidenceID: SpeakerEvidenceID,
        of personID: PersonID,
        excluded: Bool,
        at date: Date = Date()
    ) throws -> Person {
        try updatePerson(personID) { person in
            guard let index = person.prototypes.firstIndex(where: {
                $0.id == evidenceID
            }) else {
                throw LibraryError.speakerEvidenceNotFound(evidenceID)
            }
            person.prototypes[index].excludedAt = excluded ? date : nil
        }
    }

    /// Dasselbe fuer ein Hard Negative. Hier ist das Ausnehmen der eigentliche
    /// Zweck: ein falsch gesetztes Negativ blockiert eine echte Erkennung
    /// dauerhaft, und dies ist die einzige Stelle, an der es gefunden werden
    /// kann.
    @discardableResult
    public func setHardNegativeExcluded(
        _ evidenceID: SpeakerEvidenceID,
        of personID: PersonID,
        excluded: Bool,
        at date: Date = Date()
    ) throws -> Person {
        try updatePerson(personID) { person in
            guard let index = person.hardNegatives.firstIndex(where: {
                $0.id == evidenceID
            }) else {
                throw LibraryError.speakerEvidenceNotFound(evidenceID)
            }
            person.hardNegatives[index].excludedAt = excluded ? date : nil
        }
    }

    /// Fuehrt `sourceID` in `targetID` zusammen. Das Ziel behaelt Namen und
    /// Identitaet, die Quelle verschwindet.
    ///
    /// Die Falle, deretwegen das eine eigene Operation und kein Loeschen mit
    /// Umhaengen ist: ein Negativ "nicht Ziel" kann genau dadurch entstanden
    /// sein, dass jemand denselben Cluster als Quelle bestaetigt hat. Waren
    /// beide dieselbe Person, wuerde dieses Negativ nach dem Zusammenfuehren
    /// die eigene Stimme dauerhaft unterdruecken. Solche gegenseitigen
    /// Negatives fallen weg; alle anderen bleiben, auch in fremden Profilen,
    /// denn die Stimme der Quelle existiert weiter.
    @discardableResult
    public func mergePersons(
        _ sourceID: PersonID,
        into targetID: PersonID,
        updatedAt: Date = Date()
    ) throws -> Person {
        guard sourceID != targetID else {
            throw LibraryError.cannotMergePersonIntoItself
        }
        var persons = try listPersons()
        guard let sourceIndex = persons.firstIndex(where: { $0.id == sourceID }) else {
            throw LibraryError.personNotFound(sourceID)
        }
        guard let targetIndex = persons.firstIndex(where: { $0.id == targetID }) else {
            throw LibraryError.personNotFound(targetID)
        }
        let source = persons[sourceIndex]
        var target = persons[targetIndex]

        let mutualKeys = Set(source.prototypes.map(EvidenceKey.init))
            .union(target.prototypes.map(EvidenceKey.init))

        var prototypes = target.prototypes
        var seenPrototypes = Set(prototypes.map(EvidenceKey.init))
        for prototype in source.prototypes {
            guard seenPrototypes.insert(EvidenceKey(prototype)).inserted else { continue }
            var moved = prototype
            moved.personID = targetID
            prototypes.append(moved)
        }

        var negatives: [HardNegative] = []
        var seenNegatives: Set<EvidenceKey> = []
        for negative in target.hardNegatives + source.hardNegatives {
            let key = EvidenceKey(negative)
            guard !mutualKeys.contains(key), seenNegatives.insert(key).inserted else {
                continue
            }
            var moved = negative
            moved.personID = targetID
            negatives.append(moved)
        }

        target.prototypes = prototypes
        target.hardNegatives = negatives
        // Leere Felder fuellen, belegte nie ueberschreiben: das Ziel ist die
        // Person, die der Benutzer behalten wollte.
        if target.email == nil { target.email = source.email }
        if target.organization == nil { target.organization = source.organization }
        target.updatedAt = updatedAt
        persons[targetIndex] = target
        persons.removeAll { $0.id == sourceID }

        // Kein Sweep durch fremde Profile, anders als beim Loeschen.
        try write(persons)
        return target
    }

    /// Loescht eine Person und liefert alles zurueck, was dafuer aus der
    /// Bibliothek verschwindet - die Person selbst und die aus ihren
    /// Prototypen abgeleiteten Negatives in fremden Profilen. Nur mit diesem
    /// Schnappschuss ist `restorePerson` verlustfrei.
    public func deletePerson(_ personID: PersonID) throws -> DeletedPerson? {
        var persons = try listPersons()
        guard let target = persons.first(where: { $0.id == personID }) else {
            return nil
        }
        let evidenceKeys = Set(target.prototypes.map(EvidenceKey.init))
        persons.removeAll { $0.id == personID }
        var removedNegatives: [PersonID: [HardNegative]] = [:]
        for index in persons.indices {
            let owner = persons[index].id
            let removed = persons[index].hardNegatives.filter {
                evidenceKeys.contains(EvidenceKey($0))
            }
            guard !removed.isEmpty else { continue }
            removedNegatives[owner] = removed
            persons[index].hardNegatives.removeAll {
                evidenceKeys.contains(EvidenceKey($0))
            }
        }
        try write(persons)
        return DeletedPerson(person: target, removedNegatives: removedNegatives)
    }

    /// Setzt einen Loeschvorgang punktgenau zurueck. Bewusst kein
    /// Zurueckschreiben des ganzen Dokuments: zwischen Loeschen und Ruecknahme
    /// kann eine andere Aenderung liegen, und die soll nicht verlorengehen.
    /// Ein inzwischen vergebener gleicher Name laesst die Ruecknahme
    /// scheitern, statt zwei gleichnamige Personen anzulegen.
    @discardableResult
    public func restorePerson(_ snapshot: DeletedPerson) throws -> Person {
        var persons = try listPersons()
        guard !persons.contains(where: { $0.id == snapshot.person.id }) else {
            throw LibraryError.personAlreadyExists(snapshot.person.id)
        }
        try Self.validateUniqueName(snapshot.person.displayName, among: persons)
        persons.append(snapshot.person)
        for (owner, negatives) in snapshot.removedNegatives {
            guard let index = persons.firstIndex(where: { $0.id == owner }) else {
                continue
            }
            let existing = Set(persons[index].hardNegatives.map(EvidenceKey.init))
            persons[index].hardNegatives.append(contentsOf: negatives.filter {
                !existing.contains(EvidenceKey($0))
            })
        }
        try write(persons)
        return snapshot.person
    }

    private func updatePerson(
        _ personID: PersonID,
        _ mutate: (inout Person) throws -> Void
    ) throws -> Person {
        var persons = try listPersons()
        guard let index = persons.firstIndex(where: { $0.id == personID }) else {
            throw LibraryError.personNotFound(personID)
        }
        try mutate(&persons[index])
        persons[index].updatedAt = Date()
        try write(persons)
        return persons[index]
    }

    private nonisolated static func readDocument(
        layout: LibraryLayout
    ) throws -> PersonsDocument {
        try JSONDocumentStore.read(
            PersonsDocument.self,
            from: layout.persons,
            currentSchemaVersion: PersonsDocument.currentSchemaVersion,
            schemaVersion: \.schemaVersion
        )
    }

    private func write(_ persons: [Person]) throws {
        try LibraryMutationCoordination.withExclusiveAccess(layout: layout) {
            try JSONDocumentStore.write(
                PersonsDocument(persons: persons),
                to: layout.persons
            )
        }
    }

    /// Bewusst milde Prüfung: genau ein @, links und rechts davon etwas ohne
    /// Leerraum, im Domänenteil ein Punkt. Sie fängt Tippfehler ab, ohne
    /// gültige Adressen wegzuwerfen, die eine strenge Grammatik ablehnen würde.
    private static func normalizedEmail(_ email: String?) throws -> String? {
        guard let trimmed = email?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }
        let parts = trimmed.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2,
              !parts[0].isEmpty,
              !parts[1].isEmpty,
              parts[1].contains("."),
              !trimmed.contains(where: \.isWhitespace)
        else {
            throw LibraryError.invalidPersonEmail
        }
        return trimmed
    }

    private static func normalizedDisplayName(_ name: String) throws -> String {
        let normalized = name
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !normalized.isEmpty else {
            throw LibraryError.invalidPersonName
        }
        return normalized
    }

    private static func comparisonKey(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.folding(
            options: [.caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private static func validateUniqueName(
        _ name: String,
        among persons: [Person],
        excluding excludedID: PersonID? = nil
    ) throws {
        let key = comparisonKey(name)
        if persons.contains(where: {
            $0.id != excludedID && comparisonKey($0.displayName) == key
        }) {
            throw LibraryError.duplicatePersonName(name)
        }
    }

    private static func validateUniqueNames(_ persons: [Person]) throws {
        var keys: Set<String> = []
        for person in persons {
            let name = try normalizedDisplayName(person.displayName)
            let key = comparisonKey(name)
            guard keys.insert(key).inserted else {
                throw LibraryError.duplicatePersonName(name)
            }
        }
    }
}

private struct EvidenceKey: Hashable {
    let meetingID: MeetingID?
    let runID: RunID?
    let channel: String?
    let clusterID: String

    init(_ prototype: SpeakerPrototype) {
        meetingID = prototype.meetingID
        runID = prototype.runID
        channel = prototype.channel
        clusterID = prototype.clusterID
    }

    init(_ negative: HardNegative) {
        meetingID = negative.meetingID
        runID = negative.runID
        channel = negative.channel
        clusterID = negative.clusterID
    }
}
