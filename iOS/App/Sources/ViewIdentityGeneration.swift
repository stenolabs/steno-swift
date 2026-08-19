struct ViewIdentityGeneration<Value: Equatable> {
    struct Token: Equatable {
        let value: Value
        fileprivate let generation: UInt64
    }

    private var value: Value?
    private var generation: UInt64 = 0

    mutating func begin(_ value: Value) -> Token {
        generation &+= 1
        self.value = value
        return Token(value: value, generation: generation)
    }

    func token(for value: Value) -> Token? {
        guard self.value == value else { return nil }
        return Token(value: value, generation: generation)
    }

    func accepts(_ token: Token, currentValue: Value) -> Bool {
        value == currentValue
            && token.value == currentValue
            && token.generation == generation
    }
}
