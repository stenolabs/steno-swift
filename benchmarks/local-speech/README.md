# Lokaler Sprachbenchmark

Dieses Verzeichnis ist der versionierte Vertrag fuer Stenos ASR- und Diarisierungsbenchmarks.
Audio, Referenzkopien, Modellgewichte und Ergebnisse bleiben ausserhalb von Git in einem expliziten Corpus-Root.

## Warum das Manifest zunaechst keine Samples enthaelt

Die Quellenmetadaten sind verifiziert, aber noch kein Ausschnitt erfuellt alle Anforderungen an einen belastbaren Produktbenchmark.
Der Ready-Check scheitert deshalb absichtlich und sichtbar.
Eine plausible Zahl aus einer maschinellen Untertitelspur waere gefaehrlicher als eine offen fehlende Zahl.

Das Kölner Korpus des Kiezdeutschen ist unter CC BY 4.0 veroeffentlicht und manuell nach GAT2 transkribiert.
Die PDF-Transkripte enthalten Sprecher und Ueberlappungen, aber keine direkt nutzbaren Zeitstempel pro Zeile.
Es bleibt der geplante Stressfall, bis ein exakter Ausschnitt ausgerichtet und danach von Hand geprueft ist.

Das Open Oldenburg Conversation Corpus enthaelt zweiminuetige deutsche Dialoge mit manuell korrigierten Segment- und Wortzeitstempeln.
Seine mitgelieferte Lizenz ist jedoch CC BY-NC-ND 4.0.
Es ist daher ein technisch sehr guter lokaler Kandidat, aber keine frei kommerziell nutzbare Produktreferenz und wird nicht still als solche behandelt.

## Verzeichnisstruktur ausserhalb von Git

```text
<corpus-root>/
  samples/
    <sample-id>/
      audio.wav
      reference.json
      reference.rttm
      reference.uem
      hypotheses/
      scores/
```

Jeder fertige Sample-Eintrag in `manifest.json` verweist relativ auf diese Dateien und pinnt ihren SHA-256-Hash.
Der unveraenderliche Quelldownload bleibt durch die veroeffentlichte MD5-Pruefsumme nachvollziehbar.

## Referenzformat fuer ASR

```json
{
  "schemaVersion": 1,
  "sampleID": "example-de-01",
  "locale": "de-DE",
  "segments": [
    {
      "speaker": "spk01",
      "start": 0.0,
      "end": 2.4,
      "text": "Die Stadt Musterstadt prueft das Verfahren."
    }
  ],
  "namedTerms": ["Musterstadt"]
}
```

Sprecherkennungen sind dateilokal und enthalten keine echten Namen.
Die Diarisierungsreferenz verwendet RTTM, der ausgewertete Bereich UEM.
Ein Sample darf genau eine Aufnahme und einen Kanal enthalten; abweichende RTTM- oder UEM-Identitaeten werden abgelehnt.

## Pruefen und auswerten

Die registrierten Quellen lassen sich ohne lokale Audiodateien pruefen:

```sh
python3 scripts/benchmark/manifest.py metadata benchmarks/local-speech/manifest.json
```

Der strikte Check verlangt alle lokalen, manuell geprueften Referenzen und ihre Hashes:

```sh
python3 scripts/benchmark/manifest.py ready benchmarks/local-speech/manifest.json \
  --corpus-root "$STENO_BENCH_CORPUS"
```

Eine ASR-Hypothese erzeugt Stenos vorhandenes CLI:

```sh
swift run --package-path StenoKit steno-transcribe \
  "$STENO_BENCH_CORPUS/samples/example-de-01/audio.wav" de-DE \
  > "$STENO_BENCH_CORPUS/samples/example-de-01/hypotheses/apple.json"
```

WER, CER, Auslassungen und Eigennamen-Treffer werden so berechnet:

```sh
python3 scripts/benchmark/score_asr.py \
  "$STENO_BENCH_CORPUS/samples/example-de-01/reference.json" \
  "$STENO_BENCH_CORPUS/samples/example-de-01/hypotheses/apple.json" \
  --output "$STENO_BENCH_CORPUS/samples/example-de-01/scores/apple.json"
```

Die Diarisierung schreibt Steno als RTTM:

```sh
swift run --package-path StenoKit steno-diarize-bench \
  "$STENO_BENCH_CORPUS/samples/example-de-01/audio.wav" \
  "$STENO_BENCH_CORPUS/samples/example-de-01/hypotheses/sortformer.rttm"
```

Der Scorer uebernimmt den in Steno Legacy belegten Vertrag mit 0,25 Sekunden Collar sowie All-, Non-overlap- und Overlap-only-Sicht.
Wenn keine Ueberlappung vorhanden ist oder alle Ueberlappungsfenster vollstaendig vom Collar verbraucht werden, wird bewusst keine Overlap-Kennzahl ausgegeben.
Der verwendete dscore-Checkout und seine Version muessen ausdruecklich angegeben werden:

```sh
python3 scripts/benchmark/score_diarization.py \
  "$STENO_BENCH_CORPUS/samples/example-de-01/reference.rttm" \
  "$STENO_BENCH_CORPUS/samples/example-de-01/hypotheses/sortformer.rttm" \
  --uem "$STENO_BENCH_CORPUS/samples/example-de-01/reference.uem" \
  --dscore "$STENO_DSCORE/score.py" \
  --dscore-version "$STENO_DSCORE_COMMIT" \
  --output "$STENO_BENCH_CORPUS/samples/example-de-01/scores/sortformer.json"
```

## Geplanter Hardwarelauf

Der eigentliche Vergleich von Apple, Parakeet und Sortformer laeuft auf dem M5 Air mit demselben Audioausschnitt und denselben Referenzen.
Jeder Bericht nennt Steno-Commit, Modellkennung und Gewichtsdigest, macOS-Build, Hardware, Compute Units, kalten oder warmen Lauf und Laufreihenfolge.
Der Mac mini bleibt fuer diesen Vergleich bewusst ungemessen, damit die Zahlen nicht mit zwei Hardwareplattformen vermischt werden.
