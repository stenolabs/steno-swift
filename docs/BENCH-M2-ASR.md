# Milestone 2: SpeechAnalyzer benchmark and ASR reference decision

Measured on 5 August 2026 on this machine running macOS 26.5 on Apple Silicon.
The method and summarized results are recorded here; task-local raw working artifacts from the original run are not distributed with the repository.
Scoring matches the Parakeet baseline from section 2d, using the same single-stream reference, normalizer, and jiwer version.

## Result

| Engine | WER, length-weighted across six AMI-dev meetings using Array1-01 | RTF |
|---|---:|---:|
| Parakeet TDT v3, Steno Legacy baseline | 18.31% | 0.0271 |
| SpeechAnalyzer on macOS 26 | 21.30% | 0.0116 |

- Parakeet wins all six meetings by 1.5 to 6.8 percentage points, and the gap grows with overlap share.
- SpeechAnalyzer is 2.3 times faster and provides native word timestamps through a streaming contract without Python, bundled models, or FFmpeg.
- Deletions dominate both systems.
  A substantial share comes from the documented artifact of merging overlapping speech into a single-stream reference rather than from lost audio.
- AMI Array1-01 is far-field array audio and represents the difficult case.
  This measurement says nothing directly about close-talk microphones and system-audio loopback, which are Steno's main use case.
- German remained unmeasured for both engines because no suitable reference corpus was available, repeating the open point from `RESULTS.md` section 2d.

## Recorded decision from architecture milestone 2

**SpeechAnalyzer remains the primary ASR reference.**

1. The three-point WER gap occurs in the far-field worst case.
   The main product case, a close microphone plus a separate system-audio track, is acoustically less difficult.
2. The architectural advantages are structural: a native streaming contract with provisional and final results replaces the legacy re-decode path, word timestamps require no additional machinery, no foreign runtime is needed, and the operating system manages the model.
3. The provider boundary remains open.
   Parakeet or Nemotron can remain benchmark candidates behind the same interface if quality proves insufficient for real use.

Revisit this decision when any of the following occurs:

- A German reference becomes available, such as a manually corrected ten-minute CCC excerpt, and shows a substantially larger gap than the English material.
- Real meetings show systematic omissions resembling the AMI deletion profile.
- A close-talk benchmark shows an alternative leading by more than approximately three WER points.

## Secondary finding and fix

`LocaleResolver` did not match hyphenated BCP 47 requests such as `en-US` and `de-DE` exactly against the underscore identifiers returned by `SpeechTranscriber`, such as `en_US` and `de_DE`.
It therefore fell back to the first locale with the same language, which was `en_ZA` or `de_AT` in the observed runs.

The resolver now compares normalized identifiers, then applies an explicit region fallback, with a regression test.
The WER effect was negligible, 21.19% versus 21.30%, because the normalizer absorbs dialect-specific spelling variants.
