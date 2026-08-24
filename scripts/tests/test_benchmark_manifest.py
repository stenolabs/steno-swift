import hashlib
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).parents[1] / "benchmark" / "manifest.py"
SPEC = importlib.util.spec_from_file_location("benchmark_manifest", MODULE_PATH)
manifest_module = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(manifest_module)


def source(source_id: str = "stress") -> dict:
    return {
        "id": source_id,
        "role": "stress",
        "title": "Public corpus",
        "language": "deu",
        "sourceURL": "https://example.test/record",
        "doi": "10.1234/example",
        "publicationDate": "2026-08-13",
        "license": {
            "id": "cc-by-4.0",
            "url": "https://creativecommons.org/licenses/by/4.0/",
            "commercialUse": True,
            "derivatives": True,
            "redistribution": True,
        },
        "files": [
            {
                "role": "audio",
                "key": "audio.wav",
                "size": 4,
                "checksum": {
                    "algorithm": "md5",
                    "value": "098f6bcd4621d373cade4e832627b4f6",
                },
                "url": "https://example.test/audio.wav",
            }
        ],
        "reference": {
            "kind": "manual_transcript",
            "status": "source_registered",
            "notes": "Not aligned yet.",
        },
    }


def manifest(samples: list[dict] | None = None) -> dict:
    return {
        "schemaVersion": 1,
        "sources": [source()],
        "samples": samples or [],
    }


class ManifestValidationTests(unittest.TestCase):
    def test_metadata_requires_explicit_license_capabilities(self) -> None:
        value = manifest()
        del value["sources"][0]["license"]["commercialUse"]

        with self.assertRaisesRegex(ValueError, "commercialUse"):
            manifest_module.validate_metadata(value)

    def test_metadata_rejects_duplicate_source_ids(self) -> None:
        value = manifest()
        value["sources"].append(source())

        with self.assertRaisesRegex(ValueError, "duplicate source id"):
            manifest_module.validate_metadata(value)

    def test_metadata_rejects_malformed_source_checksum(self) -> None:
        value = manifest()
        value["sources"][0]["files"][0]["checksum"]["value"] = "not-a-hash"

        with self.assertRaisesRegex(ValueError, "checksum"):
            manifest_module.validate_metadata(value)

    def test_ready_mode_rejects_source_only_manifest(self) -> None:
        value = manifest()
        manifest_module.validate_metadata(value)

        with self.assertRaisesRegex(ValueError, "no benchmark-ready samples"):
            manifest_module.validate_ready(value, Path("/unused"))

    def test_ready_mode_verifies_human_references_and_hashes(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            root = Path(raw_tmp)
            files = {
                "audio.wav": b"audio",
                "reference.json": b"reference",
                "reference.rttm": b"rttm",
                "reference.uem": b"uem",
            }
            for name, data in files.items():
                (root / name).write_bytes(data)

            def artifact(path: str) -> dict:
                return {
                    "path": path,
                    "sha256": hashlib.sha256(files[path]).hexdigest(),
                }

            sample = {
                "id": "sample-1",
                "sourceID": "stress",
                "role": "stress",
                "locale": "de-DE",
                "excerpt": {"startSeconds": 10.0, "endSeconds": 40.0},
                "audio": artifact("audio.wav"),
                "transcription": {
                    **artifact("reference.json"),
                    "status": "human_verified",
                },
                "diarization": {
                    **artifact("reference.rttm"),
                    "status": "human_verified",
                },
                "uem": artifact("reference.uem"),
                "namedTerms": ["Musterstadt"],
                "conditions": ["overlap"],
            }

            manifest_module.validate_ready(manifest([sample]), root)

            sample["transcription"]["status"] = "machine_generated"
            with self.assertRaisesRegex(ValueError, "human_verified"):
                manifest_module.validate_ready(manifest([sample]), root)

    def test_ready_mode_rejects_parent_symlink_escape(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp, tempfile.TemporaryDirectory() as outside_tmp:
            root = Path(raw_tmp)
            outside = Path(outside_tmp)
            (outside / "audio.wav").write_bytes(b"audio")
            (root / "escaped").symlink_to(outside, target_is_directory=True)
            artifact = {
                "path": "escaped/audio.wav",
                "sha256": hashlib.sha256(b"audio").hexdigest(),
            }

            with self.assertRaisesRegex(ValueError, "outside corpus root"):
                manifest_module.artifact_path(root.resolve(), artifact, "audio")

    def test_cli_metadata_and_ready_modes_have_distinct_exit_codes(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            root = Path(raw_tmp)
            manifest_path = root / "manifest.json"
            manifest_path.write_text(json.dumps(manifest()), encoding="utf-8")

            self.assertEqual(
                manifest_module.main(["metadata", str(manifest_path)]),
                0,
            )
            self.assertEqual(
                manifest_module.main(
                    ["ready", str(manifest_path), "--corpus-root", str(root)]
                ),
                2,
            )


if __name__ == "__main__":
    unittest.main()
