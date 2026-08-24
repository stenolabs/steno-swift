from __future__ import annotations

import array
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest import mock
import wave

DEMO_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(DEMO_DIR))

from mix_demo_audio import (  # noqa: E402
    ArchitectureError,
    ClipMetadata,
    ClippingBudgetExceeded,
    ensure_native_apple_silicon,
    mix_clips,
    render_mix,
    round_fixed_pcm,
    validate_clip_metadata,
)


class MixerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="steno-mixer-tests-")
        self.root = Path(self.temporary.name)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def write_clip(self, name: str, samples: list[int], sample_rate: int = 8_000) -> Path:
        path = self.root / name
        payload = array.array("h", samples)
        if sys.byteorder != "little":
            payload.byteswap()
        with wave.open(str(path), "wb") as destination:
            destination.setparams((1, 2, sample_rate, len(samples), "NONE", "not compressed"))
            destination.writeframes(payload.tobytes())
        return path

    def clip(
        self,
        path: Path,
        *,
        start_frame: int = 0,
        numerator: int = 65_536,
        fraction_bits: int = 16,
        speaker: str = "Sprecherin A",
        gain_db: str = "0.0",
    ) -> ClipMetadata:
        return ClipMetadata(
            path=path,
            speaker=speaker,
            start_frame=start_frame,
            start_seconds=str(start_frame / 8_000),
            gain_db=gain_db,
            gain_numerator=numerator,
            fraction_bits=fraction_bits,
        )

    def test_fixed_point_rounding_is_half_away_from_zero(self) -> None:
        self.assertEqual(round_fixed_pcm(1, 1, 1), 1)
        self.assertEqual(round_fixed_pcm(-1, 1, 1), -1)
        self.assertEqual(round_fixed_pcm(3, 1, 1), 2)
        self.assertEqual(round_fixed_pcm(-3, 1, 1), -2)
        self.assertEqual(round_fixed_pcm(123, 65_536, 16), 123)

    def test_exact_frame_placement_and_overlap_sum(self) -> None:
        first = self.clip(self.write_clip("first.wav", [100]), start_frame=2)
        second = self.clip(self.write_clip("second.wav", [-30]), start_frame=2)
        result = mix_clips([first, second], sample_rate=8_000)
        self.assertEqual(result.samples, [0, 0, 70])
        self.assertEqual(result.metrics.output_frame_count, 3)
        self.assertEqual(result.metrics.input_peak, 100)
        self.assertEqual(result.metrics.pre_clamp_mixed_peak, 70)
        self.assertEqual(result.metrics.output_peak, 70)
        self.assertEqual(result.metrics.clipped_sample_count, 0)

    def test_gain_mapping_and_documentary_metadata_are_validated(self) -> None:
        clip = self.clip(self.write_clip("gain.wav", [1]), numerator=58_409, gain_db="-1.0")
        validate_clip_metadata(
            clip,
            sample_rate=8_000,
            expected_gain_db="-1.0",
            expected_gain_numerator=58_409,
            expected_fraction_bits=16,
        )
        with self.assertRaises(ValueError):
            validate_clip_metadata(
                clip,
                sample_rate=8_000,
                expected_gain_db="-0.5",
                expected_gain_numerator=58_409,
                expected_fraction_bits=16,
            )
        with self.assertRaises(ValueError):
            validate_clip_metadata(
                clip,
                sample_rate=8_000,
                expected_gain_db="-1.0",
                expected_gain_numerator=61_870,
                expected_fraction_bits=16,
            )

    def test_canonical_little_endian_pcm16_output_and_deterministic_json(self) -> None:
        clip = self.clip(self.write_clip("canonical.wav", [1, -2]))
        output = self.root / "result.wav"
        timeline = self.root / "timeline.json"
        metrics = self.root / "metrics.json"
        render_mix(
            clips=[clip],
            sample_rate=8_000,
            output=output,
            timeline_output=timeline,
            metrics_output=metrics,
            item_id="test-item",
        )

        payload = output.read_bytes()
        self.assertEqual(payload[:4], b"RIFF")
        self.assertEqual(payload[8:16], b"WAVEfmt ")
        self.assertEqual(struct.unpack_from("<I", payload, 16)[0], 16)
        self.assertEqual(struct.unpack_from("<HHIIHH", payload, 20), (1, 1, 8_000, 16_000, 2, 16))
        self.assertEqual(payload[36:40], b"data")
        self.assertEqual(struct.unpack_from("<I", payload, 40)[0], 4)
        self.assertEqual(payload[44:], struct.pack("<hh", 1, -2))
        self.assertEqual(json.loads(metrics.read_text())["clippedSampleCount"], 0)
        self.assertEqual(json.loads(timeline.read_text())[0]["startFrame"], 0)
        self.assertTrue(metrics.read_bytes().endswith(b"\n"))
        self.assertTrue(timeline.read_bytes().endswith(b"\n"))

    def test_unbudgeted_clipping_fails_without_replacing_any_output(self) -> None:
        first = self.clip(self.write_clip("hot-a.wav", [32_000]))
        second = self.clip(self.write_clip("hot-b.wav", [32_000]))
        output = self.root / "existing.wav"
        timeline = self.root / "existing-timeline.json"
        metrics = self.root / "existing-metrics.json"
        output.write_bytes(b"original audio")
        timeline.write_bytes(b"original timeline")
        metrics.write_bytes(b"original metrics")

        with self.assertRaises(ClippingBudgetExceeded):
            render_mix(
                clips=[first, second],
                sample_rate=8_000,
                output=output,
                timeline_output=timeline,
                metrics_output=metrics,
                item_id="clipping",
            )
        self.assertEqual(output.read_bytes(), b"original audio")
        self.assertEqual(timeline.read_bytes(), b"original timeline")
        self.assertEqual(metrics.read_bytes(), b"original metrics")

    def test_publication_failure_rolls_back_audio_timeline_and_metrics(self) -> None:
        clip = self.clip(self.write_clip("atomic.wav", [123]))
        output = self.root / "existing.wav"
        timeline = self.root / "existing-timeline.json"
        metrics = self.root / "existing-metrics.json"
        output.write_bytes(b"original audio")
        timeline.write_bytes(b"original timeline")
        metrics.write_bytes(b"original metrics")
        real_replace = __import__("os").replace
        replacement_count = 0

        def fail_on_second_metadata_publish(source: Path, destination: Path) -> None:
            nonlocal replacement_count
            replacement_count += 1
            if replacement_count == 2:
                raise OSError("injected metadata publication failure")
            real_replace(source, destination)

        with mock.patch("mix_demo_audio.os.replace", side_effect=fail_on_second_metadata_publish):
            with self.assertRaises(OSError):
                render_mix(
                    clips=[clip],
                    sample_rate=8_000,
                    output=output,
                    timeline_output=timeline,
                    metrics_output=metrics,
                    item_id="atomic",
                )

        self.assertEqual(output.read_bytes(), b"original audio")
        self.assertEqual(timeline.read_bytes(), b"original timeline")
        self.assertEqual(metrics.read_bytes(), b"original metrics")
        self.assertFalse(any(self.root.glob("*.partial.*")))

    def test_second_partial_creation_failure_removes_the_first_partial(self) -> None:
        clip = self.clip(self.write_clip("partial.wav", [123]))
        output = self.root / "result.wav"
        timeline = self.root / "timeline.json"
        metrics = self.root / "metrics.json"
        from mix_demo_audio import _temporary_path

        call_count = 0

        def fail_on_second_partial(destination: Path) -> Path:
            nonlocal call_count
            call_count += 1
            if call_count == 2:
                raise OSError("injected second mkstemp failure")
            return _temporary_path(destination)

        with mock.patch("mix_demo_audio._temporary_path", side_effect=fail_on_second_partial):
            with self.assertRaises(OSError):
                render_mix(
                    clips=[clip],
                    sample_rate=8_000,
                    output=output,
                    timeline_output=timeline,
                    metrics_output=metrics,
                    item_id="partial",
                )

        self.assertFalse(output.exists())
        self.assertFalse(timeline.exists())
        self.assertFalse(metrics.exists())
        self.assertFalse(any(self.root.glob("*.partial.*")))

    def test_backup_copy_failure_preserves_all_outputs_without_partial_leaks(self) -> None:
        clip = self.clip(self.write_clip("backup.wav", [123]))
        output = self.root / "existing.wav"
        timeline = self.root / "existing-timeline.json"
        metrics = self.root / "existing-metrics.json"
        output.write_bytes(b"original audio")
        timeline.write_bytes(b"original timeline")
        metrics.write_bytes(b"original metrics")

        with mock.patch("mix_demo_audio.shutil.copy2", side_effect=OSError("copy failed")):
            with self.assertRaises(OSError):
                render_mix(
                    clips=[clip],
                    sample_rate=8_000,
                    output=output,
                    timeline_output=timeline,
                    metrics_output=metrics,
                    item_id="backup",
                )

        self.assertEqual(output.read_bytes(), b"original audio")
        self.assertEqual(timeline.read_bytes(), b"original timeline")
        self.assertEqual(metrics.read_bytes(), b"original metrics")
        self.assertFalse(any(self.root.glob("*.partial.*")))

    def test_saturation_requires_an_explicit_budget(self) -> None:
        first = self.clip(self.write_clip("budget-a.wav", [32_000]))
        second = self.clip(self.write_clip("budget-b.wav", [32_000]))
        result = mix_clips([first, second], sample_rate=8_000, clipping_budget=1)
        self.assertEqual(result.samples, [32_767])
        self.assertEqual(result.metrics.pre_clamp_mixed_peak, 64_000)
        self.assertEqual(result.metrics.clipped_sample_count, 1)

    def test_architecture_guard_is_injectable(self) -> None:
        ensure_native_apple_silicon(machine_reader=lambda: "arm64", translated_reader=lambda: "0")
        with self.assertRaises(ArchitectureError):
            ensure_native_apple_silicon(machine_reader=lambda: "x86_64", translated_reader=lambda: "0")
        with self.assertRaises(ArchitectureError):
            ensure_native_apple_silicon(machine_reader=lambda: "arm64", translated_reader=lambda: "1")


if __name__ == "__main__":
    unittest.main()
