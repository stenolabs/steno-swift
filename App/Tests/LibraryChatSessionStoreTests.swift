import Foundation
import Testing
@testable import steno_macos

@Suite("Library chat session store")
struct LibraryChatSessionStoreTests {
    private func makeStore() -> (store: LibraryChatSessionStore, suiteName: String) {
        let suiteName = "LibraryChatSessionStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (LibraryChatSessionStore(defaults: defaults), suiteName)
    }

    @Test("sessions round-trip through defaults as JSON")
    func roundTrip() {
        let (store, suiteName) = makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let session = LibraryChatSession(
            title: "Launch prep",
            messages: [
                LibraryChatMessage(role: .user, text: "What did we decide about pricing?"),
                LibraryChatMessage(role: .assistant, text: "Tiered pricing won."),
            ]
        )

        store.save([session])
        // A fresh store over the same defaults must see identical data.
        let reloaded = LibraryChatSessionStore(
            defaults: UserDefaults(suiteName: suiteName)!
        ).load()

        #expect(reloaded.count == 1)
        #expect(reloaded.first == session)
        #expect(reloaded.first?.messages == session.messages)
    }

    @Test("a missing key yields an empty list")
    func missingKeyIsEmpty() {
        let (store, suiteName) = makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        #expect(store.load().isEmpty)
    }

    @Test("undecodable data is treated as absent instead of fatal")
    func corruptDataStartsFresh() {
        let (store, suiteName) = makeStore()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        UserDefaults(suiteName: suiteName)!.set(
            Data("not json".utf8),
            forKey: LibraryChatSessionStore.defaultsKey
        )
        #expect(store.load().isEmpty)
    }
}
