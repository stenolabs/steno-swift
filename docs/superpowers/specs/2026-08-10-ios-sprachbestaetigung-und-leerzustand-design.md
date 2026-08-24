# iOS-Sprachbestaetigung und ehrlicher Meeting-Leerzustand

Stand: 2026-08-10.
Verfasser: Codex, nach fachlicher Freigabe des Entwurfs.

## Ziel

Die iOS-App macht eine nur abgeleitete Transkriptionssprache als unbestaetigt erkennbar und bietet eine eindeutige Aktion, mit der genau die angezeigte Sprache bestaetigt wird.
Ein Meeting ohne Transkript beschreibt den tatsaechlichen Zustand der lokal gespeicherten Aufnahme, statt auf eine kuenftige gemeinsame Audiokomponente zu verweisen, die bereits vorhanden ist.

## Beobachtete Ursachen

Der Sprach-Picker zeigt die abgeleitete Sprache bereits als aktuellen Wert.
Wer denselben sichtbaren Eintrag bestaetigen moechte, kann deshalb keine Wertveraenderung ausloesen, obwohl `AppModel.setLanguage` denselben Wert bewusst als Bestaetigung akzeptiert.
Die bestehende Warnung beschreibt das Risiko, bietet aber keine eindeutige Handlung fuer den bereits angezeigten Wert.

Der Meeting-Leerzustand unterscheidet derzeit nur zwischen Entwurf und allen anderen Meetings.
Dadurch erscheint auch bei nachweislich gespeicherter Aufnahme der veraltete Hinweis, Aufnahme und Transkription faenden noch ausschliesslich auf dem Mac statt.
Die bereits geladene Dauer liefert der Ansicht eine vorhandene Unterscheidung zwischen einem Meeting mit Audio und einem Meeting ohne Medien.

## Entscheidungen

1. Eine nur abgeleitete Sprache bleibt unbestaetigt, bis der Nutzer eine ausdrueckliche Aktion ausloest.
2. Das blosse Oeffnen von `Audio readiness`, die System-Locale und der bereits sichtbare Picker-Wert gelten nicht als Bestaetigung.
3. Unter dem Picker erscheint bei einer aenderbaren, noch unbestaetigten Sprache die Aktion `Use <language>`.
4. Die Aktion verwendet dieselbe `AppModel.setLanguage`-Pipeline wie eine Picker-Auswahl und bestaetigt damit auch den bereits angezeigten Wert.
5. Waehrend Aufnahme, Modellinstallation oder Pipeline-Neustart bleibt die Sprache gesperrt und es wird keine zweite Bestaetigungsaktion angeboten.
6. Eine gespeicherte Aufnahme ohne Transkript zeigt `Audio saved. No transcript yet. If the speech model is missing, install it under Audio readiness. Steno retries automatically.`
7. Ein Nicht-Entwurf ohne Audio und ohne Transkript zeigt `This meeting has no saved audio or transcript yet.` und behauptet damit weder gespeichertes Audio noch Mac-exklusive Verarbeitung.
8. Der vorhandene Entwurfszustand bleibt unveraendert.

## Oberflaeche

Die Bestaetigungsaktion steht direkt unter dem Sprach-Picker und vor der bestehenden Erklaerung, warum die Sprache nicht geraten werden darf.
Sie verwendet den vorhandenen Link-Stil der `Form` und keine neue Farbe, Karte oder Bestaetigungsdialog.
Der dynamische Titel nennt den lokalisierten Anzeigenamen, zum Beispiel `Use German (Germany)`.
Nach erfolgreicher Bestaetigung verschwindet die Aktion zusammen mit der Warnung, weil `wasChosenExplicitly` dann wahr ist.

Der Meeting-Leerzustand verwendet weiterhin `ContentUnavailableView` und das bestehende Symbol.
Bei gespeicherter Aufnahme erklaert der Text, dass das Audio sicher vorliegt, wo ein fehlendes Modell installiert wird und dass Steno den finalen Lauf danach automatisch erneut versucht.
Bei fehlendem Audio lautet der Text `This meeting has no saved audio or transcript yet.`

## Zustandsfluss

1. `TranscriptionLanguage.refresh()` leitet bei Bedarf eine unterstuetzte Sprache ab, setzt aber `wasChosenExplicitly` nicht.
2. `AudioReadinessView` zeigt die abgeleitete Sprache im Picker und zusaetzlich die explizite Bestaetigungsaktion.
3. Die Aktion ruft `AppModel.setLanguage(app.language.locale.identifier)` auf.
4. `AppModel.setLanguage` erkennt den noch unbestaetigten gleichen Wert als Bestaetigung und fuehrt den vorhandenen serialisierten Sprachwechsel aus.
5. `TranscriptionLanguage.select(_:)` speichert Wert und Bestaetigungskennzeichen.
6. Die Ansicht aktualisiert sich und entfernt Aktion sowie Warnung.

Beim Laden eines Meetings werden Meeting, Transkript, Review-Daten und Dauer wie bisher gelesen.
`MeetingDetailView` leitet den Leerzustand aus Meetingstatus und `duration != nil` ab.
Es werden keine Audiodaten veraendert und keine neuen Bibliothekszugriffe eingefuehrt.

## Fehlerverhalten

Eine gesperrte Sprache bleibt sichtbar, aber unveraenderbar, und der vorhandene Sperrhinweis erklaert den Grund.
Die neue Aktion startet keine Installation und veraendert die Aufnahmebereitschaft nicht.
Ein fehlendes Sprachmodell bleibt vom Audiopfad getrennt.
Fehlt ein Transkript trotz gespeicherter Aufnahme, behauptet die Ansicht weder einen Audioverlust noch eine bereits erfolgreiche Transkription.

## Tests

Eine kleine reine Darstellungslogik liefert den Bestaetigungstitel nur fuer eine unbestaetigte und aktuell aenderbare Sprache.
Tests belegen den dynamischen lokalisierten Titel sowie das Verschwinden der Aktion nach Bestaetigung oder bei gesperrtem Zustand.

Eine reine Meeting-Darstellungslogik unterscheidet Entwurf, gespeichertes Audio ohne Transkript und ein Meeting ohne Medien.
Tests belegen fuer jeden Zustand den Titel, das Symbol und die handlungsorientierte Beschreibung.
Die Produktionsansichten verwenden genau diese Logik, damit die Tests nicht eine vom sichtbaren Verhalten getrennte Kopie pruefen.

Nach den fokussierten Rot-Gruen-Zyklen laufen alle iOS-App-Tests und der iOS-Build.
Da StenoKit unveraendert bleibt, ist fuer diese beiden App-Ansichten kein erneuter Kern-Testlauf erforderlich.

## Nicht in diesem Paket

- Eine Aenderung der Apple-Sprachmodellinstallation oder der gespeicherten Zustimmung.
- Automatische Spracherkennung aus dem Audiosignal.
- Ein Erstlauf-Wizard.
- Aenderungen an Aufnahme, Final-ASR, Diarisierung oder Sprecheridentitaet.
- Eine neue gemeinsame SwiftUI-Schicht fuer macOS und iOS.

## Abnahmekriterien

- Eine abgeleitete Sprache kann bestaetigt werden, ohne vorher eine andere Sprache auszuwaehlen.
- Der sichtbare Titel nennt die konkret angezeigte Sprache.
- Oeffnen der Ansicht allein bestaetigt nichts.
- Gesperrte oder bereits bestaetigte Sprache zeigt keine zusaetzliche Bestaetigungsaktion.
- Ein Meeting mit gespeichertem Audio und ohne Transkript sagt ausdruecklich, dass das Audio gespeichert ist.
- Derselbe Zustand verweist auf `Audio readiness` und den automatischen erneuten Versuch.
- Ein Meeting ohne Audio behauptet kein gespeichertes Audio.
- Aufnahme und Modellinstallation bleiben funktional unveraendert und getrennt.
