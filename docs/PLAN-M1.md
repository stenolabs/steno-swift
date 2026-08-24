# Meilenstein 1: App-Hülle, Bibliothek, Aufnahme, Import, Live-Transkript

> Historical, non-normative milestone record retained in German. Use `ARCHITECTURE.md` and `FEATURE-PARITY.md` for current status.

Umsetzungsplan zu `ARCHITECTURE.md` Abschnitt 10, Meilenstein 1.
Reihenfolge ist verbindlich; jeder Schritt endet mit grünem `swift test` und einem Commit.

## Rahmen

- Toolchain: Swift 6.3, Xcode 26.6, Zielplattform macOS 26.
- Ein lokales SwiftPM-Paket `StenoKit` unter `StenoKit/` mit den Targets aus der Architektur.
- App-Target `Steno` per XcodeGen (`project.yml` im Repo-Root, `xcodegen generate` erzeugt `Steno.xcodeproj`, das nicht eingecheckt wird).
- Strikte Swift-6-Concurrency (`StrictConcurrency` aktiv), keine externen Abhängigkeiten in M1.
- Tests: swift-testing (`import Testing`), nicht XCTest, außer wo XCTest technisch nötig ist.

## Schritt 1: StenoDomain und StenoLibrary

`StenoDomain` (reine Werttypen, `Sendable`, `Codable`):

- `MeetingID`, `MediaAssetID`, `RunID`, `RevisionID`, `PersonID`, `JobID` als typisierte Wrapper um UUIDv7 (eigene UUIDv7-Erzeugung, RFC 9562, mit Test auf zeitliche Sortierbarkeit).
- `Meeting` (Titel, createdAt, Status: recording, interrupted, ready, processing), `MediaAsset` (kind: micTrack, systemTrack, imported; sampleRate, duration, provenanceKey), `ProcessingRun` (kind, EngineDescriptor, Status, Zeiten, Fehlertext), `TranscriptRevision` (Turns mit Segmenten und Wörtern samt start/end, origin: liveProvisional, finalRun(RunID), userEdit(RevisionID)), `Job` (kind, meetingID, Status: queued, running, finished, failed, cancelled; attemptCount).
- Jedes persistierte Dokument trägt `schemaVersion: Int`.

`StenoLibrary` (Dateibibliothek):

- `LibraryLayout`: Pfadableitung für `library.json`, `meetings/<id>/…`, `jobs/…` exakt nach ARCHITECTURE.md Abschnitt 3.
- `AtomicFile`: write-to-temp + `replaceItemAt`/rename, fsync vor rename (die fehlende fsync war ein dokumentierter Altfehler).
- `Library`: öffnen/anlegen, `library.json` mit schemaVersion validieren, Ablehnung unbekannter Versionen mit klarem Fehler.
- CRUD: Meeting anlegen/laden/auflisten, MediaAsset registrieren (Datei wird hineinkopiert, nie bewegt; provenanceKey = SHA-256 bei Import, `"<meetingID>/<trackKind>"` bei Aufnahme; Duplikat-Import wirft `duplicateProvenance` mit Verweis auf das existierende Meeting).
- Revisionen: append-only unter `transcript/revisions/`, `current.json` als atomarer Zeiger, Regel "Benutzer-Edit wird nie stillschweigend ersetzt" (neuer Finallauf über einer userEdit-Revision landet als Kandidat: Feld `pendingCandidate` in `current.json`).
- `JobStore`: persistente Queue in `jobs/`, Statusübergänge atomar, `recoverAtLaunch()` setzt `running` auf `queued` zurück.
- `RecoverySweep`: findet Meetings im Status `recording` ohne aktive Session, setzt sie auf `interrupted`, reiht Finalisierungsjob ein.
- Beschädigte JSON-Dokumente: Umbenennung nach `<name>.corrupt-<timestamp>`, Fehler wird gemeldet, nie stilles Überschreiben.
- Tests: Roundtrips aller Dokumente, Atomik (simulierter Abbruch zwischen temp-Write und rename), Duplikat-Import, Revisionsregeln inkl. Kandidatenfall, Job-Recovery, Corrupt-Quarantäne, UUIDv7-Monotonie.

## Schritt 2: StenoMacAudio

- `AudioPermissions`: Mikrofonstatus abfragen/anfordern; Systemaudio-Berechtigung (TCC für Audio-Capture) erkennen und verständlich melden.
- `MicRecorder`: AVAudioEngine-Input-Tap im Gerätenativformat, konvertiert nichts, schreibt inkrementell.
- `SystemAudioRecorder`: CoreAudio Process Tap (`AudioHardwareCreateProcessTap` mit `CATapDescription`, Aggregate Device) über alle Prozesse, macOS-14.4+-API, hier ohne Fallback (Mindestziel macOS 26).
- `TrackWriter`: CAF Linear PCM 16 bit über `AVAudioFile`, Flush-Politik so, dass ein Kill höchstens die letzten ~1 s kostet; Schreibfehler (voller Datenträger) beenden die Aufnahme sauber mit intaktem Prefix.
- `RecordingSession` (actor): startet beide Recorder, besitzt je Spur einen Ring-Puffer mit zwei Konsumenten (TrackWriter, Live-Abonnent via `AsyncStream<AVAudioPCMBuffer>`), liefert Pegel für die UI, `stop()` schließt Dateien und registriert beide MediaAssets im Meeting.
- `ProcessInfo.beginActivity` gegen App Nap/Idle Sleep während der Aufnahme.
- Freier-Platz-Check vor Start (Schwelle 2 GB) und Warnung bei Unterschreiten während der Aufnahme.
- Hardwarefreie Tests: TrackWriter gegen synthetische Puffer, RecordingSession mit injizierten Fake-Quellen (Recorder hinter Protokollen `AudioSource`).

## Schritt 3: StenoTranscription

- Verträge exakt wie ARCHITECTURE.md Abschnitt 6 (`TranscriptionProvider`, `LiveTranscriptionSession`, `TranscriptionEvent` mit `.volatile`/`.final`).
- `SpeechAnalyzerProvider`: `SpeechTranscriber` mit `volatileResults` + `audioTimeRange`; `AssetInventory`-Handling (Status prüfen, Download anstoßen, Fortschritt melden); Locale-Auswahl mit Auto-Fallback.
- Live: ein Transcriber je Spur, gespeist aus dem `AsyncStream` der RecordingSession.
- Datei: `transcribeFile` über die fertige CAF-Datei, Ergebnis mit Wortzeitstempeln als `TranscriptOutput`.
- Mapping `TranscriptOutput` → `TranscriptRevision` (Turns = zusammenhängende Ergebnisblöcke je Spur, Sprecherlabel = Kanal: "Ich"/"Andere"; Wortliste mit start/end).
- Tests: Mapping-Logik mit synthetischen Ergebnissen; der Provider selbst wird in M1 manuell verifiziert (echte Modelle), Benchmarks kommen in M2.

## Schritt 4: StenoPipeline

- `PipelineCoordinator` (actor): konsumiert den JobStore, führt `finalASR`-Jobs aus (je Spur transcribeFile, Revision erzeugen, Regeln aus Schritt 1), idempotent (Lauf schreibt erst `runs/<id>/` temporär, dann atomar), Abbruch setzt `cancelled` und räumt Teilartefakte.
- Start-Sequenz als eine Funktion: Bibliothek öffnen, Migration (in M1 nur Versionscheck), RecoverySweep, JobStore.recoverAtLaunch, Queue starten.
- Tests: Fake-Provider, Crash-Simulation (Job mid-run abbrechen, neu starten, Ergebnis konsistent), Cancel-Pfad.

## Schritt 5: App

- `project.yml` für XcodeGen: Target `Steno` (SwiftUI, macOS 26), hängt an `StenoKit`-Produkten; `Info.plist` mit `NSMicrophoneUsageDescription` und `NSAudioCaptureUsageDescription`; Sandbox zunächst aus (lokale Entwicklung), als vertagte Entscheidung dokumentiert.
- UI, bewusst schlicht aber sauber: Meetingliste (Titel, Datum, Dauer, Status), Aufnahme-View (Start/Stop, Pegel je Spur, Live-Transkript mit vorläufig/final unterscheidbar), Import per Fileimporter und Drag-and-drop, Meeting-Detail mit Transkriptansicht (Turns, Zeitstempel, Sprecherlabel) und Statuszeile laufender Jobs.
- Bibliotheksort: `~/Library/Application Support/Steno/Library`, überschreibbar per `STENO_LIBRARY_DIR` (Testbarkeit, Muster aus dem Altprojekt).
- `scripts/build-app.sh`: `xcodegen generate` + `xcodebuild -scheme Steno build` mit ad-hoc-Signierung, Ausgabepfad wird ausgegeben.

## Akzeptanz M1 (aus ARCHITECTURE.md, überprüfbar)

1. Aufnahme erzeugt zwei getrennte CAF-Originale unter `media/`.
2. Import einer m4a kopiert die Datei, provenanceKey verhindert Doppelimport.
3. Live-Transkript erscheint während der Aufnahme, vorläufige Ergebnisse als solche markiert.
4. `kill -9` während der Aufnahme: nach Neustart existiert das Meeting als `interrupted`, die CAF-Prefixe sind abspielbar, der Finalisierungsjob läuft.
5. Finallauf erzeugt Revision mit Wortzeitstempeln; die Transkriptansicht zeigt sie.
