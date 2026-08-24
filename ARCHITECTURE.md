# Steno für macOS - Architektur

Stand: 2026-08-04.
Verfasser: Claude (Fable 5), auf Basis der in `HANDOFF.md` genannten Quellen, alle lokal geprüft.
Kennzeichnung im Text: **[Fakt]** ist an einer lokalen Quelle verifiziert, **[Annahme]** ist plausibel aber ungemessen, **[Empfehlung]** ist eine Entscheidung dieses Entwurfs.

## 1. Gesamtentscheidung

Steno wird eine native Swift-App mit einem einzigen Repository, einem lokalen SwiftPM-Paket `StenoKit` mit klar geschnittenen Targets und einem dünnen macOS-App-Target.
Der Kern ist eine **dateibasierte, versionierte Bibliothek** mit unveränderlichen Originalen, append-only Verarbeitungsläufen und expliziten Revisionen, ohne Datenbank-Abhängigkeit im ersten Schnitt.
Transkription läuft primär über Apples `SpeechAnalyzer`/`SpeechTranscriber` (im macOS-26-SDK verifiziert, inklusive `audioTimeRange` für Wortzeitstempel und `volatileResults` für vorläufige Live-Ergebnisse).
Diarisierung übernimmt der vorhandene Sortformer/WeSpeaker-Code aus dem Sidecar als internes Swift-Target, in-process statt als Unterprozess.
Die Sprecheridentitätslogik aus `speaker_suggestions.py` wird als Swift-Domänenmodell neu geschnitten, ihre 13 gemessen begründeten Invarianten werden übernommen.

### Notwendige Korrekturen an den Annahmen des Handoffs

1. **"Mikrofon und Systemaudio bleiben als getrennte lokale Originalspuren erhalten" beschreibt einen Neubau, keinen Port.**
   [Fakt] Die heutige App nimmt eine einzige Stereo-WebM/Opus-Datei auf (Mikro=links, System=rechts, 48 kHz, `useSystemAudioCapture.ts:318-461`) und splittet erst nachträglich per ffmpeg auf 16 kHz mono (`transcriber.py:1877`).
   Die neue Aufnahmearchitektur schreibt von Anfang an zwei getrennte, unveränderliche Spuren.
2. **"Der Live-Pfad dekodiert ca. alle 400 ms ein wachsendes Fenster" stimmt nur halb.**
   [Fakt] Das Intervall ist 0,4 s, aber das Fenster ist auf 15 s gedeckelt und gleitet danach (`simple_recorder.py:2202-2203, 2576`); ein Keep-Pace-Guard streckt das Intervall bei Überlast bis 8 s.
   Die echten Probleme sind der doppelte Decode (Partial und Final je Utterance), ein einziger synchroner Consumer-Thread mit Backpressure auf der stdin-Pipe und der veraltete `ScriptProcessorNode` im Renderer.
   Das Zielbild bleibt richtig: eine streaming-native Pipeline ohne wiederholtes Dekodieren, die `SpeechAnalyzer` nativ liefert.
3. **Der experimentelle Offline-Diarizer aus `/private/tmp/wt-4plus` ist gemessen nicht auslieferbar.**
   [Fakt] VBx/AHC über 18 AMI-dev-Meetings: DER 40,01 gegen Sortformers 20,34; ohne Constraints DER 52,70; der Constraint-Pfad ist nicht deterministisch (ungeseedetes KMeans in FluidAudios `KMeansClustering.swift:64`).
   Der eigentliche Mehr-als-vier-Sprecher-Vergleich (8-Sprecher-Konkat in `work/eightspk/`) wurde begonnen, aber nie gescored.
   Konsequenz: Das Domänenmodell darf keine Slot-Grenze kennen, aber die Engine-Frage für mehr als vier Sprecher ist offen und bleibt hinter der Provider-Grenze.
4. **Die Vier-Slot-Grenze gilt pro Kanal, nicht pro Meeting.**
   [Fakt] Mit Mikro- und Systemspur sind heute bis zu acht Cluster möglich; ein Cross-Channel-Identity-Matching existiert nicht (`transcriber.py:1281`).
5. **LM Studio wird heute nirgends unterstützt.**
   [Fakt] `ai_provider` kennt `local` (gebündeltes Ollama), `remote` (Ollama-URL), `cloud`, `adapter` (`config.py:1781`); LM Studio kommt im Repository nicht vor.
   Die OpenAI-kompatible Provider-Grenze der neuen App deckt LM Studio, fremdes Ollama und Cloud-APIs mit einem Vertrag ab.
6. **Der Schutz der Originale widerspricht dem heutigen Default.**
   [Fakt] `keep_recordings: false` löscht Audio nach der Verarbeitung (`config.py:693-763`).
   In der neuen App sind Originale unveränderlich und werden nie automatisch gelöscht.
7. **Die größte Recovery-Lücke heute ist die fehlende persistente Job-Queue.**
   [Fakt] `processingQueue` ist In-Memory; nach einem Crash zwischen Stop und Verarbeitung bleibt die Aufnahme verwaist (`app/main.js`, `live-snapshot-sweep.js:12-20`).
   Die neue App persistiert Verarbeitungsläufe als Teil des Datenmodells.
8. **Alignment-Feinarbeit lohnt auf Konferenzmaterial nicht.**
   [Fakt] Overlap-Voting, Island-Smoothing, A-B-A-Kollaps: Exposure 0 bis 0,3 Prozent, alle "nicht bauen" (`HANDOFF-feat-speaker-alignment.md:60-72`).
   Übernommen werden nur der wortweise Split langer Sätze (ab 5 s, `transcriber.py:570`), Overlap-Clamping und die Distanzgrenze für den Nearest-Fallback.
   Ungemessen bleibt der Fall mehrerer Personen an einem Mikrofon; er ist Benchmark-Aufgabe, nicht Architekturannahme.

## 2. Module und Abhängigkeiten

Ein Repository, ein lokales SwiftPM-Paket `StenoKit` mit mehreren Targets, ein Xcode-App-Target.
[Empfehlung] Ein Paket mit Targets statt vieler Pakete: echte Grenzen über Target-Abhängigkeiten, ohne Versions- und Release-Overhead zwischen künstlich getrennten Paketen.

```
                        ┌─────────────────────┐
                        │      Steno.app       │  macOS-only (SwiftUI, AppKit bei Bedarf)
                        └──────────┬──────────┘
              ┌───────────────┬────┴─────┬────────────────┐
     ┌────────▼───────┐ ┌────▼─────┐ ┌──▼───────────┐ ┌──▼──────────┐
     │ StenoMacAudio  │ │StenoPipe-│ │StenoIntelli- │ │StenoExchange│
     │ (macOS-only)   │ │line      │ │gence         │ │             │
     └────────┬───────┘ └────┬─────┘ └──┬───────────┘ └──┬──────────┘
              │         ┌────┴──────────┴─────┐          │
              │         │  StenoTranscription │          │
              │         │  StenoDiarization   │          │
              │         │  StenoIdentity      │          │
              │         └────┬────────────────┘          │
              │              │                           │
     ┌────────▼──────────────▼───────────────────────────▼──┐
     │                    StenoLibrary                       │
     └───────────────────────────┬──────────────────────────┘
                        ┌────────▼────────┐
                        │   StenoDomain   │
                        └─────────────────┘
```

| Target | Inhalt | iOS-wiederverwendbar |
|---|---|---|
| `StenoDomain` | Reine Werttypen: Meeting, MediaAsset, Transcript, Revision, ProcessingRun, Person, Prototype, IDs. Keine I/O, keine Plattform-Frameworks. | Ja, vollständig |
| `StenoLibrary` | Bibliothekslayout auf Platte, atomare Writes, Schema-Versionierung und Migration, persistente Run-Queue, Integritätsprüfung. | Ja (FileManager-basiert) |
| `StenoTranscription` | ASR-Provider-Vertrag, `SpeechAnalyzerProvider`, Wort-Alignment-Regeln (wortweiser Split, Clamping). | Ja (Speech gibt es auf iOS 26) |
| `StenoDiarization` | Diarisierungs-Provider-Vertrag, `FluidSortformerProvider` (portierter Sidecar-Code), Embedding-Extraktion. | Ja (CoreML/FluidAudio läuft auf iOS), aber erst nach Bedarf |
| `StenoIdentity` | Sprecheridentität: Prototypen, Hard Negatives, Vorschlags-Gates, Run-Provenienz, Merge-Logik. | Ja, vollständig |
| `StenoIntelligence` | Vorlagen, `FoundationModelsProvider`, `OpenAICompatibleProvider` (LM Studio, Ollama, Cloud), strikt optional. | Ja |
| `StenoExchange` | Nicht destruktiver Steno-Altimport, Obsidian-Export, generische Exporte (Markdown, JSON). | Ja |
| `StenoPipeline` | Orchestrierung der Verarbeitungsläufe: Zustandsmaschine, Wiederaufnahme nach Crash, Fortschritt. | Ja |
| `StenoMacAudio` | Bewusst macOS-spezifisch: AVAudioEngine-Mikrofonaufnahme, CoreAudio Process Tap für Systemaudio, Mic-Monitor als interner Dienst (portiert aus `mic_monitor.swift`), Berechtigungen, Geräteverwaltung. | Nein, bewusst nicht |
| `Steno.app` | SwiftUI-Oberfläche, Menüleiste, Einstellungen, Onboarding. | Nein, bewusst nicht |

Abhängigkeitsregeln:
`StenoDomain` hängt von nichts ab.
Alles hängt von `StenoDomain` ab, nichts von der App.
Provider-Targets kennen `StenoLibrary` nur lesend über schmale Protokolle, die Pipeline schreibt.
Externe Abhängigkeit im ersten Schnitt: nur FluidAudio 0.15.2 (bereits gepinnt und im Sidecar produktiv bewährt).

## 3. Datenmodell

Die Bibliothek ist ein Verzeichnis mit definiertem, versioniertem Layout.
[Empfehlung] Dateibasiert statt SQLite/SwiftData im ersten Schnitt: atomare Writes sind im Altprojekt bewährt, die Verschlüsselungs-Beta (Kopie erstellen, prüfen, umschalten) und der Obsidian-Export arbeiten natürlich auf Dateien, und es entsteht keine Abhängigkeit.
Ein rein abgeleiteter Suchindex (später SQLite FTS oder Spotlight) darf jederzeit gelöscht und neu gebaut werden.

```
StenoLibrary/
  library.json                     # {schemaVersion, libraryId, createdAt}
  meetings/<meetingID>/
    meeting.json                   # Titel, Datum, Status, Teilnehmerliste (meeting-skopiert)
    media/<assetID>.caf            # unveränderliche Originale, eine Datei je Spur
    media/<assetID>.json           # MediaAsset-Metadaten inkl. provenanceKey
    runs/<runID>/
      run.json                     # Art, Engine+Version, Parameter, Status, Zeiten
      transcript.json              # ASR-Ausgabe mit Wortzeitstempeln (bei ASR-Läufen)
      diarization.json             # Sprechersegmente + Cluster-Embeddings (bei Diar-Läufen)
    transcript/
      revisions/<revisionID>.json  # append-only, nie überschrieben
      current.json                 # Zeiger auf die aktuelle Revision
    notes/…, reports/…             # Vorlagenergebnisse, Nutzernotizen
  identity/
    persons.json                   # Personen mit Prototypen und Hard Negatives
  jobs/
    <jobID>.json                   # persistente Verarbeitungsqueue
  exports/                         # Protokoll der Exporte (nicht die Exportziele selbst)
```

Kernentitäten (alle `Codable`, alle mit `schemaVersion` je Dokument):

- **Meeting**: Klammer um Medien, Läufe, Transkript, Ergebnisse. Trägt die meeting-skopierte Teilnehmerliste (Invariante aus dem Altsystem: Anwesenheit übersteht Re-Diarisierung).
- **MediaAsset**: unveränderliches Original. `kind` (micTrack, systemTrack, imported), Aufnahmegerät, Sample-Rate, Dauer, `provenanceKey`.
- **ProcessingRun**: ein Lauf einer Engine über definierte Eingaben. `kind` (liveASR, finalASR, diarization, identitySuggestion, templateRender, export), `engine` (Name + Version + Modellversion), Parameter, Status (queued, running, finished, failed, cancelled), Eingabe-IDs, Fehlerdetails. Läufe werden nie gelöscht, nur ihr Speicherplatz für Großartefakte kann kompaktiert werden.
- **TranscriptRevision**: vollständiger Transkriptstand als Folge von Turns mit Segmenten und Wörtern (`text`, `start`, `end` je Wort), Sprecherzuordnung je Turn (Cluster-Referenz oder bestätigte Person), `origin` (liveProvisional, finalRun(runID), userEdit(parentRevisionID)).
- **SpeakerCluster** (je Diarisierungslauf): `clusterID`, Kanal, Segmente, Embedding (256 floats), Sprechdauer, `containsMultipleSpeakers`, `reviewState`.
- **Person / SpeakerPrototype / HardNegative**: wie im Altsystem, kontextgetaggt (`recordingType`, `channel`, `meetingID`, `runID`), nie gemittelt über Kontexte hinweg.
- **UserCorrection**: als eigene Revision mit `origin: userEdit`, nie als In-place-Änderung.
- **TemplateResult**: Ergebnis eines Vorlagenlaufs, referenziert Transkript-Revision und Modell.
- **ExportRecord**: was wann wohin exportiert wurde, mit Revision-Referenz.

## 4. IDs, Provenienz, Revisionsregeln

- Alle IDs sind UUIDv7 (zeitlich sortierbar, kollisionsfrei), erzeugt bei Entstehung, nie wiederverwendet.
- **provenanceKey** je MediaAsset: SHA-256 über die Audiobytes bei Import; bei eigenen Aufnahmen `meetingID/trackKind`. Der Steno-Altimport bildet zusätzlich `legacy:<stem>` ab. Ein Import mit bekanntem provenanceKey wird abgelehnt beziehungsweise als Duplikat gemeldet; genau das verhindert doppelte Importe.
- **Unveränderliche Originale**: `media/*.caf` wird nach Abschluss der Aufnahme nie mehr beschrieben; jede Verarbeitung liest, schreibt aber nur in `runs/`.
- **Revisionsregeln**: Revisionen sind append-only; `current.json` ist ein atomarer Zeiger. Ein finaler ASR-Lauf erzeugt eine neue Revision und ersetzt niemals eine Benutzerkorrektur stillschweigend: Existieren Benutzer-Edits über einer älteren Basis, wird der neue Stand als Kandidat abgelegt und in der UI zur Übernahme angeboten, nicht automatisch umgeschaltet.
- **Run-Provenienz** für Identität: jede Bestätigung referenziert `runID` und `clusterID`; nach Re-Diarisierung werden alte Bestätigungen als veraltet markiert statt fälschlich als bestätigt angezeigt (Invariante und Fehlklasse aus dem Altsystem, `prototype_run_matches`).
- Getrennt gespeichert wird, was getrennt entsteht: Originale (unveränderlich), Lauf-Artefakte (reproduzierbar, kompaktierbar), Benutzerentscheidungen (wertvollstes Gut, klein, nie automatisch veränderbar).

## 5. Datenflüsse

**Live-Aufnahme.**
`StenoMacAudio` startet zwei Capture-Pfade: AVAudioEngine-Tap für das Mikrofon und CoreAudio Process Tap für Systemaudio.
Jede Spur geht in einen Ring-Puffer mit zwei Konsumenten: einem inkrementellen Disk-Writer (CAF, flush-freundlich, crash-tolerant) und der Live-Pipeline.
Die Live-Pipeline speist je Spur einen eigenen `SpeechTranscriber` mit `volatileResults`; vorläufige Ergebnisse erscheinen sofort im Transkript-Panel und sind als vorläufig markiert.
Live-Sprecherzuordnung ist im ersten Schnitt reine Kanalzuordnung ("Ich"/"Andere"), wie heute.
Kein erneutes Dekodieren: die Streaming-API ersetzt den 400-ms-Redecode-Pfad des Altsystems vollständig.

**Externer Import.**
Datei wählen, per AVFoundation dekodieren, provenanceKey berechnen, als MediaAsset kopieren (nie verschieben), Meeting anlegen, finalen Verarbeitungsjob einreihen.

**Finaler ASR-Lauf.**
Nach Stop oder Import erzeugt `StenoPipeline` einen persistierten Job: je Spur ein `SpeechTranscriber`-Lauf über die ganze Datei mit `audioTimeRange` je Wort, Ergebnis als `runs/<id>/transcript.json`, daraus eine neue TranscriptRevision, die die Live-Revision ersetzt (Regeln aus Abschnitt 4).

**Diarisierung.**
Je Spur läuft der `FluidSortformerProvider` (portierter Sidecar-Code: overlap-bereinigte Masken, 10-s-Fenster, WeSpeaker-Zentroide) über die Originaldatei.
Ausgabe sind Sprechersegmente plus ein Embedding je Cluster.
Das Alignment ordnet Sätze dem Segment am Satz-Mittelpunkt zu; Sätze ab 5 s über mehreren Sprechern werden wortweise zugeordnet; Unplatzierbares behält das Kanal-Label und wird nie verworfen (übernommene, gemessene Regeln).

**Sprecheridentifikation.**
`StenoIdentity` merged Fragmente je Kanal (Distanz kleiner gleich 0,10), rechnet Kandidaten über minimale Distanz zu kontextpassenden Prototypen, wendet die Gates an (Distanz 0,40, Margin 0,10, 20 s, 3 Segmente, mittlere Turn-Länge 1,55 s, mindestens 2 bestätigte Meetings) und liefert `confirmed`/`possible`/`none`.
Nichts wird automatisch benannt; nur der Mensch bestätigt, Bestätigungen erzeugen Prototypen und gegenseitige Hard Negatives, Re-Zuordnung entfernt alte Evidenz run-skopiert.

**Manuelle Korrektur.**
Jede Korrektur (Text, Sprecher, Segmentgrenzen) erzeugt eine neue Revision mit `origin: userEdit`; Undo ist Zeigerbewegung, nichts wird überschrieben.

**Vorlagenauswertung.**
`StenoIntelligence` rendert eine Vorlage gegen die aktuelle Revision; primär Foundation Models on-device, optional ein bewusst konfigurierter OpenAI-kompatibler Endpunkt.
Ohne LLM bleiben Transkript, Sprecher und Export vollständig nutzbar.

**Export.**
`StenoExchange` schreibt Markdown (mit Frontmatter) in ein vom Benutzer gewähltes Ziel; Obsidian-Export nur nach aktiver Freigabe, mit deutlichem Klartext-Hinweis; jeder Export erzeugt einen ExportRecord.

## 6. Provider-Verträge

Klein, konkret, ohne generische Überbauten.

```swift
protocol TranscriptionProvider {
    var descriptor: EngineDescriptor { get }   // Name, Version, Modellstand
    func liveSession(format: AudioFormat, locale: Locale) async throws -> LiveTranscriptionSession
    func transcribeFile(_ url: URL, locale: Locale) async throws -> TranscriptOutput  // mit Wortzeitstempeln
}

protocol LiveTranscriptionSession {
    func append(_ buffer: AudioBuffer) async
    var events: AsyncStream<TranscriptionEvent> { get }  // .volatile(...), .final(...)
    func finish() async throws -> TranscriptOutput
}

protocol DiarizationProvider {
    var descriptor: EngineDescriptor { get }
    func diarize(_ url: URL, hints: DiarizationHints) async throws -> DiarizationOutput
    // DiarizationHints: optionale minimale Sprecherzahl; Output: Segmente + Embeddings je Cluster
}

protocol SpeakerSuggestionEngine {   // reine Domänenlogik, kein ML-Provider
    func suggestions(for run: DiarizationOutput, in context: IdentityContext) -> [ClusterSuggestion]
}

protocol TextModelProvider {
    var descriptor: EngineDescriptor { get }
    func render(template: Template, transcript: TranscriptRevision) async throws -> TemplateResult
}

protocol Exporter {
    func export(_ meeting: MeetingSnapshot, to destination: ExportDestination) async throws -> ExportRecord
}
```

Benchmark-Kandidaten wie Nemotron oder ein späterer VBx-Pfad implementieren `TranscriptionProvider` beziehungsweise `DiarizationProvider` und werden erst nach eigenen Messungen produktiv geschaltet.
Der `EngineDescriptor` landet in jedem `run.json`, damit jedes Artefakt seinem Erzeuger zuordenbar bleibt.

## 7. Verhalten im Fehlerfall

- **Absturz während der Aufnahme**: CAF wird inkrementell geschrieben; beim nächsten Start findet die Recovery ein Meeting im Zustand `recording` ohne laufenden Prozess, schließt die Dateien, markiert die Aufnahme als "unterbrochen" und reiht den finalen Lauf ein. Nichts wird verworfen.
- **Absturz während der Verarbeitung**: Jobs liegen in `jobs/` mit Status und Wiederholungszähler; beim Start werden `running`-Jobs auf `queued` zurückgesetzt und idempotent neu ausgeführt (Läufe schreiben erst temporär, dann atomar).
- **Abbruch durch den Benutzer**: Job-Status `cancelled`, Teilartefakte werden gelöscht, das Meeting bleibt mit Live-Revision nutzbar.
- **Energiesparzustand**: Aufnahme setzt `ProcessInfo.beginActivity` gegen App-Nap/Idle-Sleep; Verarbeitungsjobs sind unterbrechbar und werden nach dem Aufwachen fortgesetzt.
- **Modellfehler**: Ein fehlgeschlagener Lauf beschädigt nie den vorherigen Stand; die letzte gültige Revision bleibt aktuell, der Fehler steht als `failed`-Run mit Details sichtbar im Meeting. Fallback-Kette: finaler ASR-Lauf scheitert, dann bleibt die Live-Revision final nutzbar (Rettungsnetz-Prinzip aus dem Altsystem, dort Issue #207).
- **Zu wenig Speicherplatz**: Vor Aufnahmestart und vor großen Läufen wird freier Platz geprüft; während der Aufnahme führt Unterschreiten einer Schwelle zu Warnung und sauberem Stop mit intaktem Original statt stillem Verlust.
- **Beschädigte Artefakte**: Jedes JSON-Dokument trägt `schemaVersion`; Parser lehnen ab statt zu raten. Ein beschädigtes Lauf-Artefakt wird quarantänisiert (`.corrupt`-Suffix), der Lauf gilt als `failed` und ist reproduzierbar; beschädigte Originale werden nie überschrieben, nur gemeldet.
- **Erneuter Start**: Die Startsequenz ist genau eine Funktion: Bibliothek validieren, Migration falls nötig (immer Kopie-dann-Umschalten bei strukturellen Änderungen), Recovery-Sweep, Queue fortsetzen.

## 8. Datenschutz, Logging, Verschlüsselung

- **Logging**: ausschließlich `os.Logger` mit Privacy-Annotationen; Gesprächsinhalte, Dateinamen, Transkripttexte und Modellausgaben sind grundsätzlich `.private` oder gar nicht geloggt. Es gibt keine Telemetrie im ersten Schnitt; falls später, dann opt-in und inhaltsfrei.
- **Netzwerkgrenze**: `StenoIntelligence` ist die einzige Stelle mit Netzwerkzugriff, und nur bei explizit konfiguriertem externem Provider; ein App-interner Schalter erzwingt "nur lokal". Modell-Downloads (SpeechAnalyzer-Assets über `AssetInventory`, FluidAudio-Modelle) sind Systemfunktionen beziehungsweise einmalige, sichtbare Downloads ohne Inhaltsdaten.
- **Verschlüsselungs-Beta** (zunächst deaktiviert): Aktivierung erzeugt eine vollständige verschlüsselte Kopie der Bibliothek (Dateiebene, Schlüssel im Keychain plus Recovery-Code für den Benutzer), entschlüsselt sie zur Prüfung vollständig zurück, vergleicht, und schaltet erst dann atomar um; die alte Bibliothek bleibt bis zur expliziten Löschung durch den Benutzer liegen. Niemals In-place.
   [Fakt] Das stärkste Schutzargument sind die Stimm-Embeddings als biometrische Daten (Entwurf `encryption-at-rest.md` im Altprojekt).
- **Recovery-Grenzen**: Ohne Schlüssel und ohne Recovery-Code sind verschlüsselte Daten verloren; das wird bei Aktivierung unmissverständlich gesagt und der Recovery-Code verpflichtend bestätigt.
- iCloud-Synchronisation und automatische Cloud-Importe bleiben ausgeschlossen, bis Verschlüsselung und Wiederherstellung zuverlässig funktionieren.

## 9. Test- und Benchmarkstrategie

- **Unit-Ebene** (schnell, deterministisch): Domäneninvarianten in `StenoDomain`/`StenoIdentity` (die 13 Invarianten des Altsystems werden als Testkatalog übernommen), Storage-Migrationen, Revisionsregeln, Alignment-Regeln mit synthetischen Wortzeitstempeln.
- **Integrationsebene**: Pipeline-Läufe gegen kleine echte Audiofixtures (mit `say` erzeugte Sprache wie im Alt-E2E), Crash-Recovery-Tests (Prozess töten, neu starten, Zustand prüfen), Storage-Roundtrips.
- **Benchmark-Kit**: `~/Dev/sandbox/steno-diar-bench` (AMI dev/test, CCC-Fenster, dscore, DER/JER-Dreiteilung) wird weiterverwendet; die neue App bekommt ein CLI-Target `steno-bench`, das dieselben RTTM-Formate erzeugt, damit alte und neue Zahlen vergleichbar bleiben.
- **Offene Messfragen mit Priorität**:
  1. SpeechAnalyzer gegen Parakeet auf Deutsch und Englisch (WER, Wortzeitstempel-Güte, Latenz, Energie); das entscheidet, ob die primäre ASR-Referenz hält. [Annahme] SpeechAnalyzer ist gut genug; ungemessen.
  2. Mehrere Personen an einem Mikrofon: echtes Material mit zeitaufgelöster Referenz beschaffen (die dokumentierte Lücke beider Alt-Handoffs); ohne dieses Material keine Alignment-Feinarbeit.
  3. Der ungescorte 8-Sprecher-Fall (`work/eightspk/`) wird zu Ende gemessen, bevor irgendeine Mehr-als-vier-Engine gebaut wird.
  4. Lange Sitzungen (4 h): Speicher- und Energieprofil der Streaming-Pipeline; Ziel ist konstanter Speicher statt wachsender Fenster.
- **Echtzeitfähigkeit**: Live-Pfad wird mit synthetischer Echtzeit-Einspeisung gemessen (Muster aus dem Alt-`@perf`-Spec); Kriterium ist, dass die Pipeline dauerhaft schneller als Echtzeit bleibt, auch bei zwei aktiven Spuren.

## 10. Vertikale Meilensteine

Reihenfolge wie im Handoff, mit einer Korrektur: Meilenstein 1 braucht bereits minimale SpeechAnalyzer-Integration, denn "sichtbares Transkript" ohne ASR ist leer; Meilenstein 2 vertieft dann Finallauf und Benchmarks.

1. **App-Hülle, Bibliothek, Aufnahme, Import, Live-Transkript.**
   Akzeptanz: Aufnahme erzeugt zwei getrennte CAF-Originale; Import kopiert mit provenanceKey; Live-Transkript erscheint während der Aufnahme; Kill -9 während der Aufnahme verliert kein Audio; Bibliothek übersteht Neustart mit Recovery-Sweep.
2. **Finaler ASR-Lauf und Benchmarks.**
   Akzeptanz: Finallauf ersetzt Live-Revision regelkonform, Wortzeitstempel je Wort vorhanden; WER-Vergleich SpeechAnalyzer gegen Parakeet-Referenzzahlen dokumentiert; Entscheidung über die ASR-Referenz aktenkundig.
3. **Diarisierung und Sprecheridentität als interne Module.**
   Akzeptanz: Sortformer-Port liefert auf den AMI-Fixtures DER im Rahmen der Alt-Basislinie (20,3 auf dev Array1-01, 8,98 auf IS1008a/b); Identitätsvorschläge reproduzieren die Gates; Bestätigen, Umbenennen, Many-to-one und Mixed-Marking funktionieren mit Run-Provenienz.
4. **Vorlagen mit Foundation Models.**
   Akzeptanz: Besprechungsprotokoll-Vorlage on-device; ohne Modell bleibt alles andere nutzbar.
5. **Optionale externe LLM-Provider.**
   Akzeptanz: LM Studio und eigenes Ollama über einen OpenAI-kompatiblen Vertrag, nie automatisch kontaktiert, Provider sichtbar am Ergebnis.
6. **Steno-Altimport und Obsidian-Export.**
   Akzeptanz: Import kopiert, verändert die alte Installation nie, dedupliziert über provenanceKey/legacy-Stems; Export nur nach Freigabe, mit Klartext-Hinweis.
7. **Verschlüsselungs-Beta.**
   Akzeptanz: Kopie-Prüfung-Umschalten nachgewiesen, Recovery-Code-Pflicht, alte Bibliothek bleibt bis zur expliziten Löschung.
8. **Später: iCloud, automatische Importe.** Erst nach 7.

## 11. Risiken und vertagte Entscheidungen

**Risiken:**
- SpeechAnalyzer-Qualität (insbesondere Deutsch, Fachvokabular, lange Sitzungen) ist ungemessen; Gegenmaßnahme ist die frühe Benchmark in Meilenstein 2 und die kleine Provider-Grenze.
- Mehr als vier Sprecher pro Kanal bleibt ungelöst; der VBx-Pfad ist gemessen schlechter und nicht deterministisch. Das Produktversprechen "unterscheidet mehr als vier Teilnehmende" ist heute nur kanalübergreifend einlösbar (Mikro plus System), nicht innerhalb eines Kanals. Das ist der größte Widerspruch zwischen Produktziel und vorhandener Technik.
- FluidAudio lädt Modelle von Hugging Face nach; Modell-Asset-Verwaltung (Bündeln, Pinnen, Offline-Fähigkeit) braucht eine bewusste Lösung, sonst erbt die App die fragile Download-Löschlogik des Altsystems.
- Mehrere Personen an einem Mikrofon: ohne Messmaterial bleibt jede Aussage dazu Annahme.
- CoreAudio Process Taps für Systemaudio erfordern Berechtigungen und haben App-übergreifende Eigenheiten; früh im Meilenstein 1 gegen reale Konferenz-Apps testen.

**Bewusst vertagt (offene Produktentscheidungen):**
1. Codec der Originalspuren (Start: CAF/PCM 16 bit; ALAC-Umstieg als Platzoption).
2. Ob ein SQLite-Suchindex in Meilenstein 2 oder später kommt.
3. Nemotron oder andere ASR-Alternativen: erst nach der SpeechAnalyzer-Benchmark überhaupt bewerten.
4. UI-Designsprache und Markenauftritt der neuen App.
5. Distribution (Developer-ID-Signierung, Notarisierung, Updates); im ersten Schnitt lokaler Build.
6. iOS: Domäne und Verträge bleiben portabel, aber keine iOS-Zeile vor stabilem macOS-Kern.
7. Verschlüsselungs-Detailentwurf (Schlüsselformat, Recovery-Code-UX) vor Meilenstein 7.
8. Ob das Sprecherzahl-Eingabefeld je kommt; falls ja, mit der Frage "wie viele haben gesprochen", nicht "wie viele nahmen teil".
