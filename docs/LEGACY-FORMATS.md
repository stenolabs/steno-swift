# Legacy stenoai data formats: import specification

Analyzed on 5 August 2026 from the writer code in the authoritative Steno Legacy repository, then checked against representative local data without committing that data.
Legend: `[C]` means established by code and `[D]` means inferred only from example data.

## 0. Directory layout

[C] `src/config.py get_data_dirs`: base is `storage_path` from `config.json`, otherwise `~/Library/Application Support/stenoai`, otherwise the repository root during development.

```text
<base>/recordings/     Audio: .webm Opus native system-audio recordings, .m4a/.wav imports
<base>/transcripts/    <stem>_transcript.txt
<base>/output/         <stem>_summary.md|json, _reports.json, _speakers.json,
                       _original.json, _overrides.json, <safeSessionStem>_notes.txt
<base>/folders.json
<base>/chat_sessions_v2.json
<base>/config.json     person_profiles, voiceprints, custom_templates, template_overrides
```

[D] Observed: 17 recordings, 23 transcripts, and 54 output files, including 19 `_summary.md`, 14 `_speakers.json`, 13 `_reports.json`, four `_summary.json`, three `_original.json`, and one `_overrides.json`.

## 1. Stem as provenance identifier

[C] The stem is the audio file name without its extension.
Native recordings use `sysaudio-<epoch_ms>-<SafeName>`, where `Date.now()` in milliseconds is the recording start and `safeName = sessionName.replace(/[^a-zA-Z0-9_-]/g,'_').slice(0,64)`.
Imports use the unsanitized original basename, and observed data includes spaces and umlauts.

- All sidecars are coupled to the stem: `_speakers.json.meeting_id` and `person_profiles[].prototypes[].meeting_id` equal the stem. [C]
- A collision risk is documented in `main.js`: `meeting.wav` and `meeting.m4a` collide. Markdown and JSON summaries for the same stem collapse to one `summaryStemKey`, with Markdown winning. [C]
- Preserve the stem as legacy provenance while assigning new internal UUIDs.

## 2. `recordings/`

[C] Interrupted recordings remain as partial files without sidecars.
When `keep_recordings=false`, audio is deleted after processing, so a transcript without audio is normal.

## 3. `transcripts/<stem>_transcript.txt`

[C] The only writer is `simple_recorder.py _write_transcript_file`.
Encoding is UTF-8.

```text
Session: {session_name}
File: {audio_path.name}
Date: {YYYY-MM-DD HH:MM:SS}          <- local time, NO time zone, processing time
Language setting: {display name}
Detected language: {display name or "Unknown"}
Summary output language: {display name}

============================================================

{body}
```

Body variants [C]:

- Without diarization: paragraphs or turns separated by blank lines, without prefixes.
- With diarization: `[{MM:SS or H:MM:SS}] [{speaker}] {text}` per turn, separated by blank lines. Timestamps are whole seconds from recording start and identify only turn start. There are no end times or word timestamps because ASR segments were never persisted.

Speaker labels [C+D] include `You`, `Others`, `Speaker 2/3/4`, `Owner`, and clear names inserted through speaker confirmation.

[D] Real orphaned files exist in both directions: transcripts without summaries and one summary without a transcript.

## 4. `output/<stem>_summary.md`: canonical note

[C] Frontmatter is not YAML.
It uses a line-based `key: value` parser with quote removal, JSON parsing for values starting with `[`, recognition of null/true/false, and integer parsing for `^-?\d+$`.
The importer must reproduce this interpretation.

Fields are `title`, `date`, `duration_seconds`, `language`, `configured_language`, `detected_language`, `is_diarised`, `notes_generated`, `is_live_transcript`, `processing`, `notes_stale`, `folders`, `transcript_corrected_at`, `summary_generated_at`, and `updated_at`.
Failure cases add `transcription_failed`, `reprocessable`, `audio_file`, and `error`.
`date` is normally local ISO without a time zone and represents processing time, but Electron placeholder files use UTC with `Z`.

Body sections use a standalone `## ` heading: Summary, Key Topics with `### {title}` and free text, Key Points as bullets, Action Items as bullets, Participants as one comma-separated line, Transcript using the preferred diarized transcript body without its header, and User Notes always last.

## 5. `output/<stem>_summary.json`: legacy read-only format

Top-level fields are `session_info`, `summary`, `participants`, `discussion_areas`, `key_points`, `action_items`, `transcript`, `is_diarised`, `diarised_text`, `user_notes`, and `folders`.
`session_info` includes name, absolute paths, `processed_at`, `duration_seconds`, languages, `reprocessable`, and `updated_at`.
`discussion_areas` contains `{title, analysis}` objects.
Markdown and JSON may coexist for one stem; Markdown wins. [C]

## 6. `output/<stem>_reports.json`

```jsonc
{ "reports": [ { "id": "rep_<12hex>", "template_id": "…", "template_name": "…",
    "model": "…", "content": "Markdown", "created_at": "local ISO" } ],
  "active_report": "rep_…|null" }   // null or "standard" selects the standard note
```

[D] Observed template identifiers are `detailed`, `kollegen`, `sales-call`, `shareable-summary`, and `standard-backup`.
`standard-backup` is an automatic snapshot labeled `Previous version · <date>`.
[C] Built-ins in `src/templates.py` are `standard`, `product-demo`, `sales-call`, `one-on-one`, `standup`, and `shareable-summary`.
`detailed` and `kollegen` come from `custom_templates` in `config.json`, so templates must be imported or their reports lose their named reference.

## 7. `output/<stem>_speakers.json`: most valuable legacy artifact

```jsonc
{ "meeting_id": "<stem>",
  "created_at": 1785862866.9,          // floating-point Unix SECONDS
  "channels": { "mic"|"system": {      // these are the only two keys
      "recording_type": "in_person"|"remote"|"imported"|"unknown",
      "clusters": { "SPEAKER_0": {     // numbered independently per channel
          "embedding": [256 floats],   // WeSpeaker centroid, dimension 256
          "speech_duration_seconds": f, "segment_count": int,
          "segments": [{"start": f, "end": f}],
          "review_state": "generic",
          "contains_multiple_speakers": true } } } },
  "transcript_lines": [                // OPTIONAL; missing from 8 of 14 files
    { "start": f, "channel": "mic"|"system",
      "diarization_speaker_id": "SPEAKER_n"|null,
      "original_label": "You|Speaker 2|…" } ] }
```

Critical [C]: `transcript_lines` matches diarized transcript-body lines exactly by position.
Pair by array index, never by timestamp.
The key is `(channel, SPEAKER_n)`.
This file contains the only copy of embeddings, which cannot be reproduced after audio deletion.

## 8. `_original.json` and `_overrides.json`: legacy user-edit sidecars

Current legacy code no longer writes these files.
`_original.json` stores the original model-output snapshot, `edited_fields`, and `edited_at` in UTC with `Z`.
`_overrides.json` stores `{fields: {<field>: {value, edited_at}}}`.
Apply user overrides after importing the summary.

## 9. `<safeSessionStem>_notes.txt`

This file is coupled to the session name rather than the stem and is consumed into `## User Notes` in the Markdown file after processing.
[D] None remain in observed data, so importing `## User Notes` is sufficient.

## 10. `folders.json`

Shape: `{folders: [{id: "8hex", name, color, created_at ISO, order, icon?}]}`.
Folders are flat and cannot nest.
Meeting assignment lives in each meeting file as frontmatter `folders: ["<id>"]` in Markdown or top-level `folders` in JSON, and multiple assignments are possible.
[D] Observed data contains one folder named `Arbeit` and one assigned meeting.
A corrupt file is quarantined as `folders.json.corrupt`.

## 11. `chat_sessions_v2.json`

Shape: `{sessions: [{id: "s-<ms>-<rand>", name, summaryFile: ABSOLUTE path, createdAt/updatedAt: epoch MILLISECONDS, messages: [{role, content, ts}]}]}`.
Normalize the meeting binding from the absolute path to the stem.
[D] Four sessions were observed.

## 12. `config.json` to `person_profiles`: speaker identities

```jsonc
"person_profiles": [ { "person_id": uuid4, "display_name": "UNIQUE case-insensitively",
  "created_at"/"updated_at": floating-point Unix seconds,
  "prototypes": [P], "hard_negatives": [P] } ]
```

SpeakerPrototype `P` contains `prototype_id`, redundant `person_id`, `embedding_mean` as 256 floats, `sample_count`, `quality_score` from 0 to 1, `recording_type`, `meeting_id` equal to the stem, `diarization_speaker_id`, nullable `channel`, `speech_duration_seconds`, `segment_count`, `created_from`, and `created_at`.
`recording_type` is `in_person`, `remote`, `imported`, or `unknown`.
`channel` is `mic`, `system`, or null for legacy or enrollment data.
`created_from` is `user_confirmed`, `user_corrected`, or `manual_enrollment`.

[D] There are 14 profiles, all embeddings have dimension 256, and two meeting identifiers are dangling because their meetings no longer exist.
The importer must tolerate dangling identifiers.
[C] Deleting a person must remove derived hard negatives in all other profiles using the key `meeting_id + channel + speaker id`.
Preserve this coupling during import.

`voiceprints`, used for legacy self-matching, is empty in observed data and needs no import.
Other relevant keys are `custom_templates`, `template_overrides`, `language`, `ui_language`, `user_name`, `storage_path`, and `keep_recordings`.

## 13. Deleted meetings

There is no archive.
Deletion uses `output/.pending-delete/` for an eight-second undo window, then becomes permanent.
An importer should inspect `.pending-delete/` because crash remnants are possible.
[D] It was empty or absent in observed data.

## 14. No meeting index

Metadata exists only in `_summary.md` frontmatter or `session_info` in legacy JSON.
The meeting list scans `output/*_summary.md`.
Real data contains transcript-only, summary-only, and recording-only orphans.

## 15. Mixed timestamp epochs

- Floating-point Unix seconds: `_speakers.json.created_at`, person profiles and prototypes, and voiceprints.
- Integer Unix milliseconds: chat sessions and the numeric part of `sysaudio-<ms>-…`, which is recording start.
- Local ISO without time zone: Markdown-frontmatter `date`, report and folder `created_at`, and `session_info.processed_at`.
- UTC ISO with `Z`: Electron-written fields such as placeholder `date` and `_original.json.edited_at`.
- Relative seconds from recording start: `segments[].start/end`, `transcript_lines[].start`, and `[MM:SS]` in text.

The most important legacy source files are `src/speaker_suggestions.py`, `src/config.py`, `src/report_store.py`, `src/reports.py`, `src/folders.py`, `src/transcriber.py`, `simple_recorder.py`, `app/main.js`, `app/notes-file.js`, and `src/templates.py`.
