import Foundation
import Observation
import StenoDomain

@MainActor
@Observable
public final class MeetingNotesEditingSession {
    public private(set) var text = ""
    public private(set) var isSaving = false
    public private(set) var errorMessage: String?

    private let meetingID: MeetingID
    private let store: any MeetingNotesPersistence
    private let autosaveDelay: Duration
    private var savedText = ""
    private var generation = 0
    private var hasLoaded = false

    @ObservationIgnored
    private var saveTask: Task<Void, Never>?
    @ObservationIgnored
    private var loadTask: Task<Void, Never>?

    public init(
        meetingID: MeetingID,
        store: any MeetingNotesPersistence,
        autosaveDelay: Duration = .seconds(1)
    ) {
        self.meetingID = meetingID
        self.store = store
        self.autosaveDelay = autosaveDelay
    }

    public func load() async {
        if hasLoaded { return }
        if let loadTask {
            await loadTask.value
            return
        }

        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await performInitialLoad()
        }
        loadTask = task
        await task.value
        loadTask = nil
    }

    private func performInitialLoad() async {
        saveTask?.cancel()
        generation += 1
        let loadGeneration = generation
        do {
            let loaded = try await store.notes(meetingID) ?? ""
            guard generation == loadGeneration else { return }
            text = loaded
            savedText = loaded
            isSaving = false
            errorMessage = nil
            hasLoaded = true
        } catch {
            guard generation == loadGeneration else { return }
            isSaving = false
            errorMessage = error.localizedDescription
        }
    }

    public func update(_ value: String) {
        text = value
        generation += 1
        let updateGeneration = generation
        saveTask?.cancel()

        guard value != savedText else {
            isSaving = false
            errorMessage = nil
            return
        }

        isSaving = true
        saveTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: autosaveDelay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await persist(value, generation: updateGeneration)
        }
    }

    public func appendMarker(elapsed: TimeInterval) async {
        let pendingSave = saveTask
        pendingSave?.cancel()

        let seconds = max(0, Int(elapsed.rounded()))
        let stamp = String(
            format: "%02d:%02d:%02d",
            seconds / 3_600,
            (seconds % 3_600) / 60,
            seconds % 60
        )
        let separator = text.isEmpty || text.hasSuffix("\n") ? "" : "\n"
        text += "\(separator)[\(stamp)] "
        generation += 1
        let markerGeneration = generation
        let value = text
        isSaving = true

        await pendingSave?.value
        await persist(value, generation: markerGeneration)
    }

    public func flush() async {
        let pendingSave = saveTask
        pendingSave?.cancel()
        generation += 1
        let flushGeneration = generation
        let value = text

        await pendingSave?.value
        guard value != savedText || errorMessage != nil else {
            isSaving = false
            return
        }
        isSaving = true
        await persist(value, generation: flushGeneration)
    }

    private func persist(_ value: String, generation expectedGeneration: Int) async {
        guard generation == expectedGeneration else { return }
        do {
            try await store.setNotes(meetingID, to: value)
            guard generation == expectedGeneration else { return }
            savedText = value
            isSaving = false
            errorMessage = nil
        } catch {
            guard generation == expectedGeneration else { return }
            isSaving = false
            errorMessage = error.localizedDescription
        }
    }
}
