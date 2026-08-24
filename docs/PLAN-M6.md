# Meilenstein 6: Steno-Altimport

Umsetzungsplan zu `ARCHITECTURE.md` Abschnitt 10, Meilenstein 6 - auf Produktentscheidung (2026-08-05) reduziert auf den Altimport; Obsidian-Export und Granola-Importer sind vertagt (siehe HANDOFF, spätere Liste).
Formatgrundlage ist `docs/LEGACY-FORMATS.md`; sie ist die verbindliche Referenz für alle Parser.
Reihenfolge verbindlich; jeder Schritt endet mit grünem `swift test` und einem Commit.

Grundsätze (Architektur + Handoff-Auftrag):

- Der Import ist ein expliziter, nicht destruktiver Kopiervorgang: Die alte Installation wird ausschließlich gelesen, niemals verändert; Audio wird kopiert, nie verschoben.
- Dedup über provenanceKey `legacy:<stem>` (bei Stem-Kollision `legacy:<stem>.<ext>`): Ein zweiter Import derselben Quelle legt nichts doppelt an, sondern meldet Duplikate.
- Kein automatischer Job-Anstoß und erst recht kein LLM-Lauf: Der Import stellt Daten bereit; Re-Diarisierung oder neue Protokolle stößt der Nutzer später selbst an.
- Alte Zeitpunkte bleiben erhalten (Aufnahmestart aus `sysaudio-<ms>`-Stems, sonst Frontmatter-`date`); nichts wird auf "jetzt" gestempelt.
- Ein Import erzeugt einen Bericht (angelegt/übersprungen/Waisen/Warnungen), damit der Nutzer prüfen kann, was passiert ist.

## Abbildung alt -> neu (Entscheidungen)

1. **Meeting je Stem** (nach `.md`/`.json`-Zwilling-Kollaps, `.md` gewinnt): Titel aus Frontmatter `title` (sonst Stem), Datum bevorzugt aus dem `sysaudio-<ms>`-Stem (Aufnahmestart), sonst Frontmatter `date`, Dauer aus `duration_seconds`.
2. **Audio** -> MediaAsset `kind: .imported`, provenanceKey `legacy:<stem>`; fehlendes Audio ist zulässig (keep_recordings=false), das Meeting entsteht trotzdem.
3. **Transkript** -> eine TranscriptRevision mit neuem Origin-Fall `legacyImport` (Codable-verträglich ergänzt). Diarisierter Body: je Zeile ein Turn, Start aus `[MM:SS]`, Ende = Start des Folge-Turns (letzter: Start + geschätzte Restdauer, gedeckelt auf `duration_seconds`), ein Segment je Turn, keine Wortzeitstempel (ehrlich: gab es nie). Sprecherzuordnung über das positionsgleiche `transcript_lines`-Manifest aus `_speakers.json` (Pairing per Index, nie per Timestamp) -> SpeakerReference `.cluster(runID: <Legacy-Run>, clusterID: "<channel>/SPEAKER_n")`; ohne Manifest bleibt das Text-Label als `.channel("<Label>")`. Nicht diarisiert: ein Turn je Absatz ohne Zeiten (start/end fortlaufend geschätzt), Sprecher nil.
4. **Diarisierungs-Cluster** aus `_speakers.json` -> ein synthetischer ProcessingRun `kind: .diarization` mit EngineDescriptor `legacy-stenoai` je Meeting; Cluster als IdentityCluster mit den 256er-WeSpeaker-Embeddings (gleicher Embedding-Raum wie die neue App!), `review_state: generic` und `contains_multiple_speakers` übernommen, Cluster-Schlüssel kanalpräfixiert (`mic/SPEAKER_0` vs. `system/SPEAKER_0`). Damit funktionieren Sprecherprüfung und Hörproben (sofern Audio da ist) auch für Alt-Meetings.
5. **person_profiles** -> Person + SpeakerPrototypes + HardNegatives 1:1 (gleiche Embedding-Dimension); `meeting_id`-Stems auf neue MeetingIDs mappen, dangling Referenzen tolerieren (Prototyp bleibt, verliert nur die Rückverfolgung). Namens-Dedup gegen bereits existierende Personen (case-insensitiv, wie alt): existiert die Person, werden nur fehlende Prototypen ergänzt (Dedup über prototype_id).
6. **Standard-Notiz** (Summary/Key Topics/Key Points/Action Items aus `_summary.md`-Body, nach `_overrides.json`-Anwendung) -> ein TemplateResult mit Legacy-EngineDescriptor (`legacy-stenoai`, modelVersion aus reports/config soweit bekannt) auf der importierten Revision. **Reports** aus `_reports.json` -> je ein weiteres TemplateResult (Template-Name aus custom_templates/Built-in-Liste aufgelöst; `standard-backup` wird übernommen, Reihenfolge jüngste zuerst wie gehabt).
7. **User Notes** (`## User Notes`) -> Meeting-Notiz im `notes/`-Bereich des neuen Meetings.
8. **Ordnerzuordnung** (`folders.json` + Frontmatter `folders`) -> als Meeting-Metadatum `legacyFolders: [Name]` gesichert (die Sidebar-Hierarchie kommt später; nichts geht verloren).
9. **Bewusst nicht importiert:** chat_sessions_v2.json (kein Chat in der neuen App; bleibt in der Alt-Installation erhalten), leere `voiceprints`, Telemetrie-/App-Settings. `.pending-delete/` wird geprüft und nur gemeldet, nie importiert.

## Schritt 1: StenoExchange-Target mit Legacy-Lesern (Codex)

- Neues Target `StenoExchange` (Abhängigkeiten: StenoDomain, StenoIdentity; keine externen Pakete).
- Reine Parser, getrennt von jedem Schreiben: `LegacyStore` (Verzeichnis-Scan, Stem-Sammlung inkl. Zwilling-Kollaps und Waisen), `LegacyTranscriptFile` (Header + beide Body-Varianten), `LegacySummaryFile` (zeilenbasierter Frontmatter-Parser exakt in der Alt-Lesart, NICHT YAML-strict; Body-Sektionen), `LegacySummaryJSON`, `LegacyReportsFile`, `LegacySpeakersFile` (inkl. transcript_lines), `LegacyPersonProfiles`, `LegacyFolders`, `LegacyOverrides`.
- Alle Zeitstempel-Epochen aus LEGACY-FORMATS.md Abschnitt 15 korrekt behandeln; `Date`-Erzeugung testbar.
- Fixtures: synthetische Beispieldateien nach der Spezifikation (inkl. Sonderfälle: nicht diarisiert, ohne transcript_lines, .md+.json-Zwilling, Umlaute im Stem, Electron-UTC-Datum, `processing: true`-Leiche). Keine echten Nutzdaten ins Repo.
- Tests: jeder Parser gegen seine Fixtures; Property: transcript_lines-Pairing ist exakt positionsgleich.

## Schritt 2: Importer in die neue Bibliothek (Codex)

- `LegacyImporter` in StenoExchange, arbeitet gegen die Library-API (StenoLibrary): pro Stem Meeting + MediaAsset (Kopie) + Revision (`legacyImport`-Origin, neuer Enum-Fall in StenoDomain) + synthetischer Diarisierungs-Run + Cluster + TemplateResults + Notiz; global Personen-Profile.
- Idempotenz: provenanceKey `legacy:<stem>`; existiert er, wird der Stem vollständig übersprungen und als Duplikat gezählt. Personen-Dedup wie oben. Abbruch mitten im Import hinterlässt nur vollständige Meetings (pro Stem atomar: erst alles vorbereiten, dann committen; halbe Stems werden beim nächsten Lauf neu importiert).
- `ImportReport`: Zähler (Meetings, Audio kopiert, Audio fehlend, Revisionen, Cluster, Personen, Prototypen, Reports, Notizen), Listen (Duplikate, Waisen, `.pending-delete`-Funde, Warnungen wie dangling Prototyp-Referenzen).
- Tests gegen eine Fixture-Alt-Installation im Temp-Verzeichnis: Vollimport, Wiederholung (alles Duplikat), Teilbestand (Waisen), fehlendes Audio, Personen-Merge in eine vorbefüllte Bibliothek, Absturz-Simulation (halber Stem wird repariert).

## Schritt 3: Import-UI (Driver, nicht Codex)

- Einstiegspunkt im Menü (Ablage > "Aus alter Steno-App importieren…") und in den Einstellungen: Quellordner wählen (Vorbelegung `~/Library/Application Support/stenoai`), Vorschau (was wurde gefunden, wie viele Duplikate), expliziter Start.
- Fortschritt sichtbar (pro Meeting), am Ende der ImportReport lesbar; Fehler einzelner Stems brechen den Rest nicht ab.
- Klarer Hinweis: Die alte Installation bleibt unverändert.

## Schritt 4: Realtest

- Import einer echten Alt-Installation (lesend); Stichproben: ein diarisiertes Meeting mit bestätigten Sprechern (Hörprobe + Namen), ein Meeting ohne Audio, Personen-Profile in der Identitätsverwaltung und Reports mit sichtbarer Legacy-Engine.
- Zweiter Importlauf direkt danach: 0 neue Objekte, alles Duplikate.
- Paritätsliste aktualisieren.

## Akzeptanz M6 (aus ARCHITECTURE.md, reduziert)

1. Import kopiert und verändert die alte Installation nie; Wiederholung dedupliziert über `legacy:<stem>`.
2. Alt-Meetings sind mit Transkript, Sprechern, Reports und Notizen in der neuen App nutzbar; Alt-Voiceprints speisen die Sprecher-Vorschläge.
3. Der ImportReport macht Umfang, Duplikate und Auslassungen sichtbar.
