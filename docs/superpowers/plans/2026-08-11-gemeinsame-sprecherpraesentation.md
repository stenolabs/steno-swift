# Gemeinsame Sprecherpraesentation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Beide Apps verwenden eine einzige kanalbewusste und SwiftUI-freie Sprecherpraesentation aus StenoPipeline.

**Architecture:** `SpeakerPresentationResolver` ordnet `SpeakerReference`, Review-Daten, Merge-Aufloesungen und Vorschlaege einem sichtbaren Label sowie einer semantischen Markerrolle zu. App-eigene Theme-Erweiterungen wandeln nur die Markerrolle in `Color` um.

**Tech Stack:** Swift 6.3, Swift Testing, StenoDomain, StenoIdentity, StenoPipeline, SwiftUI in den App-Targets.

## Global Constraints

- Unbestaetigte Sprecher bleiben generisch und Vermutungen bleiben als Vermutung markiert.
- Mehrpersonencluster und kanalmehrdeutige Referenzen erhalten keinen Personennamen und keine Personenfarbe.
- Die persistierte Form von `SpeakerReference` wird nicht veraendert.
- StenoPipeline importiert fuer diese Funktion kein SwiftUI.
- Beide App-Targets muessen nach der Umstellung bauen.

---

### Task 1: Kanalbewusster Kernresolver

**Files:**
- Create: `StenoKit/Sources/StenoPipeline/SpeakerPresentation.swift`
- Create: `StenoKit/Tests/StenoPipelineTests/SpeakerPresentationTests.swift`
- Modify: `StenoKit/Sources/StenoPipeline/MeetingReview.swift`

**Interfaces:**
- Consumes: `SpeakerReference`, `MeetingReviewData`, `IdentityCluster`, `ClusterSuggestion`, `IdentityClusterResolution`, `ChannelLabel`.
- Produces: `SpeakerPresentation`, `SpeakerMarker`, `SpeakerPresentationResolver.presentation(for:review:)`, `SpeakerPresentationResolver.presentation(for:review:)` fuer einen `IdentityCluster`.

- [ ] **Step 1: Write the failing resolver tests**

```swift
@Test func namespacedClustersKeepTheirChannelWithoutReview() {
    let mic = SpeakerPresentationResolver.presentation(
        for: .cluster(runID: RunID(), clusterID: "mic/SPEAKER_0"),
        review: nil
    )
    let system = SpeakerPresentationResolver.presentation(
        for: .cluster(runID: RunID(), clusterID: "system/SPEAKER_0"),
        review: nil
    )
    #expect(mic.label == "Speaker 1 (microphone)")
    #expect(system.label == "Speaker 1 (system)")
}

@Test func ambiguousBareClusterDoesNotBorrowAnotherChannelsIdentity() {
    let meetingID = MeetingID()
    let runID = RunID()
    let person = Person(displayName: "Anna")
    let mic = IdentityCluster(
        meetingID: meetingID,
        runID: runID,
        channel: MediaAsset.Kind.micTrack.rawValue,
        clusterID: "SPEAKER_0",
        recordingType: .inPerson,
        embedding: [1, 0],
        speechDurationSeconds: 30,
        segmentCount: 3,
        reviewState: .confirmed(person.id)
    )
    let system = IdentityCluster(
        meetingID: meetingID,
        runID: runID,
        channel: MediaAsset.Kind.systemTrack.rawValue,
        clusterID: "SPEAKER_0",
        recordingType: .remote,
        embedding: [0, 1],
        speechDurationSeconds: 20,
        segmentCount: 3
    )
    let review = MeetingReviewData(
        runID: runID,
        clusters: [mic, system],
        suggestions: [],
        resolutions: [],
        persons: [person]
    )
    let result = SpeakerPresentationResolver.presentation(
        for: .cluster(runID: review.runID, clusterID: "SPEAKER_0"),
        review: review
    )
    #expect(result.label == "Speaker 1")
    #expect(result.marker == nil)
}
```

Add tests named `confirmedPersonUsesPersonMarker`, `stalePersonKeepsQuestionMark`, `multiplePeopleHasNoMarker`, `confirmedSuggestionSaysProbably`, `otherRunStaysGeneric`, `mergeResolutionKeepsChannel` and `unconfirmedRankIgnoresSelfAndMultiple`.

- [ ] **Step 2: Run the focused tests and verify RED**

Run: `swift test --package-path StenoKit --filter SpeakerPresentationTests`

Expected: compilation fails because `SpeakerPresentationResolver`, `SpeakerPresentation` and `SpeakerMarker` do not exist.

- [ ] **Step 3: Implement the pure presentation API**

```swift
public struct SpeakerPresentation: Equatable, Sendable {
    public let label: String?
    public let marker: SpeakerMarker?
    public let channel: String?
}

public enum SpeakerMarker: Equatable, Sendable {
    case person(PersonID)
    case unconfirmedRank(Int)
}

public enum SpeakerPresentationResolver {
    public static func presentation(
        for reference: SpeakerReference?,
        review: MeetingReviewData?
    ) -> SpeakerPresentation

    public static func presentation(
        for cluster: IdentityCluster,
        review: MeetingReviewData
    ) -> SpeakerPresentation
}
```

Resolve merge entries, clusters and suggestions with both `channel` and `clusterID`.
Infer a channel only from the known `mic/`, `system/`, `micTrack/` or `systemTrack/` prefix.
When a bare ID matches more than one channel, return a generic label with no marker.

- [ ] **Step 4: Run the focused and pipeline tests and verify GREEN**

Run: `swift test --package-path StenoKit --filter SpeakerPresentationTests`

Expected: all new tests pass.

Run: `swift test --package-path StenoKit --filter StenoPipelineTests`

Expected: all StenoPipeline tests pass.

- [ ] **Step 5: Commit the resolver**

```bash
git add StenoKit/Sources/StenoPipeline/SpeakerPresentation.swift StenoKit/Sources/StenoPipeline/MeetingReview.swift StenoKit/Tests/StenoPipelineTests/SpeakerPresentationTests.swift
git commit -m "feat(core): Sprecherpraesentation vereinheitlichen"
```

### Task 2: Beide Apps auf den Resolver umstellen

**Files:**
- Modify: `App/Sources/AppModel+Review.swift`
- Modify: `App/Sources/MeetingDetailView.swift`
- Modify: `App/Sources/SpeakerReviewSection.swift`
- Modify: `App/Sources/Theme.swift`
- Delete: `iOS/App/Sources/SpeakerDisplay.swift`
- Modify: `iOS/App/Sources/MeetingDetailView.swift`
- Modify: `iOS/App/Sources/Theme.swift`
- Modify: `StenoKit/Sources/StenoPipeline/TemplateParticipants.swift`
- Modify: `StenoKit/Sources/StenoPipeline/SpeakerSampleSelector.swift`

**Interfaces:**
- Consumes: `SpeakerPresentationResolver`, `SpeakerPresentation`, `SpeakerMarker` from Task 1.
- Produces: App-local `Color` mapping only; no zweite Namens- oder Review-Aufloesung.

- [ ] **Step 1: Add failing downstream channel-scope tests**

Extend `TemplateParticipantsTests` with `sameClusterIDAcrossChannelsKeepsParticipantsSeparate` and `SpeakerSampleSelectorTests` with `sameClusterIDAcrossChannelsKeepsSamplesSeparate`.
Each test creates one mic and one system cluster with `SPEAKER_0`, distinct people or turns, and asserts that each output uses only its own channel.

- [ ] **Step 2: Run the focused tests and verify RED**

Run: `swift test --package-path StenoKit --filter TemplateParticipantsTests`

Run: `swift test --package-path StenoKit --filter SpeakerSampleSelectorTests`

Expected: at least one new channel-collision assertion fails against the current ID-only lookup.

- [ ] **Step 3: Replace every duplicated presentation lookup**

Use the shared presentation once per row:

```swift
let presentation = SpeakerPresentationResolver.presentation(
    for: turn.speaker,
    review: review
)
```

Map markers in each app theme:

```swift
static func speaker(_ marker: SpeakerMarker?) -> Color? {
    switch marker {
    case .person(let personID): speaker(for: personID)
    case .unconfirmedRank(let rank): speaker(atRank: rank)
    case .none: nil
    }
}
```

Remove the macOS `SpeakerDisplay` declaration and delete the iOS copy.
Route participant and sample lookups through channel-scoped helpers from the resolver instead of a first `clusterID` match.

- [ ] **Step 4: Verify focused tests and both builds**

Run: `swift test --package-path StenoKit --filter TemplateParticipantsTests`

Run: `swift test --package-path StenoKit --filter SpeakerSampleSelectorTests`

Run: `scripts/build-app.sh`

Run: `scripts/build-ios.sh`

Expected: all commands exit successfully.

- [ ] **Step 5: Commit the app migration**

```bash
git add App/Sources/AppModel+Review.swift App/Sources/MeetingDetailView.swift App/Sources/SpeakerReviewSection.swift App/Sources/Theme.swift iOS/App/Sources/MeetingDetailView.swift iOS/App/Sources/Theme.swift StenoKit/Sources/StenoPipeline/TemplateParticipants.swift StenoKit/Sources/StenoPipeline/SpeakerSampleSelector.swift
git add -u iOS/App/Sources/SpeakerDisplay.swift
git commit -m "refactor: Sprecheranzeige gemeinsam verwenden"
```
