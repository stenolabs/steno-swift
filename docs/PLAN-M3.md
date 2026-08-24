# Meilenstein 3: Diarisierung und Sprecheridentität als interne Module

Umsetzungsplan zu `ARCHITECTURE.md` Abschnitt 10, Meilenstein 3.
Reihenfolge verbindlich; jeder Schritt endet mit grünem `swift test` und einem Commit.
Referenzwissen: Der bestehende Sidecar-Code liegt in `~/Dev/Repositorys/stenoai/diarize-sidecar/Sources/main.swift` (eigener Code, Übernahme erlaubt); die Identitätslogik in `~/Dev/Repositorys/stenoai/src/speaker_suggestions.py` und `/private/tmp/wt-455b` (fachlich übernehmen, nicht zeilenweise portieren).

## Schritt 1: StenoDiarization mit Sortformer-Port

- Neues Target `StenoDiarization`, erste und einzige externe Abhängigkeit: FluidAudio, exakt Version 0.15.2 (gepinnt, im Altsystem produktiv bewährt).
- `DiarizationProvider`-Vertrag nach ARCHITECTURE.md Abschnitt 6: `diarize(_ url: URL, hints: DiarizationHints) async throws -> DiarizationOutput`; Output: Segmente (`clusterID`, `start`, `end`) plus ein 256er-Embedding je Cluster, `EngineDescriptor` mit Modellstand.
- `FluidSortformerProvider`, portiert aus dem Sidecar mit diesen bewahrten, empirisch begründeten Entscheidungen:
  - Mindestsegmentdauer 0,25 s (80-ms-Noise-Blips).
  - `.highContextV2` erst ab 90 s Audio (darunter liefert der Chunk-Loader NULL Segmente), sonst `.default`.
  - Compute Units default `.cpuAndNeuralEngine` (echte ANE-Ausführung), per Parameter übersteuerbar.
  - Overlap-bereinigte Masken (Frames mit mehr als einem aktiven Sprecher werden für ALLE genullt), Nearest-Neighbour-Resampling aufs WeSpeaker-Framegrid, 10-s-Chunks über die Top-3-aktiven Slots, L2-normalisierter Mittelwert je Slot als Centroid.
  - Fehlertoleranz je Chunk: ein transient scheiternder Embedding-Chunk wird übersprungen, nie der ganze Lauf verworfen; Embeddings sind best-effort, Segmente sind der tragende Output.
- Audio-Laden über AVAudioFile direkt auf 16 kHz mono Float (der ffmpeg-Umweg des Sidecars war ein PyInstaller-Workaround und entfällt in einer nativen App ersatzlos).
- Modellverwaltung: FluidAudio lädt von Hugging Face nach. Downloads sind nur nach explizitem Opt-in erlaubt (Parameter `allowModelDownload`, Default false wirft einen klaren Fehler mit Installationshinweis); die fragile Download-Löschlogik des Altsystems nicht erben.
- Hardwarefreie Tests für die reinen Funktionen (Maskenbau, Resampling, Centroid-Aggregation, Segmentfilter) mit synthetischen Predictions; Modellpfade werden in Schritt 2 gegen echte Fixtures gemessen, nicht unit-getestet.

## Schritt 2: Bench-Verifikation des Ports

- CLI-Target `steno-diarize-bench`: nimmt WAV + Optionen, schreibt RTTM (Format wie `to_rttm` im Bench-Kit) und optional Embeddings-JSON.
- Der Driver fährt damit die AMI-Fixtures aus `~/Dev/sandbox/steno-diar-bench` und scored mit dessen dscore-Setup.
- Akzeptanz (aus ARCHITECTURE.md): DER im Rahmen der Alt-Basislinie - Schnitt 8,98 auf IS1008a/b, um 20 auf den 6 dev-Meetings Array1-01. Nennenswerte Abweichung nach oben blockiert den Meilenstein.

## Schritt 3: StenoIdentity mit Personenregister

- Domänentypen in `StenoDomain`: `Person`, `SpeakerPrototype` (kontextgetaggt: `recordingType`, `channel`, `meetingID`, `runID`, Dauer, Segmentzahl, Herkunft), `HardNegative` (gleiche Struktur), `ClusterSuggestion`.
- Persistenz in `StenoLibrary`: `identity/persons.json`, atomar, versioniert; Personen-Namen eindeutig (case-/whitespace-insensitiv).
- `SpeakerSuggestionEngine` (reine Domänenlogik, kein ML-Provider) mit den gemessen geeichten Regeln des Altsystems:
  - Kosinusdistanz, minimale Distanz über kontextpassende Prototypen (bevorzugt gleicher `recordingType`, Fallback alle), NIE Mittelung über Kontexte.
  - Gates: Distanz <= 0,40, Margin 0,10 zum Zweitplatzierten, >= 20 s Sprechzeit, >= 3 Segmente, mittlere Turn-Länge >= 1,55 s, >= 2 bestätigte distinct Meetings; Ergebnis `confirmed`/`possible`/`none`.
  - Hard-Negative-Unterdrückung relativ (nur wenn neg <= 0,40 UND neg < best + 0,10).
  - `mergeSameChannelFragments`: Union-Find über paarweise Distanz <= 0,10, Kollaps auf das dauerstärkste Mitglied, dauergewichteter renormalisierter Mittelwert, `mergedFrom` protokolliert.
  - Meetingweite Exklusivität: nur `confirmed` verbraucht eine Person.
- Die 13 Invarianten aus der Quellenanalyse als expliziter Testkatalog, insbesondere: nie automatisch benennen; nur Bestätigtes persistieren; ein als "mehrere Personen" markierter Cluster ist vollständig draußen und Kontamination überlebt Merges; Kanal- und Run-Skopierung überall; Teilnehmerliste ist meeting-, nicht run-skopiert; "Ich"/Selbst wird nie umbenannt.
- Bestätigungsfluss: Confirm schreibt Prototype + gegenseitige Hard Negatives je anderer bestätigter Person in Meeting+Kanal (alle Cluster, many-to-one-fest); Re-Confirm entfernt alte Evidenz run-skopiert; Rücknahme räumt Negatives nur, wenn die Person im Meeting nicht mehr vertreten ist.

## Schritt 4: Pipeline-Integration

- Neuer Job `diarization` nach `finalASR`: je Spur `FluidSortformerProvider` über das Original, Ergebnis als `runs/<id>/diarization.json` (Segmente, Cluster, Embeddings, EngineDescriptor), atomar wie gehabt.
- Alignment als reine Funktion in `StenoTranscription` erweitert: Sätze aufs Diar-Segment am Satz-Mittelpunkt; Sätze >= 5 s über mehreren Sprechern wortweise über die Wortzeitstempel; Unplatzierbares behält das Kanal-Label; Diar-Segmente vorher merge (Gap 0,3 s), Overlap-Clamp, merge.
- Ergebnis: neue TranscriptRevision mit Cluster-Sprechern (`SpeakerReference.cluster(runID, clusterID)`), Regeln aus StenoLibrary unverändert (Benutzer-Edits nie stillschweigend ersetzen).
- Job `identitySuggestion` danach: Vorschläge berechnen, als `runs/<id>/suggestions.json` ablegen; nichts wird automatisch benannt.
- Crash-/Cancel-Verhalten identisch zu finalASR (idempotente Runs, Teilartefakte aufräumen).

## Schritt 5: Sprecher-Review in der App (Driver, nicht Codex)

- Meeting-Detail bekommt ein Sprecher-Panel: Cluster mit Sprechzeit absteigend, Vorschlag samt Status, Aktionen Bestätigen / Anderer Person zuweisen (bereits im Meeting vergebene zuerst, markiert) / Neue Person / "Mehrere Personen" markieren; Umbenennen wirkt auf die Revision, reversibel.
- Transkriptansicht zeigt bestätigte Namen statt Cluster-Labels.

## Akzeptanz M3 (aus ARCHITECTURE.md, überprüfbar)

1. `steno-diarize-bench` erreicht auf IS1008a/b DER im Rahmen von 8,98 und auf den dev-6 im Rahmen von 20,3.
2. Die Gate-Logik reproduziert auf synthetischen Fixtures die Alt-Entscheidungen (Testkatalog der 13 Invarianten grün).
3. Ende-zu-Ende: Aufnahme/Import -> finalASR -> Diarisierung -> Vorschläge -> Bestätigen/Umbenennen/Many-to-one/Mixed-Marking, mit Run-Provenienz (Re-Diarisierung invalidiert Bestätigungen sichtbar statt still).
