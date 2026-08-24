# Meilenstein 2: SpeechAnalyzer-Benchmark (ASR-Referenzentscheidung)

Gemessen am 2026-08-05 auf dieser Maschine (macOS 26.5, Apple Silicon).
Methodik und Rohdaten: `~/Dev/sandbox/steno-diar-bench`, Abschnitt 2g in RESULTS.md; Scoring identisch zur Parakeet-Basislinie aus Abschnitt 2d (gleiche Single-Stream-Referenz, gleicher Normalizer, gleiches jiwer).

## Ergebnis

| Engine | WER (length-weighted, 6 AMI-dev-Meetings, Array1-01) | RTF |
|---|---|---|
| Parakeet TDT v3 (stenoai-Basislinie) | 18,31 % | 0,0271 |
| SpeechAnalyzer (macOS 26) | 21,30 % | 0,0116 |

- Parakeet gewinnt jedes der sechs Meetings, mit 1,5 bis 6,8 Punkten; die Lücke wächst mit dem Überlappungsanteil.
- SpeechAnalyzer ist 2,3-mal schneller und liefert Wortzeitstempel nativ im Streaming-Vertrag, ohne Python, ohne Modell-Bundling, ohne ffmpeg.
- Beide Systeme sind deletionsdominiert; ein erheblicher Teil davon ist das dokumentierte Artefakt der zusammengelegten Single-Stream-Referenz bei Überlappung, kein verlorenes Audio.
- AMI Array1-01 ist Fernfeld-Array-Audio, der harte Fall. Über Nahbesprechungsmikrofon und Systemaudio-Loopback (Stenos Hauptfall) sagt die Messung nichts direkt aus.
- Deutsch bleibt für beide Engines unmessbar: kein Referenzkorpus (offener Punkt aus RESULTS.md 2d, erneut bestätigt).

## Entscheidung (aktenkundig gemäß ARCHITECTURE.md, Meilenstein 2)

**SpeechAnalyzer bleibt die primäre ASR-Referenz.** Begründung:

1. Die Lücke von 3 WER-Punkten liegt im Fernfeld-Worst-Case; der Produkt-Hauptfall (Nahfeld-Mikro plus getrennte Systemaudio-Spur) ist akustisch deutlich gutmütiger.
2. Die Architekturvorteile sind strukturell: nativer Streaming-Vertrag mit vorläufigen und finalen Ergebnissen (ersetzt den Redecode-Pfad des Altsystems), Wortzeitstempel ohne Zusatzaufwand, keine Fremdlaufzeit, Modellverwaltung durchs System.
3. Der Provider-Vertrag hält die Tür offen: Ein Parakeet- oder Nemotron-Provider ist ein Benchmark-Kandidat hinter derselben Grenze, falls die Qualität im echten Nutzungsprofil nicht reicht.

Revisionsauslöser (wann diese Entscheidung neu bewertet wird):

- Ein deutsches Referenzmaterial entsteht (z. B. ein von Hand korrigiertes CCC-Zehnminutenfenster) und zeigt eine deutlich größere Lücke als im Englischen.
- Reale Meetings zeigen systematische Auslassungen, die das AMI-Deletionsprofil widerspiegeln.
- Ein Nahfeld-Benchmark zeigt mehr als ~3 Punkte Abstand zugunsten einer Alternative.

## Nebenbefund mit Fix

Der LocaleResolver löste BCP-47-Anfragen mit Bindestrich (en-US, de-DE) gegen die Unterstrich-Identifier von SpeechTranscriber (en_US, de_DE) nicht exakt auf und fiel auf die erstbeste gleiche Sprache zurück (real: en_ZA, de_AT).
Gefixt mit normalisiertem Vergleich plus Region-Fallback und Regressionstest; der WER-Effekt war vernachlässigbar (21,19 gegen 21,30), weil der Normalizer Dialektschreibungen absorbiert.
