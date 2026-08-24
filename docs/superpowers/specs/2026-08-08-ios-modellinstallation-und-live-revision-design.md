# iOS-Modellinstallation und Live-Revisionsnachweis

Stand: 2026-08-08.
Verfasser: Codex, nach abschnittsweiser fachlicher Freigabe.

## Ziel

Die iOS-App installiert das fuer die gewaehlte Transkriptionssprache benoetigte Apple-Sprachmodell nur nach ausdruecklicher Zustimmung.
Ein fehlendes oder fehlerhaftes Modell verhindert niemals die Aufnahme.
Der Stop-Pfad wird automatisiert und auf echter Hardware darauf geprueft, dass ein vorhandenes Live-Transkript als provisorische Revision erhalten bleibt und genau ein finaler ASR-Lauf eingereiht wird.

## Entscheidungen

1. iOS installiert in Meilenstein i1 nur das Apple-Sprachmodell fuer die Transkription.
2. Das Diarisierungsmodell bleibt bis Meilenstein i2 ausserhalb des iOS-Installationsumfangs.
3. Die vorhandenen Vertraege `ModelInstalling`, `SpeechAssetInstaller` und `ModelInstallationCoordinator` werden wiederverwendet.
4. Der iOS-Koordinator wird mit genau einem `SpeechAssetInstaller` aufgebaut und verwendet nicht `ModelInstallationCoordinator.standard`, weil die Standardzusammenstellung zusaetzlich das Diarisierungsmodell enthaelt.
5. Aufnahmebereitschaft und Modellbereitschaft bleiben getrennte Zustaende.
6. Fehlende Modelle deaktivieren nur Live- und Final-Transkription, nie den Audiopfad.
7. Ein Modell wird weder durch einen Provider noch im Hintergrund ohne vorherigen Klick nachgeladen.
8. Eine laufende Aufnahme wird fuer Installation, Sprachwechsel oder Pipeline-Neustart niemals beendet.

## Nicht in diesem Paket

- Installation oder Pruefsummenpruefung der Diarisierungsmodelle auf iOS.
- Diarisierung, Sprecheridentitaet oder Hintergrundverarbeitung aus Meilenstein i2.
- Ein vollstaendiger iOS-Erstlauf-Wizard.
- Eine gemeinsame SwiftUI-Schicht fuer macOS und iOS.
- Aenderungen am macOS-Verhalten der Modellinstallation.
- Nachtraegliche Live-Transkription bereits aufgenommener Audiodaten.

## Architektur

### Modellzustand

Die iOS-App bekommt eine kleine, `@MainActor`-isolierte Zustandskomponente fuer die Modellinstallation.
Sie besitzt den `ModelInstallationCoordinator`, die gespeicherte Zustimmung, die Bereitschaft fuer die aktuell gewaehlte Locale, den Fortschritt und eine sichtbare Fehlermeldung.
`AppModel` bindet diese Komponente an den Prozesszustand und sorgt dafuer, dass ein Sprachwechsel ihre Bereitschaft neu prueft.

Der Koordinator wird so aufgebaut:

```swift
ModelInstallationCoordinator(
    installers: [SpeechAssetInstaller(assets: SystemSpeechAssets())]
)
```

Damit bleiben Zustimmungsschranke, Fortschritt, Serialisierung und Abbruch aus dem gemeinsamen Kern erhalten, ohne das in i1 ungenutzte Diarisierungsmodell herunterzuladen.

Die Zustandskomponente erhaelt ihre Abhaengigkeiten ueber den Initializer.
Tests verwenden dadurch einen kontrollierten `SpeechAssetGateway` und weder Netz noch Apple-Systemdownloads.

### Zustimmung

Die Zustimmung lebt wie auf dem Mac in der App-Schicht und nicht in StenoKit.
Gespeichert werden Zeitpunkt und die konkret angezeigte Quelle `Apple`, nicht nur ein boolescher Wert.
Widerruf verhindert kuenftige Downloads und bricht einen laufenden Installationsauftrag ab.
Bereits installierte Systemassets werden nicht geloescht und bleiben verwendbar.

### Oberflaeche

Die vorhandene Audio-Bereitschaftsansicht bleibt der zentrale Ort fuer Diagnose und Installation.
Sie zeigt fuer die aktuell gewaehlte Sprache:

- den Modellnamen, die Quelle Apple und die dokumentierte ungefaehre Groesse,
- `Checking`, `Ready`, `Not installed`, `Installing` oder einen konkreten Fehler,
- die Aktion `Allow and install`,
- Fortschritt und Widerruf.

Der Aufnahmebildschirm zeigt bei fehlendem Modell klar `Recording without transcription` und einen Weg zur Installationsansicht.
Der Aufnahmeknopf bleibt aktiv, sofern Mikrofon, Speicher und Bibliothek bereit sind.
Waehrend einer laufenden Aufnahme wird kein neuer Installationsauftrag begonnen, damit Download und Assetvorbereitung nicht mit dem unersetzlichen Capture-Pfad konkurrieren.
Der Hinweis bleibt sichtbar und die Aktion wird nach dem Stop wieder verfuegbar.

### Sprachwechsel und Pipeline

Ein Sprachwechsel bleibt waehrend einer Aufnahme gesperrt.
Nach einem Sprachwechsel wird zuerst die Modellbereitschaft fuer die neue Locale geprueft.
Bereits installierte Assets werden nicht nochmals geladen.

Nach erfolgreicher Installation wird die Pipeline fuer die aktuell gewaehlte Sprache kontrolliert neu aufgebaut.
Sprachwechsel und Installationsabschluss rufen dafuer dieselbe private, task-serialisierte Neustartfunktion auf.
So koennen Installation und Sprachwechsel nicht zwei `PipelineCoordinator`-Instanzen auf derselben dateibasierten Warteschlange starten.

Eine bereits laufende Aufnahme wird nicht auf eine neue Live-Session umgeschaltet.
Da Installationen waehrend der Aufnahme nicht beginnen, erfolgt der Pipeline-Neustart nur im inaktiven Zustand.

## Datenfluss

### App-Start

1. `AppModel.bootstrap()` laedt die ausdruecklich gewaehlte Sprache.
2. Die Bibliothek und Pipeline starten weiterhin auch ohne installiertes Sprachmodell.
3. Der Modellzustand prueft die Bereitschaft fuer genau diese Locale.
4. Die Oberflaeche zeigt den Zustand, startet aber keinen Download.

### Installation

1. Der Nutzer oeffnet die Installationsansicht und sieht Modell, Quelle und ungefaehre Groesse.
2. `Allow and install` speichert die Zustimmung fuer Apple-Systemassets.
3. Der Modellzustand setzt synchron den Zustand `installing`, bevor der erste Suspendierungspunkt erreicht wird.
4. Der Koordinator installiert genau ein Sprachasset fuer die gewaehlte Locale.
5. Fortschrittsrueckrufe werden auf dem Hauptaktor monoton angewendet.
6. Nach Erfolg wird die Bereitschaft erneut gelesen.
7. Fehlgeschlagene `finalASR`-Jobs werden nur dann erneut eingereiht, wenn ihre gespeicherte Fehlermeldung exakt `TranscriptionError.assetsNotInstalled` fuer diese Locale entspricht.
8. Andere fehlgeschlagene Jobs bleiben unangetastet.
9. Die inaktive Pipeline wird einmal fuer dieselbe Locale neu aufgebaut und verarbeitet die gezielt zurueckgestellten Jobs.

### Aufnahme ohne Modell

1. `RecordingModel.start` startet zuerst und unabhaengig den Audiopfad.
2. Der Live-Provider meldet ein fehlendes Asset als Transkriptionsfehler.
3. Die Audioaufnahme laeuft weiter und zeigt `Recording without transcription`.
4. Beim Stop wird die Originalspur registriert.
5. Auch ohne Live-Ausgabe wird genau ein `finalASR`-Job eingereiht, damit eine spaetere Modellinstallation den reproduzierbaren Verarbeitungspfad offenhaelt.

### Stop mit Live-Ausgabe

Der persistente Teil des Stop-Pfads zieht in einen kleinen `RecordingFinalizer`-Aktor.
Sie bekommt `MeetingID`, optionalen `TranscriptOutput`, `Library` und `JobStore`.
Bei nicht leerer Live-Ausgabe erzeugt sie mit `TranscriptMapper` genau eine Revision mit Ursprung `.liveProvisional` und haengt sie an die Bibliothek an.
Danach reiht sie genau einen `Job(kind: .finalASR, meetingID: ...)` ein.
Bei leerer oder fehlender Live-Ausgabe ueberspringt sie nur die Revision und reiht den finalen Job trotzdem ein.

Der Aktor teilt gleichzeitige Abschlussaufrufe fuer dasselbe Meeting ueber einen gemeinsamen Task.
Nach erfolgreichem Abschluss merkt er das Meeting fuer die Lebensdauer des Prozesses als fertig und ignoriert spaetere doppelte Aufrufe.
Nach einem Fehler wird es nicht als fertig markiert, damit derselbe Abschluss kontrolliert wiederholt werden kann.
Nach einem Prozessabbruch uebernimmt weiterhin `CaptureRecovery`, weil der In-Memory-Schutz bewusst keine Crash-Recovery ersetzt.

Die vorhandene `stopTask`-Serialisierung in `RecordingModel` bleibt die aeussere Genau-einmal-Schranke fuer Knopf, Selbststop und Unterbrechung.

## Fehlerverhalten

- Fehlende Zustimmung startet keinen Download und veraendert die Aufnahmebereitschaft nicht.
- Netz-, Apple-Asset-, Speicher- oder Installationsfehler bleiben sichtbar und erneut versuchbar.
- Ein Installationsfehler stoppt keine Aufnahme und entfernt keine vorhandenen Assets.
- Widerruf waehrend der Installation fordert den Abbruch an und zeigt keinen roten Fehler fuer die bewusste Nutzeraktion.
- Zwei schnelle Installationsklicks teilen denselben Auftrag und starten keinen zweiten Download.
- Ein Sprachwechsel und ein Installationsabschluss koennen nicht gleichzeitig zwei Pipeline-Neustarts ausloesen.
- Nach erfolgreicher Installation werden nur Final-ASR-Fehler wegen des fuer diese Locale fehlenden Sprachmodells erneut eingereiht.
- Scheitert das Schreiben der Live-Revision oder das Einreihen des finalen Jobs, bleibt der Fehler im Aufnahmezustand sichtbar.
- Ein Fehler nach erfolgreicher Registrierung der Originalspur darf niemals behaupten, das Audio sei verloren.
- Ein fehlendes Live-Ergebnis ist kein Fehler des Stop-Pfads.

## Tests

### Modellzustand ohne Netz

Ein kontrollierter `SpeechAssetGateway` belegt:

- installiertes Asset ergibt `Ready` und startet keinen Download,
- fehlendes Asset ergibt `Not installed`,
- fehlende Zustimmung ruft `install` nicht auf,
- Zustimmung startet genau einen Installationsauftrag,
- zwei schnelle Aufrufe starten genau einen Auftrag,
- Fortschritt laeuft innerhalb eines Auftrags nur vorwaerts,
- Erfolg liest die Bereitschaft neu und fordert genau einen Pipeline-Neustart an,
- Erfolg stellt nur Final-ASR-Jobs mit dem exakten Fehlertyp `assetsNotInstalled` fuer die aktuelle Locale zurueck auf `queued`,
- andere fehlgeschlagene Jobs bleiben unveraendert,
- Fehler bleibt sichtbar und erneut versuchbar,
- Widerruf bricht ab und verhindert weitere Auftraege,
- ein Sprachwechsel prueft die neue Locale getrennt.

### Revisionspersistenz gegen eine echte Temp-Bibliothek

Integrationstests verwenden `Library.open` und `JobStore` gegen ein Wegwerfverzeichnis.
Sie belegen:

- nicht leere Live-Ausgabe erzeugt genau eine aktuelle `.liveProvisional`-Revision,
- die Revision gehoert zum aufgezeichneten Meeting und enthaelt die gemappten Bloecke,
- derselbe Abschluss reiht genau einen `finalASR`-Job ein,
- fehlende Live-Ausgabe erzeugt keine leere Revision und reiht trotzdem genau einen `finalASR`-Job ein,
- ein zweiter Stop-Aufruf erzeugt weder eine zweite Revision noch einen zweiten Job.

Die Tests liegen in einem neuen Xcode-Testtarget `StenoTests`, das vom iOS-App-Target erzeugt wird und dessen interne Zustandskomponenten per `@testable import Steno` prueft.

### Vollstaendige lokale Verifikation

Nach der Umsetzung laufen:

```text
swift test --package-path StenoKit
cd iOS/StenoiOSKit && xcodebuild -scheme StenoiOSKit -destination 'platform=iOS Simulator,name=iPhone 17' test
xcodegen generate && scripts/build-app.sh
scripts/build-ios.sh
```

Das neue iOS-App-Testtarget `StenoTests` laeuft im selben Simulatorlauf zusaetzlich.
Eine Aenderung im StenoKit-Kern erfordert weiterhin die vollstaendige Kette aus macOS-Build, iOS-Build und allen StenoKit-Tests.

## Geraeteabnahme

Der automatisierte Nachweis ersetzt den Geraetetest nicht.
Auf einem echten iPhone werden zwei kurze Durchlaeufe geprueft.

### Mit installiertem Sprachmodell

1. Aufnahme starten und auf sichtbaren Live-Text warten.
2. Aufnahme stoppen.
3. Meeting oeffnen und die provisorische Revision lesen.
4. App vollstaendig beenden und neu starten.
5. Dasselbe Meeting erneut oeffnen und bestaetigen, dass der Text weiterhin sichtbar ist.
6. Bestaetigen, dass genau ein finaler ASR-Lauf eingereiht wurde.

### Mit fehlendem Sprachmodell

1. Eine Sprache ohne installiertes Asset waehlen.
2. Bestaetigen, dass kein Download ohne Klick beginnt.
3. Aufnahme starten und bestaetigen, dass Audio trotz fehlendem Live-Text weiterlaeuft.
4. Aufnahme stoppen und die Originalspur in der Dateien-App beziehungsweise im Meeting bestaetigen.
5. `Allow and install` ausloesen und Fortschritt sowie Quelle pruefen.
6. Nach der Installation bestaetigen, dass genau der zuvor wegen des fehlenden Sprachmodells gescheiterte finale ASR-Lauf erneut auf `queued` gesetzt und verarbeitet wird.

## Abnahmekriterien

- iOS kontaktiert Apple fuer ein Sprachasset nur nach ausdruecklichem Klick.
- In i1 wird kein Diarisierungsmodell installiert.
- Aufnahme ist bei fehlendem, fehlerhaftem oder abgelehntem Sprachmodell moeglich.
- Ein fehlendes Modell beendet keine laufende Aufnahme.
- Nach erfolgreicher Installation nutzt die naechste Aufnahme und der finale ASR-Lauf die gewaehlte Sprache ohne App-Neustart.
- Ein wegen `assetsNotInstalled` fehlgeschlagener finaler ASR-Job wird nach erfolgreicher Installation genau einmal erneut eingereiht.
- Ein Stop mit Live-Ausgabe hinterlaesst nach App-Neustart eine lesbare `.liveProvisional`-Revision.
- Ein Stop ohne Live-Ausgabe hinterlaesst die Originalspur und genau einen finalen ASR-Job.
- Automatisierte Tests und beide App-Builds sind gruen.
- Der Geraetetest dokumentiert klar, was am echten iPhone belegt wurde.
