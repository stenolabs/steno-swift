#!/usr/bin/env python3
"""Deterministically mix mono PCM16 WAV clips with integer-only placement and gain.

Each scaled sample uses signed round-half-away-from-zero: the absolute integer
product receives half of the fixed-point denominator before division, then the
original sign is restored. Clips are summed as unbounded Python integers before
the clipping budget is checked. No output is published until validation passes.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from decimal import Decimal
import json
import os
from pathlib import Path
import platform
import shutil
import struct
import subprocess
import sys
import tempfile
from typing import Callable, Sequence
import wave


class ArchitectureError(RuntimeError):
    pass


class ClippingBudgetExceeded(RuntimeError):
    def __init__(self, actual: int, budget: int) -> None:
        super().__init__(f"mixed output clips {actual} samples; budget is {budget}")
        self.actual = actual
        self.budget = budget


@dataclass(frozen=True)
class ClipMetadata:
    path: Path
    speaker: str
    start_frame: int
    start_seconds: str
    gain_db: str
    gain_numerator: int
    fraction_bits: int


@dataclass(frozen=True)
class MixMetrics:
    input_peak: int
    pre_clamp_mixed_peak: int
    clipped_sample_count: int
    output_frame_count: int
    output_peak: int
    clipping_budget: int

    def json_object(self, item_id: str, sample_rate: int) -> dict[str, int | str]:
        return {
            "schemaVersion": 1,
            "itemID": item_id,
            "sampleRate": sample_rate,
            "inputPeak": self.input_peak,
            "preClampMixedPeak": self.pre_clamp_mixed_peak,
            "clippedSampleCount": self.clipped_sample_count,
            "outputFrameCount": self.output_frame_count,
            "outputPeak": self.output_peak,
            "clippingBudget": self.clipping_budget,
        }


@dataclass(frozen=True)
class MixResult:
    samples: list[int]
    metrics: MixMetrics
    timeline: list[dict[str, int | str]]


def _translated_state() -> str:
    result = subprocess.run(
        ["/usr/sbin/sysctl", "-in", "sysctl.proc_translated"],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise ArchitectureError("cannot determine whether the Python process uses Rosetta")
    return result.stdout.strip()


def ensure_native_apple_silicon(
    machine_reader: Callable[[], str] = platform.machine,
    translated_reader: Callable[[], str] = _translated_state,
) -> None:
    if machine_reader() != "arm64":
        raise ArchitectureError("the mixer supports native Apple Silicon only")
    if translated_reader() != "0":
        raise ArchitectureError("the mixer refuses Rosetta translation")


def round_fixed_pcm(sample: int, numerator: int, fraction_bits: int) -> int:
    if numerator < 0:
        raise ValueError("gain numerator must not be negative")
    if not 0 <= fraction_bits <= 30:
        raise ValueError("fraction bits must be between 0 and 30")
    product = sample * numerator
    denominator = 1 << fraction_bits
    magnitude = (abs(product) + denominator // 2) // denominator
    return magnitude if product >= 0 else -magnitude


def validate_clip_metadata(
    clip: ClipMetadata,
    *,
    sample_rate: int,
    expected_gain_db: str,
    expected_gain_numerator: int,
    expected_fraction_bits: int,
) -> None:
    if sample_rate <= 0:
        raise ValueError("sample rate must be positive")
    if clip.start_frame < 0:
        raise ValueError("start frame must not be negative")
    if Decimal(clip.start_seconds) * sample_rate != clip.start_frame:
        raise ValueError("documentary start seconds disagree with startFrame")
    if Decimal(clip.gain_db) != Decimal(expected_gain_db):
        raise ValueError("segment gainDB disagrees with its speaker gain")
    if clip.gain_numerator != expected_gain_numerator:
        raise ValueError("segment gain numerator disagrees with its speaker gain")
    if clip.fraction_bits != expected_fraction_bits:
        raise ValueError("segment fixed-point scale disagrees with rendering metadata")
    round_fixed_pcm(0, clip.gain_numerator, clip.fraction_bits)


def pcm16_samples(path: Path, sample_rate: int) -> list[int]:
    with wave.open(str(path), "rb") as source:
        actual = (
            source.getnchannels(),
            source.getsampwidth(),
            source.getframerate(),
            source.getcomptype(),
        )
        if actual != (1, 2, sample_rate, "NONE"):
            raise ValueError(f"{path} is not mono PCM16 at {sample_rate} Hz")
        frame_count = source.getnframes()
        payload = source.readframes(frame_count)
        if len(payload) != frame_count * 2:
            raise ValueError(f"{path} has a truncated PCM payload")
    if not payload:
        raise ValueError(f"{path} contains no PCM frames")
    return list(struct.unpack(f"<{len(payload) // 2}h", payload))


def _seconds(frame: int, sample_rate: int) -> str:
    return format(Decimal(frame) / Decimal(sample_rate), ".9f")


def mix_clips(
    clips: Sequence[ClipMetadata],
    *,
    sample_rate: int,
    clipping_budget: int = 0,
) -> MixResult:
    if sample_rate <= 0 or not clips:
        raise ValueError("a positive sample rate and at least one clip are required")
    if clipping_budget < 0:
        raise ValueError("clipping budget must not be negative")

    decoded: list[tuple[ClipMetadata, list[int]]] = []
    input_peak = 0
    for clip in clips:
        samples = pcm16_samples(clip.path, sample_rate)
        input_peak = max(input_peak, max(abs(sample) for sample in samples))
        decoded.append((clip, samples))

    output_frames = max(clip.start_frame + len(samples) for clip, samples in decoded)
    mixed = [0] * output_frames
    timeline: list[dict[str, int | str]] = []
    for index, (clip, samples) in enumerate(decoded):
        for offset, sample in enumerate(samples):
            mixed[clip.start_frame + offset] += round_fixed_pcm(
                sample, clip.gain_numerator, clip.fraction_bits
            )
        end_frame = clip.start_frame + len(samples)
        timeline.append(
            {
                "clipIndex": index,
                "speaker": clip.speaker,
                "startFrame": clip.start_frame,
                "endFrame": end_frame,
                "frameCount": len(samples),
                "startSeconds": _seconds(clip.start_frame, sample_rate),
                "endSeconds": _seconds(end_frame, sample_rate),
                "durationSeconds": _seconds(len(samples), sample_rate),
                "gainDB": clip.gain_db,
                "gainNumerator": clip.gain_numerator,
                "fractionBits": clip.fraction_bits,
            }
        )

    pre_clamp_peak = max(abs(sample) for sample in mixed)
    clipped_count = sum(sample < -32_768 or sample > 32_767 for sample in mixed)
    if clipped_count > clipping_budget:
        raise ClippingBudgetExceeded(clipped_count, clipping_budget)
    rendered = [max(-32_768, min(32_767, sample)) for sample in mixed]
    output_peak = max(abs(sample) for sample in rendered)
    metrics = MixMetrics(
        input_peak=input_peak,
        pre_clamp_mixed_peak=pre_clamp_peak,
        clipped_sample_count=clipped_count,
        output_frame_count=output_frames,
        output_peak=output_peak,
        clipping_budget=clipping_budget,
    )
    return MixResult(samples=rendered, metrics=metrics, timeline=timeline)


def _json_bytes(value: object) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n").encode("utf-8")


def _temporary_path(destination: Path) -> Path:
    destination.parent.mkdir(parents=True, exist_ok=True)
    descriptor, raw_path = tempfile.mkstemp(
        prefix=f".{destination.name}.partial.", dir=destination.parent
    )
    os.close(descriptor)
    return Path(raw_path)


def _write_pcm16_wav(path: Path, samples: Sequence[int], sample_rate: int) -> None:
    payload = struct.pack(f"<{len(samples)}h", *samples)
    with wave.open(str(path), "wb") as destination:
        destination.setparams((1, 2, sample_rate, len(samples), "NONE", "not compressed"))
        destination.writeframes(payload)


def render_mix(
    *,
    clips: Sequence[ClipMetadata],
    sample_rate: int,
    output: Path,
    timeline_output: Path,
    metrics_output: Path,
    item_id: str,
    clipping_budget: int = 0,
) -> MixResult:
    result = mix_clips(clips, sample_rate=sample_rate, clipping_budget=clipping_budget)
    destinations = (output, timeline_output, metrics_output)
    partials: list[Path] = []
    backups: list[Path | None] = []
    existed: list[bool] = []
    try:
        for destination in destinations:
            partials.append(_temporary_path(destination))
        _write_pcm16_wav(partials[0], result.samples, sample_rate)
        partials[1].write_bytes(_json_bytes(result.timeline))
        partials[2].write_bytes(
            _json_bytes(result.metrics.json_object(item_id=item_id, sample_rate=sample_rate))
        )
        for destination in destinations:
            destination_exists = destination.exists()
            if destination.is_symlink() or (destination_exists and not destination.is_file()):
                raise ValueError(f"output target is not a regular file: {destination}")
            existed.append(destination_exists)
            if destination_exists:
                backup = _temporary_path(destination)
                backups.append(backup)
                shutil.copy2(destination, backup)
            else:
                backups.append(None)
        # Publish the primary artifact last. A metadata publication failure can
        # therefore never replace a previously valid audio file.
        try:
            for index in (1, 2, 0):
                os.replace(partials[index], destinations[index])
        except Exception as publication_error:
            rollback_errors: list[Exception] = []
            for destination, backup, previously_existed in zip(
                destinations, backups, existed, strict=True
            ):
                try:
                    if previously_existed:
                        if backup is None:
                            raise RuntimeError(f"missing rollback backup for {destination}")
                        os.replace(backup, destination)
                    else:
                        destination.unlink(missing_ok=True)
                except Exception as rollback_error:
                    rollback_errors.append(rollback_error)
            if rollback_errors:
                raise RuntimeError("output publication and rollback both failed") from publication_error
            raise
        return result
    finally:
        for partial in partials + [backup for backup in backups if backup is not None]:
            try:
                partial.unlink()
            except FileNotFoundError:
                pass


def _decimal_string(value: Decimal | int | str) -> str:
    return str(value)


def load_item_clips(script_path: Path, item_id: str, clip_root: Path) -> tuple[int, list[ClipMetadata]]:
    script = json.loads(script_path.read_text(encoding="utf-8"), parse_float=Decimal)
    rendering = script["rendering"]
    sample_rate = int(rendering["sampleRate"])
    fraction_bits = int(rendering["fixedPointFractionBits"])
    speakers = {speaker["label"]: speaker for speaker in rendering["speakers"]}
    meetings = [meeting for meeting in script["meetings"] if meeting["itemID"] == item_id]
    if len(meetings) != 1:
        raise ValueError(f"expected exactly one script meeting for {item_id}")

    clips: list[ClipMetadata] = []
    for index, segment in enumerate(meetings[0]["segments"]):
        speaker = speakers.get(segment["speaker"])
        if speaker is None:
            raise ValueError(f"unknown speaker: {segment['speaker']}")
        clip = ClipMetadata(
            path=clip_root / f"{index}.wav",
            speaker=segment["speaker"],
            start_frame=int(segment["startFrame"]),
            start_seconds=_decimal_string(segment["start"]),
            gain_db=_decimal_string(segment["gainDB"]),
            gain_numerator=int(segment["gainNumerator"]),
            fraction_bits=fraction_bits,
        )
        validate_clip_metadata(
            clip,
            sample_rate=sample_rate,
            expected_gain_db=_decimal_string(speaker["gainDB"]),
            expected_gain_numerator=int(speaker["gainNumerator"]),
            expected_fraction_bits=fraction_bits,
        )
        clips.append(clip)
    return sample_rate, clips


def main() -> None:
    ensure_native_apple_silicon()
    parser = argparse.ArgumentParser()
    parser.add_argument("--script", type=Path, required=True)
    parser.add_argument("--item-id", required=True)
    parser.add_argument("--clip-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--timeline-output", type=Path, required=True)
    parser.add_argument("--metrics-output", type=Path, required=True)
    parser.add_argument("--clipping-budget", type=int, default=0)
    args = parser.parse_args()
    sample_rate, clips = load_item_clips(args.script, args.item_id, args.clip_root)
    render_mix(
        clips=clips,
        sample_rate=sample_rate,
        output=args.output,
        timeline_output=args.timeline_output,
        metrics_output=args.metrics_output,
        item_id=args.item_id,
        clipping_budget=args.clipping_budget,
    )


if __name__ == "__main__":
    main()
