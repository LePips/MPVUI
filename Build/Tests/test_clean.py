"""Check which build outputs make clean removes and keeps."""

from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import clean


class CleanTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.build = self.root / ".build"
        for name in ("validation/old", "validation/running", "coverage/report", "android/native/jniLibs", "android/upstream/src"):
            (self.build / name).mkdir(parents=True)
        for name in ("test-media/baseline.mp4", "benchmarks/report.json", "android/performance/result.json", "notes.log"):
            (self.build / name).parent.mkdir(parents=True, exist_ok=True)
            (self.build / name).write_text("data")

    def test_default_clean_keeps_caches_reports_and_the_running_result(self):
        running = self.build / "validation/running"
        removed = clean.clean(self.root, cache=False, keep=frozenset([running]))
        self.assertEqual(removed, ["validation", "coverage", "android/native"])
        self.assertTrue(running.is_dir())
        self.assertFalse((self.build / "validation/old").exists())
        for kept in (
            "test-media/baseline.mp4",
            "android/upstream/src",
            "benchmarks/report.json",
            "android/performance/result.json",
            "notes.log",
        ):
            self.assertTrue((self.build / kept).exists(), kept)

    def test_cache_clean_removes_inputs_and_media_but_keeps_reports(self):
        removed = clean.clean(self.root, cache=True)
        self.assertIn("test-media", removed)
        self.assertIn("android/upstream", removed)
        self.assertFalse((self.build / "validation").exists())
        self.assertTrue((self.build / "benchmarks/report.json").exists())
        self.assertTrue((self.build / "android/performance/result.json").exists())


if __name__ == "__main__":
    unittest.main()
