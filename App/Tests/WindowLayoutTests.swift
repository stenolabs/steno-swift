import AppKit
import SwiftUI
import Testing
@testable import steno_macos

@Suite("Window layout")
@MainActor
struct WindowLayoutTests {
    @Test("library and empty detail use the descriptive meetings title")
    func usesMeetingsTitle() {
        let english = Locale(identifier: "en_US_POSIX")

        #expect(String(
            localized: MacWindowPresentation.meetingsTitle.defaultValue,
            locale: english
        ) == "Meetings")
    }

    @Test("startup views use the meetings title instead of the app name")
    func startupViewsUseMeetingsTitle() throws {
        let appDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: appDirectory.appending(path: "Sources/MacStartupPresentation.swift"),
            encoding: .utf8
        )

        #expect(!source.contains(".navigationTitle(\"Steno\")"))
        #expect(source.components(
            separatedBy: ".navigationTitle(MacWindowPresentation.meetingsTitle)"
        ).count - 1 == 2)
    }

    @Test("long scrollable meeting content does not demand a taller window")
    func longMeetingContentKeepsWindowSizeStable() {
        let view = WindowStableDetail {
            ScrollView {
                LazyVStack {
                    Text(
                        String(
                            repeating: "A long transcript line that must stay inside the scroll view. ",
                            count: 1_000
                        )
                    )
                }
            }
        }
        let host = NSHostingView(rootView: view)
        let proposed = NSSize(width: 640, height: 700)
        host.setFrameSize(proposed)
        host.layoutSubtreeIfNeeded()

        #expect(
            host.fittingSize.height <= proposed.height,
            "Scrollable meeting content requested \(host.fittingSize.height) points for a \(proposed.height)-point window."
        )
    }

    @Test("multi-selection summary stays inside the current window")
    func multiSelectionKeepsWindowSizeStable() {
        let view = WindowStableDetail {
            MultiMeetingSelectionView(count: 123_456_789)
        }
        let host = NSHostingView(rootView: view)
        let proposed = NSSize(width: 640, height: 700)
        host.setFrameSize(proposed)
        host.layoutSubtreeIfNeeded()

        #expect(
            host.fittingSize.height <= proposed.height,
            "Multi-selection requested \(host.fittingSize.height) points for a \(proposed.height)-point window."
        )
    }
}
