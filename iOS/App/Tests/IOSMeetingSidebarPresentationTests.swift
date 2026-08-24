import Foundation
import StenoDomain
import Testing
@testable import Steno

@Suite("iOS meeting sidebar presentation")
struct IOSMeetingSidebarPresentationTests {
    private let now = Date(timeIntervalSince1970: 1_784_060_400)

    @Test("empty library states localize at the presentation boundary")
    func emptyLibraryStatesLocalize() {
        #expect(
            german(IOSMeetingSidebarPresentation.emptyMeetingMessage(
                isReady: true,
                query: ""
            )) == "Noch keine Aufnahmen."
        )
        #expect(
            german(IOSMeetingSidebarPresentation.emptyMeetingMessage(
                isReady: false,
                query: ""
            )) == "Bibliothek wird geöffnet…"
        )
        #expect(
            german(IOSMeetingSidebarPresentation.emptyMeetingMessage(
                isReady: true,
                query: "  Demo  "
            )) == "Keine Meeting-Titel entsprechen „Demo“."
        )
    }

    @Test("delegates visible depth order to the shared sidebar tree")
    func buildsSharedTreeInDepthOrder() {
        let work = folder(1, name: "Work", sortIndex: 0)
        let weekly = folder(
            2,
            name: "Weekly",
            parentFolderID: work.id,
            sortIndex: 0
        )
        let home = folder(3, name: "Home", sortIndex: 1)

        let presentation = IOSMeetingSidebarPresentation(
            folders: [home, weekly, work],
            meetings: [],
            query: "",
            now: now
        )

        #expect(folderNames(in: presentation.tree) == ["Work", "Weekly", "Home"])
    }

    @Test("search keeps a matching meeting's complete folder path effectively expanded")
    func searchKeepsMatchingPathAndDoesNotMutatePersistedExpansion() {
        let work = folder(1, name: "Work", sortIndex: 0)
        let weekly = folder(
            2,
            name: "Weekly",
            parentFolderID: work.id,
            sortIndex: 0
        )
        let hit = meeting(1, title: "Weekly planning", folderID: weekly.id)
        let persisted = Set([folderID(99)])
        let presentation = IOSMeetingSidebarPresentation(
            folders: [work, weekly],
            meetings: [hit],
            query: " planning ",
            now: now
        )

        let expanded = presentation.effectiveExpandedFolderIDs(persisted: persisted)

        #expect(presentation.tree.folderNodes.map(\.id) == [work.id])
        #expect(presentation.tree.folderNodes[0].children.map(\.id) == [weekly.id])
        #expect(expanded == Set([folderID(99), work.id, weekly.id]))
        #expect(persisted == Set([folderID(99)]))
    }

    @Test("search uses the shared case diacritic and width folding contract")
    func searchUsesSharedMeetingSearchMatching() {
        let work = folder(1, name: "Work", sortIndex: 0)
        let accented = meeting(
            1,
            title: "Gespräch mit Müller",
            folderID: work.id
        )
        let fullWidth = meeting(
            2,
            title: "ＭＵＬＬＥＲ follow-up",
            folderID: work.id
        )

        let asciiQuery = IOSMeetingSidebarPresentation(
            folders: [work],
            meetings: [accented, fullWidth],
            query: "muller",
            now: now
        )
        let fullWidthQuery = IOSMeetingSidebarPresentation(
            folders: [work],
            meetings: [accented, fullWidth],
            query: "ｍÜＬＬ",
            now: now
        )

        #expect(asciiQuery.tree.folderNodes.flatMap(\.meetings).map(\.id) == [
            accented.id, fullWidth.id,
        ])
        #expect(fullWidthQuery.tree.folderNodes.flatMap(\.meetings).map(\.id) == [
            accented.id, fullWidth.id,
        ])
    }

    @Test("empty folders disappear only while a title search has no matching meeting")
    func searchHidesOnlyEmptyFolders() {
        let empty = folder(1, name: "Empty", sortIndex: 0)
        let normal = IOSMeetingSidebarPresentation(
            folders: [empty],
            meetings: [],
            query: "",
            now: now
        )
        let searching = IOSMeetingSidebarPresentation(
            folders: [empty],
            meetings: [],
            query: "no match",
            now: now
        )

        #expect(normal.tree.folderNodes.map(\.id) == [empty.id])
        #expect(searching.tree.folderNodes.isEmpty)
    }

    @Test("search keeps unmatched empty folders available as move and nesting destinations")
    func searchDoesNotFilterMenuDestinations() {
        let work = folder(1, name: "Work", sortIndex: 0)
        let weekly = folder(
            2,
            name: "Weekly",
            parentFolderID: work.id,
            sortIndex: 0
        )
        let home = folder(3, name: "Home", sortIndex: 1)
        let hit = meeting(1, title: "Weekly planning", folderID: weekly.id)
        let presentation = IOSMeetingSidebarPresentation(
            folders: [work, weekly, home],
            meetings: [hit],
            query: "planning",
            now: now
        )

        #expect(presentation.tree.folderNodes.map(\.id) == [work.id])
        #expect(presentation.moveDestinations(for: hit.id).map(\.id) == [
            work.id, weekly.id, home.id,
        ])
        #expect(presentation.nestingDestinations(for: weekly.id).map(\.id) == [home.id])
    }

    @Test("meeting destinations retain every visible folder once and reject a no-op")
    func meetingDestinationsIncludeEveryFolderAndRejectCurrentFolder() {
        let work = folder(1, name: "Work", sortIndex: 0)
        let weekly = folder(
            2,
            name: "Weekly",
            parentFolderID: work.id,
            sortIndex: 0
        )
        let home = folder(3, name: "Home", sortIndex: 1)
        let planning = meeting(1, title: "Planning", folderID: weekly.id)
        let presentation = IOSMeetingSidebarPresentation(
            folders: [home, weekly, work],
            meetings: [planning],
            query: "",
            now: now
        )

        #expect(presentation.moveDestinations(for: planning.id).map(\.id) == [
            work.id, weekly.id, home.id,
        ])
        #expect(presentation.dropDecision(
            for: .meeting(planning.id),
            ontoFolder: weekly.id
        ) == .reject)
        #expect(presentation.dropDecision(
            for: .meeting(planning.id),
            onto: .foldersHeading
        ) == .moveMeeting(planning.id, nil))
    }

    @Test("the folders heading remains a no-folder drop fallback without date sections")
    func fixedNoFolderDropSurfaceExistsWithoutUnfiledMeetings() {
        let work = folder(1, name: "Work", sortIndex: 0)
        let planning = meeting(1, title: "Planning", folderID: work.id)
        let presentation = IOSMeetingSidebarPresentation(
            folders: [work],
            meetings: [planning],
            query: "",
            now: now
        )

        #expect(presentation.tree.unfiledSections.isEmpty)
        #expect(presentation.noFolderDropSurfaces == [.foldersHeading])
        let decision = presentation.dropDecision(
            for: .meeting(planning.id),
            onto: presentation.noFolderDropSurfaces[0]
        )
        #expect(decision == .moveMeeting(planning.id, nil))
        #expect(presentation.meetingActionPolicy(for: planning.id)
            .moveDestinations
            .contains(where: { destination in
                destination.folderID == nil && !destination.isCurrent
            }))
    }

    @Test("every visible unfiled date header is an additional no-folder drop surface")
    func unfiledDateHeadersAreAdditionalDropSurfaces() {
        let unfiled = meeting(1, title: "Planning")
        let presentation = IOSMeetingSidebarPresentation(
            folders: [],
            meetings: [unfiled],
            query: "",
            now: now
        )

        #expect(presentation.noFolderDropSurfaces == [
            .foldersHeading,
            .unfiledSection("date:Today"),
        ])
    }

    @Test("typed no-folder surfaces distinguish meeting unfiling from folder promotion")
    func noFolderDropSurfaceMatrixRejectsFoldersOnDateHeaders() {
        let work = folder(1, name: "Work", sortIndex: 0)
        let weekly = folder(
            2,
            name: "Weekly",
            parentFolderID: work.id,
            sortIndex: 0
        )
        let filedMeeting = meeting(1, title: "Planning", folderID: weekly.id)
        let unfiledMeeting = meeting(2, title: "Inbox")
        let staleMeetingID = meetingID(99)
        let staleFolderID = folderID(98)
        let presentation = IOSMeetingSidebarPresentation(
            folders: [work, weekly],
            meetings: [filedMeeting, unfiledMeeting],
            query: "",
            now: now
        )
        let dateHeader = IOSSidebarNoFolderDropSurface.unfiledSection("date:Today")

        #expect(presentation.dropDecision(
            for: .meeting(filedMeeting.id),
            onto: .foldersHeading
        ) == .moveMeeting(filedMeeting.id, nil))
        #expect(presentation.dropDecision(
            for: .meeting(unfiledMeeting.id),
            onto: .foldersHeading
        ) == .reject)
        #expect(presentation.dropDecision(
            for: .meeting(staleMeetingID),
            onto: .foldersHeading
        ) == .moveMeeting(staleMeetingID, nil))
        #expect(presentation.dropDecision(
            for: .folder(weekly.id),
            onto: .foldersHeading
        ) == .moveFolder(weekly.id, nil))
        #expect(presentation.dropDecision(
            for: .folder(work.id),
            onto: .foldersHeading
        ) == .reject)
        #expect(presentation.dropDecision(
            for: .folder(staleFolderID),
            onto: .foldersHeading
        ) == .reject)

        #expect(presentation.dropDecision(
            for: .meeting(filedMeeting.id),
            onto: dateHeader
        ) == .moveMeeting(filedMeeting.id, nil))
        #expect(presentation.dropDecision(
            for: .meeting(unfiledMeeting.id),
            onto: dateHeader
        ) == .reject)
        #expect(presentation.dropDecision(
            for: .meeting(staleMeetingID),
            onto: dateHeader
        ) == .moveMeeting(staleMeetingID, nil))
        #expect(presentation.dropDecision(
            for: .folder(weekly.id),
            onto: dateHeader
        ) == .reject)
        #expect(presentation.dropDecision(
            for: .folder(work.id),
            onto: dateHeader
        ) == .reject)
        #expect(presentation.dropDecision(
            for: .folder(staleFolderID),
            onto: dateHeader
        ) == .reject)

        #expect(english(IOSSidebarNoFolderDropSurface.foldersHeading.accessibilityHint) == "Drop a meeting here to move it to No folder. Drop a subfolder here to move it to the top level.")
        #expect(english(dateHeader.accessibilityHint) == "Drop a meeting here to move it to No folder.")
    }

    @Test("a root with a child has no nesting destinations")
    func rootWithChildCannotBecomeAChild() {
        let work = folder(1, name: "Work", sortIndex: 0)
        let weekly = folder(
            2,
            name: "Weekly",
            parentFolderID: work.id,
            sortIndex: 0
        )
        let home = folder(3, name: "Home", sortIndex: 1)
        let presentation = IOSMeetingSidebarPresentation(
            folders: [work, weekly, home],
            meetings: [],
            query: "",
            now: now
        )

        #expect(presentation.nestingDestinations(for: work.id).isEmpty)
        #expect(presentation.nestingDestinations(for: weekly.id).map(\.id) == [home.id])
    }

    @Test("drop decisions preserve valid local moves")
    func decidesMeetingAndPromotionDrops() {
        let work = folder(1, name: "Work", sortIndex: 0)
        let weekly = folder(
            2,
            name: "Weekly",
            parentFolderID: work.id,
            sortIndex: 0
        )
        let home = folder(3, name: "Home", sortIndex: 1)
        let planning = meeting(1, title: "Planning")
        let presentation = IOSMeetingSidebarPresentation(
            folders: [work, weekly, home],
            meetings: [planning],
            query: "",
            now: now
        )

        #expect(presentation.dropDecision(
            for: .meeting(planning.id),
            ontoFolder: work.id
        ) == .moveMeeting(planning.id, work.id))
        #expect(presentation.dropDecision(
            for: .folder(weekly.id),
            onto: .foldersHeading
        ) == .moveFolder(weekly.id, nil))
    }

    @Test("drop decisions reject wrong payload targets self reference and third levels")
    func rejectsLocallyInvalidFolderDrops() {
        let work = folder(1, name: "Work", sortIndex: 0)
        let weekly = folder(
            2,
            name: "Weekly",
            parentFolderID: work.id,
            sortIndex: 0
        )
        let home = folder(3, name: "Home", sortIndex: 1)
        let planning = meeting(1, title: "Planning")
        let presentation = IOSMeetingSidebarPresentation(
            folders: [work, weekly, home],
            meetings: [planning],
            query: "",
            now: now
        )

        #expect(presentation.dropDecision(for: .meeting(planning.id), onto: .foldersHeading) == .reject)
        #expect(presentation.dropDecision(for: .folder(work.id), ontoFolder: work.id) == .reject)
        #expect(presentation.dropDecision(for: .folder(home.id), ontoFolder: weekly.id) == .reject)
        #expect(presentation.dropDecision(for: .folder(work.id), ontoFolder: home.id) == .reject)
    }

    @Test("stale payloads reach store validation but missing destinations and reveals fail closed")
    func handlesMissingIDsAndStaleState() {
        let work = folder(1, name: "Work", sortIndex: 0)
        let home = folder(2, name: "Home", sortIndex: 1)
        let staleMeetingID = meetingID(99)
        let persisted = Set([folderID(98)])
        let presentation = IOSMeetingSidebarPresentation(
            folders: [work, home],
            meetings: [],
            query: "",
            now: now
        )

        #expect(presentation.moveDestinations(for: staleMeetingID).map(\.id) == [work.id, home.id])
        #expect(presentation.dropDecision(
            for: .meeting(staleMeetingID),
            ontoFolder: work.id
        ) == .moveMeeting(staleMeetingID, work.id))
        #expect(presentation.dropDecision(
            for: .meeting(staleMeetingID),
            ontoFolder: folderID(97)
        ) == .reject)
        #expect(presentation.dropDecision(for: .folder(folderID(96)), onto: .foldersHeading) == .reject)
        #expect(presentation.expandedFolderIDs(
            revealing: folderID(95),
            persisted: persisted
        ) == persisted)
    }

    @Test("reveal adds a parent only when the unsearched shared tree confirms it")
    func revealRejectsOrphanStaleAndThirdLevelParents() {
        let work = folder(1, name: "Work", sortIndex: 0)
        let weekly = folder(
            2,
            name: "Weekly",
            parentFolderID: work.id,
            sortIndex: 0
        )
        let orphan = folder(
            3,
            name: "Orphan",
            parentFolderID: folderID(99),
            sortIndex: 1
        )
        let thirdLevel = folder(
            4,
            name: "Third level",
            parentFolderID: weekly.id,
            sortIndex: 0
        )
        let persisted = Set([folderID(98)])
        let presentation = IOSMeetingSidebarPresentation(
            folders: [work, weekly, orphan, thirdLevel],
            meetings: [],
            query: "",
            now: now
        )

        #expect(presentation.expandedFolderIDs(
            revealing: weekly.id,
            persisted: persisted
        ) == Set([folderID(98), work.id, weekly.id]))
        #expect(presentation.expandedFolderIDs(
            revealing: orphan.id,
            persisted: persisted
        ) == Set([folderID(98), orphan.id]))
        #expect(presentation.expandedFolderIDs(
            revealing: thirdLevel.id,
            persisted: persisted
        ) == Set([folderID(98), thirdLevel.id]))
    }

    @Test("navigation reveal keeps the meeting route and opens its complete child path")
    func navigationRevealKeepsMeetingRouteAndOpensParent() throws {
        let work = folder(1, name: "Work", sortIndex: 0)
        let weekly = folder(
            2,
            name: "Weekly",
            parentFolderID: work.id,
            sortIndex: 0
        )
        let planning = meeting(1, title: "Planning", folderID: weekly.id)
        let persisted = Set([folderID(99)])
        let presentation = IOSMeetingSidebarPresentation(
            folders: [work, weekly],
            meetings: [planning],
            query: "",
            now: now
        )

        let reveal = try #require(presentation.navigationReveal(
            for: planning.id,
            persisted: persisted
        ))

        #expect(reveal.selection == .meeting(planning.id))
        #expect(reveal.expandedFolderIDs == Set([
            folderID(99), work.id, weekly.id,
        ]))
        #expect(persisted == Set([folderID(99)]))
    }

    @MainActor
    @Test("same-meeting reveal requests have unique identity and are consumed once")
    func repeatedRevealRequestsAreDistinctOneShotEvents() throws {
        var state = IOSSidebarRevealEventState()
        let meetingID = meetingID(1)
        let first = state.request(
            meetingID,
            requestID: uuid(101)
        )

        #expect(state.pending == first)
        let consumedFirst = state.consume(first)
        #expect(consumedFirst)
        #expect(state.pending == nil)
        let replayedFirst = state.consume(first)
        #expect(!replayedFirst)

        let second = state.request(
            meetingID,
            requestID: uuid(102)
        )

        #expect(first.meetingID == second.meetingID)
        #expect(first.id != second.id)
        #expect(state.pending == second)
        let staleFirstConsumed = state.consume(first)
        #expect(!staleFirstConsumed)
        let consumedSecond = state.consume(second)
        #expect(consumedSecond)
        #expect(state.pending == nil)
    }

    @MainActor
    @Test("reveal persists reopened ancestors before making selection ready")
    func revealAppliesExpansionBeforeSelectionAndCanRepeat() throws {
        let suiteName = "IOSMeetingSidebarPresentationTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = IOSFolderDisclosureStore(defaults: defaults)
        let work = folder(1, name: "Work", sortIndex: 0)
        let weekly = folder(
            2,
            name: "Weekly",
            parentFolderID: work.id,
            sortIndex: 0
        )
        let planning = meeting(1, title: "Planning", folderID: weekly.id)
        let presentation = IOSMeetingSidebarPresentation(
            folders: [work, weekly],
            meetings: [planning],
            query: "",
            now: now
        )
        var visibleExpansion: Set<FolderID> = []
        var eventOrder: [String] = []
        var selectedItems: [SidebarItem] = []

        for requestID in [uuid(101), uuid(102)] {
            let request = IOSSidebarRevealRequest(
                id: requestID,
                meetingID: planning.id
            )
            #expect(IOSSidebarRevealApplication.apply(
                request,
                presentation: presentation,
                disclosureStore: store,
                updateExpansion: { expanded in
                    eventOrder.append("expansion")
                    visibleExpansion = expanded
                },
                selectionReady: { _, selection in
                    eventOrder.append("selection")
                    selectedItems.append(selection)
                }
            ))
            #expect(eventOrder.suffix(2) == ["expansion", "selection"])
            #expect(visibleExpansion == [work.id, weekly.id])
            #expect(store.load() == [work.id, weekly.id])

            visibleExpansion = store.setExpanded(false, for: weekly.id)
            visibleExpansion = store.setExpanded(false, for: work.id)
            #expect(visibleExpansion.isEmpty)
        }

        #expect(selectedItems == [
            .meeting(planning.id),
            .meeting(planning.id),
        ])
    }

    @Test("folder action policy distinguishes root child and sibling boundaries")
    func folderActionPolicyCoversEveryApplicableAction() throws {
        let work = folder(1, name: "Work", sortIndex: 0)
        let weekly = folder(
            2,
            name: "Weekly",
            parentFolderID: work.id,
            sortIndex: 0
        )
        let planning = folder(
            3,
            name: "Planning",
            parentFolderID: work.id,
            sortIndex: 1
        )
        let home = folder(4, name: "Home", sortIndex: 1)
        let presentation = IOSMeetingSidebarPresentation(
            folders: [planning, home, weekly, work],
            meetings: [],
            query: "",
            now: now
        )

        let workPolicy = try #require(presentation.folderActionPolicy(for: work.id))
        #expect(workPolicy.canCreateChild)
        #expect(!workPolicy.canMoveUp)
        #expect(workPolicy.canMoveDown)
        #expect(workPolicy.parentDestinations.isEmpty)
        #expect(!workPolicy.canMoveToRoot)

        let weeklyPolicy = try #require(presentation.folderActionPolicy(for: weekly.id))
        #expect(!weeklyPolicy.canCreateChild)
        #expect(!weeklyPolicy.canMoveUp)
        #expect(weeklyPolicy.canMoveDown)
        #expect(weeklyPolicy.parentDestinations.map(\.folderID) == [home.id])
        #expect(weeklyPolicy.canMoveToRoot)

        let planningPolicy = try #require(presentation.folderActionPolicy(for: planning.id))
        #expect(planningPolicy.canMoveUp)
        #expect(!planningPolicy.canMoveDown)
    }

    @Test("delete confirmation explains root promotion and direct meeting unfiling")
    func deleteConfirmationDescribesTheActualFolderOutcome() throws {
        let work = folder(1, name: "Work", sortIndex: 0)
        let weekly = folder(
            2,
            name: "Weekly",
            parentFolderID: work.id,
            sortIndex: 0
        )
        let archive = folder(3, name: "Archive", sortIndex: 1)
        let presentation = IOSMeetingSidebarPresentation(
            folders: [work, weekly, archive],
            meetings: [
                meeting(1, title: "Root meeting", folderID: work.id),
                meeting(2, title: "Child meeting", folderID: weekly.id),
            ],
            query: "",
            now: now
        )

        let root = try #require(presentation.folderDeletionConfirmation(for: work.id))
        #expect(english(root.title) == "Delete \u{201c}Work\u{201d}?")
        #expect(english(root.message) == "Only the folder goes away. Its direct meetings stay in the library and move to No folder. Its subfolders move to the top level.")

        let child = try #require(presentation.folderDeletionConfirmation(for: weekly.id))
        #expect(english(child.message) == "Only the folder goes away. Its direct meetings stay in the library and move to No folder.")

        let emptyRoot = try #require(presentation.folderDeletionConfirmation(for: archive.id))
        #expect(emptyRoot.message == child.message)
    }

    @Test("every accepted drag move has an equivalent context menu action")
    func everyDropDecisionHasAMenuEquivalent() throws {
        let work = folder(1, name: "Work", sortIndex: 0)
        let weekly = folder(
            2,
            name: "Weekly",
            parentFolderID: work.id,
            sortIndex: 0
        )
        let home = folder(3, name: "Home", sortIndex: 1)
        let planning = meeting(1, title: "Planning", folderID: weekly.id)
        let presentation = IOSMeetingSidebarPresentation(
            folders: [work, weekly, home],
            meetings: [planning],
            query: "",
            now: now
        )
        let candidateDestinations: [FolderID?] = [nil, work.id, weekly.id, home.id]

        let meetingMenuDecisions = presentation
            .meetingActionPolicy(for: planning.id)
            .moveDestinations
            .map { IOSSidebarDropDecision.moveMeeting(planning.id, $0.folderID) }
        for destination in candidateDestinations {
            let decision = if let destination {
                presentation.dropDecision(
                    for: .meeting(planning.id),
                    ontoFolder: destination
                )
            } else {
                presentation.dropDecision(
                    for: .meeting(planning.id),
                    onto: .foldersHeading
                )
            }
            if decision != .reject {
                #expect(meetingMenuDecisions.contains(decision))
            }
        }
        #expect(meetingMenuDecisions == [
            .moveMeeting(planning.id, work.id),
            .moveMeeting(planning.id, weekly.id),
            .moveMeeting(planning.id, home.id),
            .moveMeeting(planning.id, nil),
        ])

        let weeklyPolicy = try #require(presentation.folderActionPolicy(for: weekly.id))
        let weeklyMenuDecisions = weeklyPolicy.parentDestinations.map {
            IOSSidebarDropDecision.moveFolder(weekly.id, $0.folderID)
        } + (weeklyPolicy.canMoveToRoot ? [.moveFolder(weekly.id, nil)] : [])
        for destination in candidateDestinations {
            let decision = if let destination {
                presentation.dropDecision(
                    for: .folder(weekly.id),
                    ontoFolder: destination
                )
            } else {
                presentation.dropDecision(
                    for: .folder(weekly.id),
                    onto: .foldersHeading
                )
            }
            if decision != .reject {
                #expect(weeklyMenuDecisions.contains(decision))
            }
        }
        #expect(weeklyMenuDecisions == [
            .moveFolder(weekly.id, home.id),
            .moveFolder(weekly.id, nil),
        ])

        let homePolicy = try #require(presentation.folderActionPolicy(for: home.id))
        let homeMenuDecisions = homePolicy.parentDestinations.map {
            IOSSidebarDropDecision.moveFolder(home.id, $0.folderID)
        }
        for destination in candidateDestinations {
            let decision = if let destination {
                presentation.dropDecision(
                    for: .folder(home.id),
                    ontoFolder: destination
                )
            } else {
                presentation.dropDecision(
                    for: .folder(home.id),
                    onto: .foldersHeading
                )
            }
            if decision != .reject {
                #expect(homeMenuDecisions.contains(decision))
            }
        }
        #expect(homeMenuDecisions == [
            .moveFolder(home.id, work.id),
        ])
    }

    @Test("visible and contextual meeting menus share destinations and enabled states")
    func meetingMoveSurfacesUseTheSamePresentation() {
        let work = folder(1, name: "Work", sortIndex: 0)
        let weekly = folder(
            2,
            name: "Weekly",
            parentFolderID: work.id,
            sortIndex: 0
        )
        let home = folder(3, name: "Home", sortIndex: 1)
        let planning = meeting(1, title: "Planning", folderID: weekly.id)
        let policy = IOSMeetingSidebarPresentation(
            folders: [work, weekly, home],
            meetings: [planning],
            query: "",
            now: now
        ).meetingActionPolicy(
            for: planning.id,
            locale: Locale(identifier: "en")
        )

        let destinations = IOSMeetingMoveActions.destinations(for: policy)

        #expect(destinations.map(\.folderID) == [work.id, weekly.id, home.id, nil])
        #expect(destinations.map(\.title) == [
            "Work",
            "Work / Weekly",
            "Home",
            "No folder",
        ])
        #expect(destinations.map(\.isCurrent) == [false, true, false, false])
    }

    @Test("payload encoding contains only its case and raw UUID")
    func payloadEncodingDoesNotContainMeetingContentOrPaths() throws {
        let privateMeeting = meeting(
            1,
            title: "Board discussion: acquisition",
            folderID: folderID(2)
        )
        let payload = IOSSidebarDragPayload.meeting(privateMeeting.id)

        let data = try JSONEncoder().encode(payload)
        let bytes = String(decoding: data, as: UTF8.self)

        #expect(try JSONDecoder().decode(IOSSidebarDragPayload.self, from: data) == payload)
        #expect(bytes.contains("meeting"))
        #expect(bytes.contains(privateMeeting.id.rawValue.uuidString))
        #expect(!bytes.contains(privateMeeting.title))
        #expect(!bytes.contains("confidential transcript"))
        #expect(!bytes.contains("/private/var/mobile/Meetings"))
        #expect(!bytes.contains(privateMeeting.folderID!.rawValue.uuidString))
    }

    @Test("folder payload round-trips through Codable")
    func folderPayloadRoundTrips() throws {
        let payload = IOSSidebarDragPayload.folder(folderID(1))

        let data = try JSONEncoder().encode(payload)

        #expect(try JSONDecoder().decode(IOSSidebarDragPayload.self, from: data) == payload)
    }

    @MainActor
    @Test("persisted disclosure survives reload and removes one folder at a time")
    func persistsDisclosureWithoutTemporarySearchState() throws {
        let suiteName = "IOSMeetingSidebarPresentationTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let work = folderID(1)
        let weekly = folderID(2)
        let temporarySearchFolder = folderID(3)
        let store = IOSFolderDisclosureStore(defaults: defaults)

        _ = store.setExpanded(true, for: weekly)
        _ = store.setExpanded(true, for: work)

        #expect(IOSFolderDisclosureStore(defaults: defaults).load() == [work, weekly])
        #expect(!store.load().contains(temporarySearchFolder))
        _ = store.remove(work)
        #expect(store.load() == [weekly])
    }

    @MainActor
    @Test("interleaved disclosure stores merge against the latest persisted state")
    func disclosureStoresDoNotLoseUpdatesAcrossScenes() throws {
        let suiteName = "IOSMeetingSidebarPresentationTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let firstScene = IOSFolderDisclosureStore(defaults: defaults)
        let secondScene = IOSFolderDisclosureStore(defaults: defaults)
        let work = folderID(1)
        let weekly = folderID(2)
        let archive = folderID(3)

        #expect(firstScene.setExpanded(true, for: work) == [work])
        #expect(secondScene.setExpanded(true, for: weekly) == [work, weekly])
        #expect(firstScene.add([archive]) == [work, weekly, archive])
        #expect(secondScene.remove(work) == [weekly, archive])
        #expect(firstScene.load() == [weekly, archive])
    }

    @Test("payload decoding fails closed for an unknown kind or absent invalid UUID")
    func payloadDecodingRejectsMalformedData() {
        let unknownKind = Data(
            #"{"kind":"other","id":"00000000-0000-7000-8000-000000000001"}"#.utf8
        )
        let missingID = Data(#"{"kind":"meeting"}"#.utf8)
        let invalidID = Data(#"{"kind":"folder","id":"not-a-uuid"}"#.utf8)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(IOSSidebarDragPayload.self, from: unknownKind)
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(IOSSidebarDragPayload.self, from: missingID)
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(IOSSidebarDragPayload.self, from: invalidID)
        }
    }

    private func folder(
        _ value: Int,
        name: String,
        parentFolderID: FolderID? = nil,
        sortIndex: Int
    ) -> Folder {
        Folder(
            id: folderID(value),
            name: name,
            parentFolderID: parentFolderID,
            sortIndex: sortIndex,
            createdAt: now
        )
    }

    private func meeting(
        _ value: Int,
        title: String,
        folderID: FolderID? = nil
    ) -> Meeting {
        Meeting(
            id: meetingID(value),
            title: title,
            createdAt: now,
            status: .ready,
            folderID: folderID
        )
    }

    private func folderNames(in tree: MeetingSidebarTree) -> [String] {
        tree.folderNodes.flatMap { root in
            [root.folder.name] + root.children.map(\.folder.name)
        }
    }

    private func english(_ resource: LocalizedStringResource) -> String {
        var resource = resource
        resource.locale = Locale(identifier: "en")
        return String(localized: resource)
    }

    private func german(_ resource: LocalizedStringResource) -> String {
        var resource = resource
        resource.locale = Locale(identifier: "de")
        return String(localized: resource)
    }

    private func meetingID(_ value: Int) -> MeetingID {
        MeetingID(rawValue: uuid(value))
    }

    private func folderID(_ value: Int) -> FolderID {
        FolderID(rawValue: uuid(value))
    }

    private func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(
            format: "00000000-0000-7000-8000-%012d",
            value
        ))!
    }
}
