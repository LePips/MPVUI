import json
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import prepare_test_media as media


class TestMediaPreparationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.output = Path(self.directory.name) / "GeneratedMedia"
        self.calls = []

    def generate(self, command, **kwargs):
        self.calls.append(Path(command[1]).name)
        destination = Path(command[3])
        group = next(value for value in media.GROUPS.values() if command[1].endswith(value[0]))
        for name in group[2]:
            (destination / name).write_bytes(("encoded fixture " + name).encode())

    def prepare(self):
        with patch.object(media.shutil, "which", return_value="/bin/tool"), \
                patch.object(media.subprocess, "run", side_effect=self.generate):
            media.prepare(self.output)

    def test_empty_cache_generates_all_required_inputs_and_reuses_verified_files(self):
        self.prepare()
        self.assertEqual(len(self.calls), len(media.DEFAULT_GROUPS))
        names = [name for key in media.DEFAULT_GROUPS for name in media.GROUPS[key][2]]
        self.assertEqual({p.name for p in self.output.iterdir()}, set(names))
        state = json.loads((self.output.parent / "GeneratedMedia.state.json").read_text())
        for key in media.DEFAULT_GROUPS:
            for name in media.GROUPS[key][2]:
                self.assertEqual(state[key]["files"][name], media.digest(self.output / name))
        timestamps = {p.name: p.stat().st_mtime_ns for p in self.output.iterdir()}
        self.prepare()
        self.assertEqual(len(self.calls), len(media.DEFAULT_GROUPS))
        self.assertEqual(timestamps, {p.name: p.stat().st_mtime_ns for p in self.output.iterdir()})

    def test_missing_or_corrupt_output_regenerates_only_its_group(self):
        self.prepare()
        (self.output / "webp-animation.webp").unlink()
        self.prepare()
        self.assertEqual(self.calls[len(media.DEFAULT_GROUPS):], ["generate_webp_fixture.py"])
        (self.output / "02-h264-multitrack.mkv").write_bytes(b"corrupt")
        self.prepare()
        self.assertEqual(self.calls[len(media.DEFAULT_GROUPS) + 1:], ["generate_multitrack_fixture.py"])

    def test_concurrent_preparation_generates_each_group_once(self):
        with patch.object(media.shutil, "which", return_value="/bin/tool"), \
                patch.object(media.subprocess, "run", side_effect=self.generate), \
                ThreadPoolExecutor(max_workers=2) as executor:
            futures = [executor.submit(media.prepare, self.output) for _ in range(2)]
            for future in futures:
                future.result(timeout=10)
        self.assertEqual(len(self.calls), len(media.DEFAULT_GROUPS))

    def test_changed_recipe_regenerates_affected_group(self):
        self.prepare()
        state_path = self.output.parent / "GeneratedMedia.state.json"
        state = json.loads(state_path.read_text())
        state["webp"]["recipe"] = "old generator"
        state_path.write_text(json.dumps(state))
        self.prepare()
        self.assertEqual(self.calls[len(media.DEFAULT_GROUPS):], ["generate_webp_fixture.py"])

    def test_missing_tools_fail_with_actionable_error(self):
        with patch.object(media.shutil, "which", return_value=None), \
                self.assertRaisesRegex(RuntimeError, "install ffmpeg.*build host"):
            media.prepare(self.output)
        self.assertEqual(list(self.output.iterdir()), [])

    def test_verified_cache_does_not_require_installed_encoders(self):
        self.prepare()
        with patch.object(media.shutil, "which", return_value=None) as lookup, \
                patch.object(media.subprocess, "run") as generate:
            media.prepare(self.output)
        lookup.assert_not_called()
        generate.assert_not_called()

    def test_failed_generation_does_not_publish_partial_files(self):
        def fail(command, **kwargs):
            self.generate(command, **kwargs)
            raise subprocess.CalledProcessError(1, command)

        with patch.object(media.shutil, "which", return_value="/bin/tool"), \
                patch.object(media.subprocess, "run", side_effect=fail), \
                self.assertRaises(subprocess.CalledProcessError):
            media.prepare(self.output)
        self.assertEqual(list(self.output.iterdir()), [])
        self.assertFalse((self.output.parent / "GeneratedMedia.state.json").exists())

    def test_explicit_group_only_requires_its_tools_and_reuses_cache(self):
        with patch.object(media.shutil, "which", return_value="/bin/tool"), \
                patch.object(media.subprocess, "run", side_effect=self.generate):
            media.prepare(self.output, groups=("native-dovi",))
            media.prepare(self.output, groups=("native-dovi",))
        self.assertEqual(self.calls, ["generate_dovi_fixture.py"])
        self.assertEqual({p.name for p in self.output.iterdir()}, {"profile5.rpu"})

    def test_invalid_state_recovers(self):
        self.prepare()
        state_path = self.output.parent / "GeneratedMedia.state.json"
        for content in ("{truncated", "null", "[]", '{"baseline": {"files": null}}'):
            with self.subTest(content=content):
                state_path.write_text(content)
                self.calls.clear()
                self.prepare()
                self.assertEqual(len(self.calls), len(media.DEFAULT_GROUPS))

    def test_incomplete_generator_does_not_replace_previously_valid_group(self):
        self.prepare()
        original = (self.output / "webp-still.webp").read_bytes()
        (self.output / "webp-animation.webp").unlink()
        with patch.object(media.shutil, "which", return_value="/bin/tool"), \
                patch.object(media.subprocess, "run"), \
                self.assertRaisesRegex(RuntimeError, "did not produce webp-still"):
            media.prepare(self.output)
        self.assertEqual((self.output / "webp-still.webp").read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
