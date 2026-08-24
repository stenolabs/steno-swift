# Local Speech Benchmark Harness Implementation Plan

**Goal:** Steno erhaelt ein reproduzierbares, datenschutzfreundliches Grundgeruest fuer deutsche ASR- und Diarisierungsbenchmarks, das nur manuell gepruefte Referenzen als belastbare Ground Truth akzeptiert.

**Architecture:** Die produktiven Swift-Provider bleiben unveraendert.
Die vorhandenen CLIs `steno-transcribe` und `steno-diarize-bench` erzeugen Hypothesen.
Ein kleines Python-Tooling validiert Quellen, lokale unveraenderliche Ausschnitte und Referenzen, berechnet ASR-Metriken und reicht RTTM-Dateien an einen explizit gepinnten `dscore`-Checkout weiter.
Audiodateien, Referenzkopien und Modellausgaben bleiben ausserhalb von Git.

**Tech Stack:** Python 3 Standardbibliothek, SwiftPM-CLIs, RTTM/UEM, dscore, JSON.

## Constraints

- Echte Meetings und personenbezogene Arbeitsdaten werden nie als Benchmark-Fixures verwendet.
- Eine maschinell erzeugte Untertitelspur darf nicht als manuell gepruefte Referenz gelten.
- Lizenz, DOI, Quelldatei, Pruefsumme, exakter Ausschnitt und Referenzstatus sind Pflichtfelder.
- Ein nicht freier oder nicht kommerziell nutzbarer Kandidat bleibt sichtbar als Kandidat, wird aber nicht still zum Produktbenchmark.
- ASR und Diarisierung verwenden dieselben unveraenderlichen Audioausschnitte.
- Ergebnisdateien enthalten Modellkennung, Commit, Maschine, OS, Scorer und Parameter.
- Der eigentliche Modellvergleich laeuft spaeter auf dem M5 Air, nicht auf diesem Mac mini.

## Task 1: Manifestvertrag und Fail-Closed-Validierung

**Files:**

- Create: `benchmarks/local-speech/manifest.json`
- Create: `scripts/benchmark/manifest.py`
- Create: `scripts/tests/test_benchmark_manifest.py`

- [x] Tests fuer fehlende Lizenz-, Quellen-, Pruefsummen-, Ausschnitt- und Referenzfelder zuerst schreiben.
- [x] `metadata`-Pruefung fuer registrierte Quellen und strikte `ready`-Pruefung fuer lokale Benchmark-Ausschnitte implementieren.
- [x] Lokale Dateien nur relativ zu einem expliziten Corpus-Root aufloesen.
- [x] MD5 fuer unveraenderliche Quelldownloads und SHA-256 fuer lokale Ausschnitte und Referenzen pruefen.
- [x] Kiezdeutsch und OOCC mit ihrem tatsaechlichen Lizenz- und Referenzstatus registrieren.

## Task 2: ASR-Scoring

**Files:**

- Create: `scripts/benchmark/score_asr.py`
- Create: `scripts/tests/test_benchmark_score_asr.py`

- [x] Deterministische RED-Tests fuer WER, CER, Einfuegungen, Auslassungen, Ersetzungen und Eigennamen-Treffer schreiben.
- [x] Unicode-Normalisierung und deutsche Buchstaben beibehalten.
- [x] Referenz-JSON mit Sprechersegmenten lesen und das aktuelle `steno-transcribe`-JSON akzeptieren.
- [x] Maschinenlesbares Ergebnis mit Eingabehashes und Normalisierungskennung ausgeben.

## Task 3: Diarisierungs-Scoring aus Steno Legacy uebernehmen

**Files:**

- Create: `scripts/benchmark/score_diarization.py`
- Create: `scripts/tests/test_benchmark_score_diarization.py`

- [x] Die bereits verifizierten RTTM-, UEM- und Overlap-Regeln aus `~/Dev/sandbox/steno-diar-bench` uebernehmen.
- [x] dscore-Pfad und Version explizit als Argument verlangen.
- [x] All-, Non-overlap- und Overlap-only-Sichten mit 0,25-Sekunden-Collar ausgeben.
- [x] Keine Zahl fuer nicht vorhandene oder zu kurze Overlap-Regionen erfinden.

## Task 4: Dokumentation und M5-Air-Handoff

**Files:**

- Create: `benchmarks/local-speech/README.md`
- Modify: `docs/BENCH-FIXTURES.md`
- Modify: `docs/FEATURE-PARITY.md`

- [x] Quellenwahl, Lizenzgrenzen, Corpus-Root und Befehle dokumentieren.
- [x] Festhalten, dass Kiezdeutsch manuell transkribiert, aber noch nicht zeitlich ausgerichtet ist.
- [x] Festhalten, dass OOCC manuell korrigierte Zeitstempel besitzt, aber CC BY-NC-ND 4.0 statt einer freien Produktlizenz nutzt.
- [x] Den Standarddeutsch-Hauptkorpus-Punkt offen lassen, bis ein frei nutzbarer Kandidat ausgewaehlt und der exakte Ausschnitt geprueft ist.
- [x] Einen reproduzierbaren M5-Air-Lauf mit Apple, Parakeet und identischer Diarisierung vorbereiten, aber ohne Audio oder Referenz in Git zu legen.

## Task 5: Verifikation und lokaler Commit

- [x] Alle neuen Python-Tests ausfuehren.
- [x] Manifest im Metadatenmodus erfolgreich und im Ready-Modus erwartungsgemaess fail-closed pruefen.
- [x] Fokussierte iPad-Testwarnungsbereinigung verifizieren.
- [x] Mac-App, iPad-Simulator, StenoKit und den synthetischen Ollama-Realtest auf dem finalen Stand pruefen.
- [x] Task-eigene Downloads, Renderings, Ergebnisdateien und temporaere Buildwurzeln entfernen.
- [x] Nur die eigenen Dateien in logisch getrennten lokalen Commits sichern.
