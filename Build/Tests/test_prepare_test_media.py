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
        group = next(group for group in media.GROUPS if media.script(group) == Path(command[1]))
        for name in media.GROUPS[group][1]:
            (destination / name).write_bytes(("encoded fixture " + name).encode())

    def prepare(self):
        with (
            patch.object(media.shutil, "which", return_value="/bin/tool"),
            patch.object(media.subprocess, "run", side_effect=self.generate),
        ):
            media.prepare(self.output)

    def test_empty_cache_generates_all_required_inputs_and_reuses_verified_files(self):
        self.prepare()
        self.assertEqual(len(self.calls), len(media.GROUPS))
        names = [name for key in media.GROUPS for name in media.GROUPS[key][1]]
        self.assertEqual({p.name for p in self.output.iterdir()}, set(names))
        state = json.loads((self.output.parent / "GeneratedMedia.state.json").read_text())
        for key in media.GROUPS:
            for name in media.GROUPS[key][1]:
                self.assertEqual(state[key]["files"][name], media.digest(self.output / name))
        timestamps = {p.name: p.stat().st_mtime_ns for p in self.output.iterdir()}
        self.prepare()
        self.assertEqual(len(self.calls), len(media.GROUPS))
        self.assertEqual(timestamps, {p.name: p.stat().st_mtime_ns for p in self.output.iterdir()})

    def test_missing_or_corrupt_output_regenerates_only_its_group(self):
        self.prepare()
        (self.output / "image-webp-animated.webp").unlink()
        self.prepare()
        self.assertEqual(self.calls[len(media.GROUPS) :], ["generate_image.py"])
        (self.output / "multitrack.mkv").write_bytes(b"corrupt")
        self.prepare()
        self.assertEqual(self.calls[len(media.GROUPS) + 1 :], ["generate_multitrack.py"])

    def test_concurrent_preparation_generates_each_group_once(self):
        with (
            patch.object(media.shutil, "which", return_value="/bin/tool"),
            patch.object(media.subprocess, "run", side_effect=self.generate),
            ThreadPoolExecutor(max_workers=2) as executor,
        ):
            futures = [executor.submit(media.prepare, self.output) for _ in range(2)]
            for future in futures:
                future.result(timeout=10)
        self.assertEqual(len(self.calls), len(media.GROUPS))

    def test_changed_recipe_regenerates_affected_group(self):
        self.prepare()
        state_path = self.output.parent / "GeneratedMedia.state.json"
        state = json.loads(state_path.read_text())
        state["image"]["recipe"] = "old generator"
        state_path.write_text(json.dumps(state))
        self.prepare()
        self.assertEqual(self.calls[len(media.GROUPS) :], ["generate_image.py"])

    def test_missing_tools_fail_with_actionable_error(self):
        with patch.object(media.shutil, "which", return_value=None), self.assertRaisesRegex(RuntimeError, "install ffmpeg.*build host"):
            media.prepare(self.output)
        self.assertEqual(list(self.output.iterdir()), [])

    def test_verified_cache_does_not_require_installed_encoders(self):
        self.prepare()
        with patch.object(media.shutil, "which", return_value=None) as lookup, patch.object(media.subprocess, "run") as generate:
            media.prepare(self.output)
        lookup.assert_not_called()
        generate.assert_not_called()

    def test_failed_generation_does_not_publish_partial_files(self):
        def fail(command, **kwargs):
            self.generate(command, **kwargs)
            raise subprocess.CalledProcessError(1, command)

        with (
            patch.object(media.shutil, "which", return_value="/bin/tool"),
            patch.object(media.subprocess, "run", side_effect=fail),
            self.assertRaises(subprocess.CalledProcessError),
        ):
            media.prepare(self.output)
        self.assertEqual(list(self.output.iterdir()), [])
        self.assertFalse((self.output.parent / "GeneratedMedia.state.json").exists())

    def test_explicit_group_only_requires_its_tools_and_reuses_cache(self):
        with (
            patch.object(media.shutil, "which", return_value="/bin/tool"),
            patch.object(media.subprocess, "run", side_effect=self.generate),
        ):
            media.prepare(self.output, groups=("image",))
            media.prepare(self.output, groups=("image",))
        self.assertEqual(self.calls, ["generate_image.py"])
        self.assertEqual({p.name for p in self.output.iterdir()}, set(media.GROUPS["image"][1]))

    def test_invalid_state_recovers(self):
        self.prepare()
        state_path = self.output.parent / "GeneratedMedia.state.json"
        for content in ("{truncated", "null", "[]", '{"baseline": {"files": null}}'):
            with self.subTest(content=content):
                state_path.write_text(content)
                self.calls.clear()
                self.prepare()
                self.assertEqual(len(self.calls), len(media.GROUPS))

    def test_incomplete_generator_does_not_replace_previously_valid_group(self):
        self.prepare()
        original = (self.output / "image-webp-still.webp").read_bytes()
        (self.output / "image-webp-animated.webp").unlink()
        with (
            patch.object(media.shutil, "which", return_value="/bin/tool"),
            patch.object(media.subprocess, "run"),
            self.assertRaisesRegex(RuntimeError, "did not produce image-webp-still"),
        ):
            media.prepare(self.output)
        self.assertEqual((self.output / "image-webp-still.webp").read_bytes(), original)

    def test_groups_follow_generator_and_file_naming_convention(self):
        names = [name for _, files in media.GROUPS.values() for name in files]
        self.assertEqual(len(names), len(set(names)), "Generated file names must be unique")
        for group, (_, files) in media.GROUPS.items():
            with self.subTest(group=group):
                self.assertTrue(media.script(group).is_file())
                for name in files:
                    self.assertTrue(name.startswith((group + "-", group + ".")), name)

    def test_retired_generated_files_are_removed_and_other_files_kept(self):
        self.prepare()
        state_path = self.output.parent / "GeneratedMedia.state.json"
        state = json.loads(state_path.read_text())
        for name in ("retired-group.mkv", "image-retired.webp", "native-sync-configuration.json"):
            (self.output / name).write_bytes(b"data")
        state["retired"] = {"recipe": "old", "files": {"retired-group.mkv": "digest"}}
        state["image"]["files"]["image-retired.webp"] = "digest"
        state_path.write_text(json.dumps(state))
        self.prepare()
        self.assertEqual(len(self.calls), len(media.GROUPS))
        self.assertFalse((self.output / "retired-group.mkv").exists())
        self.assertFalse((self.output / "image-retired.webp").exists())
        # Files added by other tools, such as the device sync probe, stay in place.
        self.assertTrue((self.output / "native-sync-configuration.json").exists())
        state = json.loads(state_path.read_text())
        self.assertNotIn("retired", state)
        self.assertNotIn("image-retired.webp", state["image"]["files"])

    def test_inband_dolby_vision_derives_from_the_chart_and_survives_preparation(self):
        self.output.mkdir()
        chart = Path(self.directory.name) / "chart.mp4"
        chart.write_bytes(b"chart")

        def extract(command, **kwargs):
            self.assertEqual(command[command.index("-i") + 1], str(chart))
            self.assertEqual(command[command.index("-bsf:v") + 1], "hevc_mp4toannexb")
            Path(command[-1]).write_bytes(b"annexb")

        with patch.object(media.subprocess, "run", side_effect=extract):
            media.prepare_inband_dolby_vision(self.output, chart)
        self.assertEqual((self.output / media.INBAND_DOLBY_VISION).read_bytes(), b"annexb")
        self.assertEqual([path.name for path in self.output.iterdir()], [media.INBAND_DOLBY_VISION])
        self.prepare()
        self.assertTrue((self.output / media.INBAND_DOLBY_VISION).exists())

    def test_missing_chart_removes_a_stale_inband_stream(self):
        self.output.mkdir()
        (self.output / media.INBAND_DOLBY_VISION).write_bytes(b"stale")
        with patch.object(media.subprocess, "run") as run, patch("sys.stdout"):
            media.prepare_inband_dolby_vision(self.output, Path(self.directory.name) / "missing.mp4")
        run.assert_not_called()
        self.assertFalse((self.output / media.INBAND_DOLBY_VISION).exists())


if __name__ == "__main__":
    unittest.main()
