import importlib.util
import sys
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).parents[1] / "benchmark" / "run_live_asr_matrix.py"
SPEC = importlib.util.spec_from_file_location("run_live_asr_matrix", MODULE_PATH)
matrix = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = matrix
SPEC.loader.exec_module(matrix)


class LiveASRMatrixTests(unittest.TestCase):
    def test_builds_three_explicit_german_engine_commands(self) -> None:
        paths = matrix.RunnerPaths(
            steno=Path("/opt/steno-live-transcribe"),
            nemotron=Path("/opt/steno-nemotron-live-bench"),
            parakeet_model=Path("/models/parakeet"),
            nemotron_cache=Path("/models/nemotron"),
        )
        sample = matrix.Sample(
            sample_id="dialog-01",
            locale="de-DE",
            audio=Path("/corpus/dialog-01/audio.wav"),
            reference=Path("/corpus/dialog-01/reference.json"),
        )

        commands = matrix.engine_commands(
            sample=sample,
            paths=paths,
            output_root=Path("/results"),
            mode="fast",
        )

        self.assertEqual([command.engine_id for command in commands], [
            "apple-live",
            "parakeet-live",
            "nemotron-live",
        ])
        self.assertEqual(commands[0].arguments, [
            "/opt/steno-live-transcribe",
            "--engine", "apple",
            "--input", "/corpus/dialog-01/audio.wav",
            "--locale", "de-DE",
            "--mode", "fast",
            "--chunk-ms", "4000",
            "--output", "/results/dialog-01/hypotheses/apple-live-fast.json",
        ])
        parakeet_chunk_index = commands[1].arguments.index("--chunk-ms")
        self.assertEqual(commands[1].arguments[parakeet_chunk_index + 1], "250")
        self.assertIn("/models/parakeet", commands[1].arguments)
        self.assertIn("de-DE", commands[2].arguments)
        self.assertIn("2240", commands[2].arguments)
        self.assertNotIn("auto", commands[2].arguments)
        self.assertIn("250", commands[2].arguments)

        realtime = matrix.engine_commands(
            sample=sample,
            paths=paths,
            output_root=Path("/results"),
            mode="realtime",
        )
        self.assertIn("20", realtime[0].arguments)
        self.assertIn("20", realtime[2].arguments)

    def test_realtime_requires_one_explicit_sample(self) -> None:
        with self.assertRaisesRegex(ValueError, "exactly one --sample"):
            matrix.validate_selection(mode="realtime", selected_samples=[])
        with self.assertRaisesRegex(ValueError, "exactly one --sample"):
            matrix.validate_selection(mode="realtime", selected_samples=["a", "b"])

        matrix.validate_selection(mode="realtime", selected_samples=["a"])
        matrix.validate_selection(mode="fast", selected_samples=[])

    def test_rejects_non_german_samples_before_running_the_matrix(self) -> None:
        document = {
            "samples": [{
                "id": "english-dialog",
                "locale": "en-US",
                "audio": {"path": "audio.wav"},
                "transcription": {"path": "reference.json"},
            }],
        }

        with self.assertRaisesRegex(ValueError, "requires de-DE"):
            matrix.manifest_samples(document, Path("/corpus"))


if __name__ == "__main__":
    unittest.main()
