"""Filesystem and input guards for local benchmark capture."""

import argparse
import contextlib
import copy
import io
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Benchmarks"))
import benchmark
from test_benchmark_comparison import report


class RunnerTests(unittest.TestCase):
    def test_display_session_identity_reads_only_explicit_console_lock_boolean(self):
        for locked in (False, True):
            payload = plistlib.dumps({"IOConsoleLocked": locked, "unrelatedUserData": "private"})
            with (
                self.subTest(locked=locked),
                patch.object(benchmark.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, stdout=payload)) as run,
            ):
                if locked:
                    with self.assertRaisesRegex(ValueError, "Unlock this Mac") as error:
                        benchmark.display_session_identity(["playback"])
                    self.assertNotIn("private", str(error.exception))
                else:
                    self.assertEqual(benchmark.display_session_identity(["playback"]), {"displaySessionUnlocked": True})
                self.assertEqual(run.call_args.args[0], ["/usr/sbin/ioreg", "-n", "Root", "-d1", "-a"])
                self.assertEqual(run.call_args.kwargs["stderr"], subprocess.DEVNULL)

    def test_display_session_identity_rejects_unavailable_or_non_boolean_lock_state(self):
        payloads = [b"unavailable", plistlib.dumps({}), plistlib.dumps({"IOConsoleLocked": 0})]
        for payload in payloads:
            with (
                self.subTest(payload=payload),
                patch.object(benchmark.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, stdout=payload)),
                self.assertRaisesRegex(ValueError, "Cannot verify"),
            ):
                benchmark.display_session_identity(["playback"])
        for failure in (OSError("unavailable"), subprocess.CalledProcessError(1, "ioreg"), subprocess.TimeoutExpired("ioreg", 5)):
            with (
                self.subTest(failure=failure),
                patch.object(benchmark.subprocess, "run", side_effect=failure),
                self.assertRaisesRegex(ValueError, "Cannot verify"),
            ):
                benchmark.display_session_identity(["playback"])
        with patch.object(benchmark.subprocess, "run") as run:
            self.assertEqual(benchmark.display_session_identity(["micro", "cache", "seek", "subtitle", "size"]), {})
            run.assert_not_called()

    def test_locked_console_rejects_playback_before_toolchain_work_only(self):
        payload = plistlib.dumps({"IOConsoleLocked": True})
        for suite in ("playback", "cache"):
            with (
                self.subTest(suite=suite),
                patch.object(benchmark.sys, "platform", "darwin"),
                patch.object(benchmark.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, stdout=payload)) as run,
                patch.object(benchmark, "pinned_developer", side_effect=ValueError("toolchain reached")) as developer,
            ):
                with contextlib.redirect_stderr(io.StringIO()) as errors:
                    self.assertEqual(benchmark.main(["run", "--label", "console-preflight", "--suites", suite]), 1)
                if suite == "playback":
                    developer.assert_not_called()
                    run.assert_called_once()
                    self.assertIn("Unlock this Mac", errors.getvalue())
                else:
                    developer.assert_called_once()
                    run.assert_not_called()

    def test_locked_console_after_playback_prevents_report_publication(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "report.json"

            def capture_swift(arguments, log, *, env):
                Path(env["MPVUI_PERF_OUTPUT"]).write_text(json.dumps({"workloads": []}))

            with contextlib.ExitStack() as stack:
                stack.enter_context(patch.object(benchmark.sys, "platform", "darwin"))
                session = stack.enter_context(
                    patch.object(
                        benchmark,
                        "display_session_identity",
                        side_effect=[{"displaySessionUnlocked": True}, ValueError("Unlock this Mac and rerun")],
                    )
                )
                stack.enter_context(patch.object(benchmark, "pinned_developer", return_value=(root, "pinned")))
                stack.enter_context(patch.object(benchmark, "source_identity", return_value={"sourceSHA256": "unchanged"}))
                stack.enter_context(patch.object(benchmark, "prepare_media", return_value=root / "media.mp4"))
                stack.enter_context(patch.object(benchmark, "media_identity", return_value={"playback": "media"}))
                stack.enter_context(patch.object(benchmark, "environment_identity", side_effect=lambda *args: {"comparisonKey": {}}))
                stack.enter_context(patch.object(benchmark, "run_step", side_effect=capture_swift))
                stack.enter_context(patch.object(benchmark, "publish_evidence"))
                stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
                errors = stack.enter_context(contextlib.redirect_stderr(io.StringIO()))
                self.assertEqual(
                    benchmark.main(
                        [
                            "run",
                            "--label",
                            "console-postflight",
                            "--suites",
                            "playback",
                            "--package-path",
                            str(root),
                            "--output",
                            str(output),
                        ]
                    ),
                    1,
                )
                self.assertEqual(session.call_count, 2)
                self.assertIn("Unlock this Mac", errors.getvalue())
            self.assertFalse(output.exists())

    def test_all_suites_exclude_audio_and_reject_ambiguous_selections(self):
        self.assertEqual(benchmark.selected_suites("all"), [suite for suite in benchmark.SUITES if suite != "audio"])
        self.assertEqual(benchmark.selected_suites("cache,seek,audio"), ["cache", "seek", "audio"])
        for value in ("", "micro,micro", "micro,", "unknown", "all,audio"):
            with self.subTest(suites=value), self.assertRaises(ValueError):
                benchmark.selected_suites(value)

    def test_audio_requires_opt_in_before_toolchain_or_media_preparation(self):
        with patch.dict(os.environ, {}, clear=True), patch.object(benchmark.sys, "platform", "darwin"):
            with patch.object(benchmark, "pinned_developer") as developer, contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(benchmark.main(["run", "--label", "audio", "--suites", "audio"]), 1)
            developer.assert_not_called()
        args = argparse.Namespace(
            media=None,
            fixture="baseline",
            decoder="software",
            hwdec_threads=None,
            seek_demuxer_offset=None,
            native_osd="inline",
            native_queue_lead_ms=None,
            backend="all",
        )
        with patch.dict(os.environ, {"MPVUI_RUN_NATIVE_AUDIO_TESTS": "1"}):
            benchmark.validate_capture_options(args, ["audio"])

    def test_playback_parser_forwards_interlaced_and_decoder_controls(self):
        with patch.object(benchmark, "run_benchmarks", return_value=0) as run:
            self.assertEqual(
                benchmark.main(
                    [
                        "run",
                        "--label",
                        "interlaced",
                        "--suites",
                        "playback",
                        "--fixture",
                        "interlaced1080",
                        "--deinterlace",
                        "frame",
                        "--decoder",
                        "videotoolbox",
                        "--hwdec-threads",
                        "2",
                        "--seek-demuxer-offset",
                        "0.5",
                        "--native-osd",
                        "composite",
                        "--native-queue-lead-ms",
                        "128",
                    ]
                ),
                0,
            )
        args = run.call_args.args[0]
        self.assertEqual((args.fixture, args.deinterlace, args.decoder, args.hwdec_threads), ("interlaced1080", "frame", "videotoolbox", 2))
        self.assertEqual((args.seek_demuxer_offset, args.native_osd), (0.5, "composite"))
        self.assertEqual(args.native_queue_lead_ms, 128)

    def test_seek_controls_preserve_unset_and_zero_and_reject_invalid_values(self):
        for supplied, expected in [([], None), (["--seek-demuxer-offset", "0"], 0.0)]:
            with self.subTest(options=supplied), patch.object(benchmark, "run_benchmarks", return_value=0) as run:
                self.assertEqual(benchmark.main(["run", "--label", "seek", *supplied]), 0)
                self.assertEqual(run.call_args.args[0].seek_demuxer_offset, expected)
                self.assertEqual(run.call_args.args[0].native_osd, "inline")
                self.assertIsNone(run.call_args.args[0].native_queue_lead_ms)
        for value in (0, 1000):
            with self.subTest(queue_lead_ms=value), patch.object(benchmark, "run_benchmarks", return_value=0) as run:
                self.assertEqual(benchmark.main(["run", "--label", "seek", "--native-queue-lead-ms", str(value)]), 0)
                self.assertEqual(run.call_args.args[0].native_queue_lead_ms, value)
        for supplied in (
            ["--seek-demuxer-offset", "nan"],
            ["--seek-demuxer-offset", "-0.1"],
            ["--seek-demuxer-offset", "2.1"],
            ["--native-osd", "unknown"],
            ["--native-queue-lead-ms", "-1"],
            ["--native-queue-lead-ms", "1001"],
            ["--native-queue-lead-ms", "0.5"],
        ):
            with self.subTest(options=supplied), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                benchmark.main(["run", "--label", "seek", *supplied])

    def test_capture_rejects_ignored_or_conflicting_fixture_options(self):
        cases = [
            (["playback"], dict(media=Path("custom.mp4"), fixture="hevc4k"), "not both"),
            (["cache"], dict(fixture="interlaced1080"), "playback suite"),
            (["playback"], dict(hwdec_threads=2), "videotoolbox"),
            (["seek"], dict(seek_demuxer_offset=0.5), "playback suite"),
            (["playback"], dict(native_osd="composite", backend="metal"), "sampleBuffer"),
            (["cache"], dict(native_osd="composite"), "sampleBuffer"),
            (["playback"], dict(native_queue_lead_ms=0, backend="metal"), "sampleBuffer"),
            (["seek"], dict(native_queue_lead_ms=128), "sampleBuffer"),
        ]
        for suites, overrides, message in cases:
            args = argparse.Namespace(
                **(
                    dict(
                        media=None,
                        fixture="baseline",
                        decoder="software",
                        hwdec_threads=None,
                        seek_demuxer_offset=None,
                        native_osd="inline",
                        native_queue_lead_ms=None,
                        backend="all",
                    )
                    | overrides
                )
            )
            with self.subTest(options=overrides), self.assertRaisesRegex(ValueError, message):
                benchmark.validate_capture_options(args, suites)

    def test_fixture_preparation_selects_only_required_generators(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            args = argparse.Namespace(media=None, fixture="interlaced1080")
            with patch.object(benchmark, "run_step") as run:
                media = benchmark.prepare_media(root, ["playback", "seek", "audio"], args, root / "logs", {})
            self.assertEqual(media, root / ".build/benchmark-media/interlaced-1080i.mkv")
            commands = [call.args[0] for call in run.call_args_list]
            self.assertEqual(commands[0][-4:], ["--kind", "interlaced1080", "--output", str(media)])
            self.assertEqual([command[-1] for command in commands[1:]], ["audio", "video"])
            self.assertTrue(all(command[1] == str(root / "Build/Tests/prepare_test_media.py") for command in commands[1:]))
            for suites, custom in [(["cache"], None), (["playback"], root / "custom.mp4")]:
                args = argparse.Namespace(media=custom, fixture="baseline")
                with self.subTest(suites=suites), patch.object(benchmark, "run_step") as run:
                    media = benchmark.prepare_media(root, suites, args, root / "logs", {})
                    run.assert_not_called()
                    self.assertEqual(media, custom or root / ".build/test-media/baseline.mp4")

    def test_media_identity_covers_seek_containers_and_audio_without_requiring_baseline(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            media = root / ".build/test-media"
            media.mkdir(parents=True)
            paths = [media / f"video-h264-long-gop.{extension}" for extension in ("mp4", "mkv", "ts")]
            paths.append(media / "audio-eac3-5.1.mka")
            for path in paths:
                path.write_bytes(path.name.encode())
            baseline = media / "baseline.mp4"
            identity = benchmark.media_identity(root, ["seek", "audio"], baseline)
            self.assertEqual(set(identity), {"seek/mp4", "seek/mkv", "seek/ts", "audio/eac3-5.1"})
            paths[1].write_bytes(b"changed fixture")
            self.assertNotEqual(identity["seek/mkv"], benchmark.media_identity(root, ["seek"], baseline)["seek/mkv"])
            self.assertEqual(benchmark.media_identity(root, ["cache"], baseline), {})
            with self.assertRaisesRegex(ValueError, "media does not exist"):
                benchmark.media_identity(root, ["playback"], baseline)

    def test_support_helpers_participate_in_source_freeze(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            helper = root / "Tests/Support/NativeAudioSession.swift"
            helper.parent.mkdir(parents=True)
            helper.write_text("original")
            with patch.object(benchmark, "capture", return_value=""):
                before = benchmark.source_identity(root)
                helper.write_text("changed")
                after = benchmark.source_identity(root)
            self.assertIn("Tests/Support/NativeAudioSession.swift", before["files"])
            self.assertNotEqual(before["sourceSHA256"], after["sourceSHA256"])

    def test_capture_summary_preserves_units_ranges_and_sample_counts(self):
        measured = report([8, 10, 12])
        summary = benchmark.measurement_summary(benchmark.compare_reports(measured, measured))
        self.assertEqual(
            summary["metrics"], [dict(workload="decode", metric="elapsed", unit="ms", median=10, min=8, max=12, sampleCount=3)]
        )

    def test_comparison_summary_keeps_gate_validity_and_prioritizes_regressions(self):
        before, after = report(), report()
        for index in range(25):
            for document in (before, after):
                workload = copy.deepcopy(document["workloads"][0])
                workload["id"] = f"workload-{index}"
                document["workloads"].append(workload)
        after["workloads"][-1]["metrics"]["elapsed"]["samples"] = [100, 100, 100]
        result = benchmark.compare_reports(before, after, regression_percent=5)
        summary = benchmark.comparison_summary(result)
        self.assertTrue(summary["thresholdsEvaluated"])
        self.assertTrue(summary["hasRegressions"])
        self.assertTrue(summary["metrics"][0]["regression"])
        self.assertEqual(summary["omittedMetrics"], 6)
        unchecked = benchmark.comparison_summary(benchmark.compare_reports(before, after))
        self.assertFalse(unchecked["thresholdsEvaluated"])
        self.assertIsNone(unchecked["metrics"][0]["regression"])

    def test_compare_publishes_full_json_and_returns_nonzero_for_regression(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            before, after, evidence = (root / name for name in ("before.json", "after.json", "evidence.json"))
            before.write_text(json.dumps(report([10, 10, 10])))
            after.write_text(json.dumps(report([20, 20, 20], label="candidate")))
            with patch.dict(os.environ, {benchmark.EVIDENCE_ENV: str(evidence)}), contextlib.redirect_stdout(io.StringIO()):
                status = benchmark.main(["compare", str(before), str(after), "--fail-regression-percent", "5"])
            result = json.loads(evidence.read_text())
            self.assertEqual(status, 2)
            self.assertEqual(result["summary"]["benchmarkComparison"]["metrics"][0]["percentChange"], 100)
            self.assertTrue(Path(result["artifacts"]["benchmarkComparison"]).is_file())

    def test_manifest_evaluation_uses_the_selected_xcode(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            framework = root / "Libmpv.xcframework"
            framework.mkdir()
            (framework / "Info.plist").write_bytes(plistlib.dumps({}))
            developer = root / "PinnedXcode.app/Contents/Developer"
            manifest = {"targets": [{"type": "binary", "name": "Libmpv-GPL", "path": "Libmpv.xcframework"}]}
            with patch.object(benchmark, "capture", return_value=json.dumps(manifest)) as capture:
                self.assertEqual(benchmark.selected_framework(root, developer), framework.resolve())
            self.assertEqual(capture.call_args.kwargs["env"]["DEVELOPER_DIR"], str(developer))

    def test_report_publication_never_replaces_a_previous_run(self):
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / "run.json"
            benchmark.write_json(report, {"value": 1})
            with self.assertRaises(FileExistsError):
                benchmark.write_json(report, {"value": 2})
            self.assertEqual(json.loads(report.read_text()), {"value": 1})
            self.assertEqual(list(report.parent.glob(".benchmark-*")), [])

    def test_nonfinite_report_is_not_published(self):
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / "run.json"
            with self.assertRaises(ValueError):
                benchmark.write_json(report, {"time": float("nan")})
            self.assertFalse(report.exists())

    def test_versioned_framework_counts_the_actual_binary_once(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "Libmpv.xcframework"
            framework = root / "macos-arm64/Libmpv.framework"
            binary = framework / "Versions/A/Libmpv"
            binary.parent.mkdir(parents=True)
            binary.write_bytes(b"native binary")
            (framework / "Libmpv").symlink_to("Versions/A/Libmpv")
            (root / "Info.plist").write_bytes(
                plistlib.dumps(
                    {
                        "AvailableLibraries": [
                            {
                                "LibraryIdentifier": "macos-arm64",
                                "LibraryPath": "Libmpv.framework",
                                "SupportedPlatform": "macos",
                                "SupportedArchitectures": ["arm64"],
                            }
                        ]
                    }
                )
            )
            workloads, identities = benchmark.binary_workloads(root)
            self.assertEqual(len(workloads), 1)
            self.assertEqual(workloads[0]["metrics"]["binaryBytes"]["samples"], [13])
            self.assertEqual(identities[0]["path"], str(binary.resolve()))

    def test_framework_cannot_measure_a_path_outside_its_bundle(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "Libmpv.xcframework"
            root.mkdir()
            (root.parent / "unrelated").write_bytes(b"unrelated")
            (root / "Info.plist").write_bytes(
                plistlib.dumps(
                    {
                        "AvailableLibraries": [
                            {
                                "LibraryIdentifier": "macos-arm64",
                                "LibraryPath": "Libmpv.framework",
                                "BinaryPath": "../../unrelated",
                                "SupportedPlatform": "macos",
                                "SupportedArchitectures": ["arm64"],
                            }
                        ]
                    }
                )
            )
            with self.assertRaisesRegex(ValueError, "Invalid framework binary path"):
                benchmark.binary_workloads(root)

    def test_labels_and_intervals_reject_ambiguous_or_unbounded_input(self):
        for value in ("../outside", "", "label/child", "$(command)"):
            with self.subTest(label=value), self.assertRaises(argparse.ArgumentTypeError):
                benchmark.label(value)
        for value in ("NaN", "inf", "-1", "61"):
            with self.subTest(seconds=value), self.assertRaises(argparse.ArgumentTypeError):
                benchmark.finite_range(1, 60)(value)


if __name__ == "__main__":
    unittest.main()
