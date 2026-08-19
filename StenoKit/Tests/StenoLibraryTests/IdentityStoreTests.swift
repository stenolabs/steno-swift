import Foundation
import StenoDomain
import Testing
@testable import StenoLibrary

@Suite("IdentityStore")
struct IdentityStoreTests {
    /// Feste Herkunft je Cluster-ID, damit Prototyp und Negativ desselben
    /// Clusters denselben Evidence Key tragen - genau daran haengt, was ein
    /// Merge und ein Loeschen als zusammengehoerig erkennen.
    private func evidence(
        personID: PersonID,
        clusterID: String,
        meetingID: MeetingID = Self.sharedMeetingID,
        runID: RunID = Self.sharedRunID
    ) -> SpeakerPrototype {
        SpeakerPrototype(
            personID: personID,
            embedding: [1, 0],
            recordingType: .remote,
            channel: "system",
            meetingID: meetingID,
            runID: runID,
            clusterID: clusterID,
            speechDurationSeconds: 20,
            segmentCount: 3,
            source: .userConfirmed
        )
    }

    private func counterEvidence(
        personID: PersonID,
        clusterID: String,
        meetingID: MeetingID = Self.sharedMeetingID,
        runID: RunID = Self.sharedRunID
    ) -> HardNegative {
        HardNegative(
            personID: personID,
            embedding: [0, 1],
            recordingType: .remote,
            channel: "system",
            meetingID: meetingID,
            runID: runID,
            clusterID: clusterID,
            speechDurationSeconds: 20,
            segmentCount: 3,
            source: .userConfirmed
        )
    }

    private static let sharedMeetingID = MeetingID()
    private static let sharedRunID = RunID()

    @Test("persists a schema-versioned persons document atomically")
    func persistsPersonsDocument() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let store = try IdentityStore(layout: library.layout)

            let person = try await store.createPerson(displayName: "  Ada   Lovelace  ")
            let reopened = try IdentityStore(layout: library.layout)
            let document = try JSONSerialization.jsonObject(
                with: Data(contentsOf: library.layout.persons)
            ) as? [String: Any]

            #expect(person.displayName == "Ada Lovelace")
            #expect(try await reopened.listPersons() == [person])
            #expect(document?["schemaVersion"] as? Int == 1)
        }
    }

    @Test("names are unique independent of case and whitespace")
    func rejectsNormalizedDuplicateNames() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let store = try IdentityStore(layout: library.layout)
            _ = try await store.createPerson(displayName: "Ada Lovelace")

            do {
                _ = try await store.createPerson(displayName: "  ADA\tLOVELACE\n")
                Issue.record("Expected duplicatePersonName")
            } catch let error as LibraryError {
                guard case .duplicatePersonName(let name) = error else {
                    Issue.record("Unexpected error: \(error)")
                    return
                }
                #expect(name == "ADA LOVELACE")
            }

            _ = try await store.createPerson(displayName: "Straße")
            await #expect(throws: LibraryError.self) {
                _ = try await store.createPerson(displayName: "STRASSE")
            }
        }
    }

    @Test("rejects an unsupported persons schema before decoding entries")
    func rejectsUnsupportedSchema() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let store = try IdentityStore(layout: library.layout)
            try Data("{\"schemaVersion\":99,\"persons\":[]}".utf8).write(
                to: library.layout.persons
            )

            do {
                _ = try await store.listPersons()
                Issue.record("Expected unsupportedSchemaVersion")
            } catch let error as LibraryError {
                guard case .unsupportedSchemaVersion(_, let found, let supported) = error else {
                    Issue.record("Unexpected error: \(error)")
                    return
                }
                #expect(found == 99)
                #expect(supported == 1)
            }
        }
    }

    @Test("renaming enforces the same normalized uniqueness rule")
    func renameRejectsDuplicate() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let store = try IdentityStore(layout: library.layout)
            let ada = try await store.createPerson(displayName: "Ada")
            _ = try await store.createPerson(displayName: "Grace Hopper")

            await #expect(throws: LibraryError.self) {
                _ = try await store.renamePerson(ada.id, to: " grace   hopper ")
            }
            #expect(try await store.person(ada.id)?.displayName == "Ada")
        }
    }

    @Test("deleting a person removes their derived voice from every hard-negative list")
    func deleteCleansDerivedNegatives() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let store = try IdentityStore(layout: library.layout)
            let meetingID = MeetingID()
            let runID = RunID()
            let adaID = PersonID()
            let graceID = PersonID()
            let adaPrototype = SpeakerPrototype(
                personID: adaID,
                embedding: [1, 0],
                recordingType: .remote,
                channel: "system",
                meetingID: meetingID,
                runID: runID,
                clusterID: "A",
                speechDurationSeconds: 20,
                segmentCount: 3,
                source: .userConfirmed
            )
            let derivedNegative = HardNegative(
                personID: graceID,
                embedding: [1, 0],
                recordingType: .remote,
                channel: "system",
                meetingID: meetingID,
                runID: runID,
                clusterID: "A",
                speechDurationSeconds: 20,
                segmentCount: 3,
                source: .userConfirmed
            )
            try await store.replacePersons([
                Person(id: adaID, displayName: "Ada", prototypes: [adaPrototype]),
                Person(id: graceID, displayName: "Grace", hardNegatives: [derivedNegative]),
            ])

            let deleted = try #require(try await store.deletePerson(adaID))
            let grace = try #require(try await store.person(graceID))
            #expect(grace.hardNegatives.isEmpty)
            #expect(deleted.removedNegatives[graceID] == [derivedNegative])
        }
    }

    @Test("an e-mail address survives reopening and is cleared by empty input")
    func personEmailRoundTrip() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let store = try IdentityStore(layout: library.layout)
            let ada = try await store.createPerson(displayName: "Ada Lovelace")

            let withEmail = try await store.setPersonEmail(
                ada.id,
                to: "  ada@example.org  "
            )
            let reopened = try IdentityStore(layout: library.layout)

            #expect(withEmail.email == "ada@example.org")
            #expect(try await reopened.person(ada.id)?.email == "ada@example.org")

            let cleared = try await store.setPersonEmail(ada.id, to: "   ")
            #expect(cleared.email == nil)
            #expect(try await reopened.person(ada.id)?.email == nil)
        }
    }

    @Test("an organization is stored, trimmed and cleared by empty input")
    func personOrganizationRoundTrip() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let store = try IdentityStore(layout: library.layout)
            let ada = try await store.createPerson(displayName: "Ada Lovelace")

            let set = try await store.setPersonOrganization(ada.id, to: "  Example   GmbH ")
            #expect(set.organization == "Example GmbH")
            #expect(try await IdentityStore(layout: library.layout)
                .person(ada.id)?.organization == "Example GmbH")

            // Mehrere Menschen derselben Firma sind erlaubt - anders als beim
            // Namen gibt es hier keine Eindeutigkeit.
            let bob = try await store.createPerson(displayName: "Alan Turing")
            _ = try await store.setPersonOrganization(bob.id, to: "Example GmbH")

            let cleared = try await store.setPersonOrganization(ada.id, to: "  ")
            #expect(cleared.organization == nil)
        }
    }

    @Test("a persons document written before the e-mail field still decodes")
    func decodesPersonsDocumentWithoutEmailField() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let legacy = """
            {
              "schemaVersion": 1,
              "persons": [
                {
                  "id": "\(PersonID().rawValue)",
                  "displayName": "Ada Lovelace",
                  "createdAt": 0,
                  "updatedAt": 0,
                  "prototypes": [],
                  "hardNegatives": []
                }
              ]
            }
            """
            try Data(legacy.utf8).write(to: library.layout.persons)

            let persons = try await IdentityStore(layout: library.layout).listPersons()

            #expect(persons.count == 1)
            #expect(persons.first?.displayName == "Ada Lovelace")
            #expect(persons.first?.email == nil)
        }
    }

    @Test("an address without a local and domain part is rejected")
    func rejectsMalformedEmail() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let store = try IdentityStore(layout: library.layout)
            let ada = try await store.createPerson(displayName: "Ada Lovelace")

            for malformed in ["ada", "ada@", "@example.org", "ada example@org"] {
                do {
                    _ = try await store.setPersonEmail(ada.id, to: malformed)
                    Issue.record("Expected invalidPersonEmail for \(malformed)")
                } catch let error as LibraryError {
                    guard case .invalidPersonEmail = error else {
                        Issue.record("Unexpected error: \(error)")
                        return
                    }
                }
            }

            #expect(try await store.person(ada.id)?.email == nil)
        }
    }

    @Test("excluding voice evidence keeps it stored and survives reopening")
    func excludeEvidenceRoundTrip() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let store = try IdentityStore(layout: library.layout)
            let adaID = PersonID()
            let prototype = evidence(personID: adaID, clusterID: "A")
            let negative = counterEvidence(personID: adaID, clusterID: "B")
            try await store.replacePersons([
                Person(
                    id: adaID,
                    displayName: "Ada",
                    prototypes: [prototype],
                    hardNegatives: [negative]
                ),
            ])

            _ = try await store.setPrototypeExcluded(
                prototype.id,
                of: adaID,
                excluded: true
            )
            _ = try await store.setHardNegativeExcluded(
                negative.id,
                of: adaID,
                excluded: true
            )

            let reopened = try IdentityStore(layout: library.layout)
            let stored = try #require(try await reopened.person(adaID))
            // Ausgenommen heisst nicht geloescht: die Evidenz ist noch da.
            #expect(stored.prototypes.count == 1)
            #expect(stored.hardNegatives.count == 1)
            #expect(stored.prototypes[0].isActive == false)
            #expect(stored.hardNegatives[0].isActive == false)
            #expect(stored.prototypes[0].embedding == prototype.embedding)

            let included = try await reopened.setPrototypeExcluded(
                prototype.id,
                of: adaID,
                excluded: false
            )
            #expect(included.prototypes[0].isActive)
        }
    }

    @Test("excluding evidence that does not exist fails instead of writing")
    func excludeUnknownEvidence() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let store = try IdentityStore(layout: library.layout)
            let ada = try await store.createPerson(displayName: "Ada")

            await #expect(throws: LibraryError.self) {
                _ = try await store.setPrototypeExcluded(
                    SpeakerEvidenceID(),
                    of: ada.id,
                    excluded: true
                )
            }
            #expect(try await store.person(ada.id)?.prototypes.isEmpty == true)
        }
    }

    @Test("merging moves prototypes and drops only the mutual counter-evidence")
    func mergeMovesEvidence() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let store = try IdentityStore(layout: library.layout)
            let annaID = PersonID()
            let annaTypoID = PersonID()
            let strangerID = PersonID()

            let annaPrototype = evidence(personID: annaID, clusterID: "A")
            let typoPrototype = evidence(personID: annaTypoID, clusterID: "B")
            // Entstand, als jemand Cluster B als "Katherine Jonson" bestaetigt hat:
            // "Katherine Johnson ist das nicht". Waren beide dieselbe Person, wuerde
            // genau das nach dem Zusammenfuehren ihre eigene Stimme sperren.
            let mutual = counterEvidence(personID: annaID, clusterID: "B")
            let foreign = counterEvidence(personID: annaID, clusterID: "Z")
            let strangerNegative = counterEvidence(personID: strangerID, clusterID: "A")

            try await store.replacePersons([
                Person(
                    id: annaID,
                    displayName: "Katherine Johnson",
                    organization: nil,
                    prototypes: [annaPrototype],
                    hardNegatives: [mutual, foreign]
                ),
                Person(
                    id: annaTypoID,
                    displayName: "Katherine Jonson",
                    email: "katherine@example.org",
                    organization: "Example",
                    prototypes: [typoPrototype]
                ),
                Person(
                    id: strangerID,
                    displayName: "Stranger",
                    hardNegatives: [strangerNegative]
                ),
            ])

            let merged = try await store.mergePersons(annaTypoID, into: annaID)

            #expect(merged.displayName == "Katherine Johnson")
            #expect(merged.prototypes.map(\.clusterID).sorted() == ["A", "B"])
            #expect(merged.prototypes.allSatisfy { $0.personID == annaID })
            #expect(merged.hardNegatives.map(\.clusterID) == ["Z"])
            // Leere Felder werden gefuellt, der Name bleibt der des Ziels.
            #expect(merged.email == "katherine@example.org")
            #expect(merged.organization == "Example")
            #expect(try await store.person(annaTypoID) == nil)

            // Der Sweep aus deletePerson darf hier nicht laufen: die Stimme
            // existiert weiter und bleibt gueltige Gegen-Evidenz bei anderen.
            let stranger = try #require(try await store.person(strangerID))
            #expect(stranger.hardNegatives.count == 1)
        }
    }

    @Test("merging a person into themselves is refused")
    func mergeIntoSelfRefused() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let store = try IdentityStore(layout: library.layout)
            let ada = try await store.createPerson(displayName: "Ada")

            await #expect(throws: LibraryError.self) {
                _ = try await store.mergePersons(ada.id, into: ada.id)
            }
            #expect(try await store.listPersons().count == 1)
        }
    }

    @Test("restoring a deleted person brings back the counter-evidence too")
    func deleteAndRestoreIsLossless() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let store = try IdentityStore(layout: library.layout)
            let adaID = PersonID()
            let graceID = PersonID()
            let adaPrototype = evidence(personID: adaID, clusterID: "A")
            let derived = counterEvidence(personID: graceID, clusterID: "A")
            let unrelated = counterEvidence(personID: graceID, clusterID: "Q")
            try await store.replacePersons([
                Person(id: adaID, displayName: "Ada", prototypes: [adaPrototype]),
                Person(
                    id: graceID,
                    displayName: "Grace",
                    hardNegatives: [derived, unrelated]
                ),
            ])

            let snapshot = try #require(try await store.deletePerson(adaID))
            #expect(try await store.person(graceID)?.hardNegatives == [unrelated])

            _ = try await store.restorePerson(snapshot)

            let ada = try #require(try await store.person(adaID))
            let grace = try #require(try await store.person(graceID))
            #expect(ada.prototypes == [adaPrototype])
            #expect(grace.hardNegatives.map(\.clusterID).sorted() == ["A", "Q"])
        }
    }

    @Test("restoring is refused when the name was taken in the meantime")
    func restoreRefusedOnNameCollision() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let store = try IdentityStore(layout: library.layout)
            let ada = try await store.createPerson(displayName: "Ada Lovelace")
            let snapshot = try #require(try await store.deletePerson(ada.id))
            _ = try await store.createPerson(displayName: "ada lovelace")

            await #expect(throws: LibraryError.self) {
                _ = try await store.restorePerson(snapshot)
            }
            #expect(try await store.listPersons().count == 1)
        }
    }

    @Test("a persons document written before the excludedAt field still decodes")
    func decodesPersonsDocumentWithoutExcludedField() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let personID = PersonID()
            let legacy = """
            {
              "schemaVersion": 1,
              "persons": [
                {
                  "id": "\(personID.rawValue)",
                  "displayName": "Ada Lovelace",
                  "createdAt": 0,
                  "updatedAt": 0,
                  "prototypes": [
                    {
                      "id": "\(SpeakerEvidenceID().rawValue)",
                      "personID": "\(personID.rawValue)",
                      "embedding": [1, 0],
                      "recordingType": "remote",
                      "channel": "system",
                      "clusterID": "A",
                      "speechDurationSeconds": 20,
                      "segmentCount": 3,
                      "source": "userConfirmed",
                      "createdAt": 0
                    }
                  ],
                  "hardNegatives": []
                }
              ]
            }
            """
            try Data(legacy.utf8).write(to: library.layout.persons)

            let persons = try await IdentityStore(layout: library.layout).listPersons()

            #expect(persons.first?.prototypes.first?.excludedAt == nil)
            #expect(persons.first?.prototypes.first?.isActive == true)
        }
    }

    @Test("meeting participants are persisted on the meeting independent of run ids")
    func meetingScopedParticipants() async throws {
        try await withTemporaryDirectory { root in
            let library = try Library.open(at: root)
            let meeting = try await library.createMeeting(title: "Review", status: .ready)
            let participants = [PersonID(), PersonID()]

            let updated = try await library.setMeetingParticipants(
                meeting.id,
                participantIDs: participants
            )

            #expect(updated.participantIDs == participants)
            #expect(try await library.loadMeeting(meeting.id).participantIDs == participants)
        }
    }
}
