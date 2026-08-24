import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


VERIFY_SCRIPT = (
    Path(__file__).parents[2]
    / "benchmarks"
    / "live-asr"
    / "air-kit"
    / "verify.sh"
)


class LiveASRAirKitTests(unittest.TestCase):
    def test_verify_rejects_a_package_without_the_swift_resource_bundle(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shutil.copy2(VERIFY_SCRIPT, root / "verify.sh")

            result = subprocess.run(
                ["bash", str(root / "verify.sh")],
                cwd=root,
                capture_output=True,
                text=True,
            )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("StenoKit_StenoTranscription.bundle", result.stderr)


if __name__ == "__main__":
    unittest.main()
