#!/usr/bin/env python3
"""Score RTTM output with the verified Steno Legacy dscore contract."""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
import tempfile
from pathlib import Path


COLLAR = 0.25
RTTM_PRECISION = 3


def run_dscore(
    dscore: Path,
    reference: Path,
    system: Path,
    uem: Path | None,
    ignore_overlaps: bool,
) -> dict[str, float]:
    command = [
        sys.executable,
        str(dscore),
        "-r",
        str(reference),
        "-s",
        str(system),
        "--collar",
        str(COLLAR),
        "--table_fmt",
        "tsv",
        "--n_digits",
        "4",
    ]
    if uem is not None:
        command += ["-u", str(uem)]
    if ignore_overlaps:
        command.append("--ignore_overlaps")
    process = subprocess.run(command, capture_output=True, text=True, check=False)
    if process.returncode != 0:
        raise ValueError(f"dscore failed:\n{process.stdout}\n{process.stderr}")
    lines = [line for line in process.stdout.splitlines() if line.strip()]
    if len(lines) < 2:
        raise ValueError(f"dscore returned no result table: {process.stdout}")
    header = lines[0].split("\t")
    values = lines[-1].split("\t")
    row = dict(zip(header, values))

    def number(prefix: str) -> float:
        for key, raw in row.items():
            if key.strip().upper().startswith(prefix):
                return float(raw)
        raise ValueError(f"dscore produced no {prefix} column: {header}")

    return {"DER": number("DER"), "JER": number("JER")}


def read_turns(path: Path) -> list[tuple[float, float, str]]:
    turns: list[tuple[float, float, str]] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        fields = line.split()
        if len(fields) < 8 or fields[0] != "SPEAKER":
            continue
        start = round(float(fields[3]), RTTM_PRECISION)
        end = round(start + float(fields[4]), RTTM_PRECISION)
        if end > start:
            turns.append((start, end, fields[7]))
    return turns


def rttm_identity(path: Path) -> tuple[str, str]:
    identities = {
        (fields[1], fields[2])
        for line in path.read_text(encoding="utf-8").splitlines()
        if len(fields := line.split()) >= 8 and fields[0] == "SPEAKER"
    }
    if len(identities) != 1:
        raise ValueError(f"{path}: expected exactly one recording and channel")
    return next(iter(identities))


def overlap_spans(path: Path) -> list[tuple[float, float]]:
    events: list[tuple[float, int, str]] = []
    for start, end, speaker in read_turns(path):
        events.append((start, 1, speaker))
        events.append((end, -1, speaker))
    events.sort(key=lambda event: (event[0], event[1]))
    active: dict[str, int] = {}
    spans: list[tuple[float, float]] = []
    opened_at: float | None = None
    for time, delta, speaker in events:
        before = sum(1 for count in active.values() if count > 0)
        active[speaker] = active.get(speaker, 0) + delta
        after = sum(1 for count in active.values() if count > 0)
        if before < 2 <= after:
            opened_at = time
        elif before >= 2 > after and opened_at is not None:
            if time > opened_at:
                spans.append((opened_at, time))
            opened_at = None
    merged: list[tuple[float, float]] = []
    for start, end in spans:
        if merged and start <= merged[-1][1]:
            merged[-1] = (merged[-1][0], max(merged[-1][1], end))
        else:
            merged.append((start, end))
    return merged


def read_uem(path: Path) -> list[tuple[str, str, float, float]]:
    rows: list[tuple[str, str, float, float]] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        fields = line.split()
        if len(fields) >= 4:
            rows.append((fields[0], fields[1], float(fields[2]), float(fields[3])))
    return rows


def intersect(
    spans: list[tuple[float, float]],
    windows: list[tuple[float, float]],
) -> list[tuple[float, float]]:
    result: list[tuple[float, float]] = []
    for start, end in spans:
        for window_start, window_end in windows:
            lower = max(start, window_start)
            upper = min(end, window_end)
            if upper > lower:
                result.append((lower, upper))
    return sorted(result)


def overlap_uem(reference: Path, uem: Path | None, destination: Path) -> dict:
    spans = overlap_spans(reference)
    identifier, channel = rttm_identity(reference)
    if uem is not None:
        rows = read_uem(uem)
        if rows:
            channel = rows[0][1]
        spans = intersect(spans, [(start, end) for _, _, start, end in rows])
    rounded = [(round(start, 3), round(end, 3)) for start, end in spans]
    kept = [(start, end) for start, end in rounded if end > start]
    total = round(sum(end - start for start, end in kept), 3)
    short = round(sum(end - start for start, end in kept if end - start < 2 * COLLAR), 3)
    effective = round(sum(max(0.0, end - start - 2 * COLLAR) for start, end in kept), 3)
    stats = {
        "regions": len(kept),
        "scored_s": total,
        "short_region_s": short,
        "short_region_share": round(short / total, 4) if total else 0.0,
        "effective_scored_s": effective,
        "sub_millisecond_regions_dropped": len(rounded) - len(kept),
        "collar_s": COLLAR,
    }
    if not kept:
        stats["available"] = False
        stats["reason"] = "reference contains no scored simultaneous speech"
        return stats
    if effective == 0:
        stats["available"] = False
        stats["reason"] = "all simultaneous-speech regions are consumed by the scoring collar"
        return stats
    destination.write_text(
        "".join(f"{identifier} {channel} {start:.3f} {end:.3f}\n" for start, end in kept),
        encoding="utf-8",
    )
    stats["available"] = True
    return stats


def score(
    dscore: Path,
    dscore_version: str,
    reference: Path,
    system: Path,
    uem: Path | None,
) -> dict:
    reference_identity = rttm_identity(reference)
    system_identity = rttm_identity(system)
    if system_identity != reference_identity:
        raise ValueError("reference and system RTTM identities differ")
    if uem is not None:
        uem_identities = {(identifier, channel) for identifier, channel, _, _ in read_uem(uem)}
        if uem_identities != {reference_identity}:
            raise ValueError("UEM identity must match the single RTTM recording and channel")

    result = {
        "schemaVersion": 1,
        "reference": reference.name,
        "system": system.name,
        "uem": uem.name if uem else None,
        "scorer": "dscore",
        "scorerVersion": dscore_version,
        "collar_s": COLLAR,
        "inputs": {
            "referenceSHA256": hashlib.sha256(reference.read_bytes()).hexdigest(),
            "systemSHA256": hashlib.sha256(system.read_bytes()).hexdigest(),
            "uemSHA256": hashlib.sha256(uem.read_bytes()).hexdigest() if uem else None,
        },
        "all": run_dscore(dscore, reference, system, uem, False),
        "nonoverlap": run_dscore(dscore, reference, system, uem, True),
    }
    with tempfile.TemporaryDirectory(prefix="steno-overlap-") as raw_tmp:
        overlap_path = Path(raw_tmp) / "overlap.uem"
        overlap = overlap_uem(reference, uem, overlap_path)
        if overlap.get("available"):
            overlap.update(run_dscore(dscore, reference, system, overlap_path, False))
        result["overlapOnly"] = overlap
    return result


def main(arguments: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("reference", type=Path)
    parser.add_argument("system", type=Path)
    parser.add_argument("--uem", type=Path)
    parser.add_argument("--dscore", type=Path, required=True)
    parser.add_argument("--dscore-version", required=True)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args(arguments)
    try:
        result = score(
            args.dscore,
            args.dscore_version,
            args.reference,
            args.system,
            args.uem,
        )
        encoded = json.dumps(result, indent=2) + "\n"
        if args.output:
            args.output.write_text(encoded, encoding="utf-8")
        else:
            print(encoded, end="")
    except (OSError, ValueError) as error:
        print(f"score_diarization: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
