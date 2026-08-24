# Live-ASR-Benchmark auf dem M5 Air

**Ziel:** Apple SpeechAnalyzer, Stenos verborgenen Parakeet-Livepfad und FluidAudios multilingualen Nemotron-Streamingpfad mit denselben deutschen Audiodateien reproduzierbar messen, ohne die produktive Modellauswahl zu veraendern.

**Architektur:** Stenos bestehende Live-Provider bekommen ein reines Datei-Benchmark-CLI, das Audio in festen Blöcken einspeist und jedes vorlaeufige sowie bestaetigte Ergebnis mit Audio- und Wanduhrzeit als JSON protokolliert.
Nemotron bleibt in einem eigenen Swift-Paket auf einen geprüften FluidAudio-Commit gepinnt, damit Stenos produktive FluidAudio-Version und Diarisierung unangetastet bleiben.
Ein Python-Orchestrator validiert das bestehende Corpus-Manifest, startet alle drei Engines und wertet ihre finalen Texte mit dem vorhandenen ASR-Scorer aus.

## Grenzen

- Es werden nur die bereits vorbereiteten, lokal lizenzierten OOCC-Dateien verwendet.
- Apple und Nemotron bekommen explizit `de-DE`; automatische Spracherkennung ist kein eigener Vergleichsmodus.
- FluidAudio 0.15.5 reicht im vorhandenen Parakeet-Sliding-Window-API keine Sprache an den Decoder weiter. Der Lauf misst diesen echten aktuellen Steno-Pfad und kennzeichnet diese Grenze offen.
- Modellgewichte, Audio, Referenzen und Ergebnisse bleiben ausserhalb von Git.
- Der schnelle Modus misst Qualitaet und Rechenzeit.
- Der Echtzeitmodus misst sichtbare Live-Latenz und dauert so lange wie das Audio.
- Der Benchmark schaltet keine experimentelle Engine in der App frei.

## Umsetzung

1. Einen testbaren, providerneutralen Ereignis- und Ergebnisvertrag fuer Live-ASR-Messungen anlegen.
2. Ein `steno-live-transcribe`-CLI fuer Apple und den vorhandenen Parakeet-Liveadapter bauen.
3. Einen eigenstaendigen, auf FluidAudio `667181a368da13b3a9178e310414e9dcbe8f23ce` gepinnten Nemotron-Runner bauen.
4. Einen fail-closed Python-Orchestrator fuer Manifest, drei Engines, Hypothesen und Scoring bauen.
5. Das Air-Paket ohne Modellgewichte vorbereiten und nach dem Anschliessen auf dem M5 Air bauen, Modelle laden und einmal schnell sowie einmal in Echtzeit ausfuehren.

## Verifikation

- Neue Tests zuerst rot und danach gruen ausfuehren.
- Beide Runner im Release-Modus bauen.
- Die vorhandenen 19 Benchmarktests erneut ausfuehren.
- Wegen der StenoKit-Aenderung abschliessend XcodeGen, macOS-Build, iOS-Build und die komplette StenoKit-Suite einmal auf dem finalen Stand ausfuehren.
- Erst der echte M5-Lauf darf Hardware-, Latenz- oder Qualitaetsaussagen erzeugen.
