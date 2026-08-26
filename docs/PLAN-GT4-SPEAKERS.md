# Plan: more than four speakers per channel (LS-EEND evaluation)

Status: 26 August 2026. Decision document - nothing here runs until Ben authorizes
the exact model download (AGENTS.md local-model rule).

## Why this matters less than it looks

stenoai shares the same Sortformer 4-slot ceiling (`minimum_speaker_count` surfaced
from the same FluidAudio engine). This plan is therefore an improvement over BOTH
apps, not strict parity. Parity holds today.

## Candidate: LS-EEND (TASLP 2025)

Source: `github.com/Audio-WestlakeU/FS-EEND`, directory `LS-EEND`.
- Attractor-based streaming EEND; paper claims up to 8 flexible speakers, one-hour audio.
- Published DER: CALLHOME 12.11, DIHARD III 19.61, **AMI Dev 20.97** (8 kHz, their collar).
- Deterministic given weights (retention attention, no clustering) - unlike VBx.
- License: `LS-EEND/LICENSE` now present (issue 28 complained it was missing);
  FS-EEND dir is MIT. Re-verify at download time.
- Runtime reality check: PyTorch-Lightning reference code, Python 3.9 / PyTorch 1.13.
  No ONNX/CoreML export ships in the repo. Issue 30 (May 2026) confirms standalone
  inference instructions were still being added.

## Estimates required by the authorization rule

| Item | Estimate | Method |
|---|---|---|
| Download size | 25-80 MB per checkpoint (`ami.ckpt`); simu 1-8spk ckpt additional | conf `n_units=256, enc_n_layers=4, dec_n_layers=2` -> approx 5-7 M params fp32; Lightning ckpts may carry optimizer state (up to ~3x) |
| Peak memory (inference) | < 1 GB process RSS | chunked streaming, chunk_size 2000 frames (20 s), linear-complexity retention |
| Disk use | < 300 MB total (ckpts + converted artifact + venv if path B) | sum of estimates above |
| Expected duration (path A measure-only) | 1-2 h wall | export attempt + 18 AMI meetings x RTFx >= 20 |
| Expected duration (path B sidecar) | 3-5 h wall incl. Python env | reuse steno-diar-bench harness around `streaming_infer_dia.py` |

## Integration paths

A. **Convert once, run in-process** (architecture-clean): PyTorch ckpt -> ONNX ->
   Core ML or onnxruntime-swift consumer inside `StenoDiarization`. Risk: retention /
   online-attractor ops may not convert cleanly; conversion engineering is the cost.
B. **Python sidecar for measurement only** (never shipped): wrap
   `LS-EEND/streaming_infer_dia.py` behind the existing steno-diar-bench harness to
   get the head-to-head numbers; no product code changes. Violates the sidecar-free
   architecture only inside the bench sandbox.
C. **Do nothing**: parity already holds (stenoai has the identical ceiling).

Recommended sequence: B strictly as measurement, then decide A vs C on numbers.

## Measurement protocol (identical meetings, identical scoring)

1. Corpus: the 18 AMI development meetings from `~/Dev/sandbox/steno-diar-bench`
   (same fixtures as the Sortformer baseline DER 20.34 / IS1008a-b 8.60/9.36 rows).
2. Report three-way DER/JER + speaker-count error per meeting; primary read-out is
   the >= 5-speaker subset where Sortformer collapses to exactly four clusters.
3. Determinism: run every meeting twice; byte-identical RTTM required (VBx failed
   this gate).
4. Gates to replace Sortformer: DER within 2 points of baseline on <= 4-speaker
   meetings AND correct cluster counts (> 4 slots actually emitted) on >= 5-speaker
   meetings AND deterministic repeats AND RTFx >= 20 on M5 Max.

## First gate before ANY authorization

The published AMI config pins `data.max_speakers: 4`. Verify the shared `ami.ckpt`
actually emits more than four attractor channels (inspect checkpoint head shape,
~5 min, read-only metadata) BEFORE approving anything larger. If it caps at four,
LS-EEND as released does not solve our problem either and this plan closes.

## Decision requested from Ben

Authorize ONE of: (a) metadata inspection only (no model weights downloaded),
(b) path B measurement with the sizes above, (c) close this plan and keep the
Sortformer ceiling as product behavior.
