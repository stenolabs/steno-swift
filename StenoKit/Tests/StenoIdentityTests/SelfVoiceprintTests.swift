import Foundation
import StenoDomain
import Testing
@testable import StenoIdentity

/// The "Me" person binding. The pointer - not the name - is the identity, and
/// every resolution path must leave at most one self person behind.
@Suite("Self voiceprint person")
struct SelfVoiceprintTests {

    private final class Store: SelfVoiceprintPersonStoring, @unchecked Sendable {
        var stored: PersonID?
        func loadSelfPersonID() throws -> PersonID? { stored }
        func saveSelfPersonID(_ id: PersonID?) throws { stored = id }
    }

    @Test("first use creates the operator person and stores the pointer")
    func createsOperatorPerson() throws {
        let store = Store()

        let resolution = try SelfVoiceprint.resolveOrCreate(
            persons: [makeKnownPerson(name: "Ada")],
            operatorName: "Grace  Hopper",
            store: store
        )

        #expect(resolution.mutated)
        #expect(resolution.selfPerson.displayName == "Grace Hopper")
        #expect(resolution.persons.count == 2)
        #expect(store.stored == resolution.selfPerson.id)
    }

    @Test("a blank operator name falls back to Me")
    func blankNameFallsBack() throws {
        let store = Store()

        let resolution = try SelfVoiceprint.resolveOrCreate(
            persons: [],
            operatorName: "   ",
            store: store
        )

        #expect(resolution.selfPerson.displayName == SelfVoiceprint.fallbackDisplayName)
    }

    @Test("a stored pointer wins over names and creates nothing")
    func storedPointerWins() throws {
        let store = Store()
        let bound = makeKnownPerson(name: "Old Name")
        store.stored = bound.id

        let resolution = try SelfVoiceprint.resolveOrCreate(
            persons: [bound, makeKnownPerson(name: "New Name")],
            operatorName: "New Name",
            store: store
        )

        #expect(!resolution.mutated)
        #expect(resolution.selfPerson.id == bound.id)
        #expect(resolution.persons.count == 2)
    }

    @Test("a dangling pointer adopts a same-named person instead of duplicating them")
    func danglingPointerAdoptsNamesake() throws {
        let store = Store()
        store.stored = PersonID()
        let namesake = makeKnownPerson(name: "Grace")

        let resolution = try SelfVoiceprint.resolveOrCreate(
            persons: [makeKnownPerson(name: "Ada"), namesake],
            operatorName: "grace",
            store: store
        )

        // Case-insensitive folding matches how the store checks name
        // uniqueness, otherwise adoption and creation would disagree.
        #expect(!resolution.mutated)
        #expect(resolution.selfPerson.id == namesake.id)
        #expect(store.stored == namesake.id)
    }

    @Test("a dangling pointer with no namesake recreates the person")
    func danglingPointerRecreates() throws {
        let store = Store()
        store.stored = PersonID()

        let resolution = try SelfVoiceprint.resolveOrCreate(
            persons: [makeKnownPerson(name: "Ada")],
            operatorName: "Grace",
            store: store
        )

        #expect(resolution.mutated)
        #expect(resolution.selfPerson.displayName == "Grace")
        #expect(store.stored == resolution.selfPerson.id)
    }
}
