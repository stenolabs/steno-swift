# Testmaterial fuer Entwicklung und Benchmarks

Steno arbeitet im Alltag mit echten Besprechungen. Fuer Entwicklung, Screenshots
und Messungen ist das ungeeignet: Sie enthalten personenbezogene Daten Dritter
und duerfen die Maschine nicht verlassen.
Dieses Dokument haelt fest, welches oeffentliche Material stattdessen dient,
wo es liegt und - wichtiger - wofuer es taugt und wofuer nicht.

Die Audiodateien selbst liegen bewusst ausserhalb des Repositorys unter
`~/Dev/sandbox/steno-ccc-fixtures`.
Sie sind jederzeit ueber die unten genannten Quellen reproduzierbar.

## Die Aufnahmen

Beide Talks stammen von media.ccc.de und waren schon im Vorgaengerprojekt die
Grundlage des Sprecher-Wiedererkennungstests.

| Datei | Talk | Vortragende laut Metadaten | Dauer |
|---|---|---|---|
| `37c3-xandr-deu` | 37C3, "Die Akte Xandr" | Grace Hopper, Ingo Dachwitz | 42 min |
| `38c3-databroker-deu` | 38C3, "Databroker Files" | Grace Hopper, Ingo Dachwitz, Katharina Brunner, Rebecca Ciesielski | 39 min |

Je Talk liegen drei Fassungen vor: das Original als Ogg/Opus, eine Wandlung nach
16 kHz mono (Ogg/Opus kann macOS nicht oeffnen - dieselbe Huerde wie beim
WebM-Altimport), und ein Zehnminutenfenster ab Minute 5 fuer schnelle Durchlaeufe.

**Korrektur einer Annahme aus dem Vorgaengerprojekt:** Dessen Vorhersagedokument
fuehrt den 38C3-Talk als "dieselben zwei" Vortragenden.
Die Metadaten nennen vier.
Zwei davon sind mit dem 37C3-Talk identisch, der Wiedererkennungstest bleibt also
tragfaehig - aber die Erwartung "zwei dominante Cluster" stimmt nicht.

## Wofuer das Material taugt

**Sprecher-Wiedererkennung ueber Aufnahmen hinweg: gut geeignet.**
Zwei Aufnahmen, dieselben zwei Menschen, ein Jahr und ein Saalwechsel dazwischen.
Dafuer braucht es keine Textreferenz, nur die Frage, ob dieselbe Person
wiedererkannt wird - und einen Kontrolltalk mit fremden Stimmen, in dem kein
Vorschlag fallen darf.
Der Aufbau des Vorgaengerprojekts ist reproduzierbar; dessen Vorhersagen wurden
vor dem Lauf schriftlich festgeschrieben, was die richtige Vorgehensweise bleibt.

**Entwicklung, Screenshots, Oberflaechenpruefung: gut geeignet.**
Oeffentliches Material, das geteilt werden darf, statt echter Besprechungen.

**Wortfehlerrate: nicht ohne eigene Referenz.**
Die Untertitel von media.ccc.de sind fuer diese Talks maschinell erzeugt.
Die 37C3-Datei sagt es in ihrer ersten Zeile selbst: automatisch von YouTube
generiert und "dementsprechend (sehr) fehlerhaft".
Dagegen zu messen hiesse, die eigene Erkennung an den Fehlern einer fremden
Erkennung zu messen.
Die in der API hinterlegte Untertitelspur des 38C3-Talks ist ausserdem nicht
abrufbar (404).
Fuer belastbare WER- und DER-Zahlen bleibt AMI die Referenz (siehe
docs/BENCH-M2-ASR.md), weil es gepruefte Referenzen mitliefert.
Wer WER auf CCC-Material messen will, braucht eine selbst korrigierte Referenz -
im Vorgaengerprojekt waren das rund 60 Minuten Handarbeit fuer sechs
Zehnminutenfenster.

## Deutscher Referenzkorpus

Das neue Manifest unter `benchmarks/local-speech/manifest.json` trennt registrierte Quellen von wirklich benchmarkfaehigen Ausschnitten.
Es pinnt DOI, Lizenz, Quelldatei und veroeffentlichte Pruefsumme, waehrend Audio und Referenzkopien ausserhalb von Git bleiben.

Das `Kölner Korpus des Kiezdeutschen` ist als CC-BY-4.0-Stresstest registriert.
Sein manuelles GAT2-Transkript unterscheidet Sprecher und markiert Ueberlappungen, besitzt im PDF aber keine direkt auswertbaren Zeitstempel pro Zeile.
Vor einer Zahl muss ein exakter Ausschnitt zeitlich ausgerichtet und danach manuell geprueft werden.

Das `Open Oldenburg Conversation Corpus` ist als standardnaeher deutscher Hauptkandidat registriert.
Es enthaelt manuell korrigierte Zeitstempel, ist laut mitgelieferter Lizenz aber CC BY-NC-ND 4.0.
Es eignet sich fuer lokale nichtkommerzielle Forschung, ersetzt jedoch keine frei nutzbare Produktreferenz.
Die Auswahl des Standarddeutsch-Hauptausschnitts bleibt deshalb offen.

## Lizenz - ungeklaert, bewusst so notiert

Das Vorgaengerprojekt fuehrt das Material als "CC-lizenziert, oeffentlich
nachvollziehbar".
Belegen laesst sich das derzeit nicht: Die media.ccc.de-API liefert fuer beide
Talks und fuer die Konferenz `license: None`, und die Talkseite gibt ohne
JavaScript keine Lizenzangabe her.

Fuer die hiesige Nutzung ist das unkritisch - das Material wird lokal
verarbeitet und nicht weiterverbreitet.
Vor einer Veroeffentlichung von Ausschnitten, Screenshots mit erkennbarem
Inhalt oder abgeleiteten Transkripten muss die Lizenz je Talk geprueft werden.

## Reproduktion

Die Talks lassen sich ueber die oeffentliche API finden und laden:

```sh
curl -s "https://api.media.ccc.de/public/events/search?q=Akte%20Xandr"
# im Ergebnis: recordings -> Eintrag mit mime_type audio/opus und language deu
```

Danach wandeln, wie oben beschrieben:

```sh
ffmpeg -i <talk>.opus -ac 1 -ar 16000 <talk>-16k.wav
ffmpeg -ss 300 -t 600 -i <talk>-16k.wav <talk>-10min.wav
```

## Getrennte Bibliothek fuer die Entwicklung

`STENO_LIBRARY_DIR` uebersteuert den Bibliothekspfad
(`AppModel.libraryURL()`).
Die Entwicklung laeuft damit gegen eine eigene Bibliothek, und die echte
Bibliothek unter `~/Library/Application Support/Steno/Library` wird nicht
einmal geoeffnet:

`open` reicht keine Umgebungsvariablen an die App weiter - die Binary muss
direkt gestartet werden:

```sh
STENO_LIBRARY_DIR="$HOME/Library/Application Support/StenoTestLibrary" \
  .build/DerivedData/Build/Products/Debug/Steno.app/Contents/MacOS/Steno &

# Material ohne Oberflaeche einspielen (importiert und transkribiert):
StenoKit/.build/release/steno-smoke "$STENO_LIBRARY_DIR" <audio>.wav
```
