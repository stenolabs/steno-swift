import StenoDomain
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            MeetingSidebarView(selection: $model.selectedMeetingIDs)
                .navigationSplitViewColumnWidth(min: 220, ideal: 280)
        } detail: {
            WindowStableDetail {
                // Aufnahme ist ein Zustand des Meetings, kein Modus der App.
                // Vorher ersetzte sie die ganze Detailflaeche, egal welches
                // Meeting gewaehlt war - ausgerechnet im Gespraech, wo man
                // nachschlagen will, war die Bibliothek unerreichbar. Der Streifen
                // bleibt sichtbar und haelt den Rueckweg offen.
                VStack(spacing: 0) {
                    if model.isRecording {
                        RecordingStrip()
                    }
                    detailContent
                }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                if model.isRecording {
                    Button {
                        Task { await model.stopRecording() }
                    } label: {
                        Label("Stop recording", systemImage: "stop.circle.fill")
                            .foregroundStyle(Steno.Colors.recording)
                    }
                    .help("Stop recording")
                } else if model.isStartingRecording {
                    ProgressView()
                        .controlSize(.small)
                        .help("Preparing recording")
                } else {
                    MicrophoneSelectionButton()

                    Button {
                        Task { await model.startRecording() }
                    } label: {
                        Label("Start recording", systemImage: "record.circle")
                    }
                    .help("Start a new recording")
                    .disabled(model.runtime == nil)

                    Button {
                        Task { await model.createDraftMeeting() }
                    } label: {
                        Label("New meeting", systemImage: "square.and.pencil")
                    }
                    .help("Create a meeting without a recording, to take notes beforehand")
                    .disabled(model.runtime == nil)

                    Button {
                        model.requestAudioImport()
                    } label: {
                        Label("Import audio", systemImage: "waveform.badge.plus")
                    }
                    .help("Import an audio file")
                    .disabled(model.runtime == nil)

                    Button {
                        model.requestMeetingTransferImport()
                    } label: {
                        Label("Import meeting package", systemImage: "shippingbox.and.arrow.backward")
                    }
                    .help("Import a .stenomeeting package")
                    .disabled(model.runtime == nil)

                }
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Settings (language, language models)")
            }
        }
        .fileImporter(
            isPresented: $model.wantsAudioImport,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                Task { await model.importAudioFile(at: url) }
            }
        }
        .fileImporter(
            isPresented: $model.wantsMeetingTransferImport,
            allowedContentTypes: [.stenoMeetingTransfer],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    model.previewMeetingPackage(at: url)
                }
            case .failure(let error):
                if (error as? CocoaError)?.code != .userCancelled {
                    model.report(AppModel.message("The meeting package could not be opened.", error))
                }
            }
        }
        .onOpenURL { url in
            guard url.pathExtension.caseInsensitiveCompare("stenomeeting") == .orderedSame else {
                return
            }
            model.previewMeetingPackage(at: url)
        }
        .sheet(
            isPresented: Binding(
                get: { model.meetingTransferImportState != nil },
                set: { if !$0 { model.closeMeetingTransferImport() } }
            )
        ) {
            MeetingTransferImportView()
                .environment(model)
                .interactiveDismissDisabled(
                    model.meetingTransferImportState?.isBusy == true
                )
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, !model.isRecording else { return false }
            Task { await model.importAudioFile(at: url) }
            return true
        }
        // Eine Meldungsleiste fuer alles, was der Benutzer erfahren muss,
        // unabhaengig davon, welche Ansicht gerade offen ist. Sie blockiert
        // nicht und verschwindet erst auf Klick.
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                if let export = model.audioExportActivity {
                    HStack(spacing: 10) {
                        ProgressView(value: export.fraction)
                            .frame(width: 120)
                        Text("Exporting \(export.fileName) \(Int(export.fraction * 100))%")
                            .font(.callout)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(8)
                    .background(.bar)
                }
                if let notice = model.notice {
                    HStack(spacing: 8) {
                        Image(systemName: notice.isError
                            ? "exclamationmark.triangle.fill"
                            : "info.circle")
                            .foregroundStyle(notice.isError ? Steno.Colors.error : .secondary)
                        Text(notice.text)
                            .font(.callout)
                            .textSelection(.enabled)
                        Spacer()
                        Button("OK") { model.dismissNotice() }
                            .controlSize(.small)
                    }
                    .padding(8)
                    .background(.bar)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .animation(.default, value: model.notice)
        .animation(.default, value: model.audioExportActivity)
        // Dismissbar: Vorher war das Binding konstant, der Alert kam nach
        // jedem Wegklicken sofort wieder.
        .alert(
            "Steno could not start",
            isPresented: Binding(
                get: { model.bootstrapError != nil },
                set: { if !$0 { model.dismissBootstrapError() } }
            ),
            actions: { Button("OK", role: .cancel) {} },
            message: { Text(model.bootstrapError ?? "") }
        )
    }
}

/// Scrollbare Transkripte und Protokolle duerfen ihre gesamte ideale Hoehe
/// nicht als Mindesthoehe an das Fenster weiterreichen. `GeometryReader`
/// uebernimmt ausschliesslich den bereits verfuegbaren Fensterplatz; der
/// Inhalt bleibt darin normal scrollbar.
struct WindowStableDetail<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        GeometryReader { _ in
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct MultiMeetingSelectionView: View {
    let count: Int

    var body: some View {
        ContentUnavailableView {
            Label(
                "\(count) Meetings Selected",
                systemImage: "rectangle.stack.fill"
            )
        } description: {
            Text("Drag the selection into a folder or use Move Meetings.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Steno")
    }
}

extension ContentView {
    @ViewBuilder
    var detailContent: some View {
        if model.selectedMeetingIDs.count > 1 {
            MultiMeetingSelectionView(count: model.selectedMeetingIDs.count)
        } else if model.isRecording,
                  model.selectedMeetingID == model.recordingMeetingID
        {
            RecordingView()
                // Ohne Titel steht waehrend der Aufnahme nur "Steno" im
                // Fenster - man sieht nicht, worin man gerade aufnimmt.
                .navigationTitle(recordingTitle)
                .navigationSubtitle("Recording")
        } else if let meetingID = model.selectedMeetingID {
            MeetingDetailView(meetingID: meetingID)
                .id(meetingID)
        } else if model.isRecording {
            // Waehrend einer Aufnahme ohne Auswahl: der Streifen oben sagt
            // schon alles Noetige, hier braucht es keinen zweiten Hinweis auf
            // dieselbe Sache.
            ContentUnavailableView(
                "No meeting selected",
                systemImage: "waveform",
                description: Text("Pick a meeting to look something up while you record.")
            )
            .navigationTitle("Steno")
        } else {
            ContentUnavailableView(
                "No meeting selected",
                systemImage: "waveform",
                description: Text("Start a recording or import an audio file.")
            )
            // Ohne Titel zeigt das Fenster den Bundle-Namen "steno-macos".
            .navigationTitle("Steno")
        }
    }

    var recordingTitle: String {
        model.meetings.first { $0.id == model.recordingMeetingID }?.title ?? "Steno"
    }
}
