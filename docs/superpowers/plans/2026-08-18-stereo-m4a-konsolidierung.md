# Stereo-M4A-Konsolidierung Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task.

**Goal:** Die aktuelle macOS-App exportiert eine kompakte Stereo-M4A mit Mikrofon links und Systemaudio rechts, ohne Originale oder Bibliotheksdaten zu verändern.

**Architecture:** Der bereits entwickelte SwiftUI-freie `StereoM4AExporter` wird mitsamt seinen dekodierenden Kerntests nach `StenoExchange` portiert.
Die aktuelle macOS-App leitet aus lesbaren `MediaAsset`-Einträgen deterministische Exportoptionen ab, öffnet den Auswahldialog erst nach dem Laden dieser Optionen und führt den kombinierten Export mit sichtbarem, gepuffertem Fortschritt aus.
Die bestehende bytegenaue Einzelspurkopie bleibt unverändert.

**Tech Stack:** Swift 6, AVFAudio und AVFoundation, Swift Testing, SwiftUI, AppKit `NSSavePanel`, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-08-12-stereo-m4a-export-design.md`

## Global Constraints

- Die Ausgabe ist AAC-LC im M4A-Container mit 48.000 Hz, zwei Kanälen und 128 kbit/s Zielbitrate.
- Mikrofon liegt ausschließlich links und Systemaudio ausschließlich rechts.
- Die kürzere Quelle wird bis zur dekodierten Dauer der längeren Quelle mit digitaler Stille aufgefüllt.
- Der Export arbeitet blockweise mit begrenztem Speicherbedarf.
- Originaldateien, `MediaAsset`-Einträge und alle weiteren Bibliotheksdaten bleiben unverändert.
- Eine Zieldatei wird erst nach erfolgreicher Kodierung, Synchronisierung und Lesbarkeitsprüfung atomar veröffentlicht.
- Die kombinierte Option erscheint nur bei genau einer lesbaren Mikrofonspur und genau einer lesbaren Systemspur.
- Die vorhandene bytegenaue Einzelspurausgabe bleibt unverändert.
- Ein Dialog wird erst sichtbar, nachdem seine Optionen geladen wurden, und bleibt bei leerer Optionsliste geschlossen.
- Fortschrittswerte dürfen keinen unbeschränkten Rückstau auf dem Main Actor erzeugen.
- Es wird keine neue Abhängigkeit hinzugefügt.
- Automatisierte und manuelle Prüfungen übertragen keine Audio- oder Meetingdaten an externe Dienste.
- Die Implementierung betrifft nur die macOS-Oberfläche.
- Vorhandene Änderungen an iOS-Diarisierung, Sprecherpräsentation, Meetingtransfer und LM-Studio-Antwortformat bleiben erhalten.

---

### Task 1: Geprüften Stereo-M4A-Kern portieren

**Files:**

- Create: `StenoKit/Sources/StenoExchange/StereoM4AExporter.swift`
- Create: `StenoKit/Tests/StenoExchangeTests/StereoM4AExporterTests.swift`

**Interfaces:**

- Consumes: lesbare Mikrofon- und Systemaudio-URLs sowie eine Ziel-URL.
- Produces: `StereoM4AExporter.export(microphoneURL:systemURL:destinationURL:progress:) throws` und `StereoM4AExportProgress`.

- [ ] **Step 1: Den Quellstand und seine Tests vor dem Portieren prüfen**

Lies die vollständigen Patches der Quellcommits `20e28cf` und `801af69`.

Bestätige, dass die Tests Kanaltrennung, Dauer, Stille nach dem kürzeren Kanal, AAC-Container, sichere Veröffentlichung, Abbruchbereinigung, blockweises Schreiben und monotonen Fortschritt prüfen.

- [ ] **Step 2: Den Kern und den ergänzenden AAC-Test portieren**

Übernimm `20e28cf` und danach ausschließlich den Testpatch aus `801af69`.

Löse Konflikte nur innerhalb der beiden genannten Dateien und ändere keine Paketabhängigkeiten.

- [ ] **Step 3: Den fokussierten Kerntest ausführen**

Run:

```bash
swift test --package-path StenoKit --filter StereoM4AExporterTests
```

Expected: Alle Exportertests bestehen.

- [ ] **Step 4: Die erzeugte Datei lokal als AAC-M4A prüfen**

Nutze nur synthetische Testsignale.

Dekodiere die von den Tests erzeugte Datei im Test selbst und prüfe zusätzlich lokal mit `afinfo`, dass Container, zwei Kanäle und 48.000 Hz erkannt werden.

Kein Upload zu SpeechMind oder einem anderen externen Dienst ist zulässig.

- [ ] **Step 5: Diff prüfen und committen**

Run:

```bash
git diff --check
```

Commit:

```bash
git add StenoKit/Sources/StenoExchange/StereoM4AExporter.swift StenoKit/Tests/StenoExchangeTests/StereoM4AExporterTests.swift
git commit -m "feat(export): create stereo M4A files"
```

---

### Task 2: Deterministische Optionen und vollständig geladener Dialog

**Files:**

- Create: `App/Sources/AudioExportPresentation.swift`
- Create: `App/Tests/AudioExportPresentationTests.swift`
- Modify: `App/Sources/AppModel+Export.swift`
- Modify: `App/Sources/MeetingSidebar/MeetingSidebarView.swift`

**Interfaces:**

- Consumes: lesbare `[MediaAsset]`-Werte und ein aktuelles `Meeting`.
- Produces: `[AudioExportOption]` sowie einen optionalen `AudioExportDialogRequest`, der Meeting und bereits geladene Optionen gemeinsam besitzt.

- [ ] **Step 1: RED-Tests für Optionsableitung und Dialog-Ladezeitpunkt schreiben**

Schreibe zuerst fokussierte Tests für diese Regeln:

- Eine Mikrofonspur und eine Systemspur erzeugen nach den beiden Originaloptionen genau eine Option `Both tracks - stereo M4A`.
- Mehr als eine Mikrofon- oder Systemspur erzeugt keine kombinierte Option.
- Importierte oder einzelne Spuren bleiben Originaloptionen.
- `AudioExportDialogRequest.load` liefert die bereits geladenen Optionen zusammen mit dem Meeting.
- Eine leere Optionsliste liefert `nil`, damit kein leerer Dialog geöffnet wird.

- [ ] **Step 2: RED beobachten**

Run:

```bash
xcodegen generate
xcodebuild -project Steno.xcodeproj -scheme Steno -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/StereoM4A -only-testing:StenoTests/AudioExportPresentationTests test
```

Expected: Die fokussierten Tests scheitern wegen der noch fehlenden Präsentationstypen.

- [ ] **Step 3: Das pure Präsentationsmodell implementieren**

Implementiere `AudioExportOptionKind`, `AudioExportOption`, `AudioExportPresentation` und `AudioExportDialogRequest` ohne SwiftUI-Abhängigkeit.

Erhalte die Reihenfolge der Originalspuren.

Verwende `ChannelLabel.trackName` für Originalbeschriftungen.

Hänge die kombinierte Option nur bei genau einem `.micTrack` und genau einem `.systemTrack` an.

- [ ] **Step 4: Nur lesbare Assets in Optionen umwandeln**

Ersetze `audioTracks(for:)` durch `audioExportOptions(for:)` in `AppModel+Export.swift`.

Filtere wie bisher anhand des tatsächlichen Dateipfads, bevor `AudioExportPresentation.options(for:)` aufgerufen wird.

Ändere `exportAudioTrack` nicht.

- [ ] **Step 5: Den heutigen Sidebar-Dialog anbinden**

Ersetze `audioExportTarget` und `audioTracks` in `MeetingSidebarView` durch einen optionalen `AudioExportDialogRequest` und einen getrennten Lade-Task.

Ein Klick auf `Export Audio…` lädt zuerst die Optionen und setzt erst danach den Dialog-Request.

Ein später fertig werdender Lade-Task darf keinen Dialog für ein inzwischen anderes Meeting öffnen.

Die Originaloptionen rufen weiterhin `exportAudioTrack` auf.

Die kombinierte Option wird in Task 3 an den Exportpfad angeschlossen.

- [ ] **Step 6: GREEN beobachten und committen**

Führe den fokussierten App-Test erneut aus.

Run:

```bash
git diff --check
```

Commit:

```bash
git add App/Sources/AudioExportPresentation.swift App/Sources/AppModel+Export.swift App/Sources/MeetingSidebar/MeetingSidebarView.swift App/Tests/AudioExportPresentationTests.swift
git commit -m "feat(mac): derive stereo audio export choices"
```

---

### Task 3: Save-Flow, Fortschritt und Fehlergrenzen anbinden

**Files:**

- Modify: `App/Sources/AppModel.swift`
- Modify: `App/Sources/AppModel+Export.swift`
- Modify: `App/Sources/ContentView.swift`
- Modify: `App/Sources/MeetingSidebar/MeetingSidebarView.swift`
- Modify: `App/Tests/AudioExportPresentationTests.swift`

**Interfaces:**

- Consumes: `AudioExportOption.stereoM4A`, Quell-URLs, Meetingtitel und `StereoM4AExporter`.
- Produces: `AudioExportActivity`, einen Save-Panel-Flow und sichtbaren, koaleszierenden Fortschritt.

- [ ] **Step 1: RED-Tests für den asynchronen Exportzustand schreiben**

Füge zuerst Tests für diese beobachtbaren Regeln hinzu:

- Ein kombinierter Export veröffentlicht Fortschritt und räumt `audioExportActivity` nach Erfolg auf.
- Während eines laufenden kombinierten Exports wird ein zweiter kombinierter Export abgelehnt.
- Ein Exportfehler räumt `audioExportActivity` auf und erzeugt eine sichtbare Fehlermeldung.
- `AudioExportProgressStream.make()` puffert mit `.bufferingNewest(1)`, sodass ein beschäftigter Main Actor nur den neuesten Rückstand erhält.

Verwende einen injizierbaren `StereoAudioExportPerformer`, damit die Tests weder Save Panel noch echte Dateien benötigen.

- [ ] **Step 2: RED beobachten**

Führe den fokussierten `AudioExportPresentationTests`-Befehl aus Task 2 erneut aus.

Expected: Die neuen Tests scheitern wegen fehlender Aktivität, Performer-Injektion und Exportmethoden.

- [ ] **Step 3: AppModel-Orchestrierung implementieren**

Importiere `StenoExchange` nur dort, wo die Exporttypen benötigt werden.

Ergänze den aktuellen `AppModel`-Initializer um einen optional injizierbaren `StereoAudioExportPerformer`, ohne bestehende Meetingtransfer-, Runtime- oder Testinjektionen zu verlieren.

Die Produktionsvorgabe ruft `StereoM4AExporter().export` außerhalb des Main Actors auf.

Leite Fortschritt über `AudioExportProgressStream.make()` mit `.bufferingNewest(1)` zurück auf den Main Actor.

`performStereoAudioExport` setzt eine `AudioExportActivity`, verhindert Parallelstarts, aktualisiert nur die eigene Aktivität und räumt sie auf allen Erfolgs-, Fehler- und Abbruchpfaden auf.

- [ ] **Step 4: Save Panel und Dateinamen implementieren**

`exportStereoAudio(microphone:system:of:)` löst die beiden Bibliothekspfade auf und öffnet ein `NSSavePanel` für `.m4a`.

Der vorgeschlagene Name folgt `<Meetingtitel> - Microphone left, System right.m4a`.

Die Meldung lautet `Microphone is left; system audio is right. The originals stay in Steno.`.

Nach Erfolg wird der gespeicherte Dateiname gemeldet.

Bei Fehler wird verständlich gemeldet, dass die Datei nicht gespeichert werden konnte, während die Originale erhalten bleiben.

- [ ] **Step 5: Sidebar und sichtbaren Fortschritt anschließen**

Die kombinierte Sidebar-Option startet `exportStereoAudio` mit den bereits gepinnten Assets des Dialog-Requests.

Zeige `audioExportActivity` in der vorhandenen `ContentView`-Einblendung als Dateiname plus Prozentwert an.

Blockiere nicht die übrige App-Oberfläche.

- [ ] **Step 6: GREEN beobachten und committen**

Führe die fokussierten App-Tests erneut aus.

Run:

```bash
git diff --check
```

Commit:

```bash
git add App/Sources/AppModel.swift App/Sources/AppModel+Export.swift App/Sources/ContentView.swift App/Sources/MeetingSidebar/MeetingSidebarView.swift App/Sources/AudioExportPresentation.swift App/Tests/AudioExportPresentationTests.swift
git commit -m "feat(mac): connect stereo M4A export flow"
```

---

### Task 4: Vollständige Integration prüfen und unabhängig reviewen

**Files:**

- Verify: `StenoKit/Sources/StenoExchange/StereoM4AExporter.swift`
- Verify: `StenoKit/Tests/StenoExchangeTests/StereoM4AExporterTests.swift`
- Verify: `App/Sources/AppModel.swift`
- Verify: `App/Sources/AppModel+Export.swift`
- Verify: `App/Sources/AudioExportPresentation.swift`
- Verify: `App/Sources/MeetingSidebar/MeetingSidebarView.swift`
- Verify: `App/Sources/ContentView.swift`
- Verify: `App/Tests/AudioExportPresentationTests.swift`

- [ ] **Step 1: Die verpflichtende Kette nach der StenoKit-Änderung ausführen**

Verwende denselben aufgabenspezifischen Build-Root für alle sequentiellen Xcode-Läufe.

Run:

```bash
xcodegen generate
scripts/build-app.sh
scripts/build-ios.sh
swift test --package-path StenoKit
```

Wenn der bekannte kombinierte SwiftPM-Runner nach vollständiger Ausgabe hängt, dokumentiere den Prozesszustand und führe alle StenoKit-Testtargets einzeln gegen denselben Buildzustand aus.

Behaupte den kombinierten Lauf nur als bestanden, wenn er tatsächlich mit Status 0 beendet wurde.

- [ ] **Step 2: Die vollständigen App-Suites ausführen**

Run:

```bash
xcodebuild -project Steno.xcodeproj -scheme Steno -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/StereoM4A test
cd iOS/StenoiOSKit && xcodebuild -scheme StenoiOSKit -destination 'platform=iOS Simulator,name=iPhone 17' test
```

Führe zusätzlich den vollständigen iOS-App-Scheme-Test mit dem bereits in diesem Arbeitsbaum bewährten Simulatorziel aus.

- [ ] **Step 3: Lokale Format- und Importabnahme ausführen**

Erzeuge eine synthetische M4A mit unterschiedlich langen Signalen.

Prüfe lokal mit `afinfo` 48.000 Hz, zwei Kanäle und AAC.

Importiere dieselbe synthetische Datei lokal über Stenos vorhandenen Importpfad, soweit dies automatisiert oder ohne Veränderung echter Benutzerdaten möglich ist.

Wenn eine vollständige Steno-Legacy-Abnahme in dieser Umgebung nicht verfügbar ist, dokumentiere sie als offene manuelle Abnahme und behaupte sie nicht als bestanden.

- [ ] **Step 4: Unabhängigen Read-only-Review einholen**

Lass den vollständigen Branch-Diff gegen `b477470` prüfen.

Der Reviewer soll besonders Kanalbedeutung, atomare Veröffentlichung, Speicherbegrenzung, Parallelitätszustand, Dialog-Races, Erhalt des Einzelspurexports und Auswirkungen auf beide Apps prüfen.

Behebe bestätigte Critical-, High- und Medium-Befunde testgetrieben und lasse die Fixes gezielt erneut prüfen.

- [ ] **Step 5: Abschlusszustand prüfen**

Run:

```bash
git diff --check
git status --short
git log --oneline b477470..HEAD
```

Entferne nur aufgabeneigene, regenerierbare Test- und Diagnoseartefakte, die nicht mehr benötigt werden.

Behalte höchstens einen aktuellen Build für eine noch offene manuelle Abnahme.

Committe ausschließlich notwendige Review-Fixes in einem klar benannten lokalen Commit.
