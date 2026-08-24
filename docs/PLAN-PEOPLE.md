# Personenverwaltung in den Einstellungen

Stand: 2026-08-06.
Entwurf fachlich abgestimmt, Zweitmeinung von Fable eingeholt und in Teilen gegen den urspruenglichen Wunsch uebernommen.

## Warum

Personen entstehen heute ausschliesslich als Nebenprodukt der Sprecher-Zuordnung in einem Meeting.
Danach sind sie unerreichbar: `IdentityStore` kann `renamePerson` und `deletePerson`, aber kein einziger Aufrufer in der App benutzt beides.
Ein Tippfehler im Namen bleibt fuer immer stehen, ein versehentlich angelegtes Doppelprofil laesst sich nicht zusammenfuehren, und eine falsche Bestaetigung hinterlaesst Stimm-Evidenz, an die niemand mehr herankommt.

Die alte App hat dafuer einen Einstellungen-Tab "People" (Liste, Zahl der Stimmproben, eine Hoerprobe, Loeschen mit Reichweiten-Hinweis).
Dieser Entwurf uebernimmt das und geht an drei Stellen darueber hinaus, weil die neue App Daten hat, die die alte nicht hatte: Lauf-IDs an jeder Evidenz, unantastbare Originalaufnahmen und Hard Negatives als eigenes Feld am Profil.

## Leitplanken

Sie stammen aus `UEBERGABE-sprecher-erkenntnisse.md` und sind keine allgemeinen Ratschlaege, sondern in der alten App bezahlte Erfahrung.

1. **Nichts loeschen, was Evidenz ist.**
   Ein veralteter Prototyp ist weiterhin echte Stimm-Evidenz einer echten Person.
   Evidenz still zu zerstoeren ist der schlimmere Fehler.
2. **Hard Negatives sind strenger zu behandeln als Prototypen.**
   Ein falsches Negativ unterdrueckt eine echte Erkennung dauerhaft in Meetings, die damit nichts zu tun haben, und nichts im spaeteren Fehlverhalten zeigt auf die Ursache.
3. **Wo eine Zuordnung nicht sicher ist, wird nichts gezeigt und nichts abgespielt.**
   Kein Rettungszweig, der raet.
4. **Ein einziges gemeinsames Praedikat entscheidet, ob Evidenz zaehlt.**
   Lese- und Schreibpfad rufen dasselbe auf; zwei Kopien der Regel driften garantiert auseinander.
5. **Anwesenheit ist meetingbezogen, Stimm-Evidenz laufbezogen.**
   Ein Merge darf die Teilnehmerlisten nicht laufbezogen filtern.

## Entscheidungen

### Ausschliessen statt Loeschen (Kernentscheidung)

Einzelne Stimmproben sind sichtbar und einzeln steuerbar, aber **nicht einzeln loeschbar**.
Die Aktion heisst `Exclude from recognition` mit dem Gegenteil `Include again`.
Die Probe bleibt gespeichert und zaehlt nur nicht mehr in die Bewertung.

Zwei Gruende, beide belegbar:

- Justieren gelingt damit vollstaendig, denn eine falsche Probe schadet ausschliesslich, solange sie mitbewertet wird.
- Echtes Einzelloeschen haette eine unsichtbare Reichweite in fremde Profile.
  Aus jeder Bestaetigung entstehen Hard Negatives in den Profilen aller anderen Personen mit demselben Evidence Key; `IdentityStore.deletePerson` raeumt genau diese ab.
  Eine Einzelloeschung muesste denselben Sweep machen, sonst bleiben Waisen-Negatives stehen, die auf nichts mehr zurueckfuehren.

Technisch traegt jede Evidenz ein neues Feld `excludedAt: Date?`.
Ein einziges Praedikat `isActive` in `StenoIdentity` entscheidet ueberall, ob sie zaehlt; die Vorschlags-Engine filtert Prototypen und Hard Negatives darueber.

### Hard Negatives sichtbar, aber getrennt

Eigener, standardmaessig eingeklappter Abschnitt `Not this person (N)` unter der Probenliste, mit der Erklaerzeile:
"A wrong entry here permanently blocks recognition, even in unrelated meetings."
Aktion ebenfalls nur Ausschliessen und Wiederaufnehmen.
Fuer diesen Abschnitt ist Ausschliessen die Hauptfunktion, nicht die Ausnahme: es ist der einzige Ort in der ganzen App, an dem ein falsch gesetztes Negativ ueberhaupt gefunden werden kann.

### Veraltete Laeufe sichtbar machen

Jede Probe traegt die `runID` des Laufs, gegen den sie bestaetigt wurde.
Weicht sie vom aktuellen Diarisierungslauf des Meetings ab, zeigt die Zeile das Kennzeichen `Superseded run`, die Personenzeile fasst es zusammen ("2 from a superseded run").
Der Zustand wird nur angezeigt, nie automatisch bereinigt.

### Loeschen mit Ruecknahme

Eine Person zu loeschen ist die einzige Aktion dieses Bereichs, die Evidenz wirklich und global zerstoert.
`deletePerson` liefert deshalb einen vollstaendigen Schnappschuss zurueck (die Person samt Prototypen und die aus fremden Profilen entfernten Hard Negatives), und `restorePerson` setzt genau diesen wieder ein.
Die Oberflaeche haelt den Schnappschuss bis zum Verlassen des Tabs und bietet `Undo` an.
Wiederhergestellt wird punktgenau, nicht durch Zurueckschreiben des gesamten Personendokuments, damit eine parallele Aenderung nicht verlorengeht.

### Zusammenfuehren

`Merge into ...`: der Benutzer waehlt den Ueberlebenden, das andere Profil geht darin auf.

Die Teilnehmerlisten liegen je Meeting in einer eigenen Datei, das Profil in einer weiteren; eine Transaktion darueber gibt es nicht.
Deshalb laeuft der Merge in drei Schritten, deren Reihenfolge an keiner Stelle Anwesenheit verlieren kann:

1. **Additiv:** ueberall, wo die Quelle als Teilnehmerin steht, wird das Ziel danebengesetzt.
   Schlaegt das fehl, bricht der Merge ab, bevor er die Profile anfasst - es ist nichts passiert, was nicht wieder passieren duerfte.
2. **Profile zusammenfuehren** im `IdentityStore`.
3. **Aufraeumen:** die aufgeloeste Kennung faellt aus beiden Listen.
   Ab hier zeigt sie ohnehin auf niemanden mehr, ein Fehlschlag hinterlaesst also keinen sichtbaren Schaden und wird nicht als Fehler gemeldet.
   Beide Listen werden geschrieben, sobald eine von beiden betroffen ist - sonst steht eine Person, die als stille Teilnehmerin gefuehrt war und nun Sprecherin ist, in beiden Listen.

1. Alle Prototypen der Quelle bekommen die `personID` des Ziels.
   Evidence Keys und Lauf-IDs bleiben unveraendert, nichts wird neu berechnet oder gemittelt.
2. Hard Negatives werden vereinigt und **danach** bereinigt: jedes Negativ, dessen Evidence Key auf einen Prototyp der jeweils anderen der beiden Personen zeigt, wird entfernt.
   Das ist die eigentliche Falle. Ein Negativ "nicht A" entstand, als jemand denselben Cluster als B bestaetigte; waren A und B dieselbe Person, wuerde es nach dem Merge die eigene Stimme dauerhaft unterdruecken.
3. Der Sweep aus `deletePerson` laeuft **nicht**.
   Die Stimme der Quelle existiert weiter und bleibt gueltige Gegen-Evidenz in fremden Profilen.
4. `participantIDs` und `additionalParticipantIDs` jedes Meetings werden von der Quelle auf das Ziel umgeschrieben; steht das Ziel schon drin, faellt die Quelle ersatzlos weg.
   Anwesenheit ist meetingbezogen und bleibt wahr.
5. Kontaktfelder: das Ziel behaelt seinen Namen, leere Felder werden aus der Quelle gefuellt, bei Konflikt behaelt das Ziel seinen Wert.
6. Duplikate mit gleichem Evidence Key werden nach dem Vereinigen zusammengefaltet.

Kein Undo. Der Dialog sagt das ausdruecklich, und die Probenlisten beider Seiten sind vorher anhoerbar - genau dafuer sind sie gebaut.

### Bewusst nicht in diesem Bau

- **"This is you"-Markierung.**
  Der eigene Mic-Kanal wird nie als Person benannt; ein markiertes Selbst-Profil braucht Verdrahtung in Vorschlagslogik und Review und ist ein eigenes Paket.
- **Manuelles Anlernen einer Stimme.**
  Der Quellwert `manualEnrollment` existiert ungenutzt im Domaenenmodell, der Aufnahmeweg dafuer nicht.
- **Adressbuchfunktionen** jenseits von Name, E-Mail und Firma.

## Aufbau

| Schicht | Aenderung |
|---|---|
| `StenoDomain/Identity.swift` | `excludedAt: Date?` an `SpeakerPrototype` und `HardNegative`; alte Dokumente dekodieren unveraendert weiter |
| `StenoIdentity` | gemeinsames `isActive`-Praedikat; `SpeakerSuggestionEngine` filtert Prototypen und Negatives darueber |
| `StenoLibrary/IdentityStore` | `setPrototypeExcluded`, `setHardNegativeExcluded`, `mergePersons`, `deletePerson` liefert Schnappschuss, `restorePerson` |
| `StenoPipeline/PersonVoiceSamples` | loest je Prototyp Meeting, Kanal, Zeitbereich und Veraltung auf; liefert nur abspielbare Proben als abspielbar |
| `App/Sources/AppModel+People.swift` | Ladepfad und Aktionen fuer die Oberflaeche |
| `App/Sources/PeopleSettingsView.swift` | der Tab selbst |

Die Aufloesung der Hoerprobe liest das Diarisierungsartefakt des Laufs, an dem die Probe haengt, und nimmt daraus das laengste Segment des Clusters.
Abgespielt wird aus **genau der Spur, deren Kennung im Artefakt steht** - nicht aus irgendeiner Spur derselben Art.
Wird eine Aufnahme spaeter erneut importiert, gibt es zwei Systemspuren, und die alten Segmentzeiten passen nur auf eine davon; die andere wuerde eine fremde Stimme unter einem Namen abspielen.
Fehlt das Artefakt, die Spur, der Cluster oder die Datei, ist die Probe nicht abspielbar und die Zeile sagt das ("Audio no longer available"), statt einen Ersatz zu raten.

## Test

- `IdentityStoreTests`: Ausschliessen ueberlebt das Neuladen; Merge verschiebt Prototypen, entfernt genau das gegenseitige Negativ und behaelt fremde Negatives; Loeschen und Wiederherstellen ist verlustfrei, auch fuer die aus fremden Profilen entfernten Negatives.
- `IdentityInvariantTests`: eine ausgeschlossene Probe erzeugt keinen Kandidaten mehr; ein ausgeschlossenes Negativ blockiert nicht mehr.
- `StenoPipelineTests`: Aufloesung findet das laengste Segment, erkennt einen veralteten Lauf und liefert bei fehlendem Artefakt nichts statt irgendetwas.
- Ein Dekodier-Test fuer ein Personendokument ohne `excludedAt`.
