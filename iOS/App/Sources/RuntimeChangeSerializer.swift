@MainActor
final class RuntimeChangeSerializer {
    private var current: Task<Void, Never>?

    var isRunning: Bool { current != nil }

    func run(_ operation: @MainActor @escaping () async -> Void) async {
        if let current {
            await current.value
        }
        let task = Task { @MainActor in
            await operation()
        }
        current = task
        await task.value
        if current == task {
            current = nil
        }
    }
}
