import Testing
@testable import StenoDomain

@Suite("Operator identity")
struct OperatorIdentityTests {
    @Test("name and organisation are joined for the minutes header")
    func joinsNameAndOrganisation() {
        let identity = OperatorIdentity(name: "Ada Lovelace", organization: "Stadt Musterstadt")
        #expect(identity.authorLine == "Ada Lovelace, Stadt Musterstadt")
    }

    @Test("without an organisation the name stands alone")
    func nameAlone() {
        #expect(OperatorIdentity(name: "Ada Lovelace", organization: "").authorLine == "Ada Lovelace")
    }

    @Test("without a name there is no author line at all")
    func noNameNoLine() {
        #expect(OperatorIdentity(name: "", organization: "Stadt Musterstadt").authorLine == nil)
        #expect(OperatorIdentity(name: "   ", organization: "").authorLine == nil)
    }

    @Test("surrounding whitespace never reaches the document")
    func trimsWhitespace() {
        let identity = OperatorIdentity(name: "  Ada Lovelace  ", organization: "  Stadt  ")
        #expect(identity.authorLine == "Ada Lovelace, Stadt")
    }
}
