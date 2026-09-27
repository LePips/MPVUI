"""Offline identity and preservation guards for opt-in synchronization fixtures."""

import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "Benchmarks/prepare_sync_probe.py"
spec = importlib.util.spec_from_file_location("prepare_sync_probe", SCRIPT)
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


class SyncPreparationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.direct = self.root / "direct.mp4"
        self.direct.write_bytes(b"synthetic-direct-identity")
        self.hls = self.root / "hls/index.m3u8"
        self.hls.parent.mkdir()
        self.hls.write_text('#EXTM3U\n#EXT-X-MAP:URI="init.mp4"\nsegment.mp4\n')
        (self.hls.parent / "init.mp4").write_bytes(b"synthetic-init")
        (self.hls.parent / "segment.mp4").write_bytes(b"synthetic-segment")
        self.references = []
        for name, media in (("direct", self.direct), ("hls", self.hls)):
            identity = probe.media_identity(media)
            report = {
                "runtime": {"media": identity},
                "environment": {"comparisonKey": {"protocol": {"schema": 4}, "device": "same-device"}},
                "workloads": [
                    {
                        "parameters": {"player": "mpv", "mediaSHA256": identity["sha256"]},
                        "observations": [{"schemaVersion": 4, "status": "passed"}],
                    }
                ],
            }
            path = self.root / (name + "-reference.json")
            path.write_text(json.dumps(report))
            self.references.append(path)
        self.output = self.root / "GeneratedMedia"

    def prepare(self):
        return probe.prepare(
            self.direct, self.hls, *self.references, "http://127.0.0.1:8000/hls/index.m3u8", self.output
        )

    def mutate_reference(self, index, action):
        path = self.references[index]
        report = json.loads(path.read_text())
        action(report)
        path.write_text(json.dumps(report))

    def test_prepare_copies_exact_bytes_retains_manifest_and_rechecks(self):
        config_path = self.prepare()
        config = json.loads(config_path.read_text())
        self.assertEqual((self.output / self.direct.name).read_bytes(), self.direct.read_bytes())
        self.assertEqual(config["directFileSHA256"], probe.digest(self.direct))
        self.assertEqual(len(config["hostVerification"]["hlsIdentity"]["files"]), 3)
        self.assertEqual(config["hostVerification"]["directReferenceSHA256"], probe.digest(self.references[0]))
        self.assertEqual(probe.recheck(self.direct, self.hls, config_path)["status"], "passed")

    def test_config_and_foreign_existing_copy_are_never_overwritten(self):
        self.output.mkdir()
        copy_path = self.output / self.direct.name
        copy_path.write_bytes(b"prior unrelated evidence")
        with self.assertRaisesRegex(ValueError, "refusing overwrite"):
            self.prepare()
        self.assertEqual(copy_path.read_bytes(), b"prior unrelated evidence")
        copy_path.write_bytes(self.direct.read_bytes())
        config = self.prepare()
        original = config.read_bytes()
        with self.assertRaises(FileExistsError):
            self.prepare()
        self.assertEqual(config.read_bytes(), original)

    def test_changed_direct_fixture_is_rejected_before_any_output(self):
        self.direct.write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "differ from"):
            self.prepare()
        self.assertFalse(self.output.exists())

    def test_changed_hls_segment_is_rejected_before_any_output(self):
        (self.hls.parent / "segment.mp4").write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "differ from"):
            self.prepare()
        self.assertFalse(self.output.exists())

    def test_protocol_or_environment_identity_mismatch_is_rejected(self):
        self.mutate_reference(1, lambda r: r["environment"]["comparisonKey"].update(device="other"))
        with self.assertRaisesRegex(ValueError, "keys differ"):
            self.prepare()

    def test_failed_old_protocol_or_mismatched_workload_hash_is_rejected(self):
        original = self.references[0].read_text()
        for action in (
            lambda r: r["workloads"][0]["observations"][0].update(status="failed"),
            lambda r: r["workloads"][0]["observations"][0].update(schemaVersion=3),
            lambda r: r["workloads"][0]["parameters"].update(mediaSHA256="different"),
        ):
            self.references[0].write_text(original)
            self.mutate_reference(0, action)
            with self.assertRaises(ValueError):
                self.prepare()

    def test_url_does_not_accept_credentials_or_wrong_playlist(self):
        for url in (
            "file:///index.m3u8",
            "http://user:secret@localhost/index.m3u8",
            "http://localhost/wrong.m3u8",
            "http://localhost/index.m3u8?token=x",
        ):
            with self.subTest(url=url), self.assertRaises(ValueError):
                probe.validate_url(url, self.hls)

    def test_recheck_detects_changed_source_copy_or_segment(self):
        config = self.prepare()
        for path in (self.direct, self.output / self.direct.name, self.hls.parent / "segment.mp4"):
            original = path.read_bytes()
            path.write_bytes(b"changed after run")
            with self.subTest(path=path.name), self.assertRaises(ValueError):
                probe.recheck(self.direct, self.hls, config)
            path.write_bytes(original)

    def test_recheck_rejects_disagreeing_declared_identity(self):
        config = self.prepare()
        value = json.loads(config.read_text())
        value["hlsMediaSHA256"] = "different"
        config.write_text(json.dumps(value))
        with self.assertRaisesRegex(ValueError, "disagree"):
            probe.recheck(self.direct, self.hls, config)

    def test_cli_works_outside_repository_and_refuses_recheck_overwrite(self):
        args = [
            sys.executable,
            str(SCRIPT),
            "prepare",
            "--direct",
            str(self.direct),
            "--hls",
            str(self.hls),
            "--direct-report",
            str(self.references[0]),
            "--hls-report",
            str(self.references[1]),
            "--hls-url",
            "http://localhost/hls/index.m3u8",
            "--output",
            str(self.output),
        ]
        result = subprocess.run(args, cwd=self.root, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        check = [
            sys.executable,
            str(SCRIPT),
            "recheck",
            "--direct",
            str(self.direct),
            "--hls",
            str(self.hls),
            "--configuration",
            str(self.output / "native-sync-configuration.json"),
            "--output",
            str(self.root / "recheck.json"),
        ]
        result = subprocess.run(check, cwd=self.root, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        again = subprocess.run(check, cwd=self.root, capture_output=True, text=True)
        self.assertNotEqual(again.returncode, 0)


if __name__ == "__main__":
    unittest.main()
