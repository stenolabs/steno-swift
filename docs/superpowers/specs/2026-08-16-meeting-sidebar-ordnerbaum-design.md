# Meeting-Sidebar mit Mehrfachauswahl und Ordnerbaum

**Datum:** 16. August 2026

**Status:** Fachlich freigegeben, unabhängiger Architekturreview eingearbeitet.

## Ausgangslage

Die macOS-Sidebar gruppiert Meetings derzeit in flachen Ordnerabschnitten und anschließenden Datumsabschnitten.
Die Auswahl enthält genau eine `MeetingID`, Meetings lassen sich nur einzeln über ein Kontextmenü verschieben und Ordner besitzen keine Elternbeziehung.

Die gewünschte Bedienung braucht eine zusammenhängende Baumansicht.
Mehrere Meetings sollen mit den auf macOS üblichen Tasten ausgewählt und gemeinsam in einen Ordner gezogen werden können.
Ordner sollen genau eine Unterordner-Ebene unterstützen, beispielsweise `Arbeit/Meetings` und `Arbeit/Produktvorstellung`.

## Ziele

- Die Sidebar wird als native aufklappbare Baumansicht dargestellt.
- `Shift` wählt einen zusammenhängenden Bereich von Meetings aus.
- `Cmd` fügt einzelne Meetings zur Auswahl hinzu oder entfernt sie daraus.
- Eine Mehrfachauswahl lässt sich gemeinsam per Drag-and-drop oder Kontextmenü verschieben.
- Ordner lassen sich per Drag-and-drop unter einen Hauptordner hängen und wieder auf die Hauptebene verschieben.
- Es gibt höchstens eine Unterordner-Ebene.
- Die bestehende Bibliothek wird ohne Datenverlust in das neue Ordnermodell überführt.
- Daten-Refreshes und Drag-and-drop verändern weder die Fenstergröße noch den Fensterzustand.

## Nicht-Ziele

- Dieses Paket führt keine beliebig tiefe Ordnerhierarchie ein.
- Meetings können weiterhin nur genau einem Ordner angehören.
- Umbenennen, Transkribieren, Exportieren und Löschen bleiben Einzelaktionen.
- Die Titelsuche wird nicht zu einer Volltextsuche über Transkripte erweitert.
- Gleichrangige Ordner werden in diesem Paket nicht durch freie Einfügemarken neu sortiert.
  Die vorhandenen Aktionen zum Verschieben nach oben und unten bleiben für die Reihenfolge zuständig.
- Die iOS- und iPadOS-Oberfläche erhält in diesem Paket keine neue Ordner-Sidebar.

## Gewählte Oberfläche

Die gewählte Variante ist eine native Baum-Sidebar.
Hauptordner erscheinen als aufklappbare Zeilen, Unterordner und Meetings sind direkt darunter eingerückt.
Nicht einsortierte Meetings bleiben unterhalb des Ordnerbaums in den vorhandenen Datumsgruppen sichtbar.

Die Aufklappzeilen werden als gewöhnliche `DisclosureGroup`-Zeilen innerhalb der `List` gebaut und nicht als aufklappbare `Section`-Header.
Damit läuft die neue Ansicht nicht erneut in den bereits nachgestellten SwiftUI-Fehler, der den Header der ersten Sektion verschluckt.

Eine feste, nicht auswählbare Kopfzeile `Ordner` steht unmittelbar über den Hauptordnern.
Sie ist das eindeutige Drop-Ziel zum Hochstufen eines Unterordners auf die Hauptebene und bleibt auch bei einem leeren Ordnerbaum sichtbar.

Die gesamte Ordnerzeile ist ein Drop-Ziel.
Während eines zulässigen Drops wird die Zielzeile klar hervorgehoben.
Ein unzulässiges Ziel zeigt den systemüblichen Nicht-erlaubt-Zustand und verändert keine Daten.

Leere Ordner bleiben sichtbar und erklären mit einer ruhigen Leerzeile, dass Meetings hierher verschoben werden können.
Die Aufklappzustände werden je Ordner lokal gespeichert.
Sie liegen als Menge von `FolderID`-Werten in `UserDefaults`, überstehen dadurch einen normalen Daten-Refresh und werden beim Löschen des jeweiligen Ordners bereinigt.

## Auswahlverhalten

Die Sidebar verwendet eine mengenbasierte Meetingauswahl und überlässt Bereichs- und additive Auswahl den nativen macOS-Interaktionen von `List`.
Ordnerzeilen und Datumsüberschriften sind keine Meetingauswahl und erhalten keinen Meeting-Tag.

Wird ein bereits ausgewähltes Meeting gezogen, enthält die Drag-Nutzlast alle ausgewählten Meetings.
Wird ein nicht ausgewähltes Meeting gezogen, enthält die Nutzlast ausschließlich dieses Meeting.
Dadurch führt ein versehentlicher Drag auf einer anderen Zeile nicht unbemerkt die alte Mehrfachauswahl mit.

Bei genau einem ausgewählten Meeting zeigt die Detailspalte weiterhin dessen Inhalt oder den Aufnahmezustand.
Bei mehreren ausgewählten Meetings zeigt sie eine Zusammenfassung mit Anzahl und Hinweis auf Verschieben per Drag-and-drop oder Kontextmenü.
Bei keiner Auswahl bleibt der vorhandene Leerzustand bestehen.

Die App hält ausschließlich eine Kennungsmenge als Auswahlzustand.
Der bisherige Zugriff auf ein einzelnes `selectedMeetingID` wird bei einer Menge mit genau einem Element daraus abgeleitet, damit Aufnahmestreifen, Import, Erstellung und bestehende Detailnavigation keinen zweiten Auswahlzustand pflegen.
Bestehende Schreibzugriffe auf `selectedMeetingID` ersetzen die Menge durch genau diese Kennung oder leeren sie bei `nil`.
Nur eine echte Einzelauswahl aktualisiert das dauerhaft gespeicherte zuletzt ausgewählte Meeting.

Nach einem Daten-Refresh wird die Auswahl auf weiterhin vorhandene Meetings beschnitten.
Wenn Suche oder Zuklappen Zeilen ausblenden, wird die Auswahl zusätzlich auf die sichtbaren Meetings beschnitten, damit eine Sammelaktion keine unsichtbaren Zeilen mitnimmt.
Nach einem erfolgreichen Verschieben wird der Zielpfad aufgeklappt, sodass die weiter ausgewählten Meetings sichtbar bleiben.

## Meeting-Aktionen

Das Kontextmenü einer Zeile unterscheidet zwischen Einzel- und Mehrfachauswahl.
Bei einer Mehrfachauswahl bietet es `N Meetings verschieben` mit Haupt- und Unterordnern sowie `Kein Ordner` an.
Umbenennen, erneute Transkription, Export und Löschen werden in diesem Zustand nicht als Sammelaktion angeboten.

Das Menü wird mit `contextMenu(forSelectionType: MeetingID.self)` an die `List` gebunden und nicht separat an jede Meetingzeile.
Ein Rechtsklick auf eine nicht ausgewählte Zeile folgt der nativen macOS-Auswahl und wirkt ausschließlich auf diese Zeile.
Ein Rechtsklick auf eine bereits ausgewählte Zeile erhält die Mehrfachauswahl und bietet deren gemeinsame Verschiebeaktion an.

Das Verschieben prüft vor dem ersten Schreibzugriff, dass alle Meetingkennungen existieren und der Zielordner weiterhin gültig ist.
Erst nach einem vollständig erfolgreichen Batch wird die sichtbare Bibliothek aktualisiert.

Da jedes Meeting eine eigene Metadatendatei besitzt, hält der Batch die ursprünglichen Zuordnungen bis zum Abschluss im Speicher.
Bei einem Schreibfehler stellt er bereits geänderte Meetingdateien aus diesen Zuordnungen wieder her.
Falls auch eine Wiederherstellung fehlschlägt, meldet die App den verbleibenden Teilzustand ausdrücklich, statt einen vollständig erfolgreichen Sammelzugriff vorzutäuschen.

Ein Prozessabbruch zwischen mehreren Metadatendateien kann nicht dieselbe atomare Garantie wie der einzelne Ordnerindex erhalten.
Die Zuordnungen bleiben jedoch gültige, einzeln atomar geschriebene Metadaten und die Aufnahmeoriginale werden niemals verändert.

## Ordnerinteraktionen

Das Kontextmenü eines Hauptordners bietet zusätzlich `Neuer Unterordner...` an.
Ein Ordner kann außerdem auf einen anderen Hauptordner gezogen werden und wird dadurch dessen Unterordner.
Ein Unterordner kann auf einen anderen Hauptordner gezogen werden und wechselt dadurch seinen Elternordner.
Ein Drop auf die feste Kopfzeile `Ordner` entfernt die Elternbeziehung eines Unterordners.

Ein Hauptordner kann nicht unter einen seiner eigenen Unterordner verschoben werden.
Ein Unterordner kann keinen weiteren Unterordner aufnehmen.
Ein Ordner kann weder sein eigener Elternordner sein noch Teil eines Kreises werden.
Diese Regeln werden im Store validiert und nicht nur in der Oberfläche ausgeblendet.

Ordnernamen werden getrimmt, Whitespace wird wie bisher normalisiert und Namen müssen innerhalb desselben Elternordners eindeutig sein.
Gleich benannte Ordner unter verschiedenen Hauptordnern sind erlaubt, beispielsweise `Arbeit/Kunden` und `Privat/Kunden`.

Die Sortierung gilt pro Geschwistergruppe.
`sortIndex` eines Hauptordners wird nur mit anderen Hauptordnern verglichen, der eines Unterordners nur mit den Kindern desselben Elternordners.
`FolderStore.reorderFolders(parentID:order:)` nimmt ausschließlich die vollständige Reihenfolge einer Geschwistergruppe an.
Die Aktionen `Nach oben` und `Nach unten` tauschen nur mit einem Geschwisterordner.
Beim Wechsel des Elternordners wird der verschobene Ordner an das Ende der neuen Geschwistergruppe gesetzt und beide betroffenen Gruppen werden lückenlos neu nummeriert.
`listFolders()` liefert eine deterministische Tiefenreihenfolge aus jedem Hauptordner und unmittelbar folgenden Kindern, während der Sidebar-Builder weiterhin die eigentliche Baumstruktur erzeugt.

## Löschen von Ordnern

Das Löschen eines Ordners löscht niemals ein Meeting.
Meetings, die direkt im gelöschten Ordner liegen, werden in die chronologische Liste zurückverschoben.

Wird ein Hauptordner gelöscht, werden seine unmittelbaren Unterordner zu Hauptordnern hochgestuft und behalten ihre Meetings.
Ihre Reihenfolge bleibt relativ zueinander erhalten und sie werden an der Position des gelöschten Hauptordners eingeordnet.

Der Bestätigungsdialog nennt beide Folgen ausdrücklich, wenn Unterordner vorhanden sind.
Ein Unterordner kann keine Kinder besitzen, daher entfällt dort eine weitere Hochstufung.

## Datenmodell

`Folder` erhält die optionale Eigenschaft `parentFolderID: FolderID?`.
`nil` bezeichnet einen Hauptordner.
Eine Kennung bezeichnet einen Unterordner des referenzierten Hauptordners.

```swift
public struct Folder: Codable, Equatable, Identifiable, Sendable {
    public let id: FolderID
    public var name: String
    public var parentFolderID: FolderID?
    public var sortIndex: Int
    public let createdAt: Date
}
```

Eine Eltern-ID ist robuster als ein gespeicherter Textpfad.
Umbenennungen ändern dadurch weder Kindordner noch Meetings.
Eine separate Hierarchiedatei wird ebenfalls vermieden, weil Ordneridentität und Elternbeziehung sonst unabhängig voneinander fehlschlagen könnten.

`Meeting.folderID` bleibt unverändert.
Das Meeting verweist immer auf den konkreten Haupt- oder Unterordner, in dem es liegt.

## Schemamigration

Das bisherige `folders.json` besitzt Schema 1 und enthält keine Elternkennungen.
`FolderStore` führt Schema 2 ein.

Die App besitzt pro geöffneter Bibliothek genau eine langlebige `FolderStore`-Instanz und reicht dieselbe Instanz an Sidebar, Altordnerübernahme und laufenden Legacy-Import weiter.
Dadurch serialisiert ein Actor sämtliche Ordnerlese- und Schreibzugriffe dieser App-Laufzeit.

Eine ausdrückliche Bootstrap-Vorbereitung prüft und migriert den Ordnerindex genau einmal, bevor Altordnerübernahme, Import oder Sidebar darauf zugreifen können.
Normale Lesemethoden schreiben niemals als Nebenwirkung.

Der Migrationspfad liest zuerst nur das Schema-Envelope.
Schema 1 wird mit einem eigenen `FoldersDocumentV1` dekodiert, in ein Schema-2-Dokument überführt und erst danach atomar geschrieben.
Jedes vorhandene `Folder` erhält dabei `parentFolderID = nil`.
Das vorhandene Flag `adoptedLegacyFolders` bleibt unverändert erhalten.

Eine unbekannte neuere Schemaversion wird weiterhin abgelehnt und nicht geraten.
Eine beschädigte Datei folgt weiterhin dem vorhandenen Quarantänepfad.
Die bekannte Schema-1-Fassung wird weder als nicht unterstützt behandelt noch bei einem erfolgreichen Decode quarantänisiert.

Der Altimport sucht und erzeugt Ordner ausschließlich auf der Hauptebene.
Er verändert keine vom Benutzer angelegten Unterordner.

## Baumaufbereitung

Eine reine, testbare Domänenfunktion baut aus Ordnern und Meetings das Sidebar-Modell auf.
Sie liefert sortierte Hauptordner mit ihren sortierten Unterordnern und direkten Meetings sowie danach die vorhandenen Datumsgruppen für nicht einsortierte Meetings.

Meetings mit einer unbekannten `folderID` werden wie bisher als nicht einsortiert behandelt.
Ungültige Elternkennungen, Kreise oder zu tiefe Ketten werden nicht still als gültiger Baum dargestellt.
Der Store verhindert solche Zustände beim Schreiben, während der Builder sie beim Lesen sicher auf die Hauptebene zurückfallen lässt und damit alle Ordner sichtbar hält.

Die SwiftUI-Ansicht rendert dieses Modell, besitzt aber keine eigene Hierarchielogik.
Dadurch lassen sich Migration, Sortierung, Suchpfade und Fehlerkanten ohne UI testen.

## Suche und Aufklappzustand

Die Suche bleibt eine Suche nach Meetingtiteln.
Für einen Treffer in einem Unterordner werden Unterordner und Hauptordner als sichtbarer Pfad beibehalten.
Nicht passende Meetings und leere Ordner werden während der Suche ausgeblendet.

Benötigte Vorfahren werden für die Trefferansicht vorübergehend aufgeklappt.
Diese temporäre Darstellung überschreibt nicht den dauerhaft gespeicherten Aufklappzustand.
Nach dem Löschen der Suchanfrage erscheint wieder der vorherige Zustand.

## Drag-and-drop-Vertrag

Meeting- und Ordner-Nutzlasten verwenden getrennte, app-eigene Transfer-Typen.
Eine Ordnerzeile akzeptiert eine Meeting-Nutzlast zum Einsortieren und eine Ordner-Nutzlast nur dann, wenn daraus eine gültige Elternbeziehung entsteht.
Die feste Kopfzeile `Ordner` akzeptiert ausschließlich einen derzeit verschachtelten Ordner zum Hochstufen.

Die Nutzlast enthält stabile Kennungen und keine Dateipfade oder Meetinginhalte.
Sie wird in der `draggable`-Closure erst beim tatsächlichen Drag-Start aus Startzeile und aktueller Auswahl berechnet.
Eine reine Funktion `payload(startRow:selection:)` bildet diese Regel testbar ab.
Beim Drop wird der aktuelle Storezustand erneut gelesen und validiert, weil sich die Bibliothek seit Beginn des Ziehens verändert haben kann.

Drag-Zustand, Auswahländerung und Bibliotheks-Refresh bleiben lokale Zustandsänderungen innerhalb der Sidebar.
Sie dürfen keine neue Fensterinstanz anfordern, keinen Fensterzoom auslösen und keine ideale Detailgröße als Mindestgröße an das Fenster weiterreichen.

## Barrierefreiheit und Tastaturbedienung

Jede Drag-and-drop-Aktion besitzt eine gleichwertige Menüaktion.
Meetings lassen sich über `N Meetings verschieben` ohne Ziehen einsortieren.
Ordner lassen sich über `In Ordner verschieben` beziehungsweise `Auf Hauptebene verschieben` verschachteln oder hochstufen.

Ordnerzeilen erhalten verständliche Aufklapp-, Anzahl- und Drop-Beschriftungen für VoiceOver.
Die Mehrfachzusammenfassung in der Detailspalte nennt die Anzahl ausgewählter Meetings.

## Fehlerbehandlung

Die Oberfläche aktualisiert ihr Modell erst nach bestätigtem Speichern.
Schlägt eine Ordner- oder Meetingoperation vor einer Datenänderung oder nach erfolgreicher Wiederherstellung fehl, bleibt die bisherige sichtbare Struktur bestehen und die vorhandene Meldungsleiste erklärt den Fehler.
Schlägt auch eine Wiederherstellung fehl, lädt die App den tatsächlichen Teilzustand neu und meldet ihn ausdrücklich, statt die alte Struktur weiter anzuzeigen.

Ein ungültiges Ziel, ein inzwischen gelöschter Ordner oder eine nicht mehr vorhandene Meetingkennung wird als erwartbarer Operationsfehler behandelt.
Die App weicht niemals selbstständig auf einen anderen Ordner aus.

Das Hochstufen von Kindern und die Änderung des Ordnerindex geschehen in einem einzigen atomaren Schreibvorgang der `folders.json`.
Beim Löschen werden zuerst die direkten Meetingzuordnungen mit dem rückrollbaren Batch entfernt.
Erst wenn dieser Schritt erfolgreich war, löscht der Store den Ordner und stuft seine Kinder im selben atomaren Schreibvorgang hoch.
Schlägt der Indexschreibzugriff fehl, existiert der Ordner noch und die Meetingzuordnungen werden auf ihn zurückgerollt.
Nach einem erfolgreichen Indexschreibzugriff gibt es keinen Rollback auf die gelöschte Kennung.

## Automatisierte Abnahme

### `StenoDomain`

- Der Baum sortiert Hauptordner und Kinder jeweils innerhalb ihrer Geschwistergruppe.
- Direkte Meetings eines Hauptordners und Meetings seiner Unterordner erscheinen genau einmal am richtigen Knoten.
- Nicht einsortierte und verwaiste Meetings bleiben in den korrekten Datumsgruppen sichtbar.
- Eine Titelsuche erhält den vollständigen Ordnerpfad jedes Treffers.
- Leere Ordner bleiben ohne Suche sichtbar und verschwinden während einer reinen Meetingsuche.

### `StenoLibrary`

- Ein Schema-1-Dokument wird verlustfrei auf Schema 2 mit ausschließlich Hauptordnern migriert.
- `adoptedLegacyFolders`, Kennungen, Namen, Reihenfolge und Erstellungszeiten bleiben bei der Migration erhalten.
- Ein erfolgreich migriertes Schema-1-Dokument erzeugt weder `unsupportedSchemaVersion` noch eine Quarantänedatei.
- Normale Lesemethoden verändern die bereits vorbereitete `folders.json` nicht.
- Nebenläufig angeforderte Operationen derselben langlebigen Store-Instanz werden serialisiert und verlieren keine Mutation.
- Namen werden nur unter gemeinsamen Eltern als Duplikate abgelehnt.
- Selbstbezug, Kreis, unbekannter Elternordner und dritte Ebene werden abgelehnt.
- Verschieben zwischen Hauptordnern und Hochstufen aktualisiert Elternbeziehung und Geschwistersortierung korrekt.
- Beim Löschen eines Hauptordners werden Kinder hochgestuft und direkte Meetings nicht gelöscht.
- Ein simulierter Fehler während eines Meeting-Batches stellt bereits geänderte Zuordnungen wieder her.
- Ein simulierter Fehler während der Wiederherstellung wird als Teilzustand gemeldet.

### macOS-App

- Der Auswahlwert leitet aus genau einer Kennung die bestehende Einzelauswahl und aus mehreren Kennungen den Mehrfachzustand ab.
- Die Drag-Nutzlast enthält bei einer ausgewählten Startzeile die Mehrfachauswahl und bei einer nicht ausgewählten Startzeile nur diese Zeile.
- Die Präsentationslogik wählt für mehrere Kennungen die Zusammenfassung und für eine Kennung weiterhin die Meetingdetails.
- Die Aktionslogik bietet im Mehrfachzustand nur die gemeinsame Verschiebeaktion an.
- Die Drop-Validierung akzeptiert ausschließlich zulässige Meeting- und Ordnerziele.
- Gespeicherte Aufklappzustände überstehen einen normalen Daten-Refresh.
- Das Löschen eines Ordners entfernt dessen Kennung aus dem lokal gespeicherten Aufklappzustand.
- Eine Suche klappt nur die Trefferdarstellung auf und verändert den gespeicherten Zustand nicht.
- Der Sidebar- und Detailaufbau führt keine inhaltsgetriebene Mindestgröße ein.

## Manuelle Abnahme

1. Mehrere benachbarte Meetings mit `Shift` auswählen und gemeinsam in einen Hauptordner ziehen.
2. Mit `Cmd` ein nicht benachbartes Meeting ergänzen und die Auswahl über das Kontextmenü in einen Unterordner verschieben.
3. Einen Hauptordner auf einen anderen Hauptordner ziehen und anschließend wieder auf die Hauptebene verschieben.
4. Einen unzulässigen Drop auf einen Unterordner versuchen und prüfen, dass keine Daten verändert werden.
5. Nach Meetingtiteln in einem geschlossenen Unterordner suchen und prüfen, dass der vollständige Pfad vorübergehend sichtbar wird.
6. Einen Hauptordner mit Unterordner löschen und prüfen, dass der Unterordner samt Meetings auf der Hauptebene erhalten bleibt.
7. Die Schritte mit einem nicht maximierten Fenster wiederholen und prüfen, dass Position, Größe und Maximierungszustand unverändert bleiben.
8. Prüfen, dass der erste Hauptordner und seine Aufklappzeile nach Start, Suche und Refresh immer sichtbar bleiben.

## Verifikation

Nach der Implementierung läuft die vollständige Kette für eine Änderung am gemeinsamen Kern:

```text
xcodegen generate
scripts/build-app.sh
scripts/build-ios.sh
swift test --package-path StenoKit
```

Zusätzlich laufen die macOS-App-Tests für Auswahl, Detailzustand und Fensterstabilität.

## Unabhängiger Architekturreview

Claude Fable hat die fachlich freigegebene Fassung vor dem Umsetzungsplan strikt lesend gegen den tatsächlichen Code geprüft.
Übernommen wurden der langlebige Store samt expliziter Bootstrap-Migration, der versionsspezifische Schema-1-Decode, das selektionsgebundene Kontextmenü, geschwisterbezogene Reorder-APIs, die feste Hauptebenen-Drop-Zeile, gewöhnliche `DisclosureGroup`-Zeilen, die festgelegte Löschreihenfolge sowie Präzisierungen zu Auswahl, Disclosure-Persistenz, Fehler-Refresh und Drag-Zeitpunkt.
Die Eltern-ID, der reine Sidebar-Builder, die mengenbasierte native Auswahl und die getrennten Drag-Typen wurden im Review als tragfähig bestätigt.
