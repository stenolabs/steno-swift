#!/usr/bin/env python3
"""Perf budget checker for steno-swift.

Codifies the performance budgets adopted from the stenoai legacy harness and the
steno-swift architecture (see docs/PERF-BUDGETS.md). Reads measurements from a
JSON payload (--json) and/or scrapes evidence already published in
docs/BENCH-M2-ASR.md, then reports PASS / FAIL / NO EVIDENCE per budget.

Exit codes:
  0 - every measurable budget passes (budgets without evidence are skipped)
  1 - at least one measured budget violates its threshold
  2 - usage error or unparsable input

Standard library only.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
BENCH_M2_PATH = REPO_ROOT / "docs" / "BENCH-M2-ASR.md"

# Metric key -> (human label, comparison, threshold, unit).
# comparison "<=" means measured must be at or below threshold;
# ">=" means measured must be at or above threshold.
BUDGETS: dict[str, tuple[str, str, float, str]] = {
    "live_partial_latency_ms": (
        "Live partial latency (provisional transcript visible)",
        "<=",
        150.0,
        "ms of speech",
    ),
    "final_asr_rtf": (
        "Final ASR real-time factor",
        "<=",
        0.05,
        "RTF",
    ),
    "diarization_rtfx": (
        "Diarization speed-up factor",
        ">=",
        20.0,
        "RTFx",
    ),
    "diarization_first_progress_s": (
        "Diarization first-progress heartbeat",
        "<=",
        2.0,
        "s into segmentation window",
    ),
    "soak_memory_delta_mb": (
        "Two-hour two-track session retained-memory delta",
        "<=",
        250.0,
        "MB",
    ),
    "cold_start_to_interactive_s": (
        "Cold start to interactive UI",
        "<=",
        2.5,
        "s on Apple Silicon",
    ),
    "search_query_ms_100_meetings": (
        "Library search query latency at 100 meetings",
        "<=",
        50.0,
        "ms",
    ),
    "index_incremental_update_s_per_batch": (
        "Search index incremental update per meeting batch",
        "<=",
        2.0,
        "s",
    ),
}

# Row of the BENCH-M2 result table that carries the SpeechAnalyzer RTF,
# e.g. "| SpeechAnalyzer on macOS 26 | 21.30% | 0.0116 |".
BENCH_M2_ROW = re.compile(
    r"^\|\s*SpeechAnalyzer[^|\n]*\|\s*([0-9.]+)%\s*\|\s*([0-9.]+)\s*\|",
    re.MULTILINE,
)


def parse_bench_m2(text: str) -> dict[str, float]:
    """Extract ASR metrics published in docs/BENCH-M2-ASR.md."""
    match = BENCH_M2_ROW.search(text)
    if match is None:
        return {}
    return {
        "final_asr_wer_percent": float(match.group(1)),
        "final_asr_rtf": float(match.group(2)),
    }


def coerce(value: object) -> float | None:
    """Best-effort numeric coercion for a JSON measurement."""
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        try:
            return float(value.strip())
        except ValueError:
            return None
    return None


def evaluate(
    measured: dict[str, float],
    budgets: dict[str, tuple[str, str, float, str]] = BUDGETS,
) -> list[tuple[str, str]]:
    """Compare measurements against budgets; returns (status, detail) rows."""
    rows: list[tuple[str, str]] = []
    violations = 0
    missing = 0
    for key, (label, comparison, threshold, unit) in budgets.items():
        if key not in measured:
            missing += 1
            rows.append(("NO EVIDENCE", f"{key}: {label} ({comparison} {threshold:g} {unit})"))
            continue
        value = measured[key]
        ok = value <= threshold if comparison == "<=" else value >= threshold
        verdict = "PASS" if ok else "FAIL"
        if not ok:
            violations += 1
        rows.append((
            verdict,
            f"{key}: measured {value:g} {unit} vs budget {comparison} {threshold:g}",
        ))
    return rows


def load_json_measurements(path: str) -> dict[str, float]:
    """Load a flat JSON object of metric key -> number (string numbers accepted)."""
    raw = sys.stdin.read() if path == "-" else Path(path).read_text(encoding="utf-8")
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError as error:
        print(f"error: --json {path} is not valid JSON: {error}", file=sys.stderr)
        raise SystemExit(2) from None
    if not isinstance(payload, dict):
        print(f"error: --json {path} must be a JSON object mapping metric keys to numbers", file=sys.stderr)
        raise SystemExit(2)
    known = set(BUDGETS) | {"final_asr_wer_percent"}
    measurements: dict[str, float] = {}
    unknown: list[str] = []
    for key, value in payload.items():
        number = coerce(value)
        if number is None:
            print(f"error: --json {path} key '{key}' is not numeric", file=sys.stderr)
            raise SystemExit(2)
        if key in known:
            measurements[key] = number
        else:
            unknown.append(key)
    if unknown:
        print(f"note: ignoring unknown metric keys: {', '.join(sorted(unknown))}", file=sys.stderr)
    return measurements


def collect_evidence(json_path: str | None) -> dict[str, float]:
    """Merge scraped benchmark-doc evidence with explicit --json measurements."""
    measured: dict[str, float] = {}
    if json_path is not None:
        measured.update(load_json_measurements(json_path))
    elif BENCH_M2_PATH.exists():
        # No explicit payload: fall back to evidence already committed in the docs.
        measured.update(parse_bench_m2(BENCH_M2_PATH.read_text(encoding="utf-8")))
    return measured


def self_test() -> int:
    """Exercise parsing, coercion, pass, fail, and skip paths."""
    failures: list[str] = []

    def check(name: str, condition: bool) -> None:
        if not condition:
            failures.append(name)

    sample = (
        "# Milestone 2\n\n"
        "| Engine | WER | RTF |\n"
        "|---|---:|---:|\n"
        "| Parakeet TDT v3, Steno Legacy baseline | 18.31% | 0.0271 |\n"
        "| SpeechAnalyzer on macOS 26 | 21.30% | 0.0116 |\n"
    )
    parsed = parse_bench_m2(sample)
    check("bench-m2 scrape finds RTF", abs(parsed.get("final_asr_rtf", 0.0) - 0.0116) < 1e-12)
    check("bench-m2 scrape finds WER", abs(parsed.get("final_asr_wer_percent", 0.0) - 21.30) < 1e-12)
    check("bench-m2 scrape tolerates absence", parse_bench_m2("no table here") == {})

    check("coerce int", coerce(7) == 7.0)
    check("coerce numeric string", coerce(" 0.5 ") == 0.5)
    check("coerce rejects words", coerce("fast") is None)
    check("coerce rejects bool", coerce(True) is None)

    passing = evaluate({"final_asr_rtf": 0.0116}, budgets=BUDGETS)
    statuses_passing = dict((k, s) for s, k in ((row[0], row[1].split(":")[0]) for row in passing))
    check("rtf 0.0116 passes", statuses_passing.get("final_asr_rtf") == "PASS")

    violating = evaluate({"final_asr_rtf": 0.9}, budgets={"final_asr_rtf": BUDGETS["final_asr_rtf"]})
    check("rtf 0.9 fails", violating[0][0] == "FAIL")

    skipped = evaluate({}, budgets={"soak_memory_delta_mb": BUDGETS["soak_memory_delta_mb"]})
    check("missing evidence skips", skipped[0][0] == "NO EVIDENCE")

    ge_budget = evaluate({"diarization_rtfx": 25.0}, budgets={"diarization_rtfx": BUDGETS["diarization_rtfx"]})
    check("ge budget passes above threshold", ge_budget[0][0] == "PASS")
    ge_fail = evaluate({"diarization_rtfx": 10.0}, budgets={"diarization_rtfx": BUDGETS["diarization_rtfx"]})
    check("ge budget fails below threshold", ge_fail[0][0] == "FAIL")

    if failures:
        for name in failures:
            print(f"SELF-TEST FAIL: {name}")
        return 1
    print(f"self-test passed ({len(BUDGETS)} budgets codified)")
    return 0


def main(arguments: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Check measured performance against the budgets in docs/PERF-BUDGETS.md.",
    )
    parser.add_argument(
        "--json",
        metavar="FILE",
        help=(
            "JSON object of metric keys to measured numbers ('-' for stdin). "
            f"Recognized keys: {', '.join(BUDGETS)}. "
            "Without this flag, evidence is scraped from docs/BENCH-M2-ASR.md."
        ),
    )
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="run built-in checks against synthetic data and exit",
    )
    args = parser.parse_args(arguments)

    if args.self_test:
        return self_test()

    measured = collect_evidence(args.json)
    rows = evaluate(measured)

    print("Perf budgets (docs/PERF-BUDGETS.md)")
    print("-" * 72)
    for status, detail in rows:
        print(f"{status:<12} {detail}")
    print("-" * 72)

    failed = sum(1 for status, _ in rows if status == "FAIL")
    skipped = sum(1 for status, _ in rows if status == "NO EVIDENCE")
    passed = len(rows) - failed - skipped
    print(f"{passed} pass, {failed} violate, {skipped} without evidence")
    if failed:
        return 1
    if skipped == len(rows):
        print("note: provide measurements via --json to exercise unmeasured budgets")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
