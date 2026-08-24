# Synthetische Demo-Aufnahmen

Das Bundle enthält ausschließlich drei vorgerenderte, fiktive deutsche PCM16-Mono-WAVs mit 22.050 Hz.

Die Laufzeiten sind 67,452517 Sekunden für `projektauftakt`, 59,454240 Sekunden für `wochenrunde` und 59,866485 Sekunden für `produktinterview`.

`projektauftakt` enthält zwei dokumentierte kurze Überlappungen mit zusammen 0,329161 Sekunden und maximal zwei gleichzeitigen Stimmen.

Die beiden anderen Zeitachsen sind sequenziell.

`render-demo-audio.sh` baut nur in einem markierten, task-eigenen Cache unter `/private/tmp/steno-demo-generator-*`, verifiziert alle festgelegten Artefakte und bündelt weder Modell noch Generator.

Der Cache gehört nach effektiver UID dem laufenden Nutzer, sein Wurzelverzeichnis hat Modus 0700 und seine nicht symbolische Besitzmarkierung Modus 0600.

Auch `runs`, `downloads`, Lock, Teildateien und Laufmarkierungen werden vor der Nutzung auf Eigentümer, Typ und restriktive Modi geprüft.

Jeder Build läuft nativ auf Apple Silicon in einem eigenen temporären Unterverzeichnis.

Der geteilte Download-Cache ist exklusiv gesperrt, und vollständig geprüfte Dateien werden atomar veröffentlicht.

CMake wird über die festgelegte GHCR-Digest-URL geladen; Homebrew wird weder aufgerufen noch verändert.

Der native Piper-Aufruf setzt `--noise_scale 0 --noise_w 0`, damit der gerenderte Clip bei diesem geprüften Toolchain-Stand byte-stabil ist.

Startposition und Pegel sind keine Fließkommaberechnungen mehr.

Jedes Segment enthält einen expliziten `startFrame` sowie einen ganzzahligen Verstärkungszähler mit 16 Nachkommabits.

Die Zähler sind 65.536 für 0 dB, 58.409 für -1 dB und 61.870 für -0,5 dB.

`start` und `gainDB` bleiben lesbare Dokumentation und werden gegen diese verbindlichen Ganzzahlwerte geprüft.

Bei der Pegelanpassung wird für positive und negative PCM-Werte exakt auf den nächsten ganzzahligen Wert gerundet; ein halber Wert wird jeweils von null weg gerundet.

Der Mixer misst Eingangspeak, Peak vor Begrenzung, Anzahl begrenzter Samples, Framezahl und Ausgangspeak.

Das normale Clipping-Budget ist null, und alle drei eingefrorenen Dateien wurden mit null begrenzten Samples erzeugt.

Audio, Timeline und Metriken werden zunächst in eindeutige Teildateien geschrieben; die WAV-Datei wird erst nach erfolgreicher Validierung und zuletzt atomar veröffentlicht.

Der Wrapper hält zusätzlich alle drei Meetings vollständig in einem eindeutigen Lauf-Staging zurück.

Er prüft Skript-Hash, Meeting-Menge, Null-Clipping sowie alle eingefrorenen WAV-Größen und -Hashes, bevor er ein noch nicht vorhandenes Zielverzeichnis als vollständigen Verzeichnisbaum veröffentlicht.

Optionale Evidenz wird ebenfalls als vollständiger Baum und vor dem abschließenden Audio-Ausgabebaum veröffentlicht.

Der finale Verzeichnis-Commit verwendet auf macOS direkt `renamex_np` mit `RENAME_EXCL` und kann deshalb kein zwischen Vorprüfung und Commit auftauchendes Ziel ersetzen oder als Elternverzeichnis verwenden.

Scheitert der abschließende Ausgabebaum nach bereits veröffentlichter Evidenz, wird nur der anhand von Gerät und Inode identifizierte eigene Evidenzbaum exklusiv auf seinen ursprünglichen Stagingnamen zurückbenannt und kontrolliert bereinigt.

Bei einer Identitätsabweichung bleibt der vorgefundene Baum unangetastet und der Lauf schlägt geschlossen fehl.

Zwei vollständige native Läufe mit demselben verifizierten Download-Cache, aber frischen Quell-, Build-, Installations- und Renderverzeichnissen ergaben byte-identische WAVs, Timelines und Metriken.

Geprüfter Werkzeugstand: macOS 26.5.2 (25F84), Xcode 26.6 (17F113), Apple Clang 21.0.0 (`clang-2100.1.1.101`), Python 3.14.7, jq 1.7.1-apple und CMake 4.4.2.

Piper stand auf `38917ffd8c0e219c6581d73e07b30ef1d572fce1`, Piper Phonemize auf `7e9174083b94fcc3c51c983a2394593abd81925b` und eSpeak NG auf `5c3a2e79c24f92cd408d067a9aa47553927ec891`.

Ein kleiner festgelegter Patch entfernt eSpeaks sonst auch bei deaktiviertem `USE_LIBSONIC` ausgeführten Sonic-Fetch aus der Quellkette.

Die Pins, URLs, Bytezahlen, Prüfsummen, Lizenzen und das einheitliche Prüfdatum 23. August 2026 stehen vollständig in `scripts/demo/demo-script.json`.

Piper und Piper Voices wurden als MIT geprüft.

Die Modellkarte erklärt das MLS-Trainingsmaterial als CC BY 4.0.

eSpeak NG ist GPL-3.0-or-later und nur eine nicht gebündelte Entwicklungsabhängigkeit.

Es stand kein bestätigter Hörpfad zur Verfügung.

Eine manuelle Hörannahme für Sprachverständlichkeit, Stimmtrennung und die zwei kurzen Überlappungen bleibt offen.
