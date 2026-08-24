# Legacy-Re-Transkription direkt starten und sichtbar verfolgen

## Ausgangslage

Ein aus der alten Steno-App importiertes Meeting zeigt einen Hinweis auf ungenaue Zeitmarken und alte Sprecherzuordnungen.
Der Hinweis nennt die Aktion „Re-transcribe and detect speakers“, bietet sie aber nicht direkt an.
Der vorhandene Button liegt im Inspector und ist deshalb schwer auffindbar.

Nach dem Start wird zuerst neu transkribiert und danach diarisiert und mit bekannten Stimmen verglichen.
Sobald die neue Transkription vorliegt, wechselt ihre Herkunft von `legacyImport` zu `finalRun`.
Der Legacy-Hinweis verschwindet dadurch bereits nach Schritt 1, obwohl die Schritte 2 und 3 noch laufen.
Der Nutzer sieht dann ein neues Transkript, aber noch keine Sprecher, und kann den laufenden Prozess leicht für abgeschlossen halten.

## Ziel

Der Legacy-Hinweis bietet den nächsten sinnvollen Schritt direkt an.
Nach dem Start zeigt derselbe Bereich den aktuellen Schritt und die verstrichene Zeit bis zum vollständigen Abschluss der Sprecherkette.
Das alte Transkript und die alte Sprecherzuordnung bleiben als frühere Revision erhalten.

## Nicht-Ziele

- Die Verarbeitungs-Pipeline und ihre Reihenfolge werden nicht geändert.
- Der Lauf startet nicht automatisch beim Import.
- Die Sprechererkennung und die Identitätslogik werden nicht verändert.
- Es wird kein neuer Bestätigungsdialog eingeführt.

## Verhalten

### Bereit zum Start

Für ein Legacy-Meeting mit Originalaudio und ohne eigenen finalen ASR-Lauf zeigt der Hinweis den Button **Re-transcribe and detect speakers**.
Der Button verwendet denselben Aufruf wie die bereits vorhandene Aktion im Inspector.
Ein Klick startet die bestehende Kette `finalASR -> diarization -> identitySuggestion`.

Wenn bereits ein eigener finaler ASR-Lauf existiert, aber noch keine aktuelle Sprecheranalyse vorliegt, lautet die Aktion **Detect speakers**.
Während ein Glied der Kette läuft oder wartet, kann kein zweiter Lauf gestartet werden.

### Laufende Verarbeitung

Der Hinweis bleibt für das gesamte Legacy-Upgrade sichtbar und wird nicht allein von der Herkunft der aktuell angezeigten Transkriptrevision abhängig gemacht.
Ein Legacy-Meeting wird über `meeting.metadata.legacyProvenanceKey` erkannt.
Solange ein Job der Arten `finalASR`, `diarization` oder `identitySuggestion` wartet oder läuft, zeigt der Hinweis anstelle des Buttons einen Spinner, den aktuellen Schritt und die verstrichene Zeit.

Die Texte lauten:

1. **Transcription, step 1 of 3**
2. **Detecting speakers, step 2 of 3**
3. **Comparing voices, step 3 of 3**

Der Legacy-Hinweis liegt in einem festen oberen Safe-Area-Bereich und scrollt nicht mit dem Transkript.
Die allgemeine untere Jobstatusleiste wird während eines laufenden Legacy-Upgrades nicht zusätzlich eingeblendet.

### Abschluss und Fehler

Der Hinweis verschwindet erst, wenn die aktuelle Transkriptrevision Sprechercluster des in `review.runID` bezeichneten Laufs enthält und kein Glied der Kette mehr offen ist.
Damit zählt eine beim Import übernommene alte Sprecherprüfung nicht versehentlich als Abschluss des neuen Laufs.
Danach erscheinen die erkannten Sprecher im Inspector.

Bei einem Fehler bleibt der Hinweis sichtbar.
Er zeigt die vorhandene Fehlermeldung und bietet die passende Aktion erneut an.
Die Aktion setzt beim konkret fehlgeschlagenen oder abgebrochenen Schritt fort und wiederholt keine bereits erfolgreiche Vorstufe.
Fehlt nach einer fertigen Diarisierung nur der Stimmenvergleich, wird genau dieser letzte Schritt eingereiht.
Ein erfolgreicher späterer Lauf überholt einen älteren Fehler wie bereits in der Jobstatuslogik.

## Umsetzungsschnitt

`MeetingDetailView` erhält eine gemeinsame Startfunktion für den Legacy-Hinweis und den bestehenden Inspector-Button.
Die Funktion ruft weiterhin `AppModel.requestDiarization(meetingID:)` auf und aktualisiert danach Jobs und Ansicht über die vorhandene Aktualisierungsschleife.
Ein sofort gesetztes lokales In-Flight-Gate sperrt Mehrfachklicks vor dem ersten asynchronen Rücksprung.
Die Einreihung prüft und schreibt gleichwertige Jobs zusätzlich atomar im `JobStore`.

Die Präsentation des Legacy-Upgrades leitet ihren Zustand aus folgenden vorhandenen Daten ab:

- `meeting.metadata.legacyProvenanceKey`
- `needsTranscriptionFirst`
- `review`
- die Run-Kennungen der Sprecherreferenzen in der aktuellen Revision
- den Jobs des Meetings
- der Audioverfügbarkeit des Meetings

Es wird kein neuer persistierter Zustand eingeführt.
Damit bleibt die Anzeige auch nach einem Fensterwechsel oder App-Neustart korrekt ableitbar.

## Verifikation

- Ein noch nicht neu verarbeitetes Legacy-Meeting mit Audio zeigt die direkte Re-Transkriptionsaktion.
- Ein Klick erzeugt genau einen `finalASR`-Job.
- Während Schritt 1 ist die Transkription im Hinweis sichtbar.
- Nach dem Wechsel der Revision auf `finalRun` bleibt der Hinweis für Diarisierung und Stimmenvergleich sichtbar.
- Ein zweiter Klick ist während der Verarbeitung nicht möglich.
- Nach erfolgreichem Stimmenvergleich verschwindet der Hinweis und die Sprecherprüfung erscheint.
- Nach einem Fehler bleibt eine verständliche Meldung mit erneut nutzbarer Aktion sichtbar.
- Ein Fehler im Stimmenvergleich wiederholt weder Transkription noch Diarisierung.
- Eine fertige Diarisierung ohne Stimmenvergleich gilt nicht als Abschluss und kann Schritt 3 nachholen.
- Der laufende Schritt und ein Fehler bleiben beim Scrollen sichtbar.
- Ein normales Meeting und ein Legacy-Meeting ohne Audio erhalten keinen unbrauchbaren Button.
- Die macOS-App baut erfolgreich und der Ablauf wird mit der isolierten Testbibliothek end-to-end geprüft.
