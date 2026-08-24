# Gemeinsamer Audioexport als Stereo-M4A

Stand: 2026-08-12.

Status: Fachlich freigegebener Entwurf vor dem Implementierungsplan.

## Ziel

Die macOS-App kann die Mikrofon- und Systemspur eines Meetings nicht nur einzeln, sondern auch gemeinsam in eine kompakte Audiodatei exportieren.

Der gemeinsame Export ist ohne weitere Konvertierung in Steno Swift, Steno Legacy, SpeechMind und üblichen Audioeditoren importierbar.

Die unveränderlichen Originalspuren in Stenos Bibliothek bleiben unangetastet.

## Verifizierter Ausgangszustand

Die macOS-App bietet im Kontextmenü eines Meetings bereits `Export Audio…` an.

Der anschließende Dialog listet jede vorhandene Originalspur einzeln auf.

`AppModel.exportAudioTrack` kopiert die gewählte Originaldatei bytegenau an den gewählten Speicherort.

Steno Swift importiert Audiodateien über den allgemeinen Audio-Dateityp.

Steno Legacy führt `m4a` und `aac` ausdrücklich in seiner Liste unterstützter Importformate.

Steno Legacy interpretiert eine Stereodatei als Mikrofon auf dem linken Kanal und Systemaudio auf dem rechten Kanal.

SpeechMind führt `m4a` und `aac` in seiner veröffentlichten Liste unterstützter Uploadformate.

## Produktentscheidung

Der Auswahldialog erhält zusätzlich zu den vorhandenen Einzelspuren die Option `Both tracks - stereo M4A`.

Diese Option erscheint nur, wenn genau eine lesbare Mikrofonspur und genau eine lesbare Systemspur eindeutig auflösbar sind.

Bei mehrdeutigen mehrfachen Spuren rät Steno keine Paarung.

Die vorhandenen Einzelspur-Exporte bleiben unverändert erhalten.

## Dateiformat und Kanalbelegung

Der gemeinsame Export verwendet einen M4A-Container mit AAC-LC.

Die Ausgabedatei hat 48.000 Hz, zwei Kanäle und eine Zielbitrate von 128 kbit/s.

Kanal 1 beziehungsweise links enthält ausschließlich die Mikrofonspur.

Kanal 2 beziehungsweise rechts enthält ausschließlich die Systemspur.

Die beiden Kanäle werden nicht zusammengemischt.

Die Dateien beginnen gemeinsam bei Zeit null.

Die kürzere Spur wird am Ende mit digitaler Stille bis zur Länge der längeren Spur aufgefüllt.

Abweichende Eingangs-Sampleraten und Eingangs-Kanalzahlen werden für jeden Quellkanal deterministisch auf 48 kHz Mono gewandelt.

Bei einer mehrkanaligen Quellspur verwendet Steno einen dokumentierten Mono-Downmix und rät keinen einzelnen Eingangskanal.

## Architektur

Die Audioverarbeitung liegt in einer SwiftUI-freien Exportkomponente im gemeinsamen StenoKit.

Die Komponente erhält die beiden Quell-URLs und eine Ziel-URL.

Sie liest und konvertiert blockweise, damit mehrstündige Meetings nicht vollständig in den Arbeitsspeicher geladen werden.

Sie erzeugt PCM-Blöcke mit Mikrofon links und Systemaudio rechts und übergibt diese an den AAC-Encoder von AVFoundation.

Die App bleibt für Save-Panel, Fortschrittsanzeige und verständliche Fehlermeldungen zuständig.

Die Bibliothek und die darin registrierten `MediaAsset`-Datensätze werden durch den Export nicht verändert.

## Sicheres Schreiben

Steno schreibt zunächst in eine temporäre M4A-Datei im Zielverzeichnis.

Erst nach erfolgreichem Abschluss des Encoders, Synchronisierung und erneuter Lesbarkeitsprüfung ersetzt Steno das gewählte Ziel atomar.

Ein Abbruch oder Fehler entfernt die temporäre Datei und hinterlässt weder eine scheinbar fertige noch eine teilweise überschriebene Zieldatei.

Eine bereits vorhandene Zieldatei wird nicht vor einem vollständig erfolgreichen Export gelöscht.

## Oberfläche und Fortschritt

Nach Wahl von `Both tracks - stereo M4A` öffnet Steno einen Speicherdialog mit einem Dateinamen nach dem Muster `<Meetingtitel> - Microphone left, System right.m4a`.

Der Speicherdialog erklärt die Kanalbelegung knapp.

Während des Exports zeigt Steno einen sichtbaren Fortschritt und verhindert einen zweiten gleichzeitigen Export desselben Meetings.

Die App bleibt ansonsten bedienbar.

Nach Erfolg nennt Steno den gespeicherten Dateinamen.

Bei Fehler bleibt die Originalaufnahme verfügbar und Steno zeigt eine verständliche Ursache.

## Fehlergrenzen

Fehlende, nicht lesbare oder nicht eindeutig paarbare Spuren verhindern ausschließlich den gemeinsamen Export.

Ein Konvertierungs- oder Schreibfehler verändert weder Meeting, Transkript, Berichte noch Originalaudio.

Die Dauer wird aus den tatsächlich dekodierten Frames bestimmt und nicht allein aus möglicherweise ungenauen Metadaten übernommen.

Ein Kanal, der früher endet, liefert ab diesem Punkt Stille.

Ein Kanal mit Dekodierfehler beendet den Export, statt unbemerkt eine teilweise stumme Datei als erfolgreich zu melden.

## Tests und Abnahme

Ein Kerntest erzeugt synthetische Quellspuren mit unterschiedlichen Sampleraten, Kanalzahlen und Dauern.

Der Test dekodiert die exportierte M4A erneut und belegt Mikrofoninhalt ausschließlich links, Systeminhalt ausschließlich rechts und Stille nach Ende der kürzeren Spur.

Ein Test belegt, dass die Dauer der längeren Quelle erhalten bleibt.

Ein Test belegt blockweises Schreiben bei einer langen synthetischen Quelle, ohne die gesamte Datei im Speicher zu halten.

Fehlertests belegen, dass unlesbare Quellen, Encoderfehler und Abbruch keine fertige Zieldatei veröffentlichen.

Ein App-Test belegt, dass die gemeinsame Option nur bei einer eindeutigen Mikrofon-System-Paarung erscheint.

Die manuelle Abnahme importiert dieselbe erzeugte M4A in Steno Swift und Steno Legacy und kontrolliert dort die linke und rechte Spur.

Eine zusätzliche Abnahme lädt eine unkritische Testdatei bei SpeechMind hoch und prüft lediglich Formatannahme und vollständige Dauer.

Echte Meetinginhalte werden für diese externe Abnahme nicht verwendet.

## Nicht Bestandteil dieses Schnitts

Dieser Export erzeugt keine Mono-Mischung und keine optimierte Masterspur.

Er führt keine Rauschminderung, Pegelnormalisierung, Driftkorrektur oder Sprecherseparation aus.

Er fügt nicht mehrere unabhängige Aufnahmegeräte zusammen.

Er ersetzt weder Originaldateien noch bestehende Revisionen.

iOS erhält in diesem Schnitt keine eigene Audioexport-Oberfläche, kann die erzeugte M4A aber über den vorhandenen Importpfad verarbeiten.
