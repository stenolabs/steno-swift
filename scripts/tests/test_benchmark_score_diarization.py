import importlib.util
import hashlib
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).parents[1] / "benchmark" / "score_diarization.py"
SPEC = importlib.util.spec_from_file_location("benchmark_score_diarization", MODULE_PATH)
score_module = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(score_module)


class DiarizationScoringTests(unittest.TestCase):
    def test_overlap_spans_ignore_same_speaker_and_clean_handoffs(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            rttm = Path(raw_tmp) / "reference.rttm"
            rttm.write_text(
                "".join(
                    [
                        "SPEAKER sample 1 0.000 2.000 <NA> <NA> a <NA> <NA>\n",
                        "SPEAKER sample 1 1.000 2.000 <NA> <NA> a <NA> <NA>\n",
                        "SPEAKER sample 1 2.000 2.000 <NA> <NA> b <NA> <NA>\n",
                        "SPEAKER sample 1 3.000 2.000 <NA> <NA> c <NA> <NA>\n",
                    ]
                ),
                encoding="utf-8",
            )

            self.assertEqual(score_module.overlap_spans(rttm), [(2.0, 4.0)])

    def test_overlap_uem_reports_no_number_when_reference_has_no_overlap(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            root = Path(raw_tmp)
            rttm = root / "reference.rttm"
            output = root / "overlap.uem"
            rttm.write_text(
                "".join(
                    [
                        "SPEAKER sample 1 0.000 1.000 <NA> <NA> a <NA> <NA>\n",
                        "SPEAKER sample 1 1.000 1.000 <NA> <NA> b <NA> <NA>\n",
                    ]
                ),
                encoding="utf-8",
            )

            stats = score_module.overlap_uem(rttm, None, output)

            self.assertFalse(stats["available"])
            self.assertNotIn("DER", stats)
            self.assertFalse(output.exists())

    def test_overlap_uem_reports_no_number_when_all_regions_are_consumed_by_collar(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            root = Path(raw_tmp)
            rttm = root / "reference.rttm"
            output = root / "overlap.uem"
            rttm.write_text(
                "".join(
                    [
                        "SPEAKER sample 1 0.000 1.000 <NA> <NA> a <NA> <NA>\n",
                        "SPEAKER sample 1 0.800 1.000 <NA> <NA> b <NA> <NA>\n",
                    ]
                ),
                encoding="utf-8",
            )

            stats = score_module.overlap_uem(rttm, None, output)

            self.assertFalse(stats["available"])
            self.assertEqual(stats["effective_scored_s"], 0.0)
            self.assertIn("collar", stats["reason"])
            self.assertFalse(output.exists())

    def test_score_rejects_multiple_recordings_in_one_sample(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            root = Path(raw_tmp)
            reference = root / "reference.rttm"
            system = root / "system.rttm"
            reference.write_text(
                "".join(
                    [
                        "SPEAKER sample-a 1 0.000 1.000 <NA> <NA> a <NA> <NA>\n",
                        "SPEAKER sample-b 1 0.000 1.000 <NA> <NA> b <NA> <NA>\n",
                    ]
                ),
                encoding="utf-8",
            )
            system.write_text(
                "SPEAKER sample-a 1 0.000 1.000 <NA> <NA> a <NA> <NA>\n",
                encoding="utf-8",
            )

            with self.assertRaisesRegex(ValueError, "exactly one recording"):
                score_module.score(Path("score.py"), "abcdef1", reference, system, None)

    def test_score_rejects_mismatched_uem_identity(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            root = Path(raw_tmp)
            reference = root / "reference.rttm"
            system = root / "system.rttm"
            uem = root / "reference.uem"
            row = "SPEAKER sample 1 0.000 1.000 <NA> <NA> a <NA> <NA>\n"
            reference.write_text(row, encoding="utf-8")
            system.write_text(row, encoding="utf-8")
            uem.write_text("other 1 0.000 1.000\n", encoding="utf-8")

            with self.assertRaisesRegex(ValueError, "UEM identity"):
                score_module.score(Path("score.py"), "abcdef1", reference, system, uem)

    def test_run_dscore_uses_pinned_collar_and_parses_overall(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            root = Path(raw_tmp)
            fake = root / "score.py"
            arguments = root / "arguments.txt"
            fake.write_text(
                "import pathlib, sys\n"
                f"pathlib.Path({str(arguments)!r}).write_text(' '.join(sys.argv[1:]))\n"
                "print('FILE\\tDER\\tJER')\n"
                "print('OVERALL\\t12.34\\t56.78')\n",
                encoding="utf-8",
            )
            reference = root / "reference.rttm"
            system = root / "system.rttm"
            reference.write_text("reference", encoding="utf-8")
            system.write_text("system", encoding="utf-8")

            result = score_module.run_dscore(
                fake,
                reference,
                system,
                None,
                ignore_overlaps=True,
            )

            self.assertEqual(result, {"DER": 12.34, "JER": 56.78})
            invoked = arguments.read_text(encoding="utf-8")
            self.assertIn("--collar 0.25", invoked)
            self.assertIn("--ignore_overlaps", invoked)

    def test_score_records_input_hashes_and_scorer_version(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            root = Path(raw_tmp)
            reference = root / "reference.rttm"
            system = root / "system.rttm"
            uem = root / "reference.uem"
            reference.write_text(
                "SPEAKER sample 1 0.000 1.000 <NA> <NA> a <NA> <NA>\n",
                encoding="utf-8",
            )
            system.write_text(
                "SPEAKER sample 1 0.000 1.000 <NA> <NA> x <NA> <NA>\n",
                encoding="utf-8",
            )
            uem.write_text("sample 1 0.000 1.000\n", encoding="utf-8")
            original = score_module.run_dscore
            score_module.run_dscore = lambda *_args, **_kwargs: {"DER": 0.0, "JER": 0.0}
            try:
                result = score_module.score(
                    Path("score.py"), "abcdef1", reference, system, uem
                )
            finally:
                score_module.run_dscore = original

            self.assertEqual(result["scorerVersion"], "abcdef1")
            self.assertEqual(
                result["inputs"]["referenceSHA256"],
                hashlib.sha256(reference.read_bytes()).hexdigest(),
            )
            self.assertEqual(
                result["inputs"]["systemSHA256"],
                hashlib.sha256(system.read_bytes()).hexdigest(),
            )
            self.assertEqual(
                result["inputs"]["uemSHA256"],
                hashlib.sha256(uem.read_bytes()).hexdigest(),
            )


if __name__ == "__main__":
    unittest.main()
