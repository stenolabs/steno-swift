# Altdaten-Formate der stenoai-App (Import-Spezifikation)

Analysiert 2026-08-05 (Explore-Agent, Driver-geprüft) aus dem Schreib-Code des Alt-Repos `~/Dev/Repositorys/stenoai` (Autorität) und den echten Nutzdaten unter `~/Library/Application Support/stenoai/` (Bestätigung).
Legende: [C] = im Code belegt, [D] = nur aus Beispieldateien geschlossen.

## 0. Verzeichnis-Layout

[C] `src/config.py get_data_dirs`: Basis = `storage_path` aus config.json, sonst `~/Library/Application Support/stenoai`, sonst Repo-Root (Dev).

```
<base>/recordings/     Audio (.webm Opus eigene Sysaudio-Aufnahmen, .m4a/.wav Importe)
<base>/transcripts/    <stem>_transcript.txt
<base>/output/         <stem>_summary.md|json, _reports.json, _speakers.json,
                       _original.json, _overrides.json, <safeSessionStem>_notes.txt
<base>/folders.json
<base>/chat_sessions_v2.json
<base>/config.json     (person_profiles, voiceprints, custom_templates, template_overrides)
```

[D] Real: 17 Recordings, 23 Transkripte, 54 Output-Dateien (19 `_summary.md`, 14 `_speakers.json`, 13 `_reports.json`, 4 `_summary.json`, 3 `_original.json`, 1 `_overrides.json`).

## 1. Der Stem als Herkunfts-ID

[C] Stem = Dateiname der Audiodatei ohne Extension. Eigene Aufnahmen: `sysaudio-<epoch_ms>-<SafeName>` (`Date.now()` in Millisekunden = Aufnahmestart; `safeName = sessionName.replace(/[^a-zA-Z0-9_-]/g,'_').slice(0,64)`). Importe: Original-Basename unsanitisiert ([D] Umlaute/Leerzeichen kommen vor).

- Alle Sidecars sind stem-gekoppelt; `_speakers.json.meeting_id` == Stem, `person_profiles[].prototypes[].meeting_id` == Stem. [C]
- [C] Kollisionsrisiko dokumentiert (main.js: "meeting.wav und meeting.m4a kollidieren"); `.md`- und `.json`-Summary desselben Stems werden auf einen Key kollabiert (`summaryStemKey`), `.md` gewinnt.
- Empfehlung: Stem als Legacy-Herkunft mitführen, intern neue UUIDs.

## 2. recordings/

[C] Abgebrochene Aufnahmen bleiben als partielle Datei ohne Sidecars liegen. Bei `keep_recordings=false` wird Audio nach Verarbeitung gelöscht -> Transkript ohne Audio ist normal.

## 3. transcripts/<stem>_transcript.txt

[C] Einziger Writer `simple_recorder.py _write_transcript_file`. UTF-8:

```
Session: {session_name}
File: {audio_path.name}
Date: {YYYY-MM-DD HH:MM:SS}          <- lokale Zeit, KEINE TZ, Verarbeitungszeit
Language setting: {Klarname}
Detected language: {Klarname oder "Unknown"}
Summary output language: {Klarname}

============================================================     <- '='*60

{body}
```

Body-Varianten [C]:
- nicht diarisiert: Absätze (Turns) getrennt durch Leerzeile, ohne Präfixe.
- diarisiert: `[{MM:SS oder H:MM:SS}] [{speaker}] {text}` je Turn, Turns durch Leerzeile getrennt. Zeitstempel = Sekunden ab Aufnahmestart, nur Sekundenauflösung, nur Turn-Start. Keine Endezeiten, keine Wort-Zeitstempel (ASR-Segmente wurden nie persistiert).

Sprecher-Labels [C+D]: `You`, `Others`, `Speaker 2/3/4`, `Owner`, sowie durch confirm-speaker eingesetzte Klarnamen.

[D] Waisen real vorhanden: Transkripte ohne Summary und eine Summary ohne Transkript.

## 4. output/<stem>_summary.md (kanonische Notiz)

[C] Frontmatter ist KEIN YAML, sondern zeilenbasiert (`key: value`; `"…"`-Unquoting, `[`->JSON.parse, null/true/false, `^-?\d+$`->int). Import muss diese Lesart nachbauen.

Felder: `title` (string), `date` (ISO lokal OHNE TZ = Verarbeitungszeit; Electron-Platzhalter schreibt stattdessen UTC mit `Z`!), `duration_seconds` (int|null), `language`, `configured_language`, `detected_language`, `is_diarised` (bool), `notes_generated` (nur false), `is_live_transcript` (nur true), `processing` (nur true, hängengebliebener Platzhalter), `notes_stale` (bool), `folders` (JSON-Array von Folder-IDs), `transcript_corrected_at`/`summary_generated_at`/`updated_at` (ISO), Fehlerfall: `transcription_failed`, `reprocessable`, `audio_file`, `error`.

Body-Sektionen (`## ` auf eigener Zeile): Summary, Key Topics (`### {title}` + Freitext je Topic), Key Points (Bullets), Action Items (Bullets), Participants (EINE Zeile, kommasepariert), Transcript (== Body der _transcript.txt, diarisiert bevorzugt, ohne Header), User Notes (immer letzte Sektion).

## 5. output/<stem>_summary.json (Legacy, read-only)

Top-Level: `session_info` (obj mit u. a. `name`, absoluten Pfaden, `processed_at`, `duration_seconds`, Sprachen, `reprocessable`, `updated_at`), `summary` (str), `participants` (array), `discussion_areas` (array {title, analysis}), `key_points`, `action_items`, `transcript` (str), `is_diarised`, `diarised_text` (str), `user_notes` (str|null), `folders`.
`.md` und `.json` können für denselben Stem koexistieren; `.md` gewinnt. [C]

## 6. output/<stem>_reports.json

```jsonc
{ "reports": [ { "id": "rep_<12hex>", "template_id": "…", "template_name": "…",
    "model": "…", "content": "Markdown", "created_at": "ISO lokal" } ],
  "active_report": "rep_…|null" }   // null/"standard" = Standard-Notiz anzeigen
```

[D] Reale template_ids: detailed, kollegen, sales-call, shareable-summary, standard-backup ("Previous version · <Datum>" = automatischer Backup-Snapshot).
[C] Built-ins (`src/templates.py`): standard, product-demo, sales-call, one-on-one, standup, shareable-summary. `detailed`/`kollegen` kommen aus `custom_templates` in config.json -> Templates mitimportieren, sonst sind Reports namenlos referenziert.

## 7. output/<stem>_speakers.json (wertvollstes Alt-Asset)

```jsonc
{ "meeting_id": "<stem>",
  "created_at": 1785862866.9,          // Unix-SEKUNDEN float
  "channels": { "mic"|"system": {      // nur diese zwei Keys
      "recording_type": "in_person"|"remote"|"imported"|"unknown",
      "clusters": { "SPEAKER_0": {     // je Kanal unabhängig nummeriert!
          "embedding": [256 floats],   // WeSpeaker-Centroid, Dim 256
          "speech_duration_seconds": f, "segment_count": int,
          "segments": [{"start": f, "end": f}],   // Sekunden ab Start
          "review_state": "generic",              // optional
          "contains_multiple_speakers": true } } } },  // optional
  "transcript_lines": [                // OPTIONAL (8 von 14 Dateien haben es NICHT)
    { "start": f, "channel": "mic"|"system",
      "diarization_speaker_id": "SPEAKER_n"|null,
      "original_label": "You|Speaker 2|…" } ] }   // optional, Label VOR Umbenennung
```

Kritisch [C]: `transcript_lines` ist 1:1 POSITIONSGLEICH mit den diarisierten Zeilen im Transkript-Body - per Index paaren, nie per Timestamp. `(channel, SPEAKER_n)` ist der Schlüssel. Die Datei trägt die einzige Kopie der Embeddings (nach Audio-Löschung nicht reproduzierbar).

## 8. _original.json / _overrides.json (Legacy-Sidecars, Nutzer-Edits)

Vom aktuellen Alt-Code nicht mehr geschrieben. `_original.json`: Snapshot der ursprünglichen Modellausgabe + `edited_fields` (welche Sektionen der Nutzer angefasst hat), `edited_at` UTC mit Z. `_overrides.json`: `{fields: {<feld>: {value, edited_at}}}` - Nutzer-Overrides, beim Import NACH der Summary anwenden.

## 9. <safeSessionStem>_notes.txt

An den Session-NAMEN gekoppelt (nicht Stem), wird nach Verarbeitung als `## User Notes` in die .md konsumiert. [D] Keine mehr vorhanden; `## User Notes` reicht.

## 10. folders.json

`{folders: [{id: "8hex", name, color, created_at ISO, order, icon?}]}` - flach, keine Verschachtelung. Zuordnung Meeting->Ordner hängt am Meeting-File: Frontmatter `folders: ["<id>"]` (.md) bzw. Top-Level `folders` (.json); Mehrfachzuordnung möglich. [D] Real: 1 Ordner "Arbeit", 1 Meeting zugeordnet. Korrupte Datei wird als `folders.json.corrupt` quarantäniert.

## 11. chat_sessions_v2.json

`{sessions: [{id: "s-<ms>-<rand>", name, summaryFile: ABSOLUTER Pfad, createdAt/updatedAt: Epoch-MILLISEKUNDEN, messages: [{role, content, ts}]}]}`. Meeting-Bindung über absoluten Pfad -> auf Stem normalisieren. [D] 4 Sessions.

## 12. config.json -> person_profiles (Sprecher-Identitäten)

```jsonc
"person_profiles": [ { "person_id": uuid4, "display_name": "UNIQUE (case-insensitiv)",
  "created_at"/"updated_at": Unix-Sekunden float,
  "prototypes": [P], "hard_negatives": [P] } ]
```

SpeakerPrototype P: `prototype_id` uuid4, `person_id` (redundant), `embedding_mean` float[256], `sample_count` int, `quality_score` float 0..1, `recording_type` (in_person|remote|imported|unknown), `meeting_id` (== Stem!), `diarization_speaker_id` (SPEAKER_n), `channel` (mic|system|null; null = Legacy/Enrollment), `speech_duration_seconds`, `segment_count`, `created_from` (user_confirmed|user_corrected|manual_enrollment), `created_at`.

[D] 14 Profile, Dim durchgängig 256, 2 dangling meeting_ids (Meetings existieren nicht mehr) -> dangling tolerieren.
[C] Kopplung: Beim Löschen einer Person müssen abgeleitete hard_negatives in allen anderen Profilen entfernt werden (Schlüssel meeting_id+channel+sid) - Kopplung beim Import erhalten.

`voiceprints` (Legacy-Self-Match): [D] leer, nichts zu importieren.
Weitere relevante Keys: `custom_templates` (Array: id, name, icon, prompt, format, language), `template_overrides`, `language`/`ui_language`, `user_name`, `storage_path`, `keep_recordings`.

## 13. Gelöschte Meetings

Kein Archiv. 2-Phasen-Löschung über `output/.pending-delete/` (8 s Undo, dann endgültig). Ein Import sollte `.pending-delete/` prüfen (Absturz-Leichen möglich). [D] Aktuell leer/nicht vorhanden.

## 14. Kein Meeting-Index

Metadaten leben ausschließlich im Frontmatter der `_summary.md` (bzw. `session_info` der Legacy-.json). Meeting-Liste = Scan von `output/*_summary.md`. Waisen (Transkript ohne Summary, Summary ohne Transkript, Recording ohne beides) kommen real vor.

## 15. Zeitstempel-Epochen (gemischt!)

- Unix-Sekunden float: `_speakers.json.created_at`, person_profiles/prototypes, voiceprints.
- Unix-Millisekunden int: chat_sessions, Stem-Zahlteil `sysaudio-<ms>-…` (= Aufnahmestart!).
- ISO lokal ohne TZ: .md-Frontmatter `date` (= Verarbeitungszeit), reports/folders `created_at`, `session_info.processed_at`.
- ISO UTC mit Z: Electron-geschriebene Felder (Platzhalter-`date`, `_original.json.edited_at`).
- Relative Sekunden ab Aufnahmestart: `segments[].start/end`, `transcript_lines[].start`, `[MM:SS]` im Text.

Wichtigste Alt-Quelldateien: `src/speaker_suggestions.py`, `src/config.py`, `src/report_store.py`, `src/reports.py`, `src/folders.py`, `src/transcriber.py`, `simple_recorder.py`, `app/main.js`, `app/notes-file.js`, `src/templates.py`.
