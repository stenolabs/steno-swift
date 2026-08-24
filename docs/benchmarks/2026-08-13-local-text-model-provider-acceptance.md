# Lokale Textmodell-Provider: Realabnahme

Stand: 13. August 2026.

## Umfang und Datenschutz

Geprueft wurde Stenos nativer Ollama-Dialekt gegen einen freigegebenen CachyOS-Rechner im lokalen Netz.
Alle Anfragen enthielten ausschliesslich eigens fuer diesen Test erzeugte Saetze.
Kein gespeichertes Meeting, Transkript, Audio, Teilnehmername oder API-Schluessel wurde uebertragen.

Der LM-Studio-Endpunkt auf `localhost:1234` war waehrend dieser Abnahme nicht aktiv und wurde deshalb nicht erneut aufgerufen.
Der bereits dokumentierte LM-Studio-Realtest bleibt davon unberuehrt.

## Umgebung

| Komponente | Gepruefter Stand |
|---|---|
| Ollama-Host | CachyOS Linux `7.1.4-1-cachyos`, Ollama `0.32.4` |
| GPU | NVIDIA GeForce RTX 4070 Ti, 12.282 MiB VRAM |
| Arbeitsspeicher | 31 GiB |
| Steno-Endpunkt | `http://192.168.1.10:11434`, Dialekt `ollama`, self-hosted |
| Primaermodell | `gemma4:12b`, Q4_K_M, 7,6 GB |
| Arbeitskontext | 16.384 Tokens |
| Vergleichsmodell | `steno-gemma4:26b-16k`, Q4_K_M, 17 GB |

Ollama meldete fuer die Gemma-4-Basismodelle ein theoretisches Kontextfenster von 262.144 Tokens.
Steno verwendete fuer die Abnahme bewusst 16.384 Tokens, damit der lokale KV-Cache begrenzt und das Map-Reduce-Verhalten reproduzierbar bleibt.
Der native Steno-Probe meldet derzeit nur den konfigurierten Kontext zurueck; der separat gelesene Serverwert wird nicht als Providerwert ausgegeben.

## Ergebnisse

### Gemma 4 12B

| Pruefung | Ergebnis |
|---|---|
| Modellliste ueber `/api/tags` | Bestanden, exakte Modell-ID gefunden |
| Strukturierte Generierung ueber `/api/chat` | Bestanden |
| Provider-Descriptor | `ollama-native` |
| Deutsche Ausgabe | Bestanden |
| Notiz-Schreibweise `Stadt Musterstadt` | Bestanden |
| Kurzer Probe-Lauf | 2,1 bis 4,7 Sekunden bei warmem oder kaltem Modellzustand |
| Direkte strukturierte Generierung | 2,5 bis 3,1 Sekunden |
| Langer synthetischer Map-Reduce-Lauf | 3 Map-Aufrufe, 1 Reduce-Aufruf, 20,3 Sekunden |
| iPad-Simulator ueber denselben LAN-Endpunkt | Bestanden, 1 Test in 9,0 Sekunden |

Der lange Lauf bestand aus 320 synthetischen Sprecherbeitraegen und pruefte den tokenbasierten Chunking- und Reduce-Pfad.
Das Ergebnis war vollstaendig strukturiert, deutsch und enthielt `Musterstadt` unveraendert.

Eine leere Sektion `action-items` ist kein Transport- oder Strukturfehler, wenn der Eingang keine eindeutig vereinbarte Aufgabe enthaelt.
Ein Wiederholungslauf interpretierte die zukuenftige Pruefung als Aufgabe und fuellte die Sektion entsprechend.

### Gemma 4 26B

Das vorhandene Modell `steno-gemma4:26b-16k` bestand denselben kurzen Struktur-, Sprach- und Eigennamentest.
Der Probe-Lauf dauerte 10,4 Sekunden und die anschliessende strukturierte Generierung 4,7 Sekunden.
Ollama verteilte das 18-GB-Laufzeitmodell zu 52 Prozent auf die CPU und zu 48 Prozent auf die GPU; der Prozess belegte dabei rund 10,3 GiB VRAM.

Der 26B-Lauf ist damit technisch nutzbar, aber auf der 4070 Ti nicht vollstaendig im VRAM.
Fuer interaktive Verbindungstests und normale Protokolle ist `gemma4:12b` die schnellere Standardeinstellung.
Das 26B-Modell bleibt ein sinnvoller Qualitaetsvergleich fuer Offline-Laeufe.

## Nicht als bestanden gewertet

- Kein echtes Meeting wurde fuer diese Abnahme an Ollama gesendet.
- Der generische OpenAI-kompatible iOS-Pfad mit `/models` und `/chat/completions` wurde nicht durch den nativen Ollama-Test ersetzt.
- LM Studio wurde nicht gestartet, nur der nicht aktive lokale Endpunkt festgestellt.
- Eine qualitative Bewertung gegen ein manuell geprueftes Referenzprotokoll bleibt Teil des geplanten Benchmark-Korpus.

## Empfehlung

In Steno fuer den CachyOS-Rechner `Ollama`, `http://192.168.1.10:11434`, `gemma4:12b`, `Self-hosted` und `16384` Tokens verwenden.
Der API-Schluessel bleibt leer.
Fuer einen spaeteren Qualitaetsvergleich kann `steno-gemma4:26b-16k` ausgewaehlt werden, wenn die hoehere Latenz akzeptabel ist.
