#!/usr/bin/env python3
"""Run Apple, Parakeet and Nemotron live ASR against one verified corpus."""

from __future__ import annotations

import argparse
import dataclasses
import hashlib
import json
import platform
import subprocess
import sys
from pathlib import Path

SCRIPT_DIRECTORY = Path(__file__).resolve().parent
if str(SCRIPT_DIRECTORY) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIRECTORY))
sys.dont_write_bytecode = True

from manifest import load_manifest, validate_ready


@dataclasses.dataclass(frozen=True)
class RunnerPaths:
    steno: Path
    nemotron: Path
    parakeet_model: Path
    nemotron_cache: Path


@dataclasses.dataclass(frozen=True)
class Sample:
    sample_id: str
    locale: str
    audio: Path
    reference: Path


@dataclasses.dataclass(frozen=True)
class EngineCommand:
    engine_id: str
    arguments: list[str]
    hypothesis: Path


def validate_selection(*, mode: str, selected_samples: list[str]) -> None:
    if mode == "realtime" and len(selected_samples) != 1:
        raise ValueError("realtime mode requires exactly one --sample")


def engine_commands(
    *,
    sample: Sample,
    paths: RunnerPaths,
    output_root: Path,
    mode: str,
) -> list[EngineCommand]:
    hypothesis_root = output_root / sample.sample_id / "hypotheses"
    feed_chunk_milliseconds = "20" if mode == "realtime" else "250"
    apple_chunk_milliseconds = "20" if mode == "realtime" else "4000"

    def output(engine: str) -> Path:
        return hypothesis_root / f"{engine}-{mode}.json"

    apple_output = output("apple-live")
    parakeet_output = output("parakeet-live")
    nemotron_output = output("nemotron-live")
    common_steno = [
        "--input", str(sample.audio),
        "--locale", sample.locale,
        "--mode", mode,
    ]
    return [
        EngineCommand(
            engine_id="apple-live",
            arguments=[
                str(paths.steno), "--engine", "apple", *common_steno,
                "--chunk-ms", apple_chunk_milliseconds,
                "--output", str(apple_output),
            ],
            hypothesis=apple_output,
        ),
        EngineCommand(
            engine_id="parakeet-live",
            arguments=[
                str(paths.steno), "--engine", "parakeet", *common_steno,
                "--chunk-ms", feed_chunk_milliseconds,
                "--model-dir", str(paths.parakeet_model),
                "--output", str(parakeet_output),
            ],
            hypothesis=parakeet_output,
        ),
        EngineCommand(
            engine_id="nemotron-live",
            arguments=[
                str(paths.nemotron),
                "--input", str(sample.audio),
                "--language", sample.locale,
                "--chunk-ms", "2240",
                "--feed-chunk-ms", feed_chunk_milliseconds,
                "--mode", mode,
                "--model-cache", str(paths.nemotron_cache),
                "--output", str(nemotron_output),
            ],
            hypothesis=nemotron_output,
        ),
    ]


def manifest_samples(document: dict, corpus_root: Path) -> list[Sample]:
    result: list[Sample] = []
    for value in document["samples"]:
        locale = value["locale"]
        if locale.replace("_", "-").lower() != "de-de":
            raise ValueError(
                f"live ASR matrix requires de-DE, sample {value['id']} uses {locale}"
            )
        result.append(Sample(
            sample_id=value["id"],
            locale="de-DE",
            audio=(corpus_root / value["audio"]["path"]).resolve(),
            reference=(corpus_root / value["transcription"]["path"]).resolve(),
        ))
    return result


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def require_file(path: Path, label: str) -> None:
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"{label} is not a regular file: {path}")


def require_directory(path: Path, label: str) -> None:
    if path.is_symlink() or not path.is_dir():
        raise ValueError(f"{label} is not a directory: {path}")


def run_command(arguments: list[str], *, dry_run: bool) -> None:
    print("+ " + " ".join(arguments), flush=True)
    if not dry_run:
        subprocess.run(arguments, check=True)


def main(arguments: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--corpus-root", type=Path, required=True)
    parser.add_argument("--steno-runner", type=Path, required=True)
    parser.add_argument("--nemotron-runner", type=Path, required=True)
    parser.add_argument("--parakeet-model-dir", type=Path, required=True)
    parser.add_argument("--nemotron-cache", type=Path, required=True)
    parser.add_argument("--output-root", type=Path, required=True)
    parser.add_argument("--mode", choices=("fast", "realtime"), default="fast")
    parser.add_argument("--sample", action="append", default=[])
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(arguments)

    try:
        validate_selection(mode=args.mode, selected_samples=args.sample)
        corpus_root = args.corpus_root.resolve()
        document = load_manifest(args.manifest)
        validate_ready(document, corpus_root)
        samples = manifest_samples(document, corpus_root)
        if args.sample:
            requested = set(args.sample)
            samples = [sample for sample in samples if sample.sample_id in requested]
            found = {sample.sample_id for sample in samples}
            missing = requested - found
            if missing:
                raise ValueError(f"unknown sample IDs: {', '.join(sorted(missing))}")

        paths = RunnerPaths(
            steno=args.steno_runner.resolve(),
            nemotron=args.nemotron_runner.resolve(),
            parakeet_model=args.parakeet_model_dir.resolve(),
            nemotron_cache=args.nemotron_cache.resolve(),
        )
        require_file(paths.steno, "Steno live runner")
        require_file(paths.nemotron, "Nemotron live runner")
        require_directory(paths.parakeet_model, "Parakeet model")
        paths.nemotron_cache.mkdir(parents=True, exist_ok=True)
        output_root = args.output_root.resolve()
        output_root.mkdir(parents=True, exist_ok=True)

        executed: list[dict] = []
        score_script = Path(__file__).with_name("score_asr.py")
        for sample in samples:
            for command in engine_commands(
                sample=sample,
                paths=paths,
                output_root=output_root,
                mode=args.mode,
            ):
                command.hypothesis.parent.mkdir(parents=True, exist_ok=True)
                run_command(command.arguments, dry_run=args.dry_run)
                score = (
                    output_root / sample.sample_id / "scores"
                    / f"{command.engine_id}-{args.mode}.json"
                )
                score.parent.mkdir(parents=True, exist_ok=True)
                score_arguments = [
                    sys.executable,
                    str(score_script),
                    str(sample.reference),
                    str(command.hypothesis),
                    "--output", str(score),
                ]
                run_command(score_arguments, dry_run=args.dry_run)
                executed.append({
                    "sampleID": sample.sample_id,
                    "engine": command.engine_id,
                    "hypothesis": str(command.hypothesis),
                    "score": str(score),
                })

        metadata = {
            "schemaVersion": 1,
            "mode": args.mode,
            "host": platform.node(),
            "platform": platform.platform(),
            "manifest": str(args.manifest.resolve()),
            "manifestSHA256": sha256(args.manifest),
            "runners": {
                "steno": {"path": str(paths.steno), "sha256": sha256(paths.steno)},
                "nemotron": {"path": str(paths.nemotron), "sha256": sha256(paths.nemotron)},
            },
            "results": executed,
        }
        if not args.dry_run:
            (output_root / f"run-{args.mode}.json").write_text(
                json.dumps(metadata, indent=2, ensure_ascii=False) + "\n",
                encoding="utf-8",
            )
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"run_live_asr_matrix: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
