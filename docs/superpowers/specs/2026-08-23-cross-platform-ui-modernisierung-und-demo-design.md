# Cross-Platform-UI-Modernisierung und Demo-Bibliothek

## Status

Dieses Dokument beschreibt den am 23.08.2026 freigegebenen Entwurf für die Modernisierung der macOS-, iOS- und iPadOS-App sowie für eine sichere Demo-Bibliothek.
Die Umsetzung erfolgt in mehreren kleinen, überprüfbaren Teilprojekten auf dem bestehenden Branch `codex/ios-open-todos`.
Dieses Dokument selbst ändert noch keinen Produktivcode.

## Ziele

- Häufige Aktionen müssen ohne verborgenes Long-Press, Hover oder Tastaturwissen erreichbar sein.
- Status, Fehler und Wiederherstellung müssen dort sichtbar sein, wo sie entstehen.
- Beide Apps müssen Dynamic Type, VoiceOver, Tastatur, Pointer, hohen Kontrast und Reduce Motion systematisch unterstützen.
- macOS soll native Menüs, konfliktfreie Kurzbefehle, native Suche und ein ehrliches Fenstermodell erhalten.
- iPhone und iPad sollen Transkript und Teilnehmende revisions- und provenienzsicher bearbeiten können.
- Eine kleine synthetische Demo-Bibliothek soll Screenshots und reproduzierbare Smoke-Benchmarks ermöglichen, ohne echte Meetings oder Sprecherprofile zu gefährden.
- Beide Apps sollen englische und deutsche Oberflächen aus String Catalogs erhalten.
- Beide App-Icons sollen das vorhandene Steno-Motiv als moderne Default-, Dark- und Monochrome-Variante erhalten.

## Nicht verhandelbare Invarianten

- Originalaufnahmen werden nie überschrieben.
- Transkriptkorrekturen erzeugen immer neue Revisionen.
- Eine Aufnahme darf durch UI-, Modell- oder Nachverarbeitungsfehler nie verloren gehen.
- Demo-Daten dürfen niemals Stimm-Evidenz, Sprecherprototypen oder Hard Negatives für echte Personen erzeugen.
- Demo-Eigentum wird ausschließlich über gespeicherte Provenienz und feste Manifest-IDs festgestellt.
- Namen, Titelpräfixe und Ordnernamen sind niemals ein Löschkriterium.
- Unbekannter Fortschritt wird nicht als erfundene Prozentzahl dargestellt.
- Ein Abbruch darf nur an fachlich atomaren Grenzen sichtbar werden.
- Echte Nutzerbibliotheken werden in automatisierten Tests und visuellen Prüfungen nicht geöffnet.

## Bestätigte Ausgangslage

- iOS verwendet bewusst eine gemeinsame `NavigationSplitView`, die in kompakter Breite selbstständig zu einem Stack kollabiert.
- Die aktuelle iOS-Auswahl führt Aufnahme, Meetings und Werkzeuge bereits durch einen gemeinsamen `NavigationRouter`.
- Der iOS-Inspector existiert, besitzt für normale Meetings aber keinen ausreichend sichtbaren Touch-Auslöser.
- Ordnerverwaltung und einzelne Meetingaktionen sind auf iOS überwiegend nur über Kontextmenüs erreichbar.
- `Transcribe Again` ist funktional vorhanden und zeigt den persistenten Pipelinezustand, verwendet auf iPad aber eine schlecht platzierte `confirmationDialog`-Darstellung.
- Das iOS-Modell für Installationen besitzt bereits `cancelInstall()`, die sichtbaren Abbruchaktionen fehlen jedoch.
- Die iOS- und macOS-Ansichten zeigen unbekannten Importfortschritt teilweise als determinierten Nullwert.
- Das Löschen eines Textmodell-Endpunkts entfernt auch dessen Keychain-Secret und ist deshalb nicht durch ein oberflächliches UI-Undo wiederherstellbar.
- macOS verwendet derzeit ein `WindowGroup`, obwohl Auswahl und weitere Navigationszustände im einzigen gemeinsamen `AppModel` liegen.
- macOS belegt `Cmd-M` und `Cmd-I` mit app-eigenen Aktionen und ergänzt einen möglichen zweiten `Cmd-N`-Befehl.
- macOS fordert Aufnahmeberechtigungen derzeit beim App-Start an.
- Beide Apps besitzen noch keine String Catalogs.
- Beide Apps verwenden derzeit klassische Raster-App-Icons.
- `Library.commitPreparedMeeting` veröffentlicht vollständig vorbereitete Meetings erst nach einem atomaren Staging-Commit.
- `Library.trashMeeting` verschiebt den vollständigen Meetingordner in den Systempapierkorb.
- `FolderStore.folder(named:)` bietet bereits eine idempotente Get-or-create-Schnittstelle für importartige Abläufe.
- `MeetingMetadata` besitzt Legacy- und Transferprovenienz, aber noch keine Demo-Provenienz.
- `TranscriptOrigin` besitzt noch keinen eigenen Demo-Fall.
- Das AMI Meeting Corpus wird bereits als reale Diarisierungs-Benchmarkgrundlage verwendet.

## Freigegebene Produktentscheidungen

### iOS-Informationsarchitektur

Die bestehende adaptive `NavigationSplitView` bleibt erhalten.
Es wird kein äußerer `.sidebarAdaptable`-TabView ergänzt.
Ein äußerer TabView würde auf iPad mit Ordner-Sidebar, Meetingdetail und Inspector konkurrieren und könnte bis zu vier gleichzeitige Navigationsbereiche erzeugen.
Eine nur auf dem iPhone verwendete zweite Hierarchie wird ebenfalls vermieden, damit Routing und Zustandswiederherstellung auf beiden Breiten identisch bleiben.

### macOS-Fenstermodell

Die App unterstützt bewusst genau ein Hauptfenster.
Das irreführende `WindowGroup` wird durch eine einzelne Hauptfensterszene ersetzt.
Globale Aufnahme-, Bibliotheks- und Jobzustände bleiben im gemeinsamen App-Modell.
Echte unabhängige Mehrfensternavigation ist nicht Teil dieses Vorhabens.

### Demo- und Benchmarkdaten

Die App erhält eine eingebaute synthetische Demo-Bibliothek als ausdrücklich installierbares Produktfeature.
AMI- und CCC-Material wird nicht in die App eingebaut.
AMI bleibt im externen Benchmark-Kit die reale Referenz mit Audio, Transkript und Sprecherannotation.
CCC-Material darf später nach einzelner Lizenzprüfung als externer ASR-Stresstest dienen, aber nicht als Diarisierungs-Ground-Truth.

### Sprachen

Englisch bleibt die Quellsprache.
Alle sichtbaren Oberflächentexte, Accessibility-Texte und relevanten Info.plist-Texte werden vollständig auf Deutsch angeboten.

## Demo-Bibliothek

### Gemeinsamer Kern

Ein neues portables StenoKit-Produkt `StenoDemo` kapselt Manifest, Ressourcenprüfung, Installation, Aktualisierung und Entfernung.
Das Target hängt nur von den erforderlichen Domain- und Library-Targets ab.
Beide Apps verwenden denselben Seeder und bauen keine plattformspezifische Dateischreiblogik nach.
Der Seeder erhält ausschließlich die bereits ausdrücklich geöffnete `Library` und den zugehörigen `FolderStore`.
Der Seeder startet keine Modelle, keine Jobs und keine Netzwerkverbindung.

### Provenienz und Manifest

`MeetingMetadata` erhält eine optionale Demo-Provenienz mit `datasetID`, `datasetVersion` und `itemID`.
`TranscriptOrigin` erhält einen eigenen Demo-Ursprung, damit Demo-Revisionen nicht als Legacy-Import ausgegeben werden.
Das gebündelte Manifest enthält stabile Dataset-, Meeting-, Revisions- und Run-IDs.
Das Manifest enthält feste UTC-Zeitpunkte, erwartete Dateinamen, Dauer, Sample-Rate und SHA-256 jeder Ressource.
Das Manifest enthält Generator-, Modell-, Datensatz- und Lizenzprovenienz.
Ein kleiner atomischer Installationsindex im Bibliotheksroot beschleunigt die Erkennung installierter Versionen.
Bei einem Widerspruch zwischen Index und Meetingmetadaten gewinnt immer die Provenienz des Meetings.

### Installationsablauf

Die erste Installation legt idempotent einen Top-Level-Ordner `Demo Meetings` an oder verwendet einen gleichnamigen vorhandenen Ordner.
Alle Demo-Titel beginnen zusätzlich mit `DEMO:`.
Jedes Meeting wird vollständig als `PreparedMeetingImport` vorbereitet und atomar mit `commitPreparedMeeting` veröffentlicht.
Eine erneute Installation derselben Manifestversion ist ein No-op.
Eine unterbrochene Installation ergänzt nur eindeutig fehlende Manifest-Items.
Kollidiert eine feste Demo-ID mit einem nicht als Demo markierten Meeting, bricht die Installation ohne Mutation ab.
Eine neue Datasetversion wird nur nach der ausdrücklichen Aktion `Demo-Daten ersetzen` installiert.

### Inhalt

Das Dataset enthält drei vollständig synthetische Meetings.
`DEMO: Projektauftakt Musterstadt` enthält Audio, drei Sprecher, Transkript, Notizen und einen fertigen Report.
`DEMO: Wochenrunde Muster GmbH` enthält Audio, Transkript und Notizen, aber noch keinen Report.
`DEMO: Produktinterview` enthält Audio, mehrere kurze Turns und einen fertigen Report.
Die Datumswerte sind fest und liegen sichtbar in einer Demo-Zeitachse, damit Screenshots reproduzierbar bleiben.
Personen- und Firmennamen sind erkennbar fiktiv.

### Audio-Fixture

Mindestens ein Meeting enthält etwa 60 bis 90 Sekunden deutsche Mehrsprecher-Sprache mit klaren Wechseln und kurzen Überlappungen.
Das Audio wird vorgerendert und byte-stabil in das Paket aufgenommen.
Die Erstellung verwendet eine an eine feste Revision gebundene, weiterverteilbare deutschsprachige Piper-Stimme.
Bevorzugt wird das mehrsprechende Modell `de_DE-mls-medium`, dessen Model Card 236 Sprecher und CC BY 4.0 für den zugrunde liegenden Datensatz ausweist.
Piper selbst und das Voice-Repository weisen eine MIT-Lizenz aus.
Die konkrete Modellrevision, die gewählten Speaker-IDs, der Eingabetext, die Generierungsparameter und alle Prüfsummen werden vor Aufnahme des Assets dokumentiert.
Das vorgerenderte Ergebnis erhält eine sichtbare Attribution und einen Änderungsnachweis.
Die Fixture erhält ein manuell geprüftes Referenztranskript und eine Referenz-Sprecherzeitachse.
Die Fixture ist ein reproduzierbarer Pipeline- und Laufzeit-Smoke-Test, aber kein Ersatz für einen Realwelt-Qualitätsbenchmark.

### Schutz der Sprecheridentität

Demo-Meetings legen keine globalen Personen an.
Demo-Meetings legen keine Sprecherprototypen und keine Hard Negatives an.
Der gemeinsame Identitätsablauf lehnt jede Mutation ab, die positive oder negative Stimm-Evidenz aus einem Demo-Meeting erzeugen würde.
Diese Regel wird im Kern beziehungsweise im gemeinsamen fachlichen Mutationspfad erzwungen und nicht nur durch ausgeblendete Buttons.
Importierte Textlabels dürfen für die reine Darstellung verwendet werden.
Eine erneute Transkription eines Demo-Meetings darf Cluster erzeugen, aber deren Bestätigung als reale Person bleibt gesperrt und wird erklärt.

### Bearbeitete Demo-Meetings

Ein Demo-Meeting bleibt auch nach Umbenennen oder Verschieben anhand seiner Provenienz ein Demo-Meeting.
Nutzerkorrekturen bleiben reguläre neue Revisionen.
`Demo-Daten ersetzen` überschreibt niemals ein Meeting mit Nutzerrevisionen stillschweigend.
Bei bearbeiteten Demo-Meetings bietet die UI entweder Behalten oder ausdrücklich bestätigtes Ersetzen an.
`Demo-Daten entfernen` nennt ausdrücklich, dass auch Nutzeränderungen in diesen markierten Demo-Meetings in den Papierkorb verschoben werden.

### Entfernung

Nur Meetings mit passender Demo-Provenienz und Manifestzuordnung werden entfernt.
Jedes entfernte Demo-Meeting wird mit `Library.trashMeeting` in den Systempapierkorb verschoben.
Der Demo-Ordner wird nur entfernt, wenn der Seeder ihn selbst erzeugt hat, er leer ist und keine Unterordner enthält.
Ein reales Meeting in `Demo Meetings` bleibt unangetastet und verhindert die Ordnerentfernung.
Ein reales Meeting mit einem Titelpräfix `DEMO:` bleibt unangetastet.

### Demo-Oberfläche

Beide Apps erhalten in den Einstellungen einen Abschnitt `Demo-Daten`.
Die Aktionen heißen `Demo-Meetings installieren`, `Demo-Daten ersetzen` und `Demo-Daten entfernen`.
Die Installation erklärt vorher, dass ausschließlich lokale synthetische Daten angelegt werden und kein Modell oder Netzwerk verwendet wird.
Demo-Meetings erhalten in Sidebar und Detailansicht ein sichtbares `Demo`-Badge.
Das Titelpräfix bleibt zusätzlich bestehen, damit Demo-Herkunft auch in Exporten und älteren App-Versionen erkennbar ist.

## iOS und iPadOS

### Auffindbare Aktionen

Die Sidebar erhält einen sichtbaren `New Meeting`-Button, der denselben sicheren Aktionspfad wie der vorhandene Command verwendet.
Die Meeting-Toolbar erhält einen sichtbaren Inspector-Toggle.
Ordnerzeilen erhalten einen sichtbaren Ellipsen-Button mit den bereits vorhandenen Folderaktionen.
Das sichtbare Meeting-Menü erhält `Move to Folder`.
Kontextmenüs bleiben als schneller zweiter Zugangsweg erhalten.
Sichtbare Menüs und Kontextmenüs verwenden dieselben Präsentationsregeln und dieselben Mutationsmethoden.

### Erneute Transkription

`Transcribe Again` verwendet auf iPhone und iPad einen `.alert` statt einer positionsabhängigen `confirmationDialog`.
Der Alert nennt die neue Diarisierung, neu vergebene Cluster-Kennungen und die erneut nötige Sprecherbestätigung.
Der Alert erklärt, dass das vorhandene Transkript als Revision erhalten bleibt.
Der Alert erklärt, dass Nutzerkorrekturen nicht still überschrieben werden.
Nach dem Einreihen erscheint sofort der persistierte Pipelinezustand.

### Dynamic Type

Der Aufnahmetimer verwendet einen semantischen Textstil mit gerundetem Design und monospaced digits.
Der Recording-Strip verwendet `ViewThatFits`, `AnyLayout` oder eine gleichwertige vertikale Alternative für Accessibility-Größen.
Transkriptzeitstempel verlieren ihre starre Breite und wandern bei Bedarf über den Text.
Dichte Endpoint-, Fortschritts- und Aktionszeilen erhalten stapelbare Layouts.
Die relevanten Ansichten werden mindestens bis `.accessibility5` geprüft.

### VoiceOver

Die Aufnahmedauer besitzt ein Label und einen vollständig ausgesprochenen Wert.
Der Pegelmesser wird als ein Element mit dem Label `Microphone level` zusammengefasst.
Der Pegelwert wird stabil in Zustände wie `silent`, `low`, `normal`, `high` und `clipping` gebündelt.
Kontinuierliche Pegeländerungen erzeugen keine fortlaufenden VoiceOver-Ansagen.
Aufnahme-, Stop-, Zurück- und Inspector-Aktionen erhalten eindeutige Labels und Hints.

### Mikrofonberechtigung

Der verweigerte Zustand erklärt, warum die Aufnahme blockiert ist.
Der verweigerte Zustand bietet `Open Settings` über die System-URL der App-Einstellungen.
Nach der Rückkehr in die App wird der Berechtigungszustand erneut gelesen.
Der Wiederherstellungsweg erscheint sowohl in Audio Readiness als auch beim fehlgeschlagenen Aufnahmestart.

### Modellinstallation

Laufende Speech-, Diarisierungs- und Parakeet-Installationen erhalten einen sichtbaren Abbruchknopf.
Ein kurzer `Cancelling`-Zustand verhindert Mehrfachaktionen.
Die bestehende Zustimmung bleibt nach einem Abbruch erhalten.
Ein unvollständiges oder nicht verifiziertes Modell gilt niemals als installiert.
Wenn noch kein messbarer Callback existiert, zeigt die UI einen unbestimmten `Preparing`-Zustand.

### Startup und Recovery

Die primäre Fläche unterscheidet `Opening`, `Ready` und `Failed`.
Ein Fehler bleibt sichtbar und bietet `Try Again`, solange kein neuer Bootstrap läuft.
Recovery wird nicht neu implementiert, sondern verwendet die vorhandenen Startup-, Job- und Capture-Recovery-Pfade.
Der bekannte Statuswechsel von `.unavailable` zu `.ready` oder `.modelsRequired` lädt die neue Revision zuverlässig nach.

### Textmodell-Endpunkte

Das Löschen eines Endpunkts verlangt eine Rückfrage mit Name und Host.
Die Rückfrage nennt die endgültige Entfernung des Keychain-Secrets und die Folgen für gepinnte zukünftige Jobs.
Es wird kein unechtes Undo angeboten.
URL, Modell-ID, Profil und API-Key erhalten passende Tastatur-, Großschreibungs- und Autokorrekturregeln.
Der Editor verwendet `FocusState` mit Next und Done.
Der API-Key wird als sensibler Inhalt markiert.

### Importfortschritt

Fehlende oder nicht positive Gesamtgrößen verwenden einen unbestimmten `ProgressView`.
Erst ein belastbarer positiver Gesamtwert wechselt zu einer determinierten Darstellung.

### Mobile Bearbeitungsparität

Jede Transkriptzeile erhält eine explizite Korrekturaktion.
Speichern setzt auf der aktuellen Revision auf und erzeugt eine neue Nutzerrevision.
Revisionskonflikte werden sichtbar gemeldet und überschreiben nichts.
Teilnehmende werden über einen touchgerechten Sheet-Ablauf hinzugefügt oder entfernt.
Gesprochene und zusätzlich angegebene stille Teilnehmende bleiben fachlich getrennt.
Teilnehmerpflege erzeugt keine automatische Stimm-Evidenz.
`Cmd-F` fokussiert auf dem iPad die Transkriptsuche.
Full Keyboard Access erhält eine vollständige und sichtbare Fokusreihenfolge.

### Teilen und Datenschutz

Die Freigabe von Reporttext nennt vor dem ersten Teilen die tatsächlich austretende Datenklasse.
Paketfreigaben nennen weiterhin getrennt, ob Audio enthalten ist.
Stimm-Evidenz und Embeddings werden niemals geteilt.
Harmlose rein lokale Aktionen erhalten keinen zusätzlichen Bestätigungsdialog.

## macOS

### Hauptfenster

Die Hauptszene wird als einzelne `Window`-Szene modelliert.
Onboarding-, Legacy-Import- und Settings-Fenster bleiben eigene zweckgebundene Szenen.
`Cmd-N` bezeichnet eindeutig `New Meeting` und öffnet kein weiteres Hauptfenster.

### Menüs und Commands

Ein eigener Commands-Typ bündelt Recording-, File-, Meeting-, Edit- und View-Befehle.
Kontextabhängige Aktionen werden über fokussierte Werte an die aktive Ansicht gebunden.
Die Menüleiste erhält Paketimport, Audioimport, Export, Teilen, Inspector, Transkriptsuche, Umbenennen, Verschieben, erneute Transkription und Papierkorb.
Folderaktionen werden dort angeboten, wo eine passende Folderauswahl existiert.
Kontextmenüs bleiben als Abkürzung erhalten.
`Cmd-M` bleibt der Systemaktion `Minimize` vorbehalten.
`Cmd-I` wird nicht für Audioimport umgewidmet.
`Cmd-.` bleibt der Stopbefehl.
`Cmd-N` bleibt `New Meeting`.
Marker und Import erhalten konfliktfreie Kombinationen mit zusätzlichen Modifiern.

### Toolbar und Suche

Die Sidebar verwendet native `.searchable`-Integration mit Sidebar-Platzierung.
Die Transkriptsuche bleibt eine eigene kontextuelle Suche mit `Cmd-F`.
Das Settings-Zahnrad wird aus der Haupttoolbar entfernt.
Importaktionen werden in einem Importmenü gebündelt.
Häufige Aufnahme- und Inspectoraktionen bleiben sichtbar.
Weitere Items erhalten stabile Toolbar-IDs und sinnvolle Standard-Sichtbarkeit.

### Berechtigungen

Der App-Start liest nur bestehende Berechtigungszustände.
Die eigentliche Anfrage erfolgt nach einer erklärenden Onboarding- oder Aufnahmeaktion.
Der Systemaudio-Probelauf startet nicht ungefragt beim allgemeinen App-Start.

### Bootstrap und Notizen

Bootstrapfehler werden als dauerhafter inhaltlicher Zustand mit passender Retry-Aktion gezeigt.
Der Retry unterscheidet vollständigen Runtime-Neustart von erneutem Listen- oder Ordnerladen.
macOS-Notizen erhalten sichtbare Lade-, Fehler-, Retry- und Speicherzustände nach dem bereits vorhandenen iOS-Muster.

### Status und Fehler

Kritische globale Fehler erscheinen oben in der Hauptfläche.
Meetingbezogene Pipelinefehler erscheinen direkt beim Meetingstatus.
Unkritischer Exportfortschritt darf in einer unteren Statusfläche verbleiben.
Eigene Bewegungsanimationen berücksichtigen `accessibilityReduceMotion`.

### Transkriptkorrektur

Der Korrekturknopf wird bei Hover oder Tastaturfokus sichtbar.
Eine fokussierte Zeile erhält eine Menü- oder Kontextaktion `Correct Line`.
Speichern und Abbrechen bleiben per Tastatur erreichbar.

### Legacy-Import

Das Importmodell hält den laufenden Task und bietet `Cancel`.
Der Importer prüft Cancellation vor und nach Vorbereitung sowie zwischen atomaren Meeting-Commits.
`CancellationError` wird nie als übersprungenes Meeting oder allgemeine Warnung verschluckt.
Bereits vollständig importierte Meetings bleiben erhalten.
Ein erneuter Lauf erkennt bereits importierte Meetings anhand der bestehenden Provenienz.
Der Abschluss zeigt bei Abbruch einen ehrlichen Teilbericht.

### Endpunkte und Fortschritt

Textmodell-Endpunkte verwenden dieselbe bestätigte Löschsemantik wie iOS.
Unbekannter Import- und Modellfortschritt wird unbestimmt dargestellt.
Laufende Modellinstallationen erhalten einen sichtbaren Abbruch, ohne die bereits erteilte Zustimmung zu widerrufen.
Die Modellseite zeigt im fertigen Zustand keine widersprüchliche Aufforderung `Allow and install`.

### Kleine native Korrekturen

Share-Aktionen verwenden das Share-Symbol statt des AirPlay-Symbols.
Leere Ansichten verwenden einen inhaltlichen Fenstertitel wie `Meetings` statt des redundanten App-Namens.
Create- und Rename-Aktionen bleiben bei leerer oder nur aus Leerzeichen bestehender Eingabe deaktiviert.
Validierungsfehler bleiben beim Eingabedialog.

## Lokalisierung

macOS und iOS erhalten jeweils einen eigenen `Localizable.xcstrings`-Katalog.
Info.plist-relevante Nutzungserklärungen erhalten eine kataloggestützte englische und deutsche Fassung.
SwiftUI-Literale werden durch Xcodes String-Catalog-Extraktion erfasst, soweit die API dies unterstützt.
Dynamische Präsentationstexte verwenden `LocalizedStringResource` oder `String(localized:)`.
Niedrigstufige technische Fehler werden in der App-Schicht auf nutzbare lokalisierte Texte abgebildet.
Technische IDs, Dateinamen, Logzeilen und persistierte Enumwerte werden nicht lokalisiert.
Tests mit Textvergleichen setzen die Locale ausdrücklich auf Englisch oder Deutsch.
Die breite Katalogmigration erfolgt erst nach Stabilisierung der neuen UI-Texte.

## App-Icons

Das vorhandene Steno-Motiv bleibt erhalten und wird nicht neu gebrandet.
Das Zeichen wird als saubere mehrschichtige Vektorquelle rekonstruiert.
Beide Apps erhalten Default-, Dark- und Monochrome beziehungsweise Tinted-Varianten über Icon Composer.
Das neue Asset wird zunächst parallel gebaut und mit `actool`, Simulator und Gerät geprüft.
Die klassischen AppIcon-Sets werden erst nach erfolgreicher Build- und Sichtprüfung ersetzt.

## Fehler- und Abbruchsemantik

Ein Modelldownloadabbruch hinterlässt Zustimmung, aber keinen installierten oder auswählbaren Teilzustand.
Ein Legacy-Importabbruch behält nur bereits atomar veröffentlichte Meetings.
Ein Demo-Installationsfehler veröffentlicht keine halben Meetingverzeichnisse.
Eine zwischen zwei Meeting-Commits unterbrochene Datasetinstallation wird als unvollständig erkannt und beim nächsten ausdrücklichen Installationsversuch idempotent ergänzt.
Ein Demo-ID-Konflikt mit echten Daten bricht geschlossen und ohne Überschreiben ab.
Ein fehlgeschlagener Demo-Ordner-Cleanup macht erfolgreich in den Papierkorb verschobene Meetings nicht wieder sichtbar.
Ein Endpunkt wird erst nach bestätigter Rückfrage durch den bestehenden transaktionalen Löschpfad entfernt.
Ein Bootstrap-Retry löscht die sichtbare Fehlermeldung nur für die Dauer eines tatsächlich laufenden neuen Versuchs.

## Implementierungsreihenfolge

### Teilprojekt 1: Demo-Grundlage

- Demo-Provenienz, Manifest, Kern-Target und atomare Lifecycle-Operationen.
- Synthetische Audio-, Transkript-, Notiz- und Report-Fixtures.
- Identitätsausschluss und Demo-Badges.
- Installieren, Ersetzen und Entfernen in beiden Apps.

### Teilprojekt 2: iOS-Auffindbarkeit und Accessibility

- Sichtbare Meeting-, Inspector-, Folder- und Move-Aktionen.
- Zentrierter Retranskriptionsalert.
- Dynamic Type, VoiceOver und Open Settings.
- Ehrliche Fortschrittsdarstellung und sichtbarer Downloadabbruch.

### Teilprojekt 3: Recovery und lange Operationen

- Typisierte Bootstrapzustände und Retry auf beiden Plattformen.
- Zuverlässiges Revisionsnachladen.
- macOS-Notizen-Recovery.
- Legacy-Import-Cancellation.
- Endpunktbestätigung und Datenschutzcopy.

### Teilprojekt 4: macOS-Bedienmodell

- Bewusste Einfenster-Szene.
- Vollständige Menüs, fokussierte Commands und konfliktfreie Shortcuts.
- Native Sidebar-Suche und aufgeräumte anpassbare Toolbar.
- Sichtbare Tastaturkorrektur und native kleine UI-Korrekturen.

### Teilprojekt 5: Mobile Bearbeitungsparität

- Revisionssichere Transkriptkorrektur.
- Teilnehmerpflege.
- iPad-Suche, Fokus und Endpoint-Eingabesemantik.

### Teilprojekt 6: Lokalisierung, Icons und Gesamt-QA

- Englische und deutsche String Catalogs.
- Icon-Composer-Assets für beide Apps.
- Accessibility-Regressionstests und vollständige manuelle Matrix.

## Teststrategie

Jedes Teilprojekt beginnt mit fokussierten fehlschlagenden Tests für die neue Präsentations- oder Domänenregel.
Reine View-Präsentation wird über kleine Policy- und HostingController-Tests abgesichert.
Kernänderungen erhalten temporäre Libraries und dürfen niemals die echte Mac-Bibliothek öffnen.
Demo-Tests prüfen Manifesthashes, feste IDs, atomare Installation, No-op-Wiederholung, Resume, Konflikt, Replace und sichere Entfernung.
Demo-Tests beweisen, dass keine Jobs, Personen, Prototypen oder Hard Negatives entstehen.
Importtests prüfen Cancellation vor Vorbereitung, zwischen Commits und beim Wiederanlauf.
Accessibility-Tests prüfen formatierte Werte, Layout bei `.accessibility5` und stabile Accessibility-Identifikatoren.
Commandtests prüfen Verfügbarkeit und Eindeutigkeit der Shortcut-Tabelle.
Lokalisierungstests prüfen kritische englische und deutsche Texte mit fest gesetzter Locale.

Während der Entwicklung laufen fokussierte Tests der betroffenen Targets.
Nach dem konsolidierten Gesamtstand laufen genau die vier vollständigen Suiten aus `AGENTS.md`.
Vor den Xcode-Suiten werden beide Projekte mit `xcodegen generate` neu erzeugt.

```sh
swift test --package-path StenoKit

xcodebuild -project Steno.xcodeproj -scheme Steno \
  -destination 'platform=macOS' test

cd iOS && xcodebuild -project StenoiOS.xcodeproj -scheme Steno \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath build/DerivedData test

cd iOS/StenoiOSKit && xcodebuild -scheme StenoiOSKit \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
```

## Manuelle Abnahme

- iPhone in Standardgröße und `.accessibility5`.
- iPad in Vollbild, Split View, Hochformat und Querformat.
- macOS bei Mindestgröße und normaler Fenstergröße.
- VoiceOver auf Aufnahme, Pegel, Meetingliste, Transkriptkorrektur und Alerts.
- Full Keyboard Access und Pointer auf iPad.
- Tastaturmenüs, Fokus und Kurzbefehle auf macOS.
- Dark Mode, Increase Contrast, Differentiate Without Color und Reduce Motion.
- Mikrofon zuerst ablehnen und anschließend über `Open Settings` wieder aktivieren.
- Modellinstallation starten und abbrechen.
- Bootstrap und Recovery mit einer isolierten beschädigten Testbibliothek.
- Demo installieren, bearbeiten, umbenennen, verschieben, ersetzen und entfernen.
- Default-, Dark- und Monochrome-App-Icons auf Simulator und mindestens einem Gerät.

## Gemessen und angenommen

### Gemessen oder am Quelltext bestätigt

- Die vorhandenen Navigations-, Store-, Commit-, Papierkorb-, Cancellation- und Fensterpfade wurden im aktuellen Quellstand geprüft.
- Die fehlenden String Catalogs und klassischen Rastericons wurden im Repository bestätigt.
- Das AX5-Layoutproblem wurde zuvor in iPhone- und iPad-Laufzeitansichten beobachtet.
- Der hohe Offline-Model-Row-Container wurde auf die SwiftUI-Listenzeile um den undurchsichtigen ViewBuilder eingegrenzt und bereits separat behoben.
- AMI veröffentlicht Signale und Annotationen unter CC BY 4.0.
- CCC weist darauf hin, dass die Lizenz pro Mediendatei gilt.
- Die Piper-Model-Card für `de_DE-mls-medium` nennt 236 Sprecher und CC BY 4.0 für den Datensatz.

### Erst in der Umsetzung oder manuellen Abnahme zu bestätigen

- Die genaue Systemposition eines SwiftUI-Alerts auf jedem iPad-Fensterformat.
- Die tatsächliche VoiceOver-Ausgabe und Fokusreihenfolge auf Geräten.
- Das Verhalten der neuen Icon-Varianten auf realen Home-Screen- und Dock-Darstellungen.
- Die akustische Eignung der gewählten synthetischen Sprecher für ASR- und Diarisierungs-Smoke-Tests.
- Die visuelle Qualität langer deutscher Texte in allen kompakten Layouts.
- Hardwareabhängige SpeechTranscriber- und Modellinstallationszustände.

## Übernommene Zweitmeinung von Claude Fable

Claude Fable prüfte die Leitdokumente und den Entwurf read-only ohne Zugriff auf echte Meetingdaten.
Übernommen wurde die Empfehlung, die Demo-Fixture vor den breiten UI-Umbauten zu bauen.
Übernommen wurde die Empfehlung, Recovery als eigenes Kernteilprojekt statt als beiläufiges UI-Detail zu behandeln.
Übernommen wurde die Empfehlung, AMI und CCC im Benchmark-Kit und nicht in der Produktoberfläche zu halten.
Übernommen wurde der Hinweis, Demo-Stimmen vollständig von globaler Identitäts-Evidenz auszuschließen.
Übernommen wurde der Hinweis, den bekannten Revisions-Nachladefehler gemeinsam mit Recovery zu schließen.
Nicht übernommen wurde ein späteres Bereinigen bereits erzeugter Demo-Evidenz als Normalweg.
Der Entwurf verhindert solche Evidenz stattdessen vor ihrer Erzeugung.
Claude Fable las aus Budgetgründen nicht jede View- und Store-Datei vollständig.
Die konkreten Aussagen zu Navigation, Fenstern, Store-APIs und Abbruchpfaden wurden deshalb zusätzlich im lokalen Quellbaum geprüft.

## Externe Quellen

- [Apple Human Interface Guidelines: Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)
- [Apple Human Interface Guidelines: Context menus](https://developer.apple.com/design/human-interface-guidelines/context-menus)
- [Apple Human Interface Guidelines: Keyboards](https://developer.apple.com/design/human-interface-guidelines/keyboards)
- [Apple Human Interface Guidelines: Privacy](https://developer.apple.com/design/human-interface-guidelines/privacy)
- [Apple Human Interface Guidelines: Progress indicators](https://developer.apple.com/design/human-interface-guidelines/progress-indicators)
- [CCC-Medien und Lizenzhinweise](https://media.ccc.de/about.html)
- [AMI Meeting Corpus License](https://groups.inf.ed.ac.uk/ami/corpus/license.shtml)
- [AMI Corpus Download und Annotationen](https://groups.inf.ed.ac.uk/ami/download/)
- [Piper `de_DE-mls-medium` Model Card](https://huggingface.co/rhasspy/piper-voices/blob/main/de/de_DE/mls/medium/MODEL_CARD)
- [Piper MIT License](https://github.com/rhasspy/piper/blob/master/LICENSE.md)

## Nicht Teil dieses Vorhabens

- Ein äußerer iOS-TabView oder eine zweite iPhone-Navigationshierarchie.
- Unabhängige macOS-Mehrfensternavigation.
- Automatische Installation von Demo-Daten.
- Netzwerkdownload von Demo- oder Benchmarkmaterial in der App.
- AMI- oder CCC-Aufnahmen als eingebauter Produktinhalt.
- Aussagekräftige Realwelt-WER- oder DER-Zusagen auf Basis der synthetischen Fixture.
- Änderungen an Verschlüsselung oder Synchronisation der echten Bibliothek.
- Push, Merge oder Veröffentlichung.

## Abnahmekriterium

Das Vorhaben ist abgeschlossen, wenn alle freigegebenen UI-, Recovery-, Demo-, Lokalisierungs- und Iconänderungen implementiert sind, die fokussierten Tests grün sind, die vier vollständigen Suiten erfolgreich gelaufen sind und die verbleibenden manuellen Hardwarebefunde klar als gemessen oder offen dokumentiert wurden.
