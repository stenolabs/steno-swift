#!/usr/bin/env python3
"""Score a Steno ASR hypothesis against a human-verified transcript."""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
import unicodedata
from pathlib import Path
from typing import NamedTuple, Sequence


NORMALIZATION = "steno-de-v1"


class EditCounts(NamedTuple):
    substitutions: int
    deletions: int
    insertions: int

    @property
    def total(self) -> int:
        return self.substitutions + self.deletions + self.insertions


def normalize_text(text: str) -> str:
    normalized = unicodedata.normalize("NFKC", text).casefold()
    characters: list[str] = []
    for character in normalized:
        category = unicodedata.category(character)
        characters.append(character if category[0] in {"L", "N"} else " ")
    return " ".join("".join(characters).split())


def edit_counts(reference: Sequence[str], hypothesis: Sequence[str]) -> EditCounts:
    rows: list[list[tuple[int, EditCounts]]] = []
    rows.append([(index, EditCounts(0, 0, index)) for index in range(len(hypothesis) + 1)])
    for ref_index in range(1, len(reference) + 1):
        row: list[tuple[int, EditCounts]] = [(ref_index, EditCounts(0, ref_index, 0))]
        for hyp_index in range(1, len(hypothesis) + 1):
            if reference[ref_index - 1] == hypothesis[hyp_index - 1]:
                row.append(rows[ref_index - 1][hyp_index - 1])
                continue
            substitution = rows[ref_index - 1][hyp_index - 1]
            deletion = rows[ref_index - 1][hyp_index]
            insertion = row[hyp_index - 1]
            candidates = [
                (
                    substitution[0] + 1,
                    EditCounts(
                        substitution[1].substitutions + 1,
                        substitution[1].deletions,
                        substitution[1].insertions,
                    ),
                ),
                (
                    deletion[0] + 1,
                    EditCounts(
                        deletion[1].substitutions,
                        deletion[1].deletions + 1,
                        deletion[1].insertions,
                    ),
                ),
                (
                    insertion[0] + 1,
                    EditCounts(
                        insertion[1].substitutions,
                        insertion[1].deletions,
                        insertion[1].insertions + 1,
                    ),
                ),
            ]
            row.append(min(candidates, key=lambda item: (item[0], -item[1].substitutions)))
        rows.append(row)
    return rows[-1][-1][1]


def document_text(document: dict) -> str:
    text = document.get("text")
    if isinstance(text, str) and text.strip():
        return text
    segments = document.get("segments")
    if not isinstance(segments, list):
        raise ValueError("document must contain text or text-bearing segments")
    texts = [segment.get("text") for segment in segments if isinstance(segment, dict)]
    if not texts or not all(isinstance(item, str) for item in texts):
        raise ValueError("every fallback segment must contain text")
    return " ".join(texts)


def canonical_locale(value: object) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ValueError("document locale is missing")
    return value.replace("_", "-").lower()


def contains_term(words: list[str], term: str) -> bool:
    needle = normalize_text(term).split()
    if not needle:
        return False
    return any(words[index : index + len(needle)] == needle for index in range(len(words) - len(needle) + 1))


def score_documents(reference: dict, hypothesis: dict) -> dict:
    if reference.get("schemaVersion") != 1:
        raise ValueError("reference schemaVersion must be 1")
    if canonical_locale(reference.get("locale")) != canonical_locale(hypothesis.get("locale")):
        raise ValueError("reference and hypothesis locales differ")

    reference_normalized = normalize_text(document_text(reference))
    hypothesis_normalized = normalize_text(document_text(hypothesis))
    reference_words = reference_normalized.split()
    hypothesis_words = hypothesis_normalized.split()
    if not reference_words:
        raise ValueError("reference transcript is empty")

    word_edits = edit_counts(reference_words, hypothesis_words)
    reference_characters = list(reference_normalized.replace(" ", ""))
    hypothesis_characters = list(hypothesis_normalized.replace(" ", ""))
    character_edits = edit_counts(reference_characters, hypothesis_characters)

    terms = reference.get("namedTerms", [])
    if not isinstance(terms, list) or not all(isinstance(term, str) for term in terms):
        raise ValueError("reference namedTerms must be an array of strings")
    for term in terms:
        if not contains_term(reference_words, term):
            raise ValueError(f"namedTerm is absent from reference transcript: {term}")
    matched = [term for term in terms if contains_term(hypothesis_words, term)]
    missed = [term for term in terms if term not in matched]

    return {
        "schemaVersion": 1,
        "sampleID": reference.get("sampleID"),
        "locale": reference["locale"],
        "normalization": NORMALIZATION,
        "wer": word_edits.total / len(reference_words),
        "cer": character_edits.total / len(reference_characters),
        "words": {
            "reference": len(reference_words),
            "hypothesis": len(hypothesis_words),
            "substitutions": word_edits.substitutions,
            "deletions": word_edits.deletions,
            "insertions": word_edits.insertions,
            "omissionRate": word_edits.deletions / len(reference_words),
        },
        "characters": {
            "reference": len(reference_characters),
            "hypothesis": len(hypothesis_characters),
            "substitutions": character_edits.substitutions,
            "deletions": character_edits.deletions,
            "insertions": character_edits.insertions,
        },
        "namedTerms": {
            "total": len(terms),
            "matched": matched,
            "missed": missed,
            "recall": (len(matched) / len(terms)) if terms else None,
        },
    }


def load_json(path: Path) -> tuple[dict, str]:
    data = path.read_bytes()
    try:
        document = json.loads(data.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError) as error:
        raise ValueError(f"cannot read JSON {path}: {error}") from error
    if not isinstance(document, dict):
        raise ValueError(f"{path} must contain a JSON object")
    return document, hashlib.sha256(data).hexdigest()


def main(arguments: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("reference", type=Path)
    parser.add_argument("hypothesis", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args(arguments)

    try:
        reference, reference_hash = load_json(args.reference)
        hypothesis, hypothesis_hash = load_json(args.hypothesis)
        result = score_documents(reference, hypothesis)
        result["inputs"] = {
            "reference": args.reference.name,
            "referenceSHA256": reference_hash,
            "hypothesis": args.hypothesis.name,
            "hypothesisSHA256": hypothesis_hash,
        }
        encoded = json.dumps(result, indent=2, ensure_ascii=False) + "\n"
        if args.output:
            args.output.write_text(encoded, encoding="utf-8")
        else:
            print(encoded, end="")
    except (OSError, ValueError) as error:
        print(f"score_asr: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
