# iOS-Ordnerhierarchie auf dem gemeinsamen Bibliotheksmodell

**Datum:** 18. August 2026

**Status:** Als direkt folgende Konsolidierungswelle freigegeben.

## Ziel

Die iPhone- und iPad-App zeigt und bearbeitet dieselbe zweistufige Ordnerhierarchie wie die macOS-App.
Beide Apps verwenden `FolderStore`, `Folder`, `Meeting.folderID` und `MeetingSidebarTree` aus `StenoKit`.
Es entsteht weder ein iOS-eigenes Ordnerformat noch eine zweite Hierarchielogik.

## Bestehender Stand

Der gemeinsame Kern unterstuetzt Hauptordner, genau eine Unterordnerebene, geschwisterbezogene Reihenfolge, Migration des frueheren flachen Indexes und fail-closed Validierung ungueltiger Hierarchien.
Die macOS-App besitzt die vollstaendige Ordneroberflaeche und eine AppModel-Fassade fuer Erstellen, Umbenennen, Loeschen, Verschieben und Sortieren.
Die iOS-App zeigt aktuell nur `model.meetings` als flache Liste und oeffnet keinen `FolderStore`.

## Produktumfang

Die iOS-Sidebar zeigt Hauptordner als aufklappbare Zeilen, darunter direkte Meetings und Unterordner mit ihren Meetings.
Nicht einsortierte Meetings bleiben unterhalb des Ordnerbaums in den vorhandenen Datumsgruppen sichtbar.
Leere Ordner bleiben ohne Suche sichtbar.
Eine Titelsuche behaelt fuer Treffer den vollstaendigen Ordnerpfad und blendet leere, nicht passende Ordner aus.

Auf iPhone und iPad stehen dieselben fachlichen Aktionen zur Verfuegung:

- Haupt- oder Unterordner anlegen.
- Ordner umbenennen.
- Ordner loeschen, ohne Meetings zu loeschen.
- Ein Meeting in einen Haupt- oder Unterordner beziehungsweise zurueck in die Datumsliste verschieben.
- Einen Ordner unter einen Hauptordner verschieben oder auf die Hauptebene hochstufen.
- Einen Ordner innerhalb seiner Geschwistergruppe nach oben oder unten verschieben.

Kontextmenues und Dialoge sind die verlaessliche Bedienform auf beiden Plattformen.
Drag-and-drop ergaenzt diese Aktionen auf iPad und iPhone, ist aber nie der einzige Weg.
Die iOS-App behaelt eine Einzelauswahl, weil die aktuelle kompakte Navigation und der Meetingtransfer darauf beruhen.
Mehrfachauswahl und Sammelverschieben bleiben macOS-spezifisch und sind kein Bestandteil dieses Pakets.

## Architektur

`AppModel` besitzt pro geoeffneter Bibliothek genau eine langlebige `FolderStore`-Instanz.
Beim Bootstrap wird sie nach erfolgreichem Oeffnen der Bibliothek erstellt und bei einem Runtime-Neustart zusammen mit der Runtime verworfen.
`reloadMeetings()` laedt Meetings und Ordner und veroeffentlicht nur einen konsistenten Zustand.
Ein Ordnerfehler beendet weder Aufnahme noch Transkription und wird ueber die bestehende sichtbare Fehlermeldung gemeldet.

Die iOS-App verwendet eine eigene duenne Fassade `AppModel+Folders.swift`.
Sie folgt den bereits geprueften macOS-Operationen und dupliziert keine Store-Invarianten.
Das Loeschen raeumt zuerst direkte Meetingzuordnungen mit `Library.setMeetingFolders` rueckrollbar ab und loescht erst danach den Ordnerindex.
Scheitert das Loeschen des Indexes, werden die Meetingzuordnungen wiederhergestellt.
Scheitert auch die Wiederherstellung, laedt die App den wirklichen Teilzustand neu und meldet ihn ehrlich.

`IOSMeetingSidebarPresentation` ist reine, testbare Darstellungslogik.
Sie baut `MeetingSidebarTree`, berechnet effektive Aufklappzustaende fuer Suche, validiert lokale Drag-Nutzlasten und liefert die zulaessigen Ordnerziele.
Die SwiftUI-Ansicht besitzt keine eigene Hierarchie- oder Kreislogik.

## Navigation und Zustand

`SidebarItem.meeting(MeetingID)` bleibt der einzige Meeting-Navigationswert.
Ordnerzeilen sind keine Detailauswahl und veraendern die aktuelle Meetingauswahl nicht.
Das Aufklappen wird pro Ordner als Menge von `FolderID` in `UserDefaults` gespeichert.
Beim Loeschen wird die Kennung entfernt.
Waehren einer Suche werden benoetigte Vorfahren nur temporaer aufgeklappt, ohne die gespeicherte Menge zu veraendern.

Ein Meetingtransfer, eine neue Aufnahme oder ein externer Import kann weiterhin eine Meeting-ID zur Navigation vormerken.
Wenn dieses Meeting in einem Ordner liegt, klappt die Sidebar dessen Ordnerpfad auf, bevor sie die bestehende Meetingroute auswaehlt.

## Drag-and-drop

Meeting- und Ordner-Nutzlasten enthalten ausschliesslich typisierte stabile Kennungen.
Sie enthalten keine Dateipfade, Titel, Transkripte oder sonstigen Meetinginhalt.
Ein Ordner akzeptiert eine Meeting-Nutzlast zum Einsortieren.
Ein Hauptordner akzeptiert eine Ordner-Nutzlast nur, wenn `FolderStore.moveFolder` daraus eine gueltige zweite Ebene bilden kann.
Die feste Ordnerkopfzeile akzeptiert einen Unterordner zum Hochstufen.
Der Storezustand wird beim Drop erneut validiert, weil sich die Bibliothek seit Beginn des Drags geaendert haben kann.

## Fehlerverhalten

Die sichtbare Baumstruktur wird erst nach bestaetigtem Speichern aktualisiert.
Ein inzwischen geloeschtes Meeting oder Ziel fuehrt zu einer sichtbaren Fehlermeldung und keinem stillen Ausweichen.
Das Loeschen eines Ordners loescht niemals ein Meeting und veraendert niemals Audiooriginale.
Eine ungueltige Hierarchie wird vom Store abgelehnt und nicht durch UI-Annahmen erzwungen.

## Tests

AppModel-Integrationstests mit temporaerer Bibliothek pruefen Laden, Anlegen, Umbenennen, Verschieben, Sortieren und die rueckrollbare Loeschreihenfolge.
Presentation-Tests pruefen Baumdarstellung, Suche, Aufklappzustand, Zielmenues und typisierte Drag-Nutzlasten.
Navigationstests pruefen, dass eine von Aufnahme oder Meetingtransfer angeforderte Meeting-ID weiterhin zur richtigen Detailansicht fuehrt und ihren Ordnerpfad sichtbar macht.
Die bestehenden `MeetingSidebarTreeTests`, `FolderStoreTests` und `MeetingFolderBatchTests` bleiben unveraendert gruen.

## Nicht in diesem Paket

- Mehr als eine Unterordnerebene.
- Mehrfachauswahl oder Sammelverschieben auf iOS.
- Volltextsuche im Transkript.
- Synchronisation zwischen Geraeten.
- Aenderungen am Meetingtransferformat.
- Aenderungen an Audioaufnahme, Transkription oder Diarisierung.

## Abnahme

Auf iPhone und iPad lassen sich zwei Hauptordner und ein Unterordner anlegen.
Ein Meeting kann per Menue und per Drag-and-drop in den Unterordner und wieder in die Datumsliste verschoben werden.
Umbenennen behaelt alle Meetingzuordnungen.
Beim Loeschen eines Hauptordners bleiben direkte Meetings erhalten und Kinder werden entsprechend dem gemeinsamen Storevertrag hochgestuft.
Eine Suche zeigt Treffer mit ihrem vollstaendigen Ordnerpfad.
Aufnahme, Meetingtransfer, Protokolle und Sprecheransicht bleiben nach der Sidebar-Umstellung erreichbar.
