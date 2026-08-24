# Arbeitsbaum-Konsolidierung Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fertige, noch getrennte Änderungen kontrolliert in `feat/audio-core-extraction` übernehmen, ohne bereits abgenommene Aufnahme-, Sidebar- oder Plattformpfade zu beschädigen.

**Architecture:** Direkt vom Integrationsbranch abstammende Änderungen werden nach vollständiger Quellprüfung unverändert übernommen.
Ältere, stark abgewichene Arbeitsbäume werden nicht pauschal gemergt, sondern nach fachlichen Paketen, Patch-Doppelungen und Abhängigkeiten bewertet und anschließend einzeln portiert.

**Tech Stack:** Git, Swift 6, SwiftPM, XcodeGen, Xcode, macOS-App, iOS-App.

**Spec:** `HANDOFF-audio-core-extraction.md` und die task-eigenen `HANDOFF-*.md` der jeweiligen Arbeitsbäume.

## Global Constraints

- `feat/audio-core-extraction` bleibt der lokale Integrationsbranch.
- Es wird nichts gepusht und kein Pull Request angelegt.
- `UEBERGABE-sprecher-erkenntnisse.md`, `.superpowers/` und fremde uncommittete Änderungen bleiben unangetastet.
- Änderungen in `StenoKit` werden mit `xcodegen generate`, `scripts/build-app.sh`, `scripts/build-ios.sh` und `swift test --package-path StenoKit` geprüft.
- Handoffs werden nicht committet oder gelöscht.
- Arbeitsbäume und Branches werden erst nach vollständiger Integration und frischer Verifikation entfernt.

---

### Task 1: Direkt kompatiblen LM-Studio-Fix integrieren

**Files:**
- Modify: `StenoKit/Sources/StenoIntelligence/OpenAICompatibleProvider.swift`
- Modify: `StenoKit/Tests/StenoIntelligenceTests/OpenAICompatibleProviderTests.swift`

**Interfaces:**
- Consumes: `OpenAICompatibleProvider` und seinen bestehenden strukturierten Protokollvertrag.
- Produces: Vollständigkeitsprüfung strukturierter Protokolle und eine klar beschriebene Fallback-Anfrage.

- [x] **Step 1: Quellbranch und Abstammung prüfen**

Run:

```bash
git merge-base --is-ancestor feat/audio-core-extraction codex/fix-lmstudio-structured-response
git log --oneline feat/audio-core-extraction..codex/fix-lmstudio-structured-response
git -C .worktrees/lmstudio-structured-response status --short
```

Expected: Exit 0 für die Abstammungsprüfung, genau die Commits `975b852` und `713f878`, keine Änderungen im Quellarbeitsbaum.

- [x] **Step 2: Quellbranch fokussiert prüfen**

Run:

```bash
swift test --package-path StenoKit --filter OpenAICompatibleProviderTests
```

Working directory: `.worktrees/lmstudio-structured-response`.

Expected: Alle `OpenAICompatibleProviderTests` bestehen.

- [x] **Step 3: Quellbranch vollständig prüfen**

Run:

```bash
xcodegen generate
scripts/build-app.sh
scripts/build-ios.sh
swift test --package-path StenoKit
```

Working directory: `.worktrees/lmstudio-structured-response`.

Expected: Beide Apps bauen und alle StenoKit-Tests bestehen.

- [x] **Step 4: Beide Commits übernehmen**

Run:

```bash
git cherry-pick 975b852 713f878
```

Expected: Beide Commits werden ohne Konflikt auf `feat/audio-core-extraction` übernommen.

- [x] **Step 5: Integrierten Stand vollständig prüfen**

Run:

```bash
xcodegen generate
scripts/build-app.sh
scripts/build-ios.sh
swift test --package-path StenoKit
git diff --check
```

Expected: Beide Apps bauen, alle StenoKit-Tests bestehen und der Diff-Check ist sauber.

Ergebnis vom 18.08.2026:

- Der Quellbranch bestand 21 fokussierte Provider-Tests, beide App-Builds und 419 StenoKit-Tests.
- SwiftPMs eigene Manifest-Sandbox war im Codex-Sandboxprofil nicht nutzbar; die SwiftPM-Läufe wurden deshalb wie im Projekt-Handoff vorgesehen mit `--disable-sandbox` wiederholt.
- Die Commits wurden als `736d321` und `6dc7339` konfliktfrei auf `codex/consolidate-worktrees` übernommen.
- Der integrierte Stand bestand beide App-Builds und 419 StenoKit-Tests.
- `git diff --check` war sauber.

### Task 2: Abgewichene Arbeitsbäume klassifizieren

**Files:**
- Modify: `docs/superpowers/plans/2026-08-18-arbeitsbaum-konsolidierung.md`

**Interfaces:**
- Consumes: Branchhistorie, Patch-IDs, task-eigene Handoffs und den aktuellen Funktionsstand.
- Produces: Eine Integrationsmatrix mit den Zuständen `bereits enthalten`, `direkt portierbar`, `neu zu implementieren`, `zurückgestellt` oder `fremder Arbeitsbaum`.

- [x] **Step 1: Branches und Arbeitsbäume vollständig erfassen**

Run:

```bash
git worktree list --porcelain
git branch -vv --sort=-committerdate
```

Expected: Jeder registrierte Arbeitsbaum besitzt einen eindeutigen Branch und Pfad.

- [x] **Step 2: Fachliche Pakete aus den Branches lesen**

Run für jeden Branch:

```bash
git log --reverse --oneline 9ffa9c9..<branch>
git diff --stat feat/audio-core-extraction...<branch>
git cherry feat/audio-core-extraction <branch>
```

Expected: Die Änderungen lassen sich nach fachlichen Paketen statt nur nach Commitanzahl gruppieren.

- [x] **Step 3: Aktuellen Baum nach gleichwertiger Funktion durchsuchen**

Run:

```bash
rg -n '<relevante Typen, Funktionen und UI-Texte>' App iOS StenoKit docs
```

Expected: Jede Einstufung `bereits enthalten` ist durch konkrete aktuelle Dateien oder Tests belegt.

- [x] **Step 4: Integrationsmatrix in diesem Plan ergänzen**

Die Matrix nennt Branch, fachliches Paket, Abhängigkeiten, aktuellen Doppelungsgrad, Risiko, empfohlene Übernahmeform und erforderliche Prüfungen.

- [x] **Step 5: Nächste Integrationswelle festlegen**

Die nächste Welle enthält nur voneinander abhängige oder konfliktarme Pakete und bekommt vor Codeänderungen einen eigenen ausführbaren Plan.

## Integrationsmatrix vom 18.08.2026

Keiner der älteren Swift-Branches wird vollständig gemergt oder pauschal per Cherry-pick übernommen.
Sie zweigen bei `9ffa9c9` vom aktuellen Integrationsstand ab und enthalten 55 bis 124 ältere Commits sowie fachlich überholte Zwischenstände.

| Paket | Quellen | Einstufung | Nächster Schritt |
|---|---|---|---|
| Jüngste iOS-Diarisierung und AirDrop-Transfer | Snapshot `5c7f873` mit 60 Commits nach `6fbd28d` | Maßgebliche jüngste Arbeitslinie, im ersten Audit übersehen | Vor allen älteren Wellen als zusammenhängenden Branch sichern, frisch prüfen und mit den LM- und Sprechercommits zusammenführen. |
| Gemeinsame Sprecherpräsentation | `331f57b..b926e66` | Direkt portierbar | Als erste eigene Welle integrieren und mit Kern, macOS und iOS prüfen. |
| Persistente Aufnahmeannotationen | `029b4e9..8292c0a` | Teilweise bereits enthalten | Die aktuellen Commits `eb7a899`, `e62dea8`, `263c065` und `bac9a43` behalten; fehlende Retry-, Cache- und Lifecycle-Garantien testgetrieben neu integrieren. |
| iPad-Befehle, Inspector und Sprecherreview | `e0271e6..e14622e`, `52aa6f4`, `79f16be`, `eaf77f2` | Neu auf aktuellem Stand zu integrieren | Nach Sprecherpräsentation, Notiz-Härtung und Review-Recovery portieren. |
| Transaktionale Review-Writes | `4f67a82..cca45a5` | Sicherheitskritisch, nicht direkt portieren | Als eigene Welle mit Crash-, WAL-, Divergenz- und vollständigen Plattformtests integrieren. |
| iOS-Protokolle und Textmodell-Endpunkte | `226bb3c..5435e85` | Fachlich wertvoll, aber neu zu integrieren | Aktuelle Navigation und die LM-Studio-Fixes `736d321` und `6dc7339` erhalten; Job-Äquivalenz und gepinnten Übertragungshinweis vor Übernahme korrigieren. |
| Auswählbare ASR-Modelle und Parakeet | `e52cd59..5d5aa70` | Zurückgestellt bis Rebaseline | FluidAudio `0.15.5` erst nach erneuter Sortformer-/WeSpeaker-Baseline auf denselben 18 AMI-Meetings übernehmen. |
| Stereo-M4A-Kern | `20e28cf`, `801af69` | Direkt portierbar | Nach Sprecherpräsentation als eigene Welle übernehmen; macOS-UI und die Fixes `753ae48`, `064e101` manuell an die neue Sidebar anpassen. |
| Tokenbewusster Protokoll-Renderer | `c993f36..026a753` | Neu auf aktuellem Stand zu implementieren | Nach iOS-Protokollen und Transkriptionsplan-Provenienz umsetzen; die strikte strukturierte Vollständigkeit aus `736d321` und `6dc7339` schützen. |
| Providerdialekte und Cloudprovider | `4513e7c..4d078cf` | Neu auf aktuellem Stand zu implementieren | Nach Tokenbudget und Hostingklassifikation mit Migration, Disclosure, Diagnostik und Secret-Schutz umsetzen. |
| Live-Transkript-Feed | `2bdbe44..21fb4ab` beziehungsweise `6c808b1..f0b15d9` | Wertvoll, aber neu zu implementieren | An die aktuelle Lückensegmentierung aus `cdf2337` anpassen; Text vor einer Lücke darf durch das erste Ereignis danach nicht verschwinden. |
| Mac-Modellstatus | Teil von `b30c417` | Selektiver Teilpatch direkt portierbar | Nur Darstellung und Tests übernehmen; Endpoint-abhängige Teile später. |
| Benchmark-Scorer | `4115800` | Direkt portierbar | Als unabhängige Werkzeugwelle übernehmen und fail-closed prüfen. |
| Benchmark- und Kontextdokumente | `c0c6902`, `00d8a56`, `f0da6e2`, `dafb268`, `b9467d3`, `57ef8fd` | Selektiv portierbar | Messwerte nur als datierte historische Ergebnisse mit vorhandener Provenienz übernehmen; nicht als frischen Integrationsnachweis darstellen. |
| Mikrofon-Recovery | `d93c2d9`, `41c1fe5`, `f6c2591`, `dc2810c` | Bereits deutlich besser enthalten | Nicht portieren; aktueller Pfad bis `e01beb4`, Hardwarebeleg `eae9a54` und Auswahl `ff23c3e` bleiben maßgeblich. |
| Ordnerzuordnung beim Umbenennen | `15da84a`, `b8affac` | Bereits enthalten | Nicht portieren; `Library.renameMeeting` und `MeetingFolderBatchTests.renamePreservesFolder` decken den aktuellen hierarchischen Stand ab. |
| Private Speicherung | `7c8a9e7` und `HANDOFF-pruefung-audio-private-storage.md` | Ausdrücklich zurückgestellt | Als eigene Architektur- und Migrationstask behandeln. |
| Electron-Chrome-Audio-Fallback | Fremder Arbeitsbaum unter `.worktrees/stenoai-chrome-audio-fallback` | Fremd, unvollständig und dirty | Unverändert erhalten; weder bereinigen noch in den Swift-Branch integrieren. |

### Belegte Risiken aus den Audits

- Die Job-Äquivalenz des alten iOS-Protokollpakets ignoriert Vorlage, Revision und Textmodell-Endpunkt.
- Der alte sichtbare Übertragungshinweis kann gegenüber den tatsächlich eingereihten Notizen und der gepinnten Revision veralten.
- Der alte Live-Feed ersetzt pro Kanal den Gesamtzustand und würde nach einer Aufnahmelücke bereits sichtbaren Text verlieren.
- Die Parakeet-Welle aktualisiert FluidAudio von `0.15.2` auf `0.15.5` und berührt damit zugleich die produktive Diarisierung.
- Der fremde Electron-Arbeitsbaum besitzt eine uncommittete Spec-Überarbeitung und einen ungetrackten `node_modules`-Symlink.

### Festgelegte Reihenfolge

1. Gemeinsame Sprecherpräsentation.
2. Den nachträglich entdeckten Snapshot `5c7f873` mit der jüngsten iOS-Diarisierung und der vollständigen AirDrop-Linie integrieren.
3. Erst nach der zusammengeführten Verifikation den Stereo-M4A-Kern und anschließend die Sidebar-adaptierte Exportoberfläche angehen.
4. Fehlende Notiz- und Annotationenhärtungen.
5. Transaktionale Review-Writes und fail-closed Recovery.
6. iPad-Befehle, Inspector und Sprecherreview.
7. iOS-Protokolle mit korrigierter Job-Äquivalenz und gepinntem Disclosure.
8. Live-Transkript-Feed auf Basis der aktuellen Lückensegmentierung.
9. Kleine unabhängige Werkzeug-, Modellstatus- und Dokumentationspakete passend zwischen den Wellen.
10. Tokenbudget, Providerdialekte und Ausgabelocale nach den dafür benötigten Provenienzgrundlagen.
11. Parakeet und der Live-ASR-Benchmark erst nach Diarisierungs-Rebaseline.
12. Kontextgestützte Transkriptkorrektur zuletzt als eigenes Produktpaket mit adversarialem Messgate.

### Task 3: Gemeinsame Sprecherpräsentation integrieren

**Files:**
- Add: `StenoKit/Sources/StenoPipeline/SpeakerPresentation.swift`
- Modify: `StenoKit/Sources/StenoPipeline/SpeakerSampleSelector.swift`
- Modify: `StenoKit/Sources/StenoPipeline/TemplateParticipantsBuilder.swift`
- Modify: `App/MeetingDetail.swift`
- Modify: `App/SpeakerReviewSheet.swift`
- Modify: `iOS/App/MeetingDetailView.swift`
- Modify: `iOS/App/SpeakerReviewSheet.swift`
- Delete: `iOS/App/SpeakerDisplay.swift`

**Interfaces:**
- Consumes: Sprecher-Cluster, Kanal, Laufkennung und optionale Identitaetszuordnung.
- Produces: Eine gemeinsame, SwiftUI-unabhaengige Sprecheranzeige und fail-closed Hoerprobenzuordnung fuer beide Apps.

- [x] **Step 1: Fehlenden gemeinsamen Resolver durch einen RED-Test belegen**

Der temporaere Integrationstest kompilierte erwartungsgemaess nicht, weil `SpeakerPresentationResolver` im aktuellen Stand fehlte.

- [x] **Step 2: Gemeinsamen Kern uebernehmen und fokussiert pruefen**

Der Quellcommit `331f57b` wurde als `5d177e2` uebernommen.
Alle neun `SpeakerPresentationTests` bestanden.

- [x] **Step 3: App-Aufrufer und kanalgetrennte Hoerproben integrieren**

Ein temporaerer RED-Test belegte, dass `SpeakerSampleSelector` zwei gleich benannte Cluster aus Mikrofon- und Systemkanal vor der Aenderung nicht zuordnen konnte.
Der Quellcommit `5c5f6ec` wurde als `d74bd92` uebernommen.
Danach bestanden acht `TemplateParticipantsBuilderTests` und fuenf `SpeakerSampleSelectorTests`.

- [x] **Step 4: Mehrdeutige Legacy-Proben fail-closed behandeln**

Ein temporaerer RED-Test belegte, dass eine kanalungebundene Legacy-Probe zuvor beiden gleich benannten Kanalclustern zugeordnet wurde.
Der Quellcommit `08f4595` wurde als `bf4490a` uebernommen.
Der fokussierte Ambiguitaetstest bestand danach.

- [x] **Step 5: UUID-Kontext und Laufprovenienz absichern**

Ein temporaerer RED-Test kompilierte erwartungsgemaess nicht, weil `SpeakerPresentationContext` und der kontextgebundene Resolver-Aufruf fehlten.
Der Quellcommit `b926e66` wurde als `b8e9472` uebernommen.
Danach bestanden zwoelf `SpeakerPresentationTests` und neun `SpeakerSampleSelectorTests`.

- [x] **Step 6: Vollstaendige Pflichtkette pruefen**

`xcodegen generate`, `scripts/build-app.sh`, `scripts/build-ios.sh` und `swift test --package-path StenoKit --disable-sandbox` waren erfolgreich.
Der abschliessende StenoKit-Lauf bestand 437 Tests in 73 Suites.
`git diff --check` war sauber und der Arbeitsbaum enthielt keine uncommitteten Dateien.

### Task 4: Jüngsten iOS-Diarisierungs- und AirDrop-Snapshot integrieren

Der zuerst nur nach Branches und registrierten Arbeitsbaeumen durchgefuehrte Audit hatte diese Linie nicht erfasst.
Sie lag ausschliesslich unter `refs/codex/snapshots/ebfb7264c24fa579a7760f9fb42f67c2d4aaf55e` und wurde deshalb vor jeder weiteren Integration als Branch `codex/ios-diarization-snapshot` bei `5c7f873` gesichert.

**Scope:**
- 60 zusammenhaengende Commits nach `6fbd28d`.
- Sichere `.stenomeeting`-Transfers und deren Mac-/iOS-Oberflaechen.
- iOS-Modellinstallation fuer Sprechertrennung.
- Explizite Sprechertrennung pro Meeting.
- Gezielter Retry ausschliesslich fuer fehlende Diarisierungsmodelle.

**Interfaces:**
- Consumes: Der auf Geraet und Simulator erprobte Snapshotstand sowie die bereits integrierten LM- und Sprechercommits.
- Produces: Eine gemeinsame aktuelle Linie, die AirDrop, iOS-Diarisierung, neue Sidebar, strikte LM-Antworten und gemeinsame Sprecherpraesentation erhaelt.

- [x] **Step 1: Snapshot unter einem normalen Branch sichern**

`codex/ios-diarization-snapshot` zeigt unveraendert auf `5c7f873` und besitzt einen sauberen isolierten Arbeitsbaum unter `.worktrees/ios-diarization-snapshot`.

- [x] **Step 2: Snapshotstand vor der Zusammenfuehrung frisch pruefen**

Run:

```bash
xcodegen generate
scripts/build-app.sh
scripts/build-ios.sh
swift test --package-path StenoKit --disable-sandbox
cd iOS/StenoiOSKit && xcodebuild -scheme StenoiOSKit \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
```

Expected: Beide Apps bauen, die vollstaendige Kernsuite und die iOS-Kit-Suite bestehen.

Der Snapshotstand baute auf macOS und iOS erfolgreich.
Die iOS-App-Suite bestand 112 Tests und die StenoiOSKit-Suite 26 Tests.
Der gemeinsame SwiftPM-Aufruf startete alle Tests, blieb danach jedoch ohne Abschlussausgabe aktiv.
Alle zehn StenoKit-Testtargets wurden deshalb einzeln ausgefuehrt und bestanden zusammen 673 Tests.
Der Quellarbeitsbaum blieb sauber.

- [x] **Step 3: Snapshot als zusammenhaengende Arbeitslinie mergen**

Run:

```bash
git merge --no-ff codex/ios-diarization-snapshot
```

Expected: Die gemeinsame Historie bleibt erhalten.
Die Voranalyse weist acht Konfliktflaechen aus: beide `AppModel`-Varianten, beide `MeetingDetailView`-Varianten, Mac-Review, gemeinsames Meeting-Review und Template-Teilnehmer sowie die auf iOS inzwischen gemeinsam zu nutzende Sprecheranzeige.

Der Merge wurde mit `git merge --no-ff codex/ios-diarization-snapshot` begonnen.
Git meldete Konflikte in Mac-Review, gemeinsamem Meeting-Review, iOS-AppModel, iOS-Meetingdetail und der zu entfernenden duplizierten iOS-Sprecheranzeige.

- [x] **Step 4: Konflikte gegen die aktuellen Invarianten aufloesen**

Die Snapshotfunktion fuer AirDrop und iOS-Diarisierung bleibt vollstaendig erhalten.
Die gemeinsame `SpeakerPresentationResolver`-Logik ersetzt die duplizierte iOS-`SpeakerDisplay`-Implementierung.
Die LM-Studio-Commits `736d321` und `6dc7339`, die Sidebar und die aktuelle Aufnahmeisolierung bleiben unveraendert wirksam.

Die Konflikte wurden so aufgeloest, dass iOS sowohl `MeetingDiarizationSnapshot.load` als auch den `SpeakerPresentationContext` verwendet.
Importierte Sprechertexte werden gemeinsam aufgeloest und als nicht lokal bestaetigte Herkunft gekennzeichnet.
Mehrpersonencluster, kanalmehrdeutige Hoerproben und nicht als UUID validierte Namensraeume behandeln die zusammengefuehrten Pfade fail-closed.
Die fokussierten Sprecher- und Meeting-Praesentationstests bestanden auf macOS, iOS und StenoKit.

- [x] **Step 5: Zusammengefuehrten Stand vollstaendig pruefen**

Run:

```bash
xcodegen generate
scripts/build-app.sh
scripts/build-ios.sh
swift test --package-path StenoKit --disable-sandbox
cd iOS/StenoiOSKit && xcodebuild -scheme StenoiOSKit \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
git diff --check
```

Expected: Beide Apps bauen, alle Kern- und iOS-Kit-Tests bestehen und der Diff-Check ist sauber.

`xcodegen generate`, `scripts/build-app.sh` und `scripts/build-ios.sh` waren erfolgreich.
Die vollstaendigen macOS-App-, iOS-App- und StenoiOSKit-Suiten bestanden.
Der gemeinsame SwiftPM-Aufruf reproduzierte den bereits am Quellstand beobachteten Runner-Haenger nach umfangreicher erfolgreicher Testausgabe.
Alle zehn StenoKit-Testtargets bestanden einzeln zusammen 696 Tests, darunter 210 Pipeline-Tests.
`git diff --check` und `git diff --cached --check` waren sauber.

- [x] **Step 6: Zusammenfuehrung unabhaengig pruefen lassen**

Der Review kontrolliert insbesondere Aufnahmeunabhaengigkeit, explizite Modellzustimmung, fehlermodellspezifischen Retry, Meeting-Pinning, Importprovenienz und die neue gemeinsame Sprecheranzeige.

Der erste Review fand keine Critical- oder High-Befunde und bestaetigte, dass keine Funktion einer Konfliktseite verloren ging.
Zwei Medium-Befunde wurden testgetrieben korrigiert: Mehrpersonencluster werden aus Protokollteilnehmern ausgeschlossen und iOS zeigt die Herkunft importierter Sprechernamen.
Die gezielte Re-Review bestaetigte beide Befunde als adressiert und fand keine neue Critical-, High- oder Medium-Breakage.

### Task 5: Konsolidierungsstand sichern

**Files:**
- Modify: `docs/superpowers/plans/2026-08-18-arbeitsbaum-konsolidierung.md`

**Interfaces:**
- Consumes: Verifizierten Integrationsstand und abgeschlossene Integrationsmatrix.
- Produces: Lokale, nachvollziehbare Git-Historie ohne Push oder Arbeitsbaumverlust.

- [x] **Step 1: Arbeitsbaum und gestagete Dateien prüfen**

Run:

```bash
git status --short
git diff --check
git diff --cached --check
```

Expected: Nur task-eigene Änderungen sind gestaget; fremde ungetrackte Dateien bleiben ungestaget.

Der Arbeitsbaum enthielt keine ungestageten oder ungetrackten Dateien.
Es gab keine unaufgeloesten Pfade oder Konfliktmarker.
Beide Diff-Checks waren sauber.

- [x] **Step 2: Plan und Integrationsmatrix committen**

Run:

```bash
git add docs/superpowers/plans/2026-08-18-arbeitsbaum-konsolidierung.md
git commit -m "docs: plan worktree consolidation"
```

Expected: Der Commit enthält ausschließlich den Konsolidierungsplan.

Der initiale Plan wurde als `484845b` und die Auditfortschreibung als `9b94eac` gesichert.
Die nachtraeglich entdeckte iOS-Snapshotprioritaet wurde als `ea79450` dokumentiert.

- [x] **Step 3: Arbeitsbäume erhalten**

Es wird kein Arbeitsbaum entfernt und kein Branch gelöscht, bis seine fachlichen Änderungen integriert, frisch geprüft und zur lokalen Zusammenführung bestimmt wurden.

Alle Quellarbeitsbaeume, Branches und Snapshot-Refs blieben fuer den abschliessenden Audit erhalten.
