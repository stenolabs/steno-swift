# Persistente Aufnahmeannotationen

Stand: 2026-08-11.
Verfasser: Codex, nach dem Auftrag, alle offenen Punkte in einem Zug umzusetzen.

## Ziel

Notizen und Zeitmarken ueberleben auf iPhone, iPad und Mac das Schliessen der Aufnahmeansicht, App-Abbrueche und die Nachverarbeitung.
Ein Fehler beim Speichern einer Notiz darf die Audioaufnahme weder stoppen noch als verloren darstellen.

## Beobachtete Ursache

macOS speichert Notizen bereits in `notes/user-notes.md` und schreibt eine Zeitmarke als `[HH:MM:SS] ` in dieselbe Datei.
iOS haelt `notes` und `markers` dagegen nur im `RecordingModel` und leert beide beim naechsten Start.

Auf macOS gibt es zusaetzlich ein echtes Ueberschreibungsfenster.
Der Editor haelt einen lokalen, noch nicht gespeicherten Text, waehrend `markMoment()` die Datei separat liest und schreibt.
Der spaetere Autosave kann dadurch die gerade gespeicherte Marke wieder entfernen.

## Architektur

`StenoLibrary` erhaelt eine gemeinsame `MeetingNotesEditingSession` pro Meeting.
Sie haelt den kanonischen sichtbaren Text auf dem Hauptaktor, serialisiert Laden, Debounce, sofortige Marker und Flush ueber den vorhandenen `MeetingNotesStore` und veroeffentlicht ihren Speicherzustand fuer beide Apps.

Beide App-Modelle cachen genau eine Session pro geoeffnetem Meeting.
Editor und Marker greifen damit auf denselben aktuellen Text zu.
Eine Marke wird zuerst in diesen Text eingefuegt und danach sofort atomar gespeichert.
Ein ausstehender Autosave kann sie nicht mehr mit einem aelteren Snapshot ueberschreiben.

Das bestehende Dateiformat bleibt unveraendert.
Marker sind weiterhin Textzeilen in `user-notes.md`, weil sie so ohne neues Schema in Export und Protokollkontext eingehen.
Originalaudio, Transkript-Revisionen und Verarbeitungslaufe bleiben unangetastet.

## Zustandsfluss

1. Beim Oeffnen oder Starten eines Meetings laedt die Session die vorhandene eigene oder importierte Legacy-Notiz.
2. Jede Texteingabe aktualisiert sofort den kanonischen In-Memory-Text und startet den einsekundigen Autosave neu.
3. Eine Zeitmarke wird aus der laufenden Aufnahmezeit formatiert, an denselben Text angehaengt und sofort gespeichert.
4. Beim Meetingwechsel, Verlassen der Ansicht und nach dem Schliessen der Audiospur wird ein ausstehender Stand geflusht.
5. Der Aufnahmeabschluss fuehrt unabhaengig davon die Live-Revision und den Final-ASR-Job fort.

## Fehlerverhalten

Ein Notizfehler erscheint als eigener, nicht-destruktiver Hinweis.
Er setzt die erfolgreiche Aufnahme nicht auf `failed` und verhindert weder Spurregistrierung noch Final-ASR.
Der ungespeicherte Text bleibt in der Session sichtbar, damit er nicht zusaetzlich aus der Oberflaeche verschwindet.
Ein spaeterer Editier- oder Flush-Versuch darf erneut speichern.

Leere Notizen behalten das Verhalten des vorhandenen Stores und entfernen nur `user-notes.md`.
Eine importierte `legacy-user-notes.md` bleibt unveraendert.
Die erste eigene Bearbeitung erzeugt eine neue eigene Notizdatei.

## Oberflaeche

Die iOS-Warnung, Marker und Notizen gingen verloren, wird entfernt.
Stattdessen zeigt die Aufnahmeansicht nur waehrend eines ausstehenden Speicherns `Saving...` und bei einem Fehler eine konkrete Meldung.
Der Markerzaehler bleibt waehrend der laufenden Aufnahme sichtbar.
Der Mac-Editor behaelt seinen Inspector und seine bisherige Bedienung.

## Tests

Kern- und App-Tests decken mindestens ab:

- Notiz-Roundtrip ueber eine neu geoeffnete Session.
- Marker in leerer, eigener und importierter Legacy-Notiz.
- korrektes Format unter und ueber einer Stunde.
- schnelles Tippen gefolgt von Marker verliert weder Text noch Marker.
- ein alter Debounce-Task kann eine neuere Marke nicht ueberschreiben.
- Flush-Fehler bleibt von Audiofinalisierung und Final-ASR-Einreihung getrennt.
- wiederholter Stop erzeugt keine doppelten Annotationen oder Jobs.

## Abnahmekriterien

- iOS-Notizen und Marker sind nach App-Neustart im Meeting vorhanden.
- Cmd-M und der sichtbare Markerknopf schreiben dasselbe Format.
- Ein Marker waehrend ungespeicherter Texteingabe bleibt erhalten.
- Ein Notizfehler beendet keine Aufnahme und verliert kein registriertes Audio.
- Es gibt kein neues Marker-Schema und keine Migration bestehender Meetings.
