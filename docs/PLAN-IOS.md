# Steno für iPhone und iPad - Produkt- und Umsetzungsplan

Stand: 2026-08-07.
Verfasser: Claude (Fable 5), Architektur-Session in `~/Dev/Repositorys/steno-ios`.
Dieses Dokument baut auf `HANDOFF.md` (Machbarkeitsanalyse vom 07.08.) auf und ersetzt dessen Empfehlungen dort, wo diese Session besseres Wissen hat.
Kennzeichnung im Text: **[Fakt]** ist in dieser Session lokal geprüft (Datei, Zeile oder Kommando genannt), **[Sekundärquelle]** stammt aus dem Netz und ist nicht an Apples Dokumentation verifiziert, **[Annahme]** ist plausibel aber ungemessen, **[Empfehlung]** ist eine Entscheidung dieses Entwurfs.
Werkzeugstand: Xcode 26.6, iOS-SDK 26.5, Simulator-Runtime 26.5, kein iOS-27-SDK installiert. **[Fakt]** (`xcrun --sdk iphoneos --show-sdk-path` liefert `iPhoneOS26.5.sdk`)

## 1. Produktentscheidung

### Entscheidung: Variante B, zugeschnitten als Raumaufnahme-Station, mit dem iPad als Leitgerät

Das Handoff empfiehlt Variante A (Begleiter zum Mac) und nennt als deren Preis die Bibliothekssynchronisation.
Dieser Plan dreht die Empfehlung um, aus drei Gründen:

1. **Variante A ist auf absehbare Zeit gar nicht baubar.**
   Der Begleiter braucht Synchronisation, und `ARCHITECTURE.md` Abschnitt 8 schliesst iCloud-Synchronisation aus, bis Verschlüsselung und Wiederherstellung zuverlässig funktionieren (macOS-Meilenstein 7 ist noch offen, `docs/FEATURE-PARITY.md`: "Bibliotheksverschlüsselung als Beta" unerledigt). **[Fakt]**
   Ein Begleiter ohne Synchronisation wäre ein Diktiergerät mit manueller Dateiübergabe, also ohnehin eine eigenständige App mit Exportknopf.
2. **Die eigenständige App ist technisch belegt.**
   Alle acht portablen StenoKit-Targets bauen und testen auf iOS 26 mit 263 grünen Tests, inklusive Diarisierung, Identität und Pipeline (`HANDOFF.md`, Abschnitt "Was in dieser Session belegt wurde"). **[Fakt]**
3. **Das stärkste Argument des Handoffs für A ist inzwischen schwächer.**
   Das Handoff nannte die Hintergrundverarbeitung als stärkstes A-Argument, kannte aber `BGContinuedProcessingTask` nicht: nutzergestartete Läufe dürfen seit iOS 26 mit sichtbarem Systemfortschritt im Hintergrund weiterlaufen, samt optionaler GPU-Nutzung.
   Die API ist im lokalen iOS-26.5-SDK vorhanden. **[Fakt]** (`grep -rl BGContinuedProcessingTask .../BackgroundTasks.framework/Headers/` trifft `BGTask.h`, `BGTaskRequest.h`, `BGTaskScheduler.h`)
   Das ist genau der Steno-Fall: der Benutzer drückt Stop, die Nachverarbeitung läuft als sein Auftrag weiter, auch wenn er die App wechselt.

**Das iPad verändert die Rechnung, und zwar zugunsten von B.**
Ein iPad liegt bei einer Präsenzbesprechung ohnehin auf dem Tisch, bleibt im Vordergrund, hat mehr RAM und bessere Thermik als ein iPhone **[Annahme]** (plausibel über die Gerätepalette, aber auf keinem konkreten Zielgerät gemessen), und iPadOS 26 bringt Menüleiste und fensterbasiertes Multitasking mit. **[Sekundärquelle]**
Das gestufte Produkt ist deshalb keine dritte Variante, sondern die natürliche Form von B: **eine universelle App, in der das iPhone der Rekorder mit Live-Transkript ist und das iPad die vollwertige Station mit Review, Personen und Vorlagen.**
Die Stufung ist Capability-Gating in einer Codebasis, kein zweites Produkt: auf dem iPhone sind dieselben Funktionen vorhanden, nur ist die Erwartung an lange Läufe und paralleles Arbeiten dort niedriger.
Der Mac bleibt das Gerät für Anrufmitschnitte (Systemaudio), Altimport und Benchmarks; die Geräte tauschen zunächst einzelne Meetings über Export und Import aus, wobei unveränderte Ursprungs-Meeting-ID plus kanonischer Inhaltsdigest einen No-op und derselbe Ursprung mit anderem Digest einen Konflikt ergeben, nicht über einen Sync-Dienst (Meilenstein i5).

### Kippkriterien, die die Entscheidung umdrehen

Zurück zu Variante A (iPhone nur Rekorder, Station nur Mac/iPad) kippt die Entscheidung, wenn eine der Messaufgaben aus Abschnitt 6 scheitert:

- Finallauf plus Diarisierung einer 60-Minuten-Aufnahme überlebt das Speicherlimit des Ziel-iPhones auch sequenziell nicht (Messaufgabe R1).
- Eine Stunde Aufnahme mit Live-ASR drosselt thermisch oder entleert den Akku unvertretbar (R3).
- Die einspurige Diarisierung liefert auf echten Raumaufnahmen unbrauchbare Cluster (R5).

Komplett zurück auf "iOS nur als Zubringer" kippt es, wenn der dominante Anwendungsfall Anrufmitschnitt bleibt, denn den kann iOS prinzipiell nicht (Abschnitt 7).
Umgekehrt kippt "Export statt Sync" zu echter Synchronisation erst, wenn die macOS-Verschlüsselung (M7) steht; das ist eine Reihenfolge-, keine Architekturfrage.

## 2. iPhone und iPad: ein Katalog, adaptives Layout

### 2.1 Entscheidung: eine Codebasis, ein App-Target, kein zweiter UI-Zweig

**[Empfehlung]** Es wird genau ein SwiftUI-App-Target für iPhone und iPad gebaut (XcodeGen `supportedDestinations: [iOS, iPadOS]`), mit adaptivem Layout über `NavigationSplitView` und Size Classes, ohne getrenntes iPad-Target und ohne geteiltes UI-Paket mit macOS.
Begründung statt Optionenliste:

- Die macOS-App zeigt, dass die View-Schicht dünn über `MeetingReviewController` und `StenoPipeline` sitzt; die teure Logik liegt in StenoKit und wird ohnehin geteilt.
- `NavigationSplitView` degradiert in kompakter Breite von selbst zum Stack; iPhone- und iPad-Verhalten sind damit zwei Zustände derselben Hierarchie, kein zweiter Baum. **[Fakt]** (API im iOS-26.5-SwiftUI-Interface vorhanden, 172 Treffer im `swiftinterface`)
- Zwei Zweige würden jede der schnellen UI-Iterationen des Projekts (vgl. `docs/UX-REVIEW.md`, Stufenpläne) doppelt kosten.
- Ein geteiltes UI-Paket mit macOS wäre genau die spekulative Abstraktion, vor der schon das Mac-Handoff warnt; Struktur und Wortlaut werden kopiert, nicht geteilt, und dürfen divergieren.

Die wenigen echten Weichen (Aufnahme-Vollbild auf dem iPhone gegen Aufnahme-Streifen auf dem iPad) laufen über `horizontalSizeClass`, nicht über Gerätetyp-Abfragen, damit Stage-Manager-Fenster in schmaler Breite korrekt sind.

### 2.2 Navigations- und Layoutmodell

- **Grundgerüst**: `NavigationSplitView` mit Meetingliste als Sidebar und Meeting-Detail als Detail, wie `ContentView.swift:10` auf dem Mac. **[Fakt]** (Datei gelesen)
- **Inspector**: Die Sprecher-, Teilnehmer- und Notizen-Arbeit steckt auf dem Mac in `.inspector` (`MeetingDetailView.swift:53`). **[Fakt]**
  `.inspector` existiert im iOS-26.5-SDK. **[Fakt]** (3 Treffer `func inspector` im SwiftUI-`swiftinterface`)
  Auf dem iPad erscheint er als Seitenspalte, auf dem iPhone als Sheet; das Sheet-Verhalten ist genau richtig für "kurz Sprecher bestätigen". **[Annahme]** (Darstellungsform aus der API-Semantik geschlossen, am Gerät zu verifizieren, Meilenstein i1/i3)
- **Multitasking und Stage Manager**: keine `UIRequiresFullScreen`-Deklaration, alle Fenstergrössen zulassen, Layout muss ab ~320 pt Breite funktionieren.
  Die Aufnahme gehört einem prozessweiten `@Observable`-AppModel, nicht einer Szene: zwei iPad-Fenster derselben App müssen denselben Aufnahmezustand zeigen, und ein geschlossenes Fenster darf die Aufnahme nicht beenden.
- **Fensterrestaurierung**: `@SceneStorage` für das ausgewählte Meeting je Szene; die Bibliothek selbst ist zustandslos restaurierbar, weil alles auf Platte liegt (Startsequenz aus `PipelineStartup`).
- **Menüleiste iPad**: Die `.commands`-Definitionen aus `StenoApp.swift:19-66` (Aufnahme starten/stoppen, Cmd-Punkt statt Cmd-R, "Mark This Moment" Cmd-M, New Meeting, Import) werden übernommen; auf iPadOS speisen sie Menüleiste und Tastatur. **[Fakt]** (Datei gelesen; die bewusste Cmd-R-Vermeidung samt Begründungskommentar bleibt erhalten)

### 2.3 Übernahme der macOS-Views

Der Modul-Audit des Handoffs (AppKit nur in drei Dateien) wurde nachgeprüft und um eine Datei korrigiert: `import AppKit` steht in `AppModel+Export.swift` und `ReportsSection.swift`, dazu nutzt `Theme.swift` `Color(nsColor:)` und `StenoApp.swift` die macOS-Szenen `Settings` und `Window`. **[Fakt]** (`grep -rn "import AppKit\|NSSavePanel\|NSPasteboard\|nsColor" App/Sources/`)

| macOS-Datei | iPad | iPhone | Aufwand |
|---|---|---|---|
| `ContentView.swift` (SplitView, Meldungsleiste, fileImporter, dropDestination) | sinngemäss übernehmen | übernehmen, Toolbar kompakter | klein |
| `MeetingDetailView.swift` (Transkript, Find-Bar, Inspector, Jobstatus) | übernehmen | übernehmen, Inspector wird Sheet | klein |
| `SpeakerReviewSection.swift`, `ParticipantsSection.swift`, `NotesSection.swift` | übernehmen | übernehmen, Touch-Ziele prüfen | klein |
| `ReportsSection.swift` | übernehmen, `NSPasteboard` wird `UIPasteboard`, Kopieren zusätzlich als `ShareLink` | dito | klein |
| `PeopleSettingsView.swift`, `TextModelSettingsView.swift`, `SettingsView.swift` | übernehmen, aber als navigierbare Einstellungs-Ansicht statt `Settings`-Szene (die es auf iOS nicht gibt) | dito | mittel |
| `AppModel.swift` und Extensions ausser Export | weitgehend übernehmen (kein AppKit darin **[Fakt]**, s. o.) | dito | klein |
| `AppModel+Export.swift` (`NSSavePanel`) | Neubau über `.fileExporter` und `ShareLink` **[Fakt]** (beide im iOS-26.5-`swiftinterface`, 15 Treffer je) | dito | mittel |
| `RecordingView.swift`, `RecordingStrip.swift` | Streifen-Muster übernehmen (Aufnahme ist Zustand, kein Modus) | **Neubau**: Aufnahme ist auf dem iPhone der Hauptbildschirm mit grossen Zielen, Pegel, Unterbrechungszustand | gross |
| `StenoApp.swift` | Neubau der Szenenstruktur (WindowGroup, Commands; keine `Settings`-, keine zweite `Window`-Szene) | dito | mittel |
| `LegacyImportView.swift` | entfällt: der Steno-Altimport bleibt Mac-Aufgabe, Altbestand erreicht iOS später über die Gerätebrücke (i5) | entfällt | null |
| `Theme.swift` | übernehmen, `Color(nsColor:)` wird `Color(uiColor:)`; Petrol-Akzent und Sprecherpalette aus `docs/UX-REVIEW.md` Abschnitt 2 gelten unverändert | dito | klein |

Neu zu denken (nicht nur zu portieren) sind drei Dinge:

1. Der **Aufnahmebildschirm des iPhones**: einhändig, Blickzeit unter drei Sekunden, die Regeln aus dem UX-Review-Nachtrag ("Was während einer laufenden Aufnahme zählt") gelten verschärft, weil das iPhone im Meeting gesperrt auf dem Tisch liegt.
2. Die **Unterbrechungs-UI**: eingehender Anruf, Siri, Routenwechsel; der Mac kennt diese Zustände nicht, `RecordingSessionState` bekommt dafür eine sichtbare Entsprechung ("unterbrochen durch Anruf, Aufnahme bis 00:41:23 gesichert").
3. Der **Jobstatus im Hintergrund**: auf dem Mac läuft die Pipeline einfach; auf iOS gehört der `BGContinuedProcessingTask`-Fortschritt mit dem app-eigenen Jobstatus (`jobStatusBar`) zusammengeführt.

### 2.4 iPad-spezifische Eingaben

- **Hardware-Tastatur**: `keyboardShortcut` ist auf iOS vorhanden. **[Fakt]** (7 Treffer im `swiftinterface`)
  Übernommen werden die Mac-Belegungen (Cmd-Punkt Stop, Cmd-M Marker, Cmd-F Transkriptsuche, Cmd-N neues Meeting); die Review-Tastatursteuerung (Leertaste Hörprobe, Return bestätigen) wird mit dem iPad-Inspector zusammen gebaut.
- **Zeigergerät**: Standardverhalten plus `hoverEffect` an interaktiven Elementen. **[Fakt]** (18 Treffer)
  `pointerStyle` existiert auf iOS nicht (0 Treffer) **[Fakt]**, also keine Mac-artigen Cursorformen einplanen.
- **Apple Pencil: begründet verworfen.** **[Empfehlung]**
  Steno hat keine Zeichen- oder Markup-Fläche; die einzigen Stift-Anwendungen wären Handschriftnotizen (Scribble erledigt das systemseitig in jedem Textfeld, kostenlos) und Transkript-Markup (nicht im Produkt, und `TranscriptRevision` hat dafür kein Modell).
  Ein Pencil-Feature ohne Datenmodell dahinter wäre Demoware.
- **Externe Mikrofone über USB-C**: `AVAudioEngine.inputNode` folgt der aktiven `AVAudioSession`-Route, ein USB-Interface wird damit ohne Sondercode zur Quelle; das Gegenstück zu `MicRecorder.prepare()` (nativer Formatabgriff, `MicRecorder.swift:14-24` **[Fakt]**) bleibt formatneutral.
  Für die Geräteauswahl gibt es `AVInputPickerInteraction` im iOS-26.5-SDK. **[Fakt]** (`AVKit.framework/Headers/AVInputPickerInteraction.h`)
  Routenwechsel während der Aufnahme (Interface gezogen) ist ein Pflicht-Testfall in Meilenstein i3, kein Nice-to-have: er beendet die Spur sauber oder setzt sie auf dem internen Mikrofon fort, aber niemals still mit falschem Format. **[Empfehlung]**

### 2.5 Dateien-App, Drag-and-Drop, Export

- **[Empfehlung]** Die Bibliothek liegt unter `Documents/StenoLibrary` und ist mit `UIFileSharingEnabled` plus `LSSupportsOpeningDocumentsInPlace` in der Dateien-App sichtbar.
  Das folgt der Handoff-Begründung (Originale schützen heisst auch: Der Nutzer bekommt sie ohne die App heraus) und macht die Gerätebrücke (i5) trivial.
  Der Preis ist benannt: die Dateien-App kann die Bibliothek auch beschädigen.
  Das fängt die vorhandene Schutzschicht ab, nicht neuer Code: `Library`-Validierung, Schema-Versionen, Corrupt-Quarantäne (`ARCHITECTURE.md` Abschnitt 7) melden Manipulation, statt zu raten.
- Die unverschluesselte Bibliothek unter `Documents/StenoLibrary` und der benachbarte private Validation-Root fuer Klartext-Snapshots und gestagte Transferdaten werden bis zu einer spaeteren Bibliotheksverschluesselung mit geprueftem `isExcludedFromBackupKey` aus dem iCloud-Geraetebackup ausgeschlossen.
  Dieser Ausschluss vermeidet eine unverschluesselte Cloud-Kopie, bedeutet aber ein ausdrueckliches lokales Verlustrisiko, wenn das Geraet verloren geht oder ausfaellt und keine bewusst gesicherte Kopie existiert.
  Steno verwendet dafuer weder einen iCloud-Container noch ubiquitaere Dokumente oder CloudKit.
  Die von FluidAudio nachgeladenen CoreML-Modelle bleiben ebenfalls im Container (nicht in Documents) und werden mit `isExcludedFromBackupKey` vom Backup ausgenommen.
  `FluidSortformerProvider` hat dafür bereits den Haken `modelCacheDirectory`. **[Fakt]** (`FluidSortformerProvider.swift:83-84`)
- Import per Drag-and-Drop und `fileImporter` funktioniert API-gleich zum Mac (`ContentView.swift:68-81` **[Fakt]**).
  Der Export eines einzelnen Meetings erzeugt eine regulaere, unkomprimierte und unverschluesselte `.stenomeeting`-AppleArchive-Datei fuer die Systemfreigabe.
  Audio ist standardmaessig ausgeschaltet und wird nur nach einer ausdruecklichen lokalen Entscheidung fuer genau diesen Transfer aufgenommen.
  Die Oberflaeche fordert zur Auswahl von AirDrop auf, aber die Systemfreigabe kann technisch auch andere Ziele anbieten und garantiert keinen ausschliesslich auf AirDrop begrenzten Transport.

## 3. Die iOS-27-Frage

### 3.1 Faktenlage

Recherchestand dieser Session (WebSearch/WebFetch am 07.08.2026):

- iOS 27 ist seit Juni 2026 in der Beta, Freigabe wird für September 2026 erwartet. **[Sekundärquelle]** (MacRumors, 9to5Mac)
- Apples eigene Release-Notes-Seite liefert weiterhin keinen lesbaren Inhalt (WebFetch auf `developer.apple.com/documentation/ios-ipados-release-notes`: nur Titel, kein Text). **[Fakt]** (im Sinne von: der Fetch wurde in dieser Session ausgeführt und blieb leer; derselbe Befund wie im Handoff)
- Lesbar war dagegen die WWDC26-Session 241 "What's new in the Foundation Models framework" auf `developer.apple.com`. **[Sekundärquelle]** (Apple-Seite, aber Transkript-Auszug, nicht gegen SDK-Header verifizierbar, solange kein 27er-SDK installiert ist)
- **Zu Audioaufnahme und Speech wurde erneut keine einzige iOS-27-Neuerung gefunden**, weder in Apple-Sessionlisten noch in Dritt-Roundups; die aufnahmerelevanten Neuerungen (Input-Picker, AirPods-Studioqualität, Spatial-Capture) stammen alle aus WWDC25 und sind iOS-26-APIs.
  Das deckt sich mit dem Handoff-Befund und wird hier bewusst als "nicht belegbar" stehen gelassen statt spekulativ gefüllt.
- Ebenso wurde kein Hinweis auf eine Systemaudio- oder Anrufmitschnitt-API für Dritt-Apps in iOS 27 gefunden; die Suchlage bestätigt im Gegenteil, dass es sie bis heute nicht gibt. **[Sekundärquelle]**

### 3.2 Einordnung jedes Plan-Features in drei Klassen

**(a) Geht heute auf iOS 26** (lokal belegt):

| Feature | Beleg |
|---|---|
| Mikrofonaufnahme, Berechtigung, Unterbrechung | **[Fakt]** `AVAudioApplication.h`, `AVAudioSession.h` im 26.5-SDK |
| Live- und Final-ASR über SpeechAnalyzer | **[Fakt]** `SpeechTranscriber`/`DictationTranscriber`/`SpeechDetector` im Speech-`swiftinterface` (56 bzw. 9 Treffer) |
| Diarisierung, Identität, Pipeline, Bibliothek | **[Fakt]** 263 grüne Tests auf iOS 26.5 (`HANDOFF.md`) |
| Hintergrund-Aufnahme (`UIBackgroundModes: audio`) | **[Sekundärquelle]** Standard-API, am Gerät in i1 zu verifizieren |
| Nutzergestartete Nachverarbeitung im Hintergrund | **[Fakt]** `BGContinuedProcessingTask` im 26.5-SDK, siehe Abschnitt 1 |
| On-Device-Vorlagen (Foundation Models, Text) | **[Fakt]** Framework im 26.5-SDK, inkl. `contextSize`/`tokenCount` (6 Treffer im `swiftinterface`) |
| Dateien-App, fileExporter, ShareLink, Drag-and-Drop | **[Fakt]** SwiftUI-`swiftinterface` 26.5 |
| SplitView, Inspector, Tastaturkürzel, hoverEffect | **[Fakt]** SwiftUI-`swiftinterface` 26.5 |
| Eingabegeräte-Picker | **[Fakt]** `AVInputPickerInteraction.h` im 26.5-SDK |

**(b) Geht heute, wird mit 27 besser:**

- **Vorlagen über lange Transkripte.**
  Heute: On-Device-Modell mit 8k-Kontext, der Mac-Code löst das per Map-Reduce über Turn-Grenzen (FEATURE-PARITY, "Zusammenfassung on-device"). **[Fakt]** (Kontextgrösse per `contextSize`-API abfragbar; der konkrete Wert 8k ist **[Sekundärquelle]**)
  iOS 27: `PrivateCloudComputeLanguageModel` mit 32k-Kontext, Reasoning, ohne API-Schlüssel, plus Bildeingabe und `DynamicProfile`. **[Sekundärquelle]** (WWDC26-Session 241)
  Im 26.5-SDK ist `PrivateCloudComputeLanguageModel` nicht vorhanden. **[Fakt]** (0 Treffer im FoundationModels-`swiftinterface`)
  Einordnung: PCC ist ein Cloud-Dienst und fällt unter dieselbe Regel wie externe LLM-Provider (nie automatisch, Hinweis vor Übertragung, `docs/PLAN-PRIVACY.md`); es wird ein optionaler Provider hinter `TextModelProvider`, kein Fundament.
- **Modell-Abstraktion**: das angekündigte `LanguageModel`-Protokoll samt Anthropic/Google-Paketen **[Sekundärquelle]** könnte den eigenen `OpenAICompatibleProvider` langfristig ergänzen; heute besteht kein Handlungsbedarf, die eigene Provider-Grenze existiert bereits.
- **SwiftUI-Komfort**: schnellere Dokument-APIs, lazy Subviews. **[Sekundärquelle]** Kein Feature des Plans hängt daran.
- **Build-Pflichten des 27er-SDKs** (UIScene-Lebenszyklus, Pflicht-Launch-Screen, Liquid Glass ohne Opt-out) sind für eine neu angelegte SwiftUI-App folgenlos, weil sie sie ab Tag eins erfüllt. **[Sekundärquelle]**

**(c) Geht erst mit 27 oder gar nicht**, je mit Prüfkommando für den Tag der Xcode-27-Installation:

| Feature | Status | Prüfung mit Xcode 27 |
|---|---|---|
| Systemaudio-/Anrufmitschnitt für Dritt-Apps | **gar nicht**, auch für 27 kein Hinweis; in 26.5 fehlen `CATapDescription`/`AudioHardwareCreateProcessTap` in den iOS-CoreAudio-Headern **[Fakt]** (grep in dieser Session wiederholt, "nicht vorhanden") | `grep -rl "CATapDescription\|AudioHardwareCreateProcessTap" "$(xcrun --sdk iphoneos --show-sdk-path)/System/Library/Frameworks/CoreAudio.framework/Headers/"` - bleibt der Treffer leer, bleibt die Antwort nein |
| PCC-Servermodell für Vorlagen | erst 27 **[Fakt]** (0 Treffer in 26.5, s. o.) | `grep -c PrivateCloudComputeLanguageModel .../FoundationModels.swiftmodule/arm64e-apple-ios.swiftinterface` grösser 0, dann als optionaler Provider hinter `@available(iOS 27, *)` |
| Bildeingabe an das On-Device-Modell (PDF-Seiten oder Whiteboard-Fotos als Meeting-Kontext) | erst 27 **[Sekundärquelle]** | im 27er-`swiftinterface` nach dem `Attachment`-Prompt-Baustein suchen; Produktfrage danach: fällt unter die PDF-Grenze aus PLAN-PRIVACY (on-device wäre sie einhaltbar) |
| Verschiebbare Listen per `reorderable()` (Ordner-Sortierung ohne Kontextmenü) | erst 27; die zwei `reorderable`-Treffer im 26.5-Interface sind Tab-/Toolbar-Customization, nicht die Container-API **[Fakt]** | `grep -n "func reorderable" .../SwiftUI.swiftmodule/*.swiftinterface` |
| Audio-/Speech-Neuerungen in 27 | **nicht belegbar**, keine Quelle gefunden | `diff` der `AVFAudio`- und `Speech`-`swiftinterface`-Dateien zwischen 26.5- und 27-SDK, plus der StenoKit-Testlauf `xcodebuild test -scheme StenoKit-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=27.0'` |

### 3.3 Antwort auf die Deployment-Target-Frage

**Das Deployment Target bleibt iOS 26.0.** **[Empfehlung]**
Kein Feature des Kernprodukts (Aufnahme, ASR, Diarisierung, Identität, Bibliothek, Export, On-Device-Vorlagen) braucht iOS 27; alles ist auf 26 lokal belegt.
Die einzigen belegten 27er-Gewinne (PCC-Modell, Bildeingabe, `reorderable()`) sind optionale Verbesserungen, die sauber hinter `@available(iOS 27, *)` nachrüstbar sind, sobald Xcode 27 installiert und die Prüftabelle oben abgearbeitet ist.
Ein Target-Sprung auf 27 würde nur den Gerätekreis verkleinern, ohne ein einziges Pflichtfeature zu kaufen.

## 4. Architektur und Module

### 4.1 Unverändert genutzte StenoKit-Targets

`StenoDomain`, `StenoLibrary`, `StenoTranscription`, `StenoDiarization`, `StenoIdentity`, `StenoIntelligence`, `StenoExchange` (nur der generische Teil, kein Altimport-UI), `StenoPipeline`: alle acht unverändert, mit belegtem iOS-Bau und grünen Tests. **[Fakt]** (`HANDOFF.md`; Quellstruktur in dieser Session per `ls StenoKit/Sources/*` nachvollzogen)
Nicht genutzt auf iOS: `StenoMacAudio` (CoreAudio Process Tap) und die drei CLI-Executables.

### 4.2 Neue Teile

- **`StenoiOSKit`**: ein neues lokales SwiftPM-Paket im `steno-ios`-Verzeichnis (nicht in `steno-macos`), damit kein weiterer Eingriff in fremden Arbeitsbaum nötig ist.
  Es enthält zunächst genau ein Target:
- **`StenoiOSAudio`**: `AVAudioSession`-Konfiguration (Kategorie `.playAndRecord` wegen der Hörproben-Wiedergabe im Review, Modusfrage siehe Messaufgabe R4), `AVAudioApplication.requestRecordPermission`, ein `MicRecorder`-Gegenstück auf `AVAudioEngine`-Basis, Unterbrechungs- und Routenwechselbehandlung (`AVAudioSession.interruptionNotification`, `routeChangeNotification`), und eine **einspurige Aufnahmesession**, weil `RecordingSession` heute per `precondition` genau die zwei Quellen Mikrofon und System verlangt (`RecordingSession.swift:90-92`). **[Fakt]** (Datei gelesen)
- **Woher kommen Writer, Pegel, Recovery**: die portablen 500 Zeilen aus `StenoMacAudio` (`TrackWriter`, `AudioLevelMeter`, `AudioBufferTransfer`, `CaptureRecovery`, `DiskSpaceChecker`, `AudioErrors`, `AudioSource`) sind iOS-tauglich, liegen aber im macOS-only-Target.
  **[Empfehlung]** Die saubere Lösung ist die Handoff-Idee `StenoAudioCore`: ein gemeinsames Target in StenoKit mit diesen Dateien plus einer `RecordingSession` mit variabler Quellenliste; `StenoMacAudio` und `StenoiOSAudio` setzen darauf auf.
  Das ist Freigabeschritt F2 (Eingriff in `steno-macos`).
  Ohne diese Freigabe baut Meilenstein i1 ersatzweise einen schlanken eigenen Writer und Pegelmesser in `StenoiOSAudio` (~250 Zeilen) mit dem erklärten Ziel, sie nach F2 wieder zu löschen; diese bewusst befristete Doppelung ist der einzige zulässige Verstoss gegen "nichts kopieren".
- **SwiftUI-App-Target `Steno-iOS`** nach Abschnitt 2, plus `project.yml` (unten).

### 4.3 Einbindung von StenoKit, project.yml, Info.plist

**StenoKit-Bezug**: wie im Handoff, Pfadabhängigkeit auf `../steno-macos/StenoKit` für die Prototyp-Phase, mit der Endform "StenoKit wird eigenes Repository" (Freigabeschritt F3), sobald der erste Schnitt steht.
Kopieren bleibt ausgeschlossen (Abschnitt 7).
Vorbedingung F1: `Package.swift` von StenoKit braucht `platforms: [.macOS(.v26), .iOS(.v26)]`; heute steht dort nur macOS. **[Fakt]** (`StenoKit/Package.swift:11-13`)

**Nachtrag vom 07.08.2026, korrigiert Handoff und die Zeile darüber.**
Die Aussage "diese eine Zeile genügt" stimmt nur für die App, nicht für das Paket.
Der Bautest des Handoffs hatte `StenoMacAudio` aus der Kopie entfernt und konnte den Unterschied deshalb nicht sehen.
In einer Kopie mit unverändert vorhandenem `StenoMacAudio` gemessen **[Fakt]** (Scratchpad-Kopie, `steno-macos` nicht angefasst):

- `xcodebuild build -scheme StenoKit-Package -destination 'generic/platform=iOS Simulator'` schlägt fehl: `SystemAudioRecorder.swift` findet `AudioObjectID`, `CATapDescription` und die übrigen CoreAudio-Symbole auf iOS nicht.
- `xcodebuild build -scheme StenoPipeline` beziehungsweise `StenoExchange` und `StenoIdentity` auf demselben Ziel liefern jeweils `** BUILD SUCCEEDED **`.

Konsequenz: F1 genügt für das iOS-App-Target, weil dieses nur die acht portablen Produkte linkt und `StenoMacAudio` dabei nie gebaut wird.
Für einen iOS-Testlauf des Gesamtpakets genügt F1 **nicht**; dafür müssten die macOS-only Quellen in `StenoMacAudio` zusätzlich hinter `#if os(macOS)` liegen.
F2 löst das nebenbei mit, weil es die Dateien ohnehin neu aufteilt.
Der iOS-Testlauf des Kerns bleibt bis dahin auf die Schema-Ebene beschränkt, nicht auf `StenoKit-Package`.

`project.yml`-Skizze (XcodeGen, analog `steno-macos/project.yml` **[Fakt]**, gelesen):

```yaml
name: StenoiOS
options:
  bundleIdPrefix: org.steno
  deploymentTarget:
    iOS: "26.0"
packages:
  StenoKit:
    path: ../steno-macos/StenoKit   # F3: wird Repository-Abhaengigkeit
  StenoiOSKit:
    path: StenoiOSKit
targets:
  Steno-iOS:
    type: application
    platform: iOS
    supportedDestinations: [iOS, iPadOS]
    sources: [App/Sources, App/Resources]
    dependencies:
      - package: StenoKit
        product: [StenoDomain, StenoLibrary, StenoTranscription,
                  StenoDiarization, StenoIdentity, StenoIntelligence,
                  StenoExchange, StenoPipeline]
      - package: StenoiOSKit
        product: StenoiOSAudio
    settings:
      base:
        SWIFT_VERSION: "6.0"
        SWIFT_STRICT_CONCURRENCY: complete
        TARGETED_DEVICE_FAMILY: "1,2"
```

(Die Listen-Schreibweise bei `product` ist Pseudocode zur Lesbarkeit; XcodeGen verlangt je Produkt einen Eintrag. **[Fakt]** im Sinne der gelesenen `project.yml`-Syntax des Mac-Projekts.)

Info.plist-Schlüssel und Betriebsarten:

- `NSMicrophoneUsageDescription`: sinngemäss übersetzt "auf diesem iPhone/iPad".
- `NSAudioCaptureUsageDescription`: entfällt ersatzlos (macOS-Schlüssel).
- `UIBackgroundModes: [audio]` für die Aufnahme; **kein** `processing`-Eintrag im ersten Schnitt, weil die Nachverarbeitung nutzergestartet über `BGContinuedProcessingTask` läuft und dessen Task-Kennung stattdessen unter `BGTaskSchedulerPermittedIdentifiers` deklariert wird. **[Sekundärquelle]** (API-Vertrag laut Apple-Doku-Treffern; die genaue Plist-Pflicht ist mit dem ersten i2-Build am Gerät zu verifizieren)
- `UIFileSharingEnabled: true`, `LSSupportsOpeningDocumentsInPlace: true` (Abschnitt 2.5).
- `UILaunchScreen: {}` (leeres Dictionary genügt für SwiftUI-Apps). **[Sekundärquelle]**
- Bundle-ID `org.steno.Steno-iOS`, damit Einstellungen und Keychain nicht mit der Mac-App kollidieren, die Marke aber gleich bleibt. **[Empfehlung]**

### 4.4 Erhalt der Provenienzregeln (ARCHITECTURE.md Abschnitt 4)

Die Regeln bleiben erhalten, weil iOS keinen einzigen neuen Schreibpfad einführt:

- **IDs**: alle IDs kommen weiter aus `StenoDomain/UUIDv7.swift`; kein iOS-eigener ID-Typ. **[Fakt]** (Datei existiert im Target)
- **provenanceKey**: eigene Aufnahmen registrieren ihr Asset wie auf dem Mac als `"<meetingID>/<trackKind>"`; die einspurige Session erzeugt schlicht nur ein `micTrack`-Asset statt zwei.
  Die Gerätebrücke dedupliziert nicht allein ueber diesen lokalen Medienwert, sondern ueber die unveraenderte Ursprungs-Meeting-ID und den kanonischen Paket-Inhaltsdigest.
  Gleicher Ursprung und gleicher Digest ergeben einen No-op, gleicher Ursprung und abweichender Digest einen Konflikt ohne automatisches Ueberschreiben oder Duplizieren.
- **Unveränderliche Originale**: `StenoiOSAudio` schreibt CAF nur während der Aufnahme und schliesst die Datei bei Stop; jede Verarbeitung läuft unverändert über `StenoPipeline`/`RunArtifactStore` und schreibt ausschliesslich nach `runs/`.
- **Revisionsregeln und Run-Provenienz**: unverändert, weil `RevisionStore`, `MeetingReviewController` und die Identitäts-Gates ungeändert übernommen werden; die iOS-App ruft dieselben Controller wie die Mac-App.
- Der einzige iOS-spezifische Punkt ist die Dateien-App-Sichtbarkeit: sie öffnet einen Schreibweg an der App vorbei.
  Regelerhalt heisst hier: die App behandelt extern veränderte Originale wie beschädigte Artefakte (melden, quarantänisieren, nie stillschweigend überschreiben), exakt nach `ARCHITECTURE.md` Abschnitt 7.

## 5. Meilensteine

Reihenfolge verbindlich; jeder Meilenstein endet mit grünen Tests, einem Lauf auf echter Hardware und einem Blick auf den Bildschirm (Lehre aus `docs/UX-REVIEW.md`).

### i1: Gerüst, Bibliothek, Mikrofonaufnahme, Live-Transkript (iPhone zuerst)

Ziel: eine App auf einem echten iPhone, die aufnimmt, live transkribiert, das Original unveränderlich ablegt und Anruf wie Absturz übersteht.
Schritte:

1. Freigabe F1 einholen und umsetzen (eine Zeile in `StenoKit/Package.swift`).
2. `project.yml`, App-Target, `StenoiOSKit` anlegen; gegen Simulator und Gerät bauen.
3. `StenoiOSAudio`: Session-Konfiguration, Berechtigung, einspurige Aufnahme, Unterbrechungs- und Routenwechselbehandlung, Pegel.
4. Bibliothek unter `Documents/StenoLibrary` über die unveränderte Startsequenz (`PipelineStartup`, RecoverySweep, `CaptureRecovery`).
5. Live-Transkript über den unveränderten `SpeechAnalyzerProvider`.
6. iPhone-UI: Meetingliste, Aufnahme-Hauptbildschirm, Meeting-Detail lesend.
7. **Erledigt: Modellinstallation und Wiederaufnahme des finalen ASR-Laufs.**
   iOS setzt fuer Apple-Sprachassets und die optionale lokale Sprechertrennung getrennte `ModelInstallationCoordinator`-Instanzen mit getrennten Zustimmungsnachweisen ein.
   Ein fehlendes Modell sperrt die Aufnahme nicht; Audio wird gespeichert und der modellbedingt gescheiterte finale ASR-Lauf wird nach erfolgreicher Installation gezielt erneut verarbeitet.
   Implementiert in `fd780e3` bis `cb4569c` und auf dem iPhone in `docs/BENCH-IOS-I1-MODELS.md` belegt.
   Die Diarisierungsmodelle werden nur nach einem eigenen manuellen Installationsschritt geladen, laufen nur im Vordergrund und erzeugen Sprechercluster statt Personenbezeichnungen.
   Ein Sperrmarker haelt einen noch nicht vollstaendig pruefsummenverifizierten Download fuer die laufende Diarisierung unsichtbar, ohne Aufnahme oder Final-ASR zu pausieren.
   Nach der Installation werden ausschliesslich Diarisierungsjobs mit dem typisierten Fehler `diarizationModelsNotInstalled` oder dem exakten historischen Fehlerformat vor Einfuehrung des Typs einmalig erneut eingereiht.
   Eine reale Zwei-Personen-Abnahme auf dem iPad bleibt der Hardware-Gate dieses Meilensteins.

Abnahme (am Gerät sichtbar): Aufnahme starten, Gerät sperren, zehn Minuten weiter aufzeichnen; eingehenden Anruf annehmen, danach zeigt das Meeting "unterbrochen" mit intaktem Audio bis zur Unterbrechung; `kill -9` während der Aufnahme verliert kein Audio (Recovery adoptiert die Spur); die CAF-Datei ist in der Dateien-App sichtbar; das Live-Transkript erscheint während der Aufnahme mit vorläufig/final-Unterscheidung.
Aufgelöste Risiken: AVAudioSession-Lebenszyklus, Hintergrund-Aufnahme, StenoKit-in-App auf iOS.

### i2: Nachverarbeitung auf dem Gerät

Ziel: aus Stop wird ohne Zutun ein fertiges Transkript mit Sprechern, auch wenn der Nutzer die App verlässt.
Schritte: Finallauf, Diarisierung und Identitätsvorschläge über den unveränderten `PipelineCoordinator`; Anbindung an `BGContinuedProcessingTask` (Start beim Stop-Tippen, Fortschritt aus der Job-Kette); FluidAudio-Modellverzeichnis ins Container-Cache-Verzeichnis mit Backup-Ausschluss; Sprecher-Review-UI (Inspector als Sheet); Messaufgaben R1 bis R3 durchführen und protokollieren.
Abnahme: eine echte 60-Minuten-Raumaufnahme wird auf dem Gerät ohne Jetsam-Abbruch zu einem Transkript mit Sprecherclustern; während des Laufs die App verlassen, der Systemfortschritt ist sichtbar und der Lauf endet; Bestätigen, Zuweisen und Hörproben funktionieren am Touchscreen; das Messprotokoll (Speicher, Dauer, Thermik) liegt in `docs/` ab.
Aufgelöste Risiken: Speicher, Hintergrund-Nachlauf, Modell-Downloads auf iOS.

#### Offen: zweite ASR-Engine auf iOS, Parakeet (Produktanforderung, 20.08.2026)

Die Produktanforderung ist eine iOS-Transkription, die nicht allein an Apples `SpeechTranscriber` hängt; Parakeet ist der benannte Kandidat.
Korrektur vom 20.08.2026: dieser Eintrag entstand ohne Kenntnis der bereits laufenden Parakeet-Arbeit und war insofern falsch, als er "kein Code" nahelegte.
Seit dem 14.08.2026 existiert der Parakeet-Transkriptionsprovider, der gegatete Parakeet-Live-Adapter und die verifizierte Modellinstallation mit Prüfsummenmanifest in `StenoTranscription` - einer der portablen StenoKit-Bibliotheken, die iOS unverändert mitbaut.
Offen bleiben damit nur die iOS-seitige Oberflächen-Anbindung (Modellwahl in den Einstellungen, Installations-Zustimmung) und die deutsche Messung, die vor einer Entscheidung über den tatsächlichen Einsatz auf iOS noch aussteht.

Was dafür spricht, aus der bereits vorliegenden Messung:

- `docs/BENCH-M2-ASR.md` misst Parakeet auf Englisch mit WER 18,31 gegen 21,30 für SpeechAnalyzer, also rund drei Punkte besser.
  Den Ausschlag gab damals nur die Geschwindigkeit: SpeechAnalyzer ist 2,3-fach schneller im RTF. Auf einem Gerät, das über Nacht nachverarbeiten darf, wiegt dieses Argument weniger als auf dem Mac.
- Der Simulator meldet für `SpeechTranscriber` null unterstützte Sprachen (`AGENTS.md`). Eine zweite Engine würde Live-Transkript und Sprachwahl erstmals ohne echtes Gerät prüfbar machen.
- FluidAudio ist über `StenoDiarization` bereits eine Abhängigkeit des Projekts, die Modellinstallation läuft schon über `ModelInstallationCoordinator` mit Zustimmung und Prüfsummen.

Was vor dem Bau zu klären ist:

- **Deutsche Messung.** Die 18,31 gegen 21,30 sind englisches AMI-Material. Für deutsche Praxis-Meetings zählt Deutsch, und dafür gibt es bis heute kein Referenzmaterial - genau der erste Revisionsauslöser, den `docs/BENCH-M2-ASR.md` selbst benennt. Ohne diese Messung ist der Wechsel eine Vermutung.
- **Speicher und Thermik auf dem iPhone.** Messaufgabe R1 gilt unverändert: ein zweites ASR-Modell neben Sortformer und WeSpeaker im selben Lauf ist der kritische Fall, nicht der Einzellauf.
- **Wahl oder Ersatz.** Ob Parakeet `SpeechTranscriber` ablöst oder als ausdrücklich wählbare Engine danebensteht. Letzteres passt zur Regel, dass eine abgeleitete Einstellung von einer gewählten unterscheidbar sein muss, kostet aber eine Einstellung mehr und eine zweite Modellinstallation.
- **Sprachwahl.** Parakeet hat einen anderen Sprachkatalog als `SpeechTranscriber`. `LocaleResolver` liefert seit dem Review vom 20.08.2026 für eine ausdrücklich gewählte, nicht auflösbare Sprache `nil`, statt still zu ersetzen. Ein Engine-Wechsel darf eine gespeicherte Sprachwahl deshalb nicht unbemerkt unauflösbar machen.
- **Verhältnis zum Livetranskript.** Das Live-Transkript während der Aufnahme und der Finallauf müssen nicht dieselbe Engine benutzen. Falls sie es nicht tun, gehört das in der Oberfläche gesagt, nicht verschwiegen.

Vorschlag für den ersten Schritt: der Provider ist gebaut, der nächste Schritt ist deshalb nicht mehr Code, sondern deutsches Referenzmaterial und eine Messung im Stil von `docs/BENCH-M2-ASR.md`, abgelegt als `docs/BENCH-IOS-ASR.md`.
Erst deren Ergebnis entscheidet, ob und in welcher Form Parakeet auf iOS tatsächlich zum Einsatz kommt; die iOS-Oberflächen-Anbindung selbst steht noch aus.

### i3: iPad-Station

Ziel: das iPad ist der vollwertige Arbeitsplatz.
Schritte: adaptives Layout (SplitView-Sidebar, Inspector als Spalte, Aufnahme-Streifen statt Vollbild); `.commands` für Menüleiste und Tastatur; Review-Tastatursteuerung; hoverEffects; `AVInputPickerInteraction` und Routenwechseltest mit USB-C-Interface; Drag-and-Drop-Import und -Export; `@SceneStorage`-Restaurierung; Stage-Manager-Fenstergrössen.
Abnahme: am iPad mit Magic Keyboard ein Meeting komplett per Tastatur anlegen, aufnehmen, stoppen, Sprecher bestätigen; ein USB-Audio-Interface wird als Quelle genutzt, Umstecken während der Aufnahme endet definiert statt still; die App ist im Stage Manager bei schmaler Fensterbreite bedienbar; ein Meeting-Export landet per Drag in der Dateien-App.
Aufgelöste Risiken: iPad-Layout, externe Hardware, Mehrfenster.

**Verifizierter Stand der Ordnernavigation vom 19.08.2026:**

- iPhone und iPad verwenden denselben Präsentationsbaum und denselben persistenten `FolderStore` wie macOS.
  Die Sidebar zeigt Wurzelordner, eine Kindebene, direkte Meetings, leere Ordner und ungeordnete Meetings in Datumsabschnitten.
- Die feste, nicht selektierbare Zeile `Folders` ist der eindeutige Ort zum Anlegen eines Wurzelordners, zum Hochstufen eines Kindordners und als immer vorhandenes Drop-Ziel für `No folder`.
  Sichtbare Datumsabschnitte sind zusätzliche `No folder`-Drop-Ziele.
  Ordner werden niemals zur Navigationsauswahl; nur ein Meeting erzeugt die Route `.meeting`.
- Anlegen, Umbenennen, Löschen mit Bestätigung, einzelne Meeting-Verschiebungen in jeden Ordner oder in `No folder`, Ordner-Elternwechsel, Hochstufen sowie `Move Up` und `Move Down` sind über Kontextmenüs erreichbar.
  Typisierte UUID-Drag-Nutzlasten ergänzen diese Menüs, ersetzen sie aber nicht.
- Suche verwendet den gemeinsamen `MeetingSearch`-Vertrag für Großschreibung, Diakritika und Zeichenbreite.
  Ein einmaliges Transfer-Reveal-Ereignis öffnet und persistiert die tatsächlichen Vorfahren vor der bestehenden Meetingauswahl, auch wenn dieselbe Meetingkennung erneut angefordert wird.
  Temporäre Suchöffnungen überschreiben den persistenten Disclosure-Zustand nicht.
  Eine sichtbare Mutation erfolgt erst nach erfolgreichem Aufruf der `AppModel`-Fassade.
- Die vollständige iOS-App-Suite bestand mit 227 logischen Tests beziehungsweise 235 parametrischen Ausführungen.
  Die vollständige `StenoiOSKit`-Suite bestand mit 26 logischen Tests beziehungsweise 32 parametrischen Ausführungen.
  Der generische iOS-Build war erfolgreich.
- Eine getrennte synthetische Simulatorbibliothek wurde auf frischen iPhone- und iPad-Simulatoren gestartet.
  Die iPad-Sidebar wurde im Hochformat mit geöffnetem Eltern- und Kindordner, direktem sowie verschachteltem Meeting, leerem Ordner, ungeordnetem Datumsabschnitt und allen Werkzeugrouten sichtbar geprüft.
  Auf dem iPhone blieb ohne UI-Fernsteuerung nur der unveränderte kompakte Aufnahme-Detailpfad sichtbar; die geöffnete Sidebar ist dort ein manuelles Abnahmegate.
- Kontextmenüs und Dialoge, tatsächliche Drag-Gesten, Suche, Transfer-Reveal und die kompakte iPhone-Sidebar wurden im Simulator nicht interaktiv ausgeübt und bleiben manuelle Abnahmegates.
  Es wurde keine App auf ein Gerät installiert und kein externer Dienst kontaktiert.
- Der bekannte iPad-Drag-and-Drop-Fehler wird zentral im Tracker als Issue 1 verfolgt; das Kontextmenü bleibt der funktionierende Workaround.
- Mehrfachauswahl und Sammelverschieben bleiben bewusst macOS-spezifisch.

### i4: Vorlagen, Intelligence, Datenschutzregister

Ziel: Protokolle on-device, externe Modelle nur bewusst.
Schritte: `FoundationModelsProvider` mit ehrlicher Verfügbarkeitsanzeige (`FoundationModelsProvider.availability` existiert **[Fakt]**, `FoundationModelsProvider.swift:20`); `OpenAICompatibleProvider` samt Endpunkt-Einstellungen; Übertragungshinweis und Register sinngemäss aus `docs/PLAN-PRIVACY.md`; `ReportsSection` mit `UIPasteboard` und `ShareLink`.
Abnahme: auf einem Apple-Intelligence-Gerät entsteht ein Protokoll ohne Netz (Flugmodus-Test); auf einem Gerät ohne Apple Intelligence erklärt die App das ehrlich statt zu schweigen; vor einem externen Lauf erscheint der Hinweis mit den tatsächlichen Datenklassen.
Aufgelöste Risiken: Foundation-Models-Verfügbarkeit, Datenschutzgrenze auf iOS.

**Verifizierter Umsetzungsstand vom 18.08.2026:**

- Die Implementierung baut für macOS und iOS.
  Die vollständige iOS-App-Suite bestand mit 165 logischen Tests beziehungsweise 173 parametrischen Ausführungen, die vollständige macOS-App-Suite mit 154 Tests und die targetweise vollständige StenoKit-Ersatzkette mit 718 Tests über alle zehn Targets.
- Automatisiert belegt sind Apple als Kaltstartstandard, ausdrückliche externe Auswahl, gepinnte Revision, Endpunkt und Eingabefingerabdruck, unveränderliche Versionen, Erhalt alter Versionen bei laufenden und fehlgeschlagenen Jobs, Abbruch sowie Copy- und Share-Nutzlast der sichtbaren Version.
- Die Einstellungen kontaktieren einen Endpunkt nicht selbstständig.
  Ein externer Zugriff beginnt nur durch `Test connection` oder eine ausdrücklich gestartete Protokollerzeugung.
- Eine getrennte synthetische Simulatorbibliothek mit zwei Reportversionen und langem Text wurde auf frischen iPhone- und iPad-Simulatoren gestartet.
  Sichtbar belegt sind der iPhone-Hochformatstart und der iPad-Hochformatstart mit Sidebar und synthetischem Meeting.
  Die Protokollansicht auf dem iPhone im Hochformat und auf dem iPad im Hoch- und Querformat, die sichtbare und verborgene Sidebar, die Darstellung und das Scrollen des langen Reports, zwei Versionen und die Versionsauswahl wurden wegen einer reproduzierbar hängenden Simulator-UI-Steuerung nicht belastbar interaktiv abgenommen und bleiben offen.
  Ebenfalls offen bleiben die externe Auswahl mit sichtbarem Host und den exakten Datenklassen, die sichtbare alte Version während `Pending` und `Failed`, Copy für die gewählte Version, das Öffnen und der Inhalt des Share-Sheets sowie die visuelle Bestätigung, dass die Einstellungen nicht selbstständig testen.
- Der Simulator belegt weder `SystemLanguageModel` noch echte Netzwerkberechtigungen.
  Es wurde kein Modellendpunkt kontaktiert und keine App auf ein Gerät installiert.

**Offene i4-Abnahmegates:**

1. Apple Foundation Models bleibt offen, bis ein Apple-Intelligence-fähiges iPhone oder iPad im Flugmodus mit einer harmlosen deutschen Fixture ein Protokoll erzeugt und erneut erzeugt hat und Copy, Share sowie Cancel beobachtet wurden.
2. LM Studio bleibt offen, bis ein konkreter lokaler Endpunkt und eine nicht sensitive synthetische Fixture gewählt und die echten Pfade `/models` sowie `/chat/completions` geprüft wurden.
3. Die oben genannten visuellen Simulatorinteraktionen bleiben offen.
4. Direkte Gemma-Downloads, eigene Templates und Cloud-Realtests bleiben offen.

Die garantierte Fertigstellung langer Nachverarbeitung im Hintergrund bleibt Teil der offenen i2-Abnahme und wird durch diesen Protokollschnitt nicht zugesagt.
Das vorbestehende Problem bleibt unverändert offen, dass ein Transcript-Statuswechsel von `.unavailable` zu `.ready` oder `.modelsRequired` die neue Revision nicht in jedem Fall ohne erneutes Öffnen lädt.

### i5: Gerätebrücke ohne Sync

Ziel: Meetings wandern verlustfrei zwischen iPhone, iPad und Mac, ohne Sync-Dienst.
Schritte: Der Export erzeugt genau eine regulaere, unkomprimierte `.stenomeeting`-AppleArchive-Datei mit dem freigegebenen Text- und optionalen Audioinhalt.
Die Datei ist unverschluesselt, und Audio wird nur nach einer ausdruecklichen lokalen Einzeltransferentscheidung aufgenommen, niemals automatisch, fuer Cloud-Sync oder fuer ein Modell.
Die Systemfreigabe fordert zur Auswahl von AirDrop auf, garantiert technisch aber keinen ausschliesslich auf AirDrop begrenzten Transport.
Der gemeinsame Import verwendet Ursprungs-Meeting-ID plus kanonischen Inhaltsdigest fuer No-op und Konflikt und nicht `provenanceKey` als primaeren Deduplizierungsschluessel.
Abnahme: Ein auf dem iPhone aufgenommenes Meeting wird als einzelne Datei per AirDrop ans iPad geschickt, dort geoeffnet und seine Sprecher werden bestaetigt; derselbe unveraenderte Paketinhalt ergibt beim zweiten Import einen No-op, waehrend ein abweichendes Paket desselben Ursprungs als Konflikt ohne Mutation abgelehnt wird.
Aufgelöste Risiken: der Begleiter-Nutzen von Variante A, ohne deren Sync-Preis.

### i6 (vertagt): Synchronisation und Verschlüsselung

Erst nach macOS-Meilenstein 7 (Verschlüsselungs-Beta) und einer eigenen Architekturrunde; bis dahin gilt die Brücke aus i5.
Stimm-Embeddings sind biometrische Daten, ein unverschlüsselter Sync wäre die falsche Abkürzung (`ARCHITECTURE.md` Abschnitt 8). **[Fakt]** (dort nachgelesen)

#### Library Sync (Produktanforderung, 07.08.2026)

Ziel: die Steno-Bibliothek zwischen den Geräten des Nutzers synchron halten, ohne die Sync-Risiken einzukaufen, die Abschnitt 8 der Architektur ausschliesst.
Drei Vorgaben, die die Form der Lösung bereits weitgehend festlegen:

- **Nur der Textteil.** Ein spaeterer verschluesselter Sync darf Transkripte, Meeting- und Personendokumente, Notizen und Berichte umfassen, aber niemals Audiooriginale.
  Die einzige geraeteuebergreifende Audiouebertragung bleibt der ausdruecklich bestaetigte Einzeltransfer aus i5.
  Bis zu einer Bibliotheksverschluesselung bleibt die unverschluesselte lokale Bibliothek aus dem iCloud-Geraetebackup ausgeschlossen, wodurch ohne eine bewusst gesicherte Kopie ein lokales Verlustrisiko besteht.
- **Kopplung per QR-Code.** Ein Geraet zeigt den Code, das andere scannt ihn; kein Konto, kein Server-Login, keine Mailadresse als Identitaet. Der Code transportiert das Geheimnis, aus dem der Kanalschluessel entsteht.
- **Ende-zu-Ende verschlüsselt.** Ein etwaiger Vermittler sieht Chiffrat und Metadaten, nie Inhalt.

Offene Fragen, die vor dem Bau zu klaeren sind und hier stehen, damit sie spaeter nicht neu gedacht werden:

- **Transport.** Direkt im lokalen Netz (Multipeer, Bonjour) oder ueber einen dummen Relay, damit iPhone und Mac auch dann abgleichen, wenn sie nicht gleichzeitig zu Hause sind. Ersteres ist einfacher und deckt den Zielanwendungsfall vermutlich ab.
- **Konfliktmodell.** Zwei Geraete korrigieren dieselbe Transkriptzeile. Die Bibliothek hat bereits Revisionen und `provenanceKey`; ob das fuer eine verlustfreie Zusammenfuehrung reicht oder ob es eine echte CRDT-Schicht braucht, ist die eigentliche Architekturfrage.
- **Verhaeltnis zu i5.** Die Geraetebruecke bleibt als bewusster Einzeltransfer bestehen und kann nach lokaler Bestaetigung Text und optional Audio enthalten.
  Ein spaeterer verschluesselter Sync ersetzt hoechstens regelmaessige Textuebertragungen und uebertraegt Audio nie.
- **Stimm-Embeddings.** Sie liegen in `identity/` und gehoeren fachlich zum Textteil, sind aber biometrische Daten. Entweder sie bleiben ausdruecklich lokal, oder ihr Sync braucht eine eigene Entscheidung. Nicht stillschweigend mitnehmen.
- **Schluesselverlust.** Was passiert, wenn ein gekoppeltes Geraet verloren geht. Entkopplung, Schluesselwechsel und was mit bereits repliziertem Chiffrat geschieht.

## 6. Risiken und Messaufgaben

Jede Aufgabe mit Aufbau und Erfolgskriterium; Ergebnisse werden als `docs/BENCH-IOS-*.md` abgelegt, im Stil von `docs/BENCH-M2-ASR.md`.

- **R1 Speicher/Jetsam (Meilenstein i2, blockierend für die Produktzusage).**
  Aufbau: 60-Minuten-Raumaufnahme auf dem Ziel-iPhone; danach Finallauf und Diarisierung erst sequenziell, dann probeweise parallel; Messung über `os_proc_available_memory` (im 26.5-SDK vorhanden, `usr/include/os/proc.h:87` **[Fakt]**), Instruments-Allocations und MetricKit-Crash-Reports über drei Läufe.
  Erfolg: drei sequenzielle Läufe ohne Jetsam-Abbruch, dokumentierter Peak.
  Eskalation bei Misserfolg: strikte Sequenzierung erzwingen, dann das Increased-Memory-Entitlement prüfen (`com.apple.developer.kernel.increased-memory-limit` **[Sekundärquelle]**, Name nicht lokal verifiziert), dann Kippkriterium aus Abschnitt 1.
- **R2 Hintergrund.**
  Aufbau: (a) Aufnahme 60 Minuten bei gesperrtem Display, (b) eingehender Anruf angenommen und abgelehnt, (c) Nachlauf gestartet und sofort App gewechselt.
  Erfolg: (a) lückenloses Audio, (b) sauberer `interrupted`-Zustand mit intaktem Prefix und klarer UI, (c) Lauf endet im Hintergrund mit sichtbarem Systemfortschritt; abgebrochene Läufe werden beim nächsten Start idempotent fortgesetzt (JobStore-Recovery, existiert **[Fakt]**).
- **R3 Thermik und Akku.**
  Aufbau: 60 Minuten Aufnahme mit Live-ASR auf iPhone und iPad, `ProcessInfo.thermalState` und Akkustand alle fünf Minuten geloggt.
  Erfolg: kein Zustand über `.serious`, Akkuverbrauch dokumentiert; ein Grenzwert wird erst nach der ersten Messung festgelegt statt jetzt erfunden. **[Empfehlung]**
- **R4 Mikrofonmodus.**
  Aufbau: dieselbe Tischszene (mehrere Sprecher, definierte Positionen) je einmal mit `AVAudioSessionModeMeasurement` (im 26.5-SDK vorhanden, `AVAudioSessionTypes.h:160` **[Fakt]**), Standardmodus und nutzerseitiger Stimmisolation; WER über den ASR-Lauf, DER über die vorhandene Benchmark-Kette aus `steno-diarize-bench` auf dem Mac gegen dieselben Dateien.
  Erfolg: eine aktenkundige Modus-Entscheidung mit Zahlen, keine Meinung.
- **R5 Einspurige Diarisierung und die Vier-Slot-Frage.**
  Die Grenze aus `ARCHITECTURE.md` (Korrektur 3 und 4: höchstens vier Cluster je Kanal, Domäne kennt bewusst keine Slot-Grenze, die Engine schon) trifft iOS ungefiltert, weil der zweite Kanal fehlt.
  Aufbau: echte Raumaufnahmen mit vier und mit mehr als vier Sprechern vom iPhone-Mikrofon, DER/JER über die bestehende Benchmark; zusätzlich der ungescorte 8-Sprecher-Fall aus dem Mac-Projekt, bevor irgendeine Mehr-als-vier-Engine erwogen wird.
  Erfolg: belegte Aussage, ab welcher Sprecherzahl die App ehrlich "Mehrere Personen" markieren muss; die UI-Markierung existiert bereits.
- **R6 Foundation-Models-Verfügbarkeit.**
  Kein Messaufbau, sondern UI-Pflicht: die vorhandene `availability`-Prüfung wird auf jedem Gerätetyp ehrlich angezeigt; Testmatrix iPhone mit und ohne Apple Intelligence, iPad.
- **R7 Dateien-App-Schreibzugriff.**
  Aufbau: Bibliothek in der Dateien-App absichtlich beschädigen (Original umbenennen, JSON editieren), App starten.
  Erfolg: Meldung und Quarantäne statt Absturz oder stillem Überschreiben.

## 7. Sackgassen, ausdrücklich nicht versuchen

- **Systemaudio auf iOS**, in jeder Form: kein CoreAudio-Tap (Header fehlen im iOS-SDK **[Fakt]**), kein ReplayKit-Broadcast (auf Bildschirmübertragung zugeschnitten, Telefonie- und FaceTime-Audio systemseitig ausgenommen **[Sekundärquelle]**, Setup fragil), kein CallKit (liefert Signalisierung, keinen Audiostrom **[Sekundärquelle]**), keine Konferenzschaltungs-Tricks der Callrecorder-Apps (fremder Server hört mit, das ist das Gegenteil von Steno).
  Wer hier Zeit investiert, verliert sie; der Anrufmitschnitt bleibt Mac-Funktion.
- **StenoKit kopieren** statt per Pfad oder Repository zu teilen; die Provenienzregeln und 12.000 Zeilen Kern divergieren sonst garantiert.
- **Catalyst oder "eine App für Mac und iOS"**: die Mac-App bleibt eigenständig; ein gemeinsames UI-Framework über beide wäre die spekulative Abstraktion, vor der beide Handoffs warnen.
- **Live-Diarisierung oder Live-LLM auf dem Gerät während der Aufnahme**: verstösst gegen die bewährte Regel "während der Aufnahme läuft ausser ASR kein Modell" (UX-Review-Nachtrag) und stellt CPU gegen den Capture-Pfad, auf einem Telefon mit Thermikbudget doppelt.
- **Apple-Pencil-Funktionen** (Abschnitt 2.4): kein Datenmodell, kein Produktnutzen über Scribble hinaus.
- **Ein eigener Sync-Dienst vor der Verschlüsselung** (Abschnitt 5, i6).
- **Ein separates iPad-UI-Target** (Abschnitt 2.1).

## 8. Freigabepflichtige Schritte (Eingriffe in steno-macos oder nach aussen)

Alle Arbeit in diesem Plan bleibt in `steno-ios`, mit diesen vier Ausnahmen, die je einzeln eine ausdrueckliche Freigabe brauchen:

- **F1** (Meilenstein i1, winzig): `StenoKit/Package.swift` um `.iOS(.v26)` ergänzen.
  Reicht für die iOS-App, nicht für einen iOS-Testlauf des Gesamtpakets; siehe den Nachtrag in Abschnitt 4.3.
- **F2** (empfohlen vor oder während i1): Extraktion `StenoAudioCore` in StenoKit (TrackWriter, AudioLevelMeter, AudioBufferTransfer, CaptureRecovery, DiskSpaceChecker, AudioErrors, AudioSource, `RecordingSession` mit variabler Quellenliste); ohne F2 gilt der befristete Fallback aus 4.2.
- **F3** (nach i1): StenoKit wird eigenes Repository, beide Apps binden es als Paket ein; bis dahin Pfadabhängigkeit.
- **F4** (Meilenstein i5): Import des Meeting-Paketformats in die Mac-App.

Kein `git init` in diesem Verzeichnis, kein Remote, keine Veröffentlichung ohne ausdrückliche Freigabe; das übernimmt dieser Plan unverändert aus dem Handoff.

## 9. Quellen

Lokal geprüft in dieser Session: `steno-macos` bei Branch `feat/people-management`, Commit `ccc570a` (nur lesend); iOS-SDK 26.5 unter `/Applications/Xcode.app` (Header- und `swiftinterface`-Greps wie im Text einzeln genannt); die gelesenen Dateien `ARCHITECTURE.md`, `docs/FEATURE-PARITY.md`, `docs/UX-REVIEW.md`, `docs/PLAN-PRIVACY.md`, `docs/PLAN-M1.md`, `project.yml`, `StenoKit/Package.swift`, `RecordingSession.swift`, `MicRecorder.swift`, `FluidSortformerProvider.swift`, `SpeechAnalyzerProvider.swift`, `StenoApp.swift`, `ContentView.swift`, `MeetingDetailView.swift`, `AppModel.swift`.

Netz, alles Sekundärquellen ohne Verifikation an installierten SDKs:
[Apple, What's new in the Foundation Models framework, WWDC26 Session 241](https://developer.apple.com/videos/play/wwdc2026/241/) (einzige inhaltlich lesbare Apple-Quelle dieser Recherche),
[Apple, What's new in SwiftUI, WWDC26 Session 269](https://developer.apple.com/videos/play/wwdc2026/269/) (nur über Dritt-Zusammenfassungen erschlossen),
[Apple, Finish tasks in the background, WWDC25 Session 227](https://developer.apple.com/videos/play/wwdc2025/227/),
[MacRumors, Apple Releases First iOS 27 Betas](https://www.macrumors.com/2026/06/08/apple-releases-ios-27-beta-1/),
[9to5Mac, Apple unveils iPadOS 27](https://9to5mac.com/2026/06/08/apple-unveils-ipados-27-with-speed-and-productivity-improvements-more/),
[iOS 27 for Developers, rabinarayanpatra.com](https://www.rabinarayanpatra.com/blogs/ios-27-for-developers),
[Nil Coalescing, New SwiftUI APIs for reordering on iOS 27](https://nilcoalescing.com/blog/NewSwiftUIAPIsForReorderingAndDragAndDropOniOS27/),
[InfoQ, SwiftUI Adds New Document Protocol](https://www.infoq.com/news/2026/07/swiftui-wwdc26/),
[The Swift Dev, BGContinuedProcessingTask](https://www.theswift.dev/posts/bgcontinuedprocessingtask-background-urlsession/).
Apples Release-Notes-Seite blieb auch in dieser Session ohne lesbaren Inhalt; alle iOS-27-Aussagen sind entsprechend gekennzeichnet.
