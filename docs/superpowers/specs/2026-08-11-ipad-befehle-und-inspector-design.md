# iPad-Befehle und funktionaler Inspector

Stand: 2026-08-11.
Verfasser: Codex, nach dem Auftrag, alle offenen Punkte in einem Zug umzusetzen.

## Ziel

Die universelle iOS-App wird auf dem iPad mit Menueleiste und Hardwaretastatur bedienbar und zeigt neben dem Transkript einen funktionalen Inspector.
Das iPhone behaelt denselben Navigationsbaum und zeigt den Inspector in der kompakten Systemdarstellung.

## Bestehender Stand

`NavigationSplitView`, adaptives Aufnahmelayout und der Aufnahme-Streifen sind vorhanden.
Es fehlen `.commands`, eine von Commands erreichbare fensterbezogene Navigation, programmatischer Suchfokus, ein Inspector und schreibende Review- sowie Notizoberflaechen.

## Architektur

Jedes Fenster erhaelt einen eigenen `NavigationRouter`.
Die Bibliothek und die laufende Aufnahme bleiben wie bisher prozessweit im `AppModel`.
Fensteraktionen werden ueber `FocusedSceneValue` an die Menuecommands gegeben, damit Cmd-N, Cmd-F oder ein Inspector-Toggle nur das aktive iPad-Fenster navigieren.

Die Menueleiste uebernimmt die bewussten Mac-Belegungen:

- Aufnahme starten: Cmd-R.
- Aufnahme stoppen: Cmd-Punkt.
- Moment markieren: Cmd-M.
- neues Meeting als Entwurf: Cmd-N.
- im aktuellen Transkript suchen: Cmd-F.
- Details ein- oder ausblenden: systemnaher Menuebefehl ohne konkurrierende Standardbelegung.

Cmd-R startet nur eine Aufnahme und beendet nie eine laufende.
Cmd-Punkt bleibt der einzige globale Stop-Shortcut.

## Inspector

`MeetingDetailView` erhaelt `.inspector` mit einer festen lesbaren iPad-Breite.
Der Inspector enthaelt:

1. die gemeinsame persistente Notizsession,
2. bekannte und bestaetigte Teilnehmer in lesender Form,
3. Sprechercluster mit ihrem gemeinsamen `SpeakerPresentation`-Wert,
4. Aktionen zum Bestaetigen eines Vorschlags, Zuweisen einer bekannten Person, Anlegen einer neuen Person, Markieren mehrerer Stimmen und Zuruecksetzen auf generisch.

Alle Schreibaktionen verwenden `MeetingReviewController` und laden danach den aktuellen Review-Stand neu.
Unbestaetigte Vorschlaege werden nie als bestaetigte Namen dargestellt.
Hörproben sind nicht Voraussetzung dieses Pakets, weil ihre iOS-Audiositzung ein eigenes Hardware- und Unterbrechungsthema ist.

## Entwuerfe und Navigation

Cmd-N legt ueber die vorhandene `Library` ein Meeting im Status `draft` an und waehlt es im aktiven Fenster aus.
Der Inspector oeffnet bei einem Entwurf automatisch, weil die Notiz dort der Hauptinhalt ist.
Eine laufende Aufnahme bleibt prozessweit sichtbar und kann aus jedem Fenster ueber den Aufnahme-Streifen erreicht werden.

Cmd-F aktiviert die vorhandene Suche des aktuell sichtbaren Meeting-Details.
Gibt es im aktiven Fenster kein Meeting, ist der Befehl deaktiviert.

## Simulator und Geraetegrenzen

Das Build-Skript erhaelt eine eindeutige Simulatorauswahl, damit ein bestimmtes iPad statt des ersten zufaellig gebooteten Geraets verwendet wird.
Im Simulator werden SplitView, schmale und breite Fenster, Inspector, Navigation, Entwurf, Notizen, Menuebefehle und Suchfokus geprueft.

Nicht als Simulatorabnahme ausgegeben werden SpeechTranscriber, Apple-Sprachassets, echtes Mikrofon, USB-C-Audio, Routenwechsel, Hintergrunddauerlauf, Thermik, Magic Keyboard und Stage Manager.
Diese Punkte brauchen weiterhin echte Hardware.

## Fehlerverhalten

Commands sind deaktiviert, wenn ihre Voraussetzung fehlt.
Ein fehlendes Sprachmodell sperrt die Aufnahme nicht.
Ein Review-Fehler bleibt im Inspector sichtbar und verwirft keinen vorhandenen Review-Stand.
Ein fehlender Review-Lauf zeigt keine erfundenen Sprecheraktionen.
Ein Notizfehler bleibt vom Aufnahme- und Verarbeitungspfad getrennt.

## Tests

Reine Tests decken Command-Verfuegbarkeit, Routing, Draft-Erzeugung, Such- und Inspectoranforderungen ab.
Integrationstests decken die iOS-AppModel-Aufrufe fuer Notizen und `MeetingReviewController` ab.
Die sichtbaren Zustandshelfer werden aus den Produktionsansichten verwendet.

Danach laufen die iOS-App-Tests, die StenoiOSKit-Simulatortests, der iPad-Simulatorbuild, der macOS-Build und wegen der gemeinsamen Kernveraenderungen die vollstaendige StenoKit-Suite.

## Nicht in diesem Paket

- Audioimport oder Meeting-Paket-Export per Drag and Drop.
- USB-C-Eingangsauswahl und realer Routenwechseltest.
- Mehrfenster-Synchronisation von Auswahl oder Suchtext.
- Wiedergabe von Sprecher-Hörproben waehrend einer Aufnahme.
- Verschluesselung oder Migration der Bibliothek.

## Abnahmekriterien

- Das aktive iPad-Fenster kann per Tastatur einen Entwurf anlegen, eine Aufnahme starten, markieren und stoppen.
- Cmd-F fokussiert die Transkriptsuche.
- Der Inspector zeigt und speichert Notizen und kann echte Sprecherzuweisungen schreiben.
- Zwei Fenster teilen Aufnahme und Bibliothek, aber nicht Auswahl, Suche oder Inspectorzustand.
- Das iPhone bleibt in kompakter Breite bedienbar.
- Ein bestimmter iPad-Simulator kann reproduzierbar gebaut und gestartet werden.
