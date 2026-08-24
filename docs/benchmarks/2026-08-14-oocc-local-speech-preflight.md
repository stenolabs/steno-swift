# Lokaler deutscher Sprachbenchmark: OOCC-v2-Vorlauf

Stand: 14. August 2026.

## Ergebnis

Auf den sieben Freigespräch-Ausschnitten des Open Oldenburg Conversation Corpus v2 erreicht Apples produktiver `SpeechAnalyzerProvider` die niedrigste längengewichtete Wortfehlerrate.

| Engine | WER | Fehler / Referenzwörter | Laufzeit | RTF |
|---|---:|---:|---:|---:|
| Apple SpeechAnalyzer | **19,19 %** | 495 / 2.579 | 5,61 s | 0,00686 |
| FluidAudio Parakeet TDT v3 | 21,68 % | 559 / 2.579 | 21,12 s | 0,02587 |
| Parakeet Primeline DE CoreML | 21,56 % | 556 / 2.579 | 19,31 s | 0,02365 |

Apple gewinnt sechs der sieben Gespräche.
Das reguläre Parakeet gewinnt nur Ausschnitt 1.
Der deutsche Primeline-Fine-Tune verbessert das reguläre Parakeet insgesamt um 0,12 Prozentpunkte, bleibt aber 2,36 Prozentpunkte hinter Apple.

Der erste Primeline-Lauf enthält 13,4 Sekunden einmalige CoreML-Kompilierung des FP16-Encoders.
Über die bereits aufgewärmten Ausschnitte 2 bis 7 beträgt die RTF 0,00714 für Apple, 0,00919 für das reguläre Parakeet und 0,00721 für Primeline.
Alle drei Engines bleiben damit deutlich schneller als Echtzeit.

## Eigennamen und benannte Begriffe

Ein zweiter Durchlauf bewertet 16 eindeutige Eigennamen und Werktitel aus den manuell korrigierten Referenzen der Ausschnitte 3, 4 und 7.
Die Liste lautet `Mareike Fallwickel`, `Und alles so still`, `Die Wut die bleibt`, `Witches bitches it-girls`, `Pandora`, `Neuseeland`, `Kaikoura`, `Irland`, `Dublin`, `Galway`, `Cliffs of Moher`, `Harry Potter`, `Niederlanden`, `Niederländisch`, `Niederlandistik` und `Niedersachsen`.
Ein Begriff gilt nur dann als Treffer, wenn er nach derselben Unicode-, Groß-/Kleinschreibungs- und Zeichensetzungsnormalisierung vollständig im Hypothesentext vorkommt.

| Engine | Exakte Treffer | Recall |
|---|---:|---:|
| Apple SpeechAnalyzer | **12 / 16** | **75,00 %** |
| FluidAudio Parakeet TDT v3 | 9 / 16 | 56,25 % |
| Parakeet Primeline DE CoreML | 9 / 16 | 56,25 % |

Apple erkennt als einzige Engine `Und alles so still`, `Cliffs of Moher` und `Niederlandistik` exakt.
Alle drei Engines verfehlen `Mareike Fallwickel`, `Die Wut die bleibt`, `Witches bitches it-girls` und `Kaikoura`.
Der Eigennamen-Test bestätigt damit Apples Vorsprung auf diesem Korpus, obwohl einzelne Fach- oder Ortsnamen in realen Besprechungen weiterhin modellabhängig falsch geschrieben werden können.
Der Wert misst das Vorkommen jedes eindeutigen Begriffs genau einmal und weder die Zahl aller Nennungen noch Auslassungen eines wiederholt gesprochenen Namens.

## Einzelwerte

| Ausschnitt | Dauer | Apple WER | Parakeet WER | Primeline WER | Sortformer DER |
|---|---:|---:|---:|---:|---:|
| 01 | 159,4 s | 19,50 % | **18,58 %** | 19,95 % | 17,02 % |
| 02 | 117,7 s | 18,63 % | 20,34 % | **18,14 %** | 4,05 % |
| 03 | 147,4 s | **22,09 %** | 25,24 % | 25,97 % | 5,22 % |
| 04 | 97,0 s | **17,71 %** | 18,80 % | 20,98 % | 10,96 % |
| 05 | 115,1 s | **24,93 %** | 26,06 % | 28,33 % | 3,59 % |
| 06 | 88,5 s | **15,87 %** | 26,35 % | 21,26 % | 1,97 % |
| 07 | 91,6 s | **13,75 %** | 15,61 % | 14,87 % | 4,08 % |

Die sieben Dateien enthalten zusammen 816,65 Sekunden Audio.
Sortformer erkennt in jedem Ausschnitt exakt die zwei vorhandenen Sprechercluster.
Der dauergewichtete Mittelwert der sieben Einzelmessungen beträgt 7,33 % DER und 18,67 % JER.
Ohne überlappende Rede beträgt der entsprechende DER-Mittelwert 7,38 %.

## Messaufbau

Die Messung lief als lokaler Vorlauf auf einem Mac mini mit Apple M4, 24 GB Arbeitsspeicher und macOS 26.5.2 Build 25F84.
Der geplante Vergleich auf dem M5 Air mit macOS 27 konnte noch nicht ausgeführt werden, weil das Gerät im privaten Netz zwar auf ICMP antwortete, aber weder SSH noch Bildschirmfreigabe oder Dateifreigabe erreichbar waren.

Verwendet wurden die sieben Dateien `1_free_conversation_clip.mov` bis `7_free_conversation_clip.mov` aus OOCC v2 Task 1 und die zugehörigen manuell korrigierten CSV-Transkripte.
Die Audioquellen wurden mit FFmpeg deterministisch auf Mono, 16 kHz und PCM S16LE gemischt.
Die Wortreferenz folgt der zeitlichen Reihenfolge der manuell korrigierten Wörter.
Die Sprecherreferenz übernimmt die getrennten OOCC-Kanäle `LEFT` und `RIGHT` und fasst Wörter derselben Person bei höchstens 350 ms Abstand zu RTTM-Segmenten zusammen.

Die WER wurde mit `scripts/benchmark/score_asr.py` und dem Normalisierer `steno-de-v1` berechnet.
Die Diarisierung wurde mit `scripts/benchmark/score_diarization.py`, dscore Commit `e02f949ac6592279300a2c33d03daf9e0c12fd27` und einem Collar von 250 ms bewertet.

Apple lief über Stenos produktives Kommando `steno-transcribe` und damit über `SpeechAnalyzerProvider`.
Das reguläre Parakeet lief über Stenos produktiven `ParakeetTranscriptionProvider` mit FluidAudio 0.15.5, `melChunkContext = false` und dem Modell `parakeet-tdt-0.6b-v3-coreml`.
Primeline lief direkt über denselben FluidAudio-Decoder mit `melChunkContext = false`, deutscher Sprachvorgabe und dem Modell-Commit `d912a28d658a93c7eba99760d52a462f1bd3810a`.
Der direkte Primeline-Aufruf war nötig, weil Stenos produktiver Installer derzeit absichtlich nur die geprüften Checksummen des offiziellen Parakeet-Modells akzeptiert.
Die Diarisierung lief über Stenos produktives `steno-diarize-bench`, `FluidSortformerProvider`, `Sortformer_v2.1` und `wespeaker_v2`.

## Lizenz und Aussagegrenzen

OOCC v2 ist laut ausgeliefertem Quellenpaket unter CC BY-NC-ND 4.0 lizenziert.
Der Korpus bleibt deshalb ein lokaler, nichtkommerzieller Forschungskandidat und wird nicht als frei wiederverwendbare Produktbasis eingecheckt.
Die geprüften Quellarchive waren exakt die im Manifest registrierten Dateien mit MD5 `2dedd7b8aea80bec39f6815a6ad9f104` für Audio und Video sowie `2d512c753d4275e497b38548b362cf5b` für die Transkripte.

Überlappende Wörter haben in einem linearen Mischtranskript keine vollständig eindeutige Reihenfolge.
Die WER ist deshalb ein reproduzierbarer Engine-Vergleich auf demselben Vertrag, aber keine absolute linguistische Gütezahl für simultane Rede.
Die DER-Aggregation ist der dauergewichtete Mittelwert der sieben getrennten dscore-Läufe und keine gemeinsame Mikroauswertung über eine zusammengefügte RTTM-Datei.
Die Messung enthält nur spontane Zweipersonengespräche und deckt weder große Besprechungsräume noch Fachbegriffe, Dialekt, mehr als vier Personen oder Kiezdeutsch ab.

## Vorbereitung des Livevergleichs

Fuer den M5-Air-Lauf liegt ein getrenntes Live-Benchmarkwerkzeug fuer Apple SpeechAnalyzer, Stenos verborgenen Parakeet-Liveadapter und FluidAudio Nemotron 3.5 ASR Streaming Multilingual vor.
Der Nemotron-Runner pinnt FluidAudio auf Commit `667181a368da13b3a9178e310414e9dcbe8f23ce`, damit Stenos produktive FluidAudio-Version und Diarisierung unveraendert bleiben.
Das lokale Uebertragungspaket unter `/private/tmp/steno-oocc-benchmark` umfasst sieben validierte OOCC-Samples, beide arm64-Release-Runner, das gepruefte Parakeet-Modell, Startskripte und SHA-256-Pruefsummen.
Der Matrix-Trockenlauf plant fuer die sieben Samples exakt 42 Schritte: je drei Engines und drei anschliessende ASR-Auswertungen.

Ein Parakeet-Live-Smoke-Test mit Ausschnitt 7 lief nach Behebung eines echten Abschluss-Haengers in 4,77 Sekunden durch, erzeugte neun sichtbare Updates und erreichte 15,99 Prozent WER bei einer RTF von 0,0520.
Der Hänger entstand, weil FluidAudio 0.15.5 seine Update-Stream nach `finish()` offen laesst, obwohl der Modell-Endtext bereits vorliegt.
Steno beendet den Stream nun selbst und verwendet den von FluidAudio gelieferten Endtext.
Der vorhandene Parakeet-Sliding-Window-Manager reicht `de-DE` in FluidAudio 0.15.5 nicht bis zum Decoder weiter.
Der Vergleich misst daher diesen echten Steno-Livepfad, waehrend nur Apple und Nemotron eine explizite deutsche Modellvorgabe erhalten.

Apple meldete auf dem Mac mini beim Live- und beim unveraenderten bisherigen Datei-Runner bereits im System-Preflight `noSupportedLocale`.
Da beide Runner gleich scheitern, ist das kein belegter Fehler des neuen Live-CLI.
Der M5-Air-Lauf prueft deshalb zuerst Betriebssystem, installierte deutsche Speech-Assets und Apple-Verfuegbarkeit, bevor Qualitaets- oder Latenzzahlen verglichen werden.

## Livevergleich auf dem M5 Air

Der Livevergleich lief anschliessend erfolgreich auf einem MacBook Air `Mac17,4` mit Apple M5, 10 CPU-Kernen, 16 GB Arbeitsspeicher und macOS 27.0 Build `26A5406e`.
Das deutsche Apple-Sprachmodell war installiert und fuer `de-DE` verfuegbar.
Alle 21 Qualitaetslaeufe und die drei Echtzeitlaeufe wurden lokal auf dem Air ausgefuehrt.

### Endqualitaet im schnellen Modus

| Engine | WER | CER | Auslassungsrate | Fehler / Referenzwoerter | RTF |
|---|---:|---:|---:|---:|---:|
| Apple SpeechAnalyzer | **19,15 %** | **12,48 %** | **10,90 %** | 494 / 2.579 | **0,00810** |
| FluidAudio Parakeet TDT v3 Live | 20,90 % | 14,44 % | 11,48 % | 539 / 2.579 | 0,00820 |
| FluidAudio Nemotron 3.5 ASR Streaming Multilingual | 22,41 % | 13,51 % | 11,75 % | 578 / 2.579 | 0,01153 |

Apple gewinnt auch im Livepfad die laengengewichtete Gesamt-WER.
Parakeet liegt 1,75 Prozentpunkte und Nemotron 3,26 Prozentpunkte hinter Apple.
Parakeet gewinnt die Ausschnitte 1 und 2, Apple die Ausschnitte 3, 5, 6 und 7, und Apple sowie Nemotron erreichen auf Ausschnitt 4 denselben gerundeten WER-Wert.
Die sieben Dateien enthalten zusammen 816,65 Sekunden Audio.
Die gemessene Verarbeitung nach dem Aufbau der jeweiligen Live-Session entspricht etwa 123-facher Echtzeit fuer Apple, 122-facher Echtzeit fuer Parakeet und 87-facher Echtzeit fuer Nemotron.
Modellladen und Prozessstart sind in diesen RTF-Werten nicht enthalten und muessen fuer einen Kaltstartvergleich getrennt gemessen werden.

Der schnelle Modus verwendet fuer Parakeet und Nemotron 250-ms-Bloecke.
Apple bekommt 4-Sekunden-Bloecke, weil sein auf 64 Bloecke begrenzter Live-Eingabepuffer bei einer ungehemmten 250-ms-Zufuhr sichtbar ueberlief.
Auf Ausschnitt 3 erzeugten 4-Sekunden-Schnellzufuhr und 20-ms-Echtzeitzufuhr bei allen drei Engines exakt dieselbe WER und CER.
Damit ist fuer diesen geprueften Ausschnitt kein Qualitaetsunterschied durch die engine-spezifische Schnellzufuhr sichtbar.

### Eigennamen und Werktitel im Livepfad

Die bereits manuell markierten 16 Begriffe aus den Ausschnitten 3, 4 und 7 wurden ohne erneute Transkription gegen die neuen Live-Hypothesen ausgewertet.

| Engine | Exakte Treffer | Recall |
|---|---:|---:|
| Apple SpeechAnalyzer | **12 / 16** | **75,00 %** |
| FluidAudio Parakeet TDT v3 Live | 11 / 16 | 68,75 % |
| FluidAudio Nemotron 3.5 ASR Streaming Multilingual | 9 / 16 | 56,25 % |

Apple verfehlt weiterhin `Mareike Fallwickel`, `Die Wut die bleibt`, `Witches bitches it-girls` und `Kaikoura`.
Parakeet erkennt zusaetzlich `Niederlandistik` nicht exakt.
Nemotron verfehlt ausserdem `Und alles so still` und `Cliffs of Moher`.
Apple gewinnt damit auch diesen kleinen Eigennamen-Test, obwohl der Abstand zu Parakeet geringer ist als beim bisherigen Datei-Pfad.
Die Stichprobe ist fuer belastbare Fachwort- oder Teilnehmernamen-Aussagen weiterhin zu klein.

### Sichtbare Echtzeitlatenz auf Ausschnitt 3

| Engine | Erster Text | Erster bestaetigter Abschnitt | Updates | WER |
|---|---:|---:|---:|---:|
| FluidAudio Nemotron 3.5 | **4,54 s** | kein bestaetigtes Live-Event | 63 | 25,97 % |
| Apple SpeechAnalyzer | 11,70 s | 23,26 s | 553 | **21,84 %** |
| FluidAudio Parakeet TDT v3 | 13,16 s | **13,16 s** | 13 | 23,30 % |

Nemotron liefert den fruehesten ersten Text, aber sein erstes Update lautet nur `mal gerade was liest du so` und der aktuelle Runner erhaelt kein als final markiertes Live-Event.
Apple zeigt nach 11,70 Sekunden zuerst nur `Ja` und bestaetigt den ersten Abschnitt deutlich spaeter.
Parakeet zeigt nach 13,16 Sekunden direkt einen laengeren bestaetigten Abschnitt.
Ein einzelner Zeitwert fuer den ersten Text reicht deshalb nicht aus, um die wahrgenommene Livequalitaet zu bewerten.
Fuer die Produktentscheidung sollten kuenftig zusaetzlich Zeit bis zu einem Mindestumfang und Stabilitaet der Korrekturen gemessen werden.

## Empfehlung

Apple bleibt für diesen Korpus die Qualitätsbasis und soll weiterhin ohne Zusatzdownload verfügbar sein.
Das reguläre Parakeet und Primeline sollen nicht allein aufgrund allgemeiner Modellkarten als bessere deutsche Standardeinstellung gelten.
Primeline bleibt für einen zweiten Korpus mit Fachsprache und kurzen deutschen Äußerungen interessant, weil es dort laut Modellzweck Vorteile haben kann, die OOCC nicht abbildet.
Nemotron ist wegen seiner fruehen ersten Ausgabe als experimenteller Livepfad interessant, ersetzt Apple auf Basis der gemessenen Endqualitaet aber noch nicht.
Sortformer zählt die Sprecher zuverlässig, braucht aber insbesondere bei Ausschnitt 1 und 4 eine gezielte Segmentierungsanalyse.
Als naechster belastbarer Schritt folgen ein Kaltstartvergleich, ein Fachnamen-Korpus mit Notizen und Teilnehmernamen sowie der separat ausgerichtete Kiezdeutsch-Stresstest.
