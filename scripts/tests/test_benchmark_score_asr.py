import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).parents[1] / "benchmark" / "score_asr.py"
SPEC = importlib.util.spec_from_file_location("benchmark_score_asr", MODULE_PATH)
score_module = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(score_module)


class ASRScoringTests(unittest.TestCase):
    def test_scores_substitution_and_named_terms(self) -> None:
        reference = {
            "schemaVersion": 1,
            "sampleID": "standard-1",
            "locale": "de-DE",
            "segments": [
                {
                    "speaker": "spk01",
                    "start": 0.0,
                    "end": 2.0,
                    "text": "Die Stadt Musterstadt prüft Musteramt.",
                }
            ],
            "namedTerms": ["Musterstadt", "Musteramt"],
        }
        hypothesis = {
            "locale": "de-DE",
            "text": "Die Stadt Müsterstadt prüft Musteramt.",
            "segments": [{"start": 0.0, "end": 2.0}],
            "words": 5,
        }

        result = score_module.score_documents(reference, hypothesis)

        self.assertEqual(result["words"]["reference"], 5)
        self.assertEqual(result["words"]["substitutions"], 1)
        self.assertEqual(result["words"]["deletions"], 0)
        self.assertEqual(result["words"]["insertions"], 0)
        self.assertAlmostEqual(result["wer"], 0.2)
        self.assertEqual(result["namedTerms"]["matched"], ["Musteramt"])
        self.assertEqual(result["namedTerms"]["missed"], ["Musterstadt"])
        self.assertAlmostEqual(result["namedTerms"]["recall"], 0.5)
        self.assertGreater(result["cer"], 0.0)

    def test_counts_insertions_and_deletions(self) -> None:
        counts = score_module.edit_counts(
            ["eins", "zwei", "drei"],
            ["eins", "extra", "drei", "vier"],
        )

        self.assertEqual(counts.substitutions, 1)
        self.assertEqual(counts.deletions, 0)
        self.assertEqual(counts.insertions, 1)

    def test_accepts_segment_text_when_global_text_is_absent(self) -> None:
        reference = {
            "schemaVersion": 1,
            "sampleID": "sample",
            "locale": "de-DE",
            "segments": [
                {"speaker": "a", "start": 0, "end": 1, "text": "Guten Tag"},
                {"speaker": "b", "start": 1, "end": 2, "text": "Hallo"},
            ],
            "namedTerms": [],
        }
        hypothesis = {
            "locale": "de-DE",
            "segments": [
                {"start": 0, "end": 1, "text": "Guten Tag"},
                {"start": 1, "end": 2, "text": "Hallo"},
            ],
        }

        result = score_module.score_documents(reference, hypothesis)

        self.assertEqual(result["wer"], 0.0)
        self.assertEqual(result["cer"], 0.0)

    def test_rejects_named_term_not_present_in_reference(self) -> None:
        reference = {
            "schemaVersion": 1,
            "sampleID": "sample",
            "locale": "de-DE",
            "segments": [
                {"speaker": "a", "start": 0, "end": 1, "text": "Hallo Welt"}
            ],
            "namedTerms": ["Musterstadt"],
        }
        hypothesis = {"locale": "de-DE", "text": "Hallo Welt"}

        with self.assertRaisesRegex(ValueError, "namedTerm is absent"):
            score_module.score_documents(reference, hypothesis)

    def test_cli_writes_machine_readable_result_with_hashes(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            root = Path(raw_tmp)
            reference = root / "reference.json"
            hypothesis = root / "hypothesis.json"
            output = root / "score.json"
            reference.write_text(
                json.dumps(
                    {
                        "schemaVersion": 1,
                        "sampleID": "sample",
                        "locale": "de-DE",
                        "segments": [
                            {
                                "speaker": "a",
                                "start": 0,
                                "end": 1,
                                "text": "Hallo Welt",
                            }
                        ],
                        "namedTerms": [],
                    }
                ),
                encoding="utf-8",
            )
            hypothesis.write_text(
                json.dumps({"locale": "de-DE", "text": "Hallo Welt"}),
                encoding="utf-8",
            )

            exit_code = score_module.main(
                [str(reference), str(hypothesis), "--output", str(output)]
            )
            result = json.loads(output.read_text(encoding="utf-8"))

            self.assertEqual(exit_code, 0)
            self.assertEqual(result["normalization"], "steno-de-v1")
            self.assertEqual(len(result["inputs"]["referenceSHA256"]), 64)
            self.assertEqual(len(result["inputs"]["hypothesisSHA256"]), 64)

    def test_cli_fails_closed_and_writes_no_output_on_a_broken_run(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            root = Path(raw_tmp)
            reference = root / "reference.json"
            hypothesis = root / "hypothesis.json"
            output = root / "score.json"
            reference.write_text(
                json.dumps(
                    {
                        "schemaVersion": 1,
                        "sampleID": "sample",
                        "locale": "de-DE",
                        "segments": [
                            {"speaker": "a", "start": 0, "end": 1, "text": "Hallo Welt"}
                        ],
                        "namedTerms": ["Musterstadt"],
                    }
                ),
                encoding="utf-8",
            )
            hypothesis.write_text(
                json.dumps({"locale": "de-DE", "text": "Hallo Welt"}),
                encoding="utf-8",
            )

            exit_code = score_module.main(
                [str(reference), str(hypothesis), "--output", str(output)]
            )

            self.assertEqual(exit_code, 2)
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
