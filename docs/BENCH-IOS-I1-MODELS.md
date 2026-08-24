# iOS i1 - Model installation and live revision

Status: 9 August 2026.
Device and OS: iPhone 15 Pro running iOS 26.5.2.
Build commit: `cb4569c`.

## Installed model

- Selected language: German (Germany).
- Live text visible before stopping: yes, after about 15 seconds in this short run.
- Provisional revision visible after stopping: yes.
- Revision visible after relaunch: yes, then replaced by the segmented final ASR run.
- Number of final ASR jobs for the meeting: exactly one.

## Missing model

- Selected language: French (France).
- Download observed before consent: no.
- Audio retained without a model: yes, a 1.7 MB CAF file and its metadata.
- Displayed source and size: Apple, 142.6 MB.
- Model-blocked job processed again: yes, the same final ASR job finished after two attempts.
- Diarization download observed: no.

## Limits

Only the short flows above were verified on real hardware.
The roughly 15 seconds before German live text appeared is a single observation, not a reliable performance measurement.
Long recording, thermal behavior, battery use, background operation, and interruptions were outside this run.
The diarization job was enqueued and failed as expected because the Sortformer, pyannote, and WeSpeaker models were not yet installed.
No automatic diarization download was observed.
