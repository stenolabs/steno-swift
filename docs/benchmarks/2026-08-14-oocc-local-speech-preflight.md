# Local German speech benchmark: OOCC v2 preflight

Recorded on 14 August 2026.

## Result

Across the seven free-conversation excerpts from the Open Oldenburg Conversation Corpus v2, Apple's production `SpeechAnalyzerProvider` achieves the lowest length-weighted word error rate.

| Engine | WER | Errors / reference words | Runtime | RTF |
|---|---:|---:|---:|---:|
| Apple SpeechAnalyzer | **19.19%** | 495 / 2,579 | 5.61 s | 0.00686 |
| FluidAudio Parakeet TDT v3 | 21.68% | 559 / 2,579 | 21.12 s | 0.02587 |
| Parakeet Primeline DE CoreML | 21.56% | 556 / 2,579 | 19.31 s | 0.02365 |

Apple wins six of the seven conversations.
Regular Parakeet wins only excerpt 1.
The German Primeline fine-tune improves over regular Parakeet by 0.12 percentage points overall but remains 2.36 points behind Apple.

The first Primeline run includes 13.4 seconds of one-time CoreML compilation for the FP16 encoder.
Across the already warmed excerpts 2 through 7, RTF is 0.00714 for Apple, 0.00919 for regular Parakeet, and 0.00721 for Primeline.
All three engines remain substantially faster than real time.

## Proper names and named terms

A second pass evaluates 16 unique proper names and work titles from the manually corrected references for excerpts 3, 4, and 7.
The list is `Mareike Fallwickel`, `Und alles so still`, `Die Wut die bleibt`, `Witches bitches it-girls`, `Pandora`, `Neuseeland`, `Kaikoura`, `Irland`, `Dublin`, `Galway`, `Cliffs of Moher`, `Harry Potter`, `Niederlanden`, `Niederländisch`, `Niederlandistik`, and `Niedersachsen`.
A term counts as a hit only when it appears in full in the hypothesis after the same Unicode, case, and punctuation normalization.

| Engine | Exact hits | Recall |
|---|---:|---:|
| Apple SpeechAnalyzer | **12 / 16** | **75.00%** |
| FluidAudio Parakeet TDT v3 | 9 / 16 | 56.25% |
| Parakeet Primeline DE CoreML | 9 / 16 | 56.25% |

Apple is the only engine to recognize `Und alles so still`, `Cliffs of Moher`, and `Niederlandistik` exactly.
All three miss `Mareike Fallwickel`, `Die Wut die bleibt`, `Witches bitches it-girls`, and `Kaikoura`.
The named-term test therefore confirms Apple's lead on this corpus, although model-dependent misspellings of technical or place names remain possible in real meetings.
The metric counts each unique term once and measures neither every mention nor omissions of a repeatedly spoken name.

## Per-excerpt measurements

| Excerpt | Duration | Apple WER | Parakeet WER | Primeline WER | Sortformer DER |
|---|---:|---:|---:|---:|---:|
| 01 | 159.4 s | 19.50% | **18.58%** | 19.95% | 17.02% |
| 02 | 117.7 s | 18.63% | 20.34% | **18.14%** | 4.05% |
| 03 | 147.4 s | **22.09%** | 25.24% | 25.97% | 5.22% |
| 04 | 97.0 s | **17.71%** | 18.80% | 20.98% | 10.96% |
| 05 | 115.1 s | **24.93%** | 26.06% | 28.33% | 3.59% |
| 06 | 88.5 s | **15.87%** | 26.35% | 21.26% | 1.97% |
| 07 | 91.6 s | **13.75%** | 15.61% | 14.87% | 4.08% |

The seven files contain 816.65 seconds of audio in total.
Sortformer identifies exactly the two present speaker clusters in every excerpt.
The duration-weighted mean of the seven individual measurements is 7.33% DER and 18.67% JER.
Without overlapping speech, the corresponding DER mean is 7.38%.

## Measurement setup

The preflight ran locally on a Mac mini with Apple M4, 24 GB of memory, and macOS 26.5.2 build 25F84.
The planned comparison on the M5 Air running macOS 27 could not initially run because the device answered ICMP on the private network but exposed neither SSH, screen sharing, nor file sharing.

The inputs were the seven files `1_free_conversation_clip.mov` through `7_free_conversation_clip.mov` from OOCC v2 task 1 and their manually corrected CSV transcripts.
FFmpeg mixed the sources deterministically to mono, 16 kHz, PCM S16LE.
The word reference follows the chronological order of manually corrected words.
The speaker reference uses the separate OOCC `LEFT` and `RIGHT` channels and joins consecutive words from the same person into RTTM segments when gaps do not exceed 350 milliseconds.

WER was calculated with `scripts/benchmark/score_asr.py` and normalizer `steno-de-v1`.
Diarization was scored with `scripts/benchmark/score_diarization.py`, dscore commit `e02f949ac6592279300a2c33d03daf9e0c12fd27`, and a 250-millisecond collar.

Apple ran through Steno's production `steno-transcribe` command and therefore through `SpeechAnalyzerProvider`.
Regular Parakeet ran through Steno's production `ParakeetTranscriptionProvider` with FluidAudio 0.15.5, `melChunkContext = false`, and model `parakeet-tdt-0.6b-v3-coreml`.
Primeline ran directly through the same FluidAudio decoder with `melChunkContext = false`, an explicit German language request, and model commit `d912a28d658a93c7eba99760d52a462f1bd3810a`.
The direct Primeline invocation was necessary because Steno's production installer deliberately accepts only the verified checksums of the official Parakeet model.
Diarization ran through Steno's production `steno-diarize-bench`, `FluidSortformerProvider`, `Sortformer_v2.1`, and `wespeaker_v2`.

## License and interpretation boundaries

According to the bundled source package, OOCC v2 is licensed under CC BY-NC-ND 4.0.
The corpus therefore remains a local non-commercial research candidate and is not committed as a freely reusable product foundation.
This document publishes aggregate measurements and methodology only.
It contains no corpus audio, transcript excerpts, or reconstructed reference data.
The verified source archives were exactly the files registered in the manifest, with MD5 `2dedd7b8aea80bec39f6815a6ad9f104` for audio and video and `2d512c753d4275e497b38548b362cf5b` for the transcripts.

Overlapping words do not have a fully unambiguous order in a linear mixed transcript.
WER is therefore a reproducible engine comparison under one shared contract, not an absolute linguistic quality score for simultaneous speech.
The DER aggregation is the duration-weighted mean of seven separate dscore runs, not a joint micro-evaluation over one concatenated RTTM file.
The measurement contains only spontaneous two-person conversations and covers neither large meeting rooms, specialist terminology, dialect, more than four people, nor Kiezdeutsch.

## Live-comparison preparation

A separate live benchmark was prepared for the M5 Air to compare Apple SpeechAnalyzer, Steno's hidden Parakeet live adapter, and FluidAudio Nemotron 3.5 ASR Streaming Multilingual.
The Nemotron runner pins FluidAudio to commit `667181a368da13b3a9178e310414e9dcbe8f23ce` so that Steno's production FluidAudio version and diarization remain unchanged.
The task-local transfer package contained seven validated OOCC samples, both ARM64 release runners, the verified Parakeet model, launch scripts, and SHA-256 checksums.
The matrix dry run plans exactly 42 steps for seven samples: three engines and three subsequent ASR evaluations per sample.

A Parakeet live smoke test with excerpt 7 completed in 4.77 seconds after fixing a real completion hang, produced nine visible updates, and reached 15.99% WER at RTF 0.0520.
The hang occurred because FluidAudio 0.15.5 leaves its update stream open after `finish()` even though final model text is already available.
Steno now closes the stream itself and uses the final text supplied by FluidAudio.
The existing Parakeet sliding-window manager in FluidAudio 0.15.5 does not pass `de-DE` through to the decoder.
The comparison therefore measures Steno's real live path, while only Apple and Nemotron receive an explicit German model request.

On the Mac mini, Apple reported `noSupportedLocale` during system preflight in both the live runner and the unchanged existing file runner.
Because both runners fail identically, this does not establish a bug in the new live CLI.
The M5 Air run therefore checks the operating system, installed German speech assets, and Apple availability before comparing quality or latency.

## Live comparison on the M5 Air

The live comparison subsequently completed on a MacBook Air `Mac17,4` with Apple M5, ten CPU cores, 16 GB of memory, and macOS 27.0 build `26A5406e`.
The German Apple speech model was installed and available for `de-DE`.
All 21 quality runs and three real-time runs executed locally on the Air.

### Final quality in fast mode

| Engine | WER | CER | Omission rate | Errors / reference words | RTF |
|---|---:|---:|---:|---:|---:|
| Apple SpeechAnalyzer | **19.15%** | **12.48%** | **10.90%** | 494 / 2,579 | **0.00810** |
| FluidAudio Parakeet TDT v3 Live | 20.90% | 14.44% | 11.48% | 539 / 2,579 | 0.00820 |
| FluidAudio Nemotron 3.5 ASR Streaming Multilingual | 22.41% | 13.51% | 11.75% | 578 / 2,579 | 0.01153 |

Apple also wins the total length-weighted WER on the live path.
Parakeet trails Apple by 1.75 percentage points and Nemotron by 3.26 points.
Parakeet wins excerpts 1 and 2, Apple wins excerpts 3, 5, 6, and 7, and Apple and Nemotron reach the same rounded WER on excerpt 4.
The seven files contain 816.65 seconds of audio.
Measured processing after creation of each live session corresponds to approximately 123 times real time for Apple, 122 times for Parakeet, and 87 times for Nemotron.
These RTF values exclude model loading and process startup, which require a separate cold-start comparison.

Fast mode uses 250-millisecond chunks for Parakeet and Nemotron.
Apple receives four-second chunks because its live input buffer, limited to 64 chunks, visibly overflowed during unrestricted 250-millisecond feeding.
On excerpt 3, four-second fast feeding and 20-millisecond real-time feeding produced exactly the same WER and CER for all three engines.
No quality difference caused by engine-specific fast feeding is visible for this verified excerpt.

### Proper names and work titles on the live path

The 16 terms already marked manually in excerpts 3, 4, and 7 were evaluated against the new live hypotheses without retranscription.

| Engine | Exact hits | Recall |
|---|---:|---:|
| Apple SpeechAnalyzer | **12 / 16** | **75.00%** |
| FluidAudio Parakeet TDT v3 Live | 11 / 16 | 68.75% |
| FluidAudio Nemotron 3.5 ASR Streaming Multilingual | 9 / 16 | 56.25% |

Apple still misses `Mareike Fallwickel`, `Die Wut die bleibt`, `Witches bitches it-girls`, and `Kaikoura`.
Parakeet additionally misses the exact form `Niederlandistik`.
Nemotron also misses `Und alles so still` and `Cliffs of Moher`.
Apple therefore wins this small named-term test as well, although its lead over Parakeet is smaller than on the existing file path.
The sample remains too small for defensible claims about specialist terms or participant names.

### Visible real-time latency on excerpt 3

| Engine | First text | First confirmed section | Updates | WER |
|---|---:|---:|---:|---:|
| FluidAudio Nemotron 3.5 | **4.54 s** | no confirmed live event | 63 | 25.97% |
| Apple SpeechAnalyzer | 11.70 s | 23.26 s | 553 | **21.84%** |
| FluidAudio Parakeet TDT v3 | 13.16 s | **13.16 s** | 13 | 23.30% |

Nemotron produces the earliest text, but its first update contains only `mal gerade was liest du so`, and the current runner receives no live event marked final.
Apple first shows only `Ja` after 11.70 seconds and confirms the first section substantially later.
Parakeet shows a longer confirmed section immediately after 13.16 seconds.
One time-to-first-text value is therefore insufficient to describe perceived live quality.
Future product decisions should additionally measure time to a minimum useful amount of text and correction stability.

## Recommendation

Apple remains the quality baseline for this corpus and should continue to be available without an additional download.
Neither regular Parakeet nor Primeline should be treated as the better German default based only on general model cards.
Primeline remains interesting for a second corpus containing specialist language and short German utterances because its stated model purpose may offer advantages not represented by OOCC.
Nemotron is interesting as an experimental live path because of its early first output, but the measured final quality does not yet justify replacing Apple.
Sortformer counts the speakers reliably but needs targeted segmentation analysis for excerpts 1 and 4 in particular.
The next defensible steps are a cold-start comparison, a specialist-name corpus containing notes and participant names, and the separately aligned Kiezdeutsch stress test.
