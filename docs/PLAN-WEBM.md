# Arbeitspaket: WebM/Opus lesbar machen (Altimport-Audio)

> Historical, non-normative work package retained in German. New import work must be documented in English.

Anlass: Realtest vom 2026-08-06. Die alte Steno-App nahm Systemaudio als WebM/Opus auf.
macOS kann WebM in keiner Variante öffnen (CoreAudio `AudioFileOpenURL failed`, AVFoundation `Cannot Open`, beides an nutzereigenen Dateien geprüft).
Betroffen waren mehrere importierte Spuren.
Ohne lesbares Audio gibt es für diese Meetings keine Hörproben, keine Sprecher-Benennung und keine Re-Diarisierung.

Produktentscheidung: eigener WebM-Leser in Swift, keine Fremdabhängigkeit (ffmpeg scheidet auch technisch aus, es kann Opus nicht nach CAF muxen: "muxing codec currently unsupported").

## Belegte Grundlage

- macOS unterstützt den **Opus-Codec**, nur nicht den WebM-Container. Nachgewiesen: `afconvert -f caff -d opus` erzeugt eine Datei, die `afinfo` als `opus` liest, die sich mit `afconvert -f WAVE -d LEI16` nach PCM dekodieren lässt und die AVFoundation als lesbar meldet (`isReadable: true`, 1 Audiospur, korrekte Dauer).
- Eigene Aufnahmen der neuen App liegen als CAF mit Int16-PCM, 48 kHz vor. CAF ist also bereits der Hauscontainer.
- Die WebM-Dateien enthalten Opus, 48 kHz, 2 Kanäle (ffprobe an Testdaten, nur zur Diagnose verwendet).

## Zielbild

Verlustfreies **Umpacken** statt Neukodieren: Die Opus-Pakete aus dem WebM werden unverändert in einen CAF-Container geschrieben.
Kein Qualitätsverlust und praktisch gleiche Dateigröße; ein Dekodieren nach PCM wäre um ein Vielfaches größer.

Der WebM-Import bleibt verlustfrei, weil die tatsächlichen Originale unangetastet in der alten Installation liegen; im neuen Bibliotheksordner genügt die lesbare Fassung.

## Schritt 1: WebM-Demuxer und CAF-Writer (Codex)

- Neue Dateien in `StenoExchange` (das Modul existiert genau für Altdaten): `WebMOpusReader` (Demuxer) und `OpusCAFWriter`.
- **Demuxer**: minimaler EBML/Matroska-Leser für die Ausgabe von Chromiums MediaRecorder, nicht für Matroska allgemein. Zu lesen sind: EBML-Header, Segment, Tracks (genau eine Audiospur `A_OPUS`, `CodecPrivate` = OpusHead-Magic-Cookie, SamplingFrequency, Channels), Clusters mit `Timecode`, darin `SimpleBlock` und `BlockGroup/Block`. Lacing muss unterstützt werden, soweit MediaRecorder es nutzt (mindestens "kein Lacing"; andere Lacing-Arten erkennen und mit klarem Fehler ablehnen statt still falsch zu lesen). Unbekannte Elemente werden anhand ihrer Größe übersprungen; unbekannte Größe (0x01FF...) im Segment/Cluster ist bei MediaRecorder üblich und muss behandelt werden.
- **Writer**: CAF über die AudioFile-API von AudioToolbox, `kAudioFormatOpus`, Sample-Rate und Kanalzahl aus dem OpusHead, Magic Cookie setzen, Pakete mit Paketbeschreibungen schreiben (`AudioFileWritePackets`). Ziel ist eine Datei, die `AVURLAsset.load(.isReadable)` bejaht.
- **Fallback, falls das Umpacken an CoreAudio scheitert**: über `AudioConverter` mit Opus als Eingangsformat nach PCM dekodieren und als CAF/Int16 schreiben (verlustfrei aus den Opus-Daten, aber groß). Erst umpacken versuchen, nur bei Fehlschlag dekodieren, und das im Ergebnis kennzeichnen.
- **Tests hardwarefrei**: synthetische WebM-Fixtures (selbst gebaut, nicht Testdaten) für: eine Audiospur ohne Lacing über mehrere Cluster, unbekannte Elemente dazwischen, unbekannte Segmentgröße, leere Datei, kaputter Header, Datei ohne Opus-Spur (jeweils klarer Fehler statt Absturz). Round-Trip-Test: Paketanzahl und -längen bleiben beim Umpacken erhalten.

## Schritt 2: Einbindung in den Import (Codex)

- Der Importer konvertiert eine unlesbare Alt-Spur beim Anlegen des MediaAssets und legt die CAF-Fassung ab (Dateiendung `.caf`, gleicher provenanceKey, Herkunft im Asset kenntlich).
- Schlägt die Konvertierung fehl, wird **kein** Audio-Asset angelegt und eine Warnung in den ImportReport geschrieben; die Oberfläche zeigt dann korrekt kein Audio an, statt tote Knöpfe.
- **Reparatur bereits importierter Meetings**: Trifft der Importer auf einen Duplikat-Stem, dessen vorhandenes Asset nicht lesbar ist, ersetzt er es durch die konvertierte Fassung (neuer Zähler `audioRepaired` im ImportReport). Damit repariert der Nutzer seinen Bestand durch einen erneuten Importlauf statt durch Löschen und Neuimport.
- Tests: Import mit WebM-Fixture erzeugt lesbares Asset; unlesbares, nicht konvertierbares WebM erzeugt kein Asset plus Warnung; zweiter Lauf über eine reparierte Bibliothek ändert nichts mehr (idempotent).

## Schritt 3: Realtest

- Erneuter Importlauf über die echte Alt-Installation: erwartet werden ausschließlich reparierte Spuren und keine neuen Meetings.
- Stichprobe: Hörprobe in einem reparierten Meeting, "Sprecher erkennen" darauf laufen lassen, Audio-Symbol erscheint wieder.

## Akzeptanz

1. Die 11 WebM-Spuren sind in der App abspielbar und diarisierbar, ohne Fremdabhängigkeit und ohne Neukodierung.
2. Nicht konvertierbares Audio führt zu einer ehrlichen Anzeige (kein Symbol, keine Knöpfe) plus Warnung im Bericht.
3. Ein erneuter Importlauf repariert Bestandsdaten und bleibt danach idempotent.
