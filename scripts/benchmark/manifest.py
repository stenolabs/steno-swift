#!/usr/bin/env python3
"""Validate Steno's local speech benchmark source and sample manifest."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path
from urllib.parse import urlparse


SOURCE_ROLES = {"primary_candidate", "stress"}
SAMPLE_ROLES = {"primary", "stress"}
REFERENCE_STATUSES = {
    "source_registered",
    "license_review_required",
    "alignment_required",
    "human_verified",
}
CHECKSUM_LENGTHS = {"md5": 32, "sha256": 64}


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def require_string(value: object, field: str) -> str:
    require(isinstance(value, str) and bool(value.strip()), f"{field} must be a non-empty string")
    return value


def require_https(value: object, field: str) -> str:
    text = require_string(value, field)
    parsed = urlparse(text)
    require(parsed.scheme == "https" and bool(parsed.netloc), f"{field} must be an HTTPS URL")
    return text


def validate_checksum(value: object, field: str) -> None:
    require(isinstance(value, dict), f"{field} must be an object")
    algorithm = value.get("algorithm")
    require(algorithm in CHECKSUM_LENGTHS, f"{field}.algorithm must be md5 or sha256")
    digest = value.get("value")
    expected_length = CHECKSUM_LENGTHS[algorithm]
    require(
        isinstance(digest, str)
        and len(digest) == expected_length
        and bool(re.fullmatch(r"[0-9a-f]+", digest)),
        f"{field}.checksum must be a lowercase {algorithm} digest",
    )


def validate_metadata(document: object) -> dict:
    require(isinstance(document, dict), "manifest must be a JSON object")
    require(document.get("schemaVersion") == 1, "schemaVersion must be 1")
    sources = document.get("sources")
    samples = document.get("samples")
    require(isinstance(sources, list) and bool(sources), "sources must be a non-empty array")
    require(isinstance(samples, list), "samples must be an array")

    seen_source_ids: set[str] = set()
    for index, source in enumerate(sources):
        field = f"sources[{index}]"
        require(isinstance(source, dict), f"{field} must be an object")
        source_id = require_string(source.get("id"), f"{field}.id")
        require(source_id not in seen_source_ids, f"duplicate source id: {source_id}")
        seen_source_ids.add(source_id)
        require(source.get("role") in SOURCE_ROLES, f"{field}.role is invalid")
        require_string(source.get("title"), f"{field}.title")
        require_string(source.get("language"), f"{field}.language")
        require_https(source.get("sourceURL"), f"{field}.sourceURL")
        require_string(source.get("doi"), f"{field}.doi")
        publication_date = require_string(source.get("publicationDate"), f"{field}.publicationDate")
        require(bool(re.fullmatch(r"\d{4}-\d{2}-\d{2}", publication_date)), f"{field}.publicationDate must be YYYY-MM-DD")

        license_value = source.get("license")
        require(isinstance(license_value, dict), f"{field}.license must be an object")
        require_string(license_value.get("id"), f"{field}.license.id")
        require_https(license_value.get("url"), f"{field}.license.url")
        for capability in ("commercialUse", "derivatives", "redistribution"):
            require(
                isinstance(license_value.get(capability), bool),
                f"{field}.license.{capability} must be boolean",
            )

        files = source.get("files")
        require(isinstance(files, list) and bool(files), f"{field}.files must be a non-empty array")
        seen_keys: set[str] = set()
        for file_index, source_file in enumerate(files):
            file_field = f"{field}.files[{file_index}]"
            require(isinstance(source_file, dict), f"{file_field} must be an object")
            require_string(source_file.get("role"), f"{file_field}.role")
            key = require_string(source_file.get("key"), f"{file_field}.key")
            require(key not in seen_keys, f"{field} has duplicate file key: {key}")
            seen_keys.add(key)
            require(
                isinstance(source_file.get("size"), int) and source_file["size"] > 0,
                f"{file_field}.size must be a positive integer",
            )
            validate_checksum(source_file.get("checksum"), file_field)
            require_https(source_file.get("url"), f"{file_field}.url")

        reference = source.get("reference")
        require(isinstance(reference, dict), f"{field}.reference must be an object")
        require_string(reference.get("kind"), f"{field}.reference.kind")
        require(reference.get("status") in REFERENCE_STATUSES, f"{field}.reference.status is invalid")
        require_string(reference.get("notes"), f"{field}.reference.notes")

    seen_sample_ids: set[str] = set()
    for index, sample in enumerate(samples):
        field = f"samples[{index}]"
        require(isinstance(sample, dict), f"{field} must be an object")
        sample_id = require_string(sample.get("id"), f"{field}.id")
        require(sample_id not in seen_sample_ids, f"duplicate sample id: {sample_id}")
        seen_sample_ids.add(sample_id)
        require(sample.get("sourceID") in seen_source_ids, f"{field}.sourceID is unknown")
        require(sample.get("role") in SAMPLE_ROLES, f"{field}.role is invalid")

    return document


def artifact_path(root: Path, artifact: object, field: str) -> Path:
    require(isinstance(artifact, dict), f"{field} must be an object")
    relative = Path(require_string(artifact.get("path"), f"{field}.path"))
    require(not relative.is_absolute() and ".." not in relative.parts, f"{field}.path must stay inside corpus root")
    digest = artifact.get("sha256")
    require(
        isinstance(digest, str) and bool(re.fullmatch(r"[0-9a-f]{64}", digest)),
        f"{field}.sha256 must be a lowercase SHA-256 digest",
    )
    candidate = root / relative
    require(not candidate.is_symlink(), f"{field}.path must not be a symlink")
    resolved = candidate.resolve()
    require(resolved.is_relative_to(root), f"{field}.path resolves outside corpus root")
    require(resolved.is_file(), f"{field}.path does not exist: {relative}")
    actual = hashlib.sha256(resolved.read_bytes()).hexdigest()
    require(actual == digest, f"{field}.sha256 does not match {relative}")
    return candidate


def validate_ready(document: object, corpus_root: Path) -> dict:
    value = validate_metadata(document)
    samples = value["samples"]
    require(bool(samples), "no benchmark-ready samples are registered")
    root = corpus_root.resolve()

    for index, sample in enumerate(samples):
        field = f"samples[{index}]"
        require_string(sample.get("locale"), f"{field}.locale")
        excerpt = sample.get("excerpt")
        require(isinstance(excerpt, dict), f"{field}.excerpt must be an object")
        start = excerpt.get("startSeconds")
        end = excerpt.get("endSeconds")
        require(isinstance(start, (int, float)) and start >= 0, f"{field}.excerpt.startSeconds is invalid")
        require(isinstance(end, (int, float)) and end > start, f"{field}.excerpt.endSeconds must exceed start")

        artifact_path(root, sample.get("audio"), f"{field}.audio")
        transcription = sample.get("transcription")
        require(isinstance(transcription, dict), f"{field}.transcription must be an object")
        require(transcription.get("status") == "human_verified", f"{field}.transcription.status must be human_verified")
        artifact_path(root, transcription, f"{field}.transcription")
        diarization = sample.get("diarization")
        require(isinstance(diarization, dict), f"{field}.diarization must be an object")
        require(diarization.get("status") == "human_verified", f"{field}.diarization.status must be human_verified")
        artifact_path(root, diarization, f"{field}.diarization")
        artifact_path(root, sample.get("uem"), f"{field}.uem")

        named_terms = sample.get("namedTerms")
        conditions = sample.get("conditions")
        require(isinstance(named_terms, list) and all(isinstance(term, str) for term in named_terms), f"{field}.namedTerms must be strings")
        require(isinstance(conditions, list) and all(isinstance(item, str) for item in conditions), f"{field}.conditions must be strings")

    return value


def load_manifest(path: Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ValueError(f"cannot read manifest {path}: {error}") from error


def main(arguments: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("metadata", "ready"))
    parser.add_argument("manifest", type=Path)
    parser.add_argument("--corpus-root", type=Path)
    args = parser.parse_args(arguments)

    try:
        document = load_manifest(args.manifest)
        if args.mode == "metadata":
            validate_metadata(document)
        else:
            require(args.corpus_root is not None, "ready mode requires --corpus-root")
            validate_ready(document, args.corpus_root)
    except ValueError as error:
        print(f"benchmark manifest: {error}", file=sys.stderr)
        return 2

    print(f"benchmark manifest: {args.mode} validation passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
