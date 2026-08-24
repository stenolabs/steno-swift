# UX-Durchsicht und Modernisierungskonzept (Fable, 2026-08-06)

> Historical, non-normative UX review retained in German. Current UI behavior and acceptance status live in `FEATURE-PARITY.md` and `docs/benchmarks/2026-08-24-cross-platform-ui-qa.md`.

Auftrag: intensive UX-Durchsicht des Oberflaechencodes plus Farb- und Modernisierungskonzept.
Grundlage war die vollstaendige Lektuere aller 13 Dateien unter `App/Sources/` plus `ARCHITECTURE.md` und `HANDOFF-main.md`, Stand Commit 17979d6.
Alle Zeilenangaben beziehen sich auf diesen Stand.

## 0. Was bereits gut ist und in Ruhe bleibt

Die App macht vieles richtig, was Electron-Portierungen typischerweise falsch machen.
Durchgehend Systemcontrols, Systemmaterialien (`.background.secondary`, `.quaternary`), `ContentUnavailableView` fuer Leerzustaende (ContentView.swift:21-25, 156-163; RecordingView.swift:72-77), echte macOS-Muster (NavigationSplitView, Kontextmenue, Settings-Szene, Popover, Sheet).
Der Loesch-Dialog erklaert die Konsequenz statt nur zu warnen (ContentView.swift:137-153).
Der Datenschutz-Hinweis vor externem LLM-Transfer (ReportsSection.swift:56-63) und die Erklaerung im Sprachmodell-Einstellungstext (TextModelSettingsView.swift:16-27) sind vorbildlich.
Die Ein-Klick-Bestaetigung mit abgestufter Prominenz (SpeakerReviewSection.swift:146-168) ist die richtige HIG-Denkweise: Sicherheit steckt in der Betonung, nicht in der Verfuegbarkeit.
Die Sortierung des Zuweisen-Menues (SpeakerReviewSection.swift:183-211) verhindert einen echten Datenfehler.
Das Import-Fenster mit Phasenmodell und Abschlussbericht (LegacyImportView.swift) ist fertig und braucht nichts.

Das strukturelle Defizit liegt woanders: Die App hat keine visuelle Identitaet, die Detailansicht stapelt drei Werkzeuge in einen Scroll, Fehler werden dahin geroutet, wo zufaellig eine View zuhoert, und die Tastatur ist praktisch unbedient.

**Zweite Durchsicht am Bildschirm, 07.08.2026** (Fable, an vier echten Aufnahmen der Testbibliothek statt am Code). Sofort umgesetzt: "Ready" nur noch bei Abweichung statt an jeder Zeile, Fenstertitel "Steno" statt "steno-macos", Spurnamen lesbar ("System audio" statt "systemTrack"), und der Wortlaut der Personenverwaltung ohne Entwicklervokabular - "Don't use for recognition"/"Use again" statt "Exclude", Kennzeichen "Not used" und "From an older analysis", Abschnitt "Confirmed not <Name>" mit Erklaersatz.

Offen aus dieser Durchsicht, nach Wirkung:
1. **Sprecherzuweisung direkt im Transkript** (Fables "zuerst bauen"): Klick auf "Others" oeffnet "Who is this?" mit den bekannten Personen. Ohne das ist die Personenverwaltung ein Backend ohne Eingang.
2. **"Minutes" steht ueber dem rohen Transkript** und liest sich wie ein fehlgeschlagenes Protokoll. Getrennte Abschnitte "Transcript" und ein leerer Minutes-Bereich mit Handlungsaufforderung.
3. **Datumsformat mischt Locales** ("6. Aug at 07:14") und "Board meeting (planned)" traegt seinen Zustand im Titel.
4. **Leerzustand ohne Knoepfe**: "Start a recording or import an audio file" ist Text, keine Aktion.
5. **Erkennungsstatus je Person** ("Recognition ready" gegen "Needs more audio") waere die Frage, die dieser Bildschirm eigentlich beantworten soll.

**Bewusst nicht bauen** (Fable): manuelles Anlernen per Audio-Upload. Es unterlaeuft das Evidenzmodell - jede Probe soll aus einem bestaetigten Meeting-Moment mit Herkunft stammen.

**Stand 07.08.2026:** Von den Stufe-1-Befunden sind B1 (zentrale Meldungsfläche), B2 (ehrliche Jobstatus-Leiste), B3 (bestätigter Cluster korrigierbar), B4 (Inspector) und B6 (Menü und Shortcuts) umgesetzt, B5 (Aufnahme sperrt die App) ebenfalls.
Das Dokument bleibt als Begründungsquelle stehen; die Befundtexte beschreiben den Stand von Commit 17979d6, nicht den heutigen.

## 1. Befunde

### Stufe 1: kostet bei jedem echten Meeting Zeit oder Vertrauen

**B1 Fehlermeldungen erreichen den Nutzer teilweise gar nicht.**
`recordingError` wird nur in der RecordingView angezeigt (RecordingView.swift:79-88), aber auch von Import-Pfaden gesetzt, die ausserhalb einer Aufnahme laufen.
"Diese Datei ist bereits importiert." und "Import fehlgeschlagen" (AppModel.swift:438-443) verpuffen unsichtbar, weil die RecordingView dann nicht auf dem Bildschirm ist.
`reviewError` ist ein Sammelbecken fuer Sprecher-, Teilnehmer-, Umbenennen-, Loesch- und Protokollfehler (AppModel+Review.swift:64-66, 82, 336, 346-348), wird aber nur innerhalb der SpeakerReviewSection gerendert (SpeakerReviewSection.swift:25-29), und die existiert nur, wenn Review-Daten vorliegen.
Ein fehlgeschlagenes Loeschen oder Umbenennen ist damit stumm.
Besser: eine zentrale, nicht-modale Meldungsflaeche am unteren Fensterrand, in die alle Fehler laufen; `recordingError` und `reviewError` werden zu einer typisierten `notice` konsolidiert.

**B2 Die Statusleiste luegt ueber die Art des laufenden Jobs.**
`jobStatusBar` zeigt fuer jeden Kettenjob "Finale Transkription laeuft" (MeetingDetailView.swift:142-152), obwohl `transcriptionJobs` auch Diarisierung und Identitaetsvorschlaege umfasst (MeetingDetailView.swift:120-122).
Nach der Transkription folgt eine Diarisierung ohne Fortschritt; der Nutzer liest weiter "Transkription", sieht aber schon ein Transkript, das wirkt wie ein Haenger.
Es fehlen Kettenposition, verstrichene Zeit und ein Abschlussmoment.
Ein Fortschrittsprozent ist ohne Pipeline-Callbacks nicht ehrlich zu haben (Annahme: die Job-Struktur traegt heute keinen Fortschrittswert); Kettenposition plus Laufzeit ist die ehrliche Ausbaustufe.

**B3 Eine falsche Bestaetigung ist ueber die Oberflaeche nicht korrigierbar.**
Sobald ein Cluster bestaetigt ist, rendert `actions(for:)` gar nichts mehr (SpeakerReviewSection.swift:114-117), das Zuweisen-Menue verschwindet.
Der `.reassign`-Pfad im Menue (SpeakerReviewSection.swift:196-203) ist damit toter Code: Er behandelt genau den Fall "Cluster ist bestaetigt", wird aber fuer bestaetigte Cluster nie angezeigt.
Wer im Routinetempo einmal danebenklickt, hat keinen sichtbaren Rueckweg, und die Fehlzuordnung erzeugt Prototypen und Hard Negatives im Identitaetsmodell.

**B4 Die Detailansicht stapelt drei Werkzeuge in einen einzigen Scroll.**
Teilnehmer, Protokoll, Sprecher-Review und das komplette Transkript liegen in einer LazyVStack (MeetingDetailView.swift:33-87).
Bei einem 70-Minuten-Meeting heisst Sprecher-Zuordnung: oben eine Hoerprobe abspielen, nach unten scrollen fuer den Kontext, wieder hoch zum Bestaetigen.
Das Protokoll steht ueber den Sprechern, obwohl der Arbeitsablauf es zuletzt braucht.
Besser: Transkript wird Hauptinhalt, Sprecher-Review und Teilnehmer wandern in einen Inspector (das native macOS-Muster fuer "Werkzeug neben Dokument").
Der Inspector ist auch der natuerliche Ort fuer die geplanten Notizen und den PDF-Kontext, ohne dass das Layout erneut umgebaut werden muss.

**B5 Waehrend der Aufnahme ist die restliche App gesperrt.**
`if model.isRecording` ersetzt die gesamte Detailflaeche, egal welches Meeting gewaehlt ist (ContentView.swift:15-16).
In einem echten Meeting will man aber gerade nachschlagen.
Besser: Die RecordingView gehoert zum Aufnahme-Meeting; ein schmaler, dauerhaft sichtbarer Aufnahme-Streifen bleibt oben stehen.
Das spielt mit dem Entwurfszustand zusammen: "Aufnahme laeuft" wird ein Zustand des Meetings, nicht ein Modus der App.

**B6 Tastaturbedienung existiert praktisch nicht.**
Die einzigen Shortcuts sind Default-Actions in zwei Dialogen (LegacyImportView.swift:265, TextModelSettingsView.swift:190).
Kein Cmd-R, kein Cmd-I, kein App-Menue ausser dem Altimport (StenoApp.swift:17-23), damit sind die Kernaktionen auch ueber die Hilfe-Menuesuche nicht auffindbar.
Im Sprecher-Review waeren Leertaste fuer Hoerprobe und Return fuer Bestaetigen der groesste Tempogewinn.

### Stufe 2: spuerbar, aber kleiner

**B7 Fehler sind orange, und Orange ist schon vergeben.**
Verarbeitungsfehler (MeetingDetailView.swift:153-163), Review-Fehler (SpeakerReviewSection.swift:25-29), Aufnahmefehler (RecordingView.swift:79-88) und Importfehlschlag (LegacyImportView.swift:165-169) sind alle orange, dieselbe Farbe wie "Unterbrochen" (ContentView.swift:188-195) und das Konzept fuer "unsicher".
Echte Fehler gehoeren auf Systemrot, Orange bleibt fuer degradiert und unsicher.

**B8 Der Bootstrap-Alert ist eine Falle.**
`.alert("Fehler", isPresented: .constant(model.bootstrapError != nil))` (ContentView.swift:76-81): `bootstrapError` wird nie zurueckgesetzt, das Binding ist konstant true, der Alert kommt nach jedem Wegklicken wieder.
Zudem zeigt er `String(describing: error)` (AppModel.swift:167, 224), im Widerspruch zur eigenen guten Regel "Rohe Fehlernamen gehoeren nicht in die Oberflaeche" (AppModel+Review.swift:112).
Dieselbe Rohausgabe steckt in `recordingError` (AppModel.swift:274) und den Teilnehmerfehlern (AppModel+Review.swift:66).

**B9 Kein Kopfbereich am Meeting.**
Die Detailansicht zeigt nirgends Titel, Datum, Dauer oder Status; der Fenstertitel bleibt "Steno", Umbenennen geht nur ueber das Sidebar-Kontextmenue (ContentView.swift:110-119).
Besser: `.navigationTitle` plus `.navigationSubtitle`, Titel per Klick editierbar.
Der Kopfbereich ist zugleich der geplante Ort fuer Teilnehmer-Chips und Notizen.

**B10 Kein Vorab-Hinweis vor dem Protokoll-Erzeugen.**
"Protokoll erstellen" (ReportsSection.swift:43-54) ist immer aktiv, auch wenn kein Sprecher bestaetigt ist; das Ergebnis nennt sie dann "Sprecher 1".
Ein einzeiliger Hinweis vor dem Knopf, keine Sperre, spart einen kompletten LLM-Lauf.
Dieselbe Zahl gehoert als Fortschritt ("2 von 5 zugeordnet") in die Ueberschrift der Sprecher-Sektion; die Routinearbeit bekommt damit ein sichtbares Ende.

**B11 Protokoll-Lauf ohne Abbruch.**
"Wird erstellt..." (ReportsSection.swift:34-40) kann bei externem Endpunkt minutenlang stehen; `coordinator.cancel(jobID:)` existiert bereits (AppModel+Review.swift:329), es fehlt nur der Knopf.

**B12 VoiceOver und Werteausgabe.**
Die Play/Stop-Knoepfe sind reine Symbole mit `.help`, aber ohne `accessibilityLabel` (MeetingDetailView.swift:223-232, SpeakerReviewSection.swift:297-307).
Der LevelMeter (RecordingView.swift:110-137) hat weder Label noch `accessibilityValue`, dabei ist "kommt Mikrofonsignal an" die kritischste Information zu Aufnahmebeginn.
Der Play-Knopf mit Opacity 0.3 (MeetingDetailView.swift:228) ist grenzwertig kontrastarm, als sekundaere Hover-Affordanz mit Zeitstempel daneben aber vertretbar, nur nicht weiter senken.
Positiv: StatusBadge und Chips tragen ihre Information in Text und Symbol, nie nur in Farbe.

**B13 Kleinigkeiten.**
Zeitstempel bleiben ueber einer Stunde im Format "72:45" (MeetingDetailView.swift:200-203, 280-283), ab 60 min ist "1:12:45" lesbarer.
Die Sidebar-Zeile zeigt kein Jahr (ContentView.swift:99).
Die Meeting-Dauer taucht nirgends auf, waere in Sidebar und Kopfbereich billig zu haben (Annahme: Dauer ist ueber die MediaAssets verfuegbar).

## 2. Farb- und Visualkonzept fuer macOS 26

Leitidee: Die Flaeche bleibt System (Materialien, Vibrancy, Standardlisten, also genau das, was macOS 26 mit Liquid Glass ohnehin liefert, wenn man Systemcontrols nutzt).
Farbe bekommt drei getrennte Aufgaben: Markenfarbe fuer Identitaet, semantische Rollen fuer Zustaende, Sprecherpalette fuer die einzige wirklich app-spezifische Farbaufgabe.
Kein eingefaerbtes Chrome, keine farbigen Flaechen um ihrer selbst willen.

**Akzentfarbe Petrol**, Light `#0F7B8A`, Dark `#4EC5D6`.
Nahe an der Audio- und Waveform-Assoziation, ruhig genug fuer ein Protokollwerkzeug, kollidiert mit keiner semantischen Rolle und unterscheidet sich vom System-Blau, das jede unkonfigurierte App traegt.
Weiss auf `#0F7B8A` erreicht rund 4,8:1, taugt also fuer gefuellte Buttons.
Die Farbe wird als `AccentColor` im Asset-Katalog hinterlegt; hat der Nutzer systemweit eine eigene Akzentfarbe erzwungen, gewinnt dessen Wahl automatisch, und das ist gewollt.
Deshalb gibt es zusaetzlich das von der Akzentmechanik unabhaengige Token `StenoBrand` mit denselben Werten fuer Stellen, die Markenfarbe unabhaengig vom Nutzerakzent tragen duerfen: Level-Meter-Fuellung, App-Icon, die "Ich"-Sprecherfarbe.

**Semantische Rollen**, alle ueber Systemfarben, die Hell/Dunkel und Vibrancy selbst beherrschen:

- Aufnahme laeuft: `systemRed`. Rot bleibt exklusiv fuer Aufnahme und Fehler.
- Job laeuft: `StenoBrand` statt des heutigen Blau, immer mit Spinner oder Text, nie Farbe allein.
- Bestaetigt und bereit: `systemGreen`.
- Unsicher, Vermutung, unterbrochen, degradiert: `systemOrange`.
- Fehler: `systemRed` (behebt B7).
- Entwurf: `secondary`-Grau, bewusst farblos, damit Entwuerfe optisch zuruecktreten.

**Sprecherfarben ohne Kirmes.**
Acht gedeckte, wahrnehmungsmaessig verteilte Toene als `Speaker1` bis `Speaker8` im Asset-Katalog:

| Rolle | Light | Dark |
|---|---|---|
| Speaker1 (Blau) | `#4C7FB8` | `#7BA6D9` |
| Speaker2 (Seegruen) | `#2F8C7E` | `#57B3A4` |
| Speaker3 (Violett) | `#8563B5` | `#AB8BD9` |
| Speaker4 (Terrakotta) | `#B0653F` | `#D98F63` |
| Speaker5 (Oliv) | `#77843B` | `#9DAB5C` |
| Speaker6 (Beere) | `#AD5F86` | `#D287AC` |
| Speaker7 (Graublau) | `#5C7A99` | `#8AA6C2` |
| Speaker8 (Ocker) | `#9A7A2E` | `#C2A14F` |

Die eigene Mikrofonspur bekommt `StenoBrand`.
Einsatzregeln: Sprecherfarbe erscheint ausschliesslich als kleiner Marker (8-pt-Punkt oder 3-pt-Balken neben dem Namen) und als 10 bis 15 Prozent Tint hinter Chips, nie als Textfarbe und nie als Flaechenfuellung.
Der Name steht immer als Text daneben, Farbe ist also nie alleiniger Informationstraeger, und Kontrastanforderungen an die Palette entfallen damit weitgehend.
Zuordnung: fuer bestaetigte Personen stabil ueber einen Hash der PersonID, damit dieselbe Person in jedem Meeting dieselbe Farbe hat; fuer unbestaetigte Cluster ueber die Position in der nach Sprechzeit sortierten Clusterliste.
Nach einer Re-Diarisierung duerfen sich Farben unbestaetigter Cluster aendern, das ist ehrlich, weil sich auch die Cluster aendern.
Bei mehr als acht Personen wiederholt sich die Palette, der Name disambiguiert.

**Hell und Dunkel** ausschliesslich ueber Asset-Katalog-Varianten und Systemfarben, keine Appearance-Abfragen im Code.

**Typografie und Abstaende.**
Schrift bleibt komplett System.
Transkript- und Protokolltext auf 14 pt mit `lineSpacing(3)`; dieselbe Groesse gehoert dann auch dem Transkript in MeetingDetailView.swift:241, das heute 13 pt hat.
Alle Zeit- und Zaehlwerte `monospacedDigit()`.
Abstandsraster auf 4-pt-Basis mit fuenf Stufen (4/8/12/16/20), Kartenradius 10, Chips bleiben Kapseln.
Jede Sektion bekommt konsistent 20 pt Abstand nach oben statt der heutigen Mischung aus Divider und Zufallsabstaenden.

**Ablage als Design-Tokens.**
Neuer Asset-Katalog `App/Resources/Assets.xcassets` (AccentColor, StenoBrand, Speaker1-8, App-Icon), in `project.yml` als Ressource des App-Targets eintragen, plus `App/Sources/Theme.swift` als einzige Codestelle, die Farbnamen kennt:

```swift
import SwiftUI

enum Steno {
    enum Colors {
        static let brand = Color("StenoBrand")
        static let recording = Color(nsColor: .systemRed)
        static let running = Color("StenoBrand")
        static let confirmed = Color(nsColor: .systemGreen)
        static let uncertain = Color(nsColor: .systemOrange)
        static let error = Color(nsColor: .systemRed)
        static let speakers: [Color] = (1...8).map { Color("Speaker\($0)") }
    }
    enum Space {
        static let xs: CGFloat = 4, s: CGFloat = 8, m: CGFloat = 12
        static let l: CGFloat = 16, xl: CGFloat = 20
    }
    static let cardRadius: CGFloat = 10
    static let transcriptBody = Font.system(size: 14)
}
```

## 3. Umsetzungsskizzen

**3.1 Zentrale Meldungsflaeche** (AppModel.swift plus ContentView.swift):

```swift
// AppModel.swift
struct Notice: Equatable { let text: String; let isError: Bool }
var notice: Notice?

// ContentView.swift, am NavigationSplitView:
.safeAreaInset(edge: .bottom) {
    if let notice = model.notice {
        HStack(spacing: Steno.Space.s) {
            Image(systemName: notice.isError
                ? "exclamationmark.triangle.fill" : "info.circle")
                .foregroundStyle(notice.isError ? Steno.Colors.error : .secondary)
            Text(notice.text)
            Spacer()
            Button("OK") { model.notice = nil }.controlSize(.small)
        }
        .padding(Steno.Space.s)
        .background(.bar)
    }
}
```

**3.2 Ehrliche Jobstatus-Leiste** (MeetingDetailView.swift, ersetzt den Text in `jobStatusBar`):

```swift
private func statusText(_ job: Job) -> String {
    let step: String = switch job.kind {
    case .finalASR: "Transkription (Schritt 1 von 3)"
    case .diarization: "Sprecherwechsel erkennen (Schritt 2 von 3)"
    case .identitySuggestion: "Stimmen vergleichen (Schritt 3 von 3)"
    default: "Verarbeitung"
    }
    return job.status == .queued ? "\(step) - eingereiht" : "\(step) laeuft"
}
// daneben: Text("seit ") + Text(job.createdAt, style: .relative)
```

**3.3 Bestaetigte Cluster korrigierbar machen** (SpeakerReviewSection.swift, `actions(for:)`):

```swift
if cluster.containsMultipleSpeakers {
    EmptyView()
} else {
    HStack(spacing: 6) {
        if case .confirmed = cluster.reviewState {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Steno.Colors.confirmed)
                .accessibilityLabel("Bestaetigt")
        } else if let suggestion, ... { confirmButton(...) }   // wie bisher
        Menu { assignmentMenu(for: cluster, review: review) }  // jetzt IMMER da
            label: { Label("Zuweisen", systemImage: "person.crop.circle.badge.checkmark") }
            .menuStyle(.borderlessButton).fixedSize()
    }
}
```

Der `.reassign`-Zweig im Menue funktioniert dafuer bereits unveraendert.

**3.4 Inspector fuer die Sprecherarbeit** (MeetingDetailView.swift):

```swift
transcriptList(revision)          // enthaelt dann nur noch Kopf, Protokoll, Turns
    .inspector(isPresented: $showReview) {
        ScrollView {
            VStack(alignment: .leading, spacing: Steno.Space.xl) {
                ParticipantsSection(meetingID: meetingID, review: review)
                SpeakerReviewSection(meetingID: meetingID,
                                     revision: revision, review: $review)
            }
            .padding()
        }
        .inspectorColumnWidth(min: 300, ideal: 360)
    }
    .toolbar {
        ToolbarItem {
            Toggle(isOn: $showReview) {
                Label("Sprecher", systemImage: "person.2.wave.2")
            }
        }
    }
```

`showReview` startet true, solange unbestaetigte Cluster existieren.
Notizen und PDF-Kontext werden spaeter ein zweiter Abschnitt im selben Inspector.

**3.5 Aufnahme-Streifen statt Detail-Uebernahme** (ContentView.swift):

```swift
} detail: {
    VStack(spacing: 0) {
        if model.isRecording { RecordingStrip() }   // Punkt, Timer, Pegel, Stop
        if model.isRecording, model.selectedMeetingID == model.recordingMeetingID {
            RecordingView()
        } else if let meetingID = model.selectedMeetingID {
            MeetingDetailView(meetingID: meetingID).id(meetingID)
        } else { ... }
    }
}
```

**3.6 Menue und Shortcuts** (StenoApp.swift):

```swift
.commands {
    CommandMenu("Aufnahme") {
        Button(model.isRecording ? "Aufnahme beenden" : "Aufnahme starten") {
            Task { model.isRecording
                ? await model.stopRecording()
                : await model.startRecording() }
        }
        .keyboardShortcut("r")
        .disabled(model.runtime == nil)
    }
    CommandGroup(after: .importExport) { /* Import Cmd-I, Altimport wie gehabt */ }
}
```

**3.7 Sprechermarker im Transkript** (MeetingDetailView.swift, identisch in der Cluster-Zeile des Reviews):

```swift
if let label = SpeakerDisplay.label(for: turn.speaker, review: review) {
    HStack(spacing: 6) {
        Circle()
            .fill(SpeakerDisplay.color(for: turn.speaker, review: review) ?? .clear)
            .frame(width: 8, height: 8)
        Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }
}
```

`SpeakerDisplay.color(...)` kommt neben `label(...)` in AppModel+Review.swift.

**3.8 Barrierefreiheit**: `accessibilityLabel` an allen Play-Knoepfen; am LevelMeter `.accessibilityElement()`, `.accessibilityLabel(label)`, `.accessibilityValue("\(Int(normalized * 100)) Prozent")`.

## 4. Umsetzungsreihenfolge

**Stufe a, hohe Wirkung bei kleinem Eingriff (zusammen etwa 1,5 bis 2 Tage):**

1. Zuweisen-Menue fuer bestaetigte Cluster (3.3), rund 1 h. Risiko praktisch keines, der Aktionspfad existiert.
2. Jobstatus nach Art plus Laufzeit (3.2), 1 bis 2 h. Reine Anzeige.
3. Zentrale Meldungsflaeche (3.1), 0,5 bis 1 Tag inklusive Umleitung aller Setzstellen. Risiko: doppelte Anzeige, solange nicht alle Stellen umgestellt sind; kontextnahe Fehler im Review bewusst behalten und nur global Unsichtbares umleiten.
4. Menue und Shortcuts (3.6), 1 bis 2 h. Shortcut-Kollisionen pruefen.
5. Fehlerfarbe Rot statt Orange, Klartext statt `String(describing:)`, Bootstrap-Alert dismissbar, 2 bis 3 h.
6. Sprecher-Fortschritt und Protokoll-Vorabhinweis (B10), Abbrechen am Protokoll-Lauf (B11), 2 bis 3 h. Risiko: Cancel-Verhalten des templateRender-Jobs ist E2E ungetestet; den Knopf notfalls erst einreihen, wenn Cancel verifiziert ist.
7. Accessibility-Labels (3.8), 1 h.

**Stufe b, das Design-System als Fundament (zusammen etwa 2 bis 3 Tage):**

1. Asset-Katalog anlegen, `project.yml` erweitern, `Theme.swift` einfuehren, 0,5 Tag. Risiko: Der Katalog muss im App-Target landen, sonst laufen `Color("...")`-Lookups ins Leere und liefern zur Laufzeit Transparenz; nach dem Einbau einmal beide Appearances real sichten und das AccentColor-Verhalten mit gesetzter Nutzerakzentfarbe gegenpruefen.
2. Bestehende Views auf Tokens umstellen, 0,5 bis 1 Tag. Flaechig, deshalb Screenshot-Vergleich hell und dunkel vor und nach der Umstellung.
3. Sprecherfarben einfuehren (3.7), 0,5 bis 1 Tag. Risiko: Farbstabilitaet ueber Re-Diarisierung; PersonID-Hash so waehlen, dass er ueber App-Starts stabil ist (kein `Hasher` mit Random Seed, sondern etwa FNV ueber die UUID-Bytes).

**Stufe c, groessere Umbauten (jeweils eigenes Arbeitspaket):**

1. Detail-Neuordnung: Kopfbereich mit Titel, Datum, Dauer, Status (B9), Protokoll unter den Kopf, Sprecher und Teilnehmer in den Inspector (3.4), Transkript als Hauptinhalt, 2 bis 4 Tage.
   Kaputtgehen kann der `review`-Binding-Fluss zwischen Detail und Review-Sektion, der 1-s-`refreshLoop` (drei Views pollen heute unabhaengig, beim Umbau in eine gemeinsame Ladeschicht ziehen) und das Verhalten bei schmalen Fenstern (Inspector plus Sidebar unter etwa 1100 pt Breite pruefen).
   Dieses Paket vor den geplanten Notizen und dem PDF-Kontext bauen, damit die neuen Features in die neue Struktur einziehen statt in die alte.
2. Aufnahme-Streifen und Bibliothek parallel zur Aufnahme (3.5), 1 bis 2 Tage.
   Kaputtgehen kann der Zustandsuebergang beim Stop (die Auswahl springt heute bewusst zum neuen Meeting, AppModel.swift:306, das bleibt) und das Live-Transkript-Autoscrolling.
3. Review-Tastatursteuerung im Inspector, 1 bis 2 Tage nach c1. Risiko: Fokus-Konkurrenz mit der Transkript-Textauswahl.
4. Transkript-Suche (`.searchable` mit Treffersprung ueber ScrollViewReader) und hh:mm:ss ab einer Stunde, 1 bis 2 Tage. Risiko: Performance der LazyVStack bei weiten Spruengen, an echten 70-Minuten-Meetings testen.
5. MenuBarExtra mit Aufnahmestatus und Stop fuer die Zeit, in der Zoom im Vordergrund ist, 0,5 bis 1 Tag, unabhaengig von allem anderen.

Bewusst nicht vorgeschlagen: eigene Fensterchrome, eingefaerbte Sidebars, Karten-Dashboards, Animationen jenseits der vorhandenen Scroll-Animation.
Die App gewinnt ihre Mac-Qualitaet dadurch, dass sie Systemmaterial bleibt und Farbe nur dort einsetzt, wo sie Bedeutung traegt: Aufnahme, Zustand, Sprecher.

---

# Nachtrag: Was waehrend einer laufenden Aufnahme zaehlt (Fable, 2026-08-06 spaet)

Der Anlass: Er wollte waehrend der Aufnahme Notizen schreiben und fand das
Feld nicht, obwohl es seit demselben Abend existiert.

Leitgedanke des Nachtrags: Waehrend der Aufnahme ist Steno meist gar nicht die
vorderste App, und die Ansicht wird nicht betrachtet, sondern konsultiert - in
Blicken von ein bis drei Sekunden, mit einer Hand, zwischen zwei Wortmeldungen.
Das Mass ist deshalb nicht "ist das nuetzlich", sondern "traegt es seinen Nutzen
in unter drei Sekunden aus und verlangt danach nichts mehr".

## Was hilft, in dieser Reihenfolge

1. **Notizfeld offen**, plus ein Shortcut, der den Cursor direkt hineinsetzt
   (Cmd-Shift-N). Klicken auf ein kleines Textfeld ist im Gespraech schon zu
   viel Motorik. Die Notiz liefert das Warum, das Transkript nur das Was.
2. **Zeitstempel-Marker, eine Taste, kein Text.** Der haeufigste Impuls ist
   nicht "ich will notieren", sondern "das eben war wichtig". Haengt eine
   Zeile `[00:41:23] ` an die Notizdatei - kein neues Datenmodell noetig, und
   die Marke fliesst dadurch kostenlos in den Protokoll-Prompt.
3. **Aufnahme-Streifen (B5)**, damit die App waehrend der Aufnahme benutzbar
   bleibt: Wer im Gespraech im letzten Protokoll desselben Kreises nachschlagen
   will, kann das heute nicht.
4. **Autoscroll zaehmen.** Der Wert des Live-Transkripts ist Aufholen, nicht
   Mitlesen. Heute reisst jede neue Zeile den Blick ans Ende zurueck; Autoscroll
   gehoert nur aktiv, solange die Ansicht unten steht.
5. **MenuBarExtra** mit Punkt, Timer, Stop, Marker - das einzige Element, das
   sichtbar ist, wenn Zoom vorn liegt.
6. **Passiver Hinweis bei stillem Mikrofon.** Der schlimmste Ausgang ist die
   70-Minuten-Aufnahme ohne Ton. Die Pegel liegen alle 100 ms vor. Nur fuers
   Mikrofon - stilles Systemaudio ist bei Praesenzterminen der Normalfall und
   darf nie warnen.
7. Zwei Kleinigkeiten: ein dauerhafter "vorlaeufig"-Hinweis am Live-Transkript,
   damit niemand live daraus zitiert. Und: **Cmd-R darf nicht stoppen** - das
   ist in jedem Browser "neu laden", ein Reflex in der falschen App zerriss das
   Meeting in zwei Haelften.

## Was bewusst nicht gebaut wird

- **Keine Sprecheridentitaet im Livebild**, auch keine geratene. Waehrend der
  Aufnahme gibt es nur Kanaltrennung; "Herr Meier:" waere erfunden und wuerde
  genau die falsche Sicherheit erzeugen, die der Finallauf spaeter korrigiert.
- **Keine Live-Zusammenfassung, keine Aktionspunkte per Sprachmodell.** Verstiesse
  gegen die Regel, dass waehrend der Aufnahme kein Modell laeuft, stellte CPU
  gegen die Capture-Pfade und laedt zum Lesen ein: Ein Absatz Zusammenfassung
  ist eine 30-Sekunden-Leseaufgabe mitten im Gespraech.
- **Kein Bearbeiten des Live-Transkripts** - es wird ohnehin ersetzt.
- **Kein Pause-Knopf.** Klingt ruecksichtsvoll, ist aber die klassische Falle:
  Man vergisst das Fortsetzen und verliert 40 Minuten unwiederbringlich. Ein
  Bedienelement, dessen Vergessen die Aufnahme zerstoert, gehoert nicht in die
  Ansicht.
- **Keine Wellenform, keine Animationen** ueber die zwei Pegel hinaus. Bewegung
  zieht das Auge an und sagt nichts, was die Pegel nicht sagen.
- **Keine Teilnehmerpflege waehrend der Aufnahme.** Wer da war, gehoert als
  Stichwort in die Notiz; die strukturierte Pflege ist Nachbereitung.
- **Keine Toene, keine Systembenachrichtigungen.** Ein Banner ueber dem
  geteilten Bildschirm oder ein Klang im Konferenzmikrofon waere schlimmer als
  jedes Problem, das er meldet.

## Zum Notizfeld im Besonderen

Ja, offen als Voreinstellung - aber die Entscheidung des Benutzers merken
(`@AppStorage` statt fluechtigem `@State`). Wer zweimal zuklappt, hat
entschieden.

Der Inspector ist die richtige Form, kein Untereinander: Notiz und Transkript
konkurrieren um Breite, nicht um Hoehe. Ein Notizfeld unter dem Transkript
striete mit dem Autoscroll um die wertvolle untere Kante. Bei 1240 pt
Fensterbreite bleiben dem Transkript auch mit Inspector ueber 600 pt.

Der Fokus wird beim Oeffnen NICHT gestohlen: Der Cursor springt erst per
Shortcut oder Klick ins Feld, damit Leertaste und Pfeiltasten nicht
versehentlich in der Notiz landen.
