"""Offline guards for diagnostic capture and Time Profiler aggregation."""

import copy
import hashlib
import json
import importlib.util
from pathlib import Path
import tempfile
import subprocess
import sys
import unittest

HERE = Path(__file__).resolve().parents[1] / "Benchmarks"


def load(name):
    spec = importlib.util.spec_from_file_location(name, HERE / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


capture = load("capture_device_profile")
analyze = load("analyze_device_profile")


class ProfileTests(unittest.TestCase):
    def synthetic_trace(self, directory):
        path = Path(directory) / "time-profile.xml"
        path.write_text("""<trace-query-result><node><row>
          <sample-time id="time1">1000000000</sample-time>
          <thread id="thread1" fmt="core (42)"><process id="proc1"><pid>42</pid></process></thread>
          <process ref="proc1"/><core>0</core><thread-state id="state">Running</thread-state><weight id="weight">1000000</weight>
          <backtrace><frame id="leaf" name="leaf" addr="0x1010"><binary id="binary" UUID="A" name="Libmpv" path="/Libmpv" load-addr="0x1000"/></frame>
          <frame id="recursive" name="recursive" addr="0x1020"><binary ref="binary"/></frame><frame ref="recursive"/></backtrace>
        </row><row><sample-time>2000000000</sample-time><thread ref="thread1"/><process ref="proc1"/><core>0</core>
          <thread-state ref="state"/><weight ref="weight"/><backtrace><frame name="0xdead" addr="0xdead"/></backtrace>
        </row><row><sample-time>3000000000</sample-time><thread fmt="other"/><process><pid>999</pid></process><core>0</core>
          <thread-state ref="state"/><weight ref="weight"/><sentinel/>
        </row></node></trace-query-result>""")
        return path

    def test_pid_filter_references_recursive_frames_unknown_binary_and_exact_summary(self):
        with tempfile.TemporaryDirectory() as directory:
            path = self.synthetic_trace(directory)
            records, binaries = analyze.parse(path, 42)
            self.assertEqual(len(records), 2)
            self.assertEqual(set(binaries), {"A"})
            summary, samples, _ = analyze.aggregate(records, 42, {"A": {"0x1010": "real_leaf (in Libmpv) + 12"}})
            expected = {
                "pid": 42,
                "samples": 2,
                "weightedSeconds": 0.002,
                "firstSampleSeconds": 1,
                "lastSampleSeconds": 2,
                "states": {"Running": 2000000},
                "threads": {"core (42)": 2000000},
                "inclusiveNanoseconds": {"real_leaf": 1000000, "recursive": 1000000, "0xdead": 1000000},
                "leafNanoseconds": {"real_leaf": 1000000, "0xdead": 1000000},
                "leafBinaryNanoseconds": {"Libmpv": 1000000, "unknown": 1000000},
            }
            self.assertEqual({key: summary[key] for key in expected}, expected)
            self.assertEqual(samples[1]["frames"], ["0xdead"])
            with self.assertRaisesRegex(ValueError, "No target process"):
                analyze.parse(path, 7)

    def test_invalid_xml_references_schema_and_weights_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = self.synthetic_trace(directory)
            original = path.read_text()
            for modified in (
                original.replace('ref="recursive"', 'ref="missing"'),
                original.replace('id="weight">1000000', 'id="weight">-1'),
                original.replace("<core>0</core>", ""),
            ):
                path.write_text(modified)
                with self.subTest(xml=modified), self.assertRaises(ValueError):
                    analyze.parse(path, 42)

    def test_analysis_cli_writes_new_output_and_never_overwrites_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            trace = self.synthetic_trace(root)
            mapping = {
                "traceSHA256": hashlib.sha256(trace.read_bytes()).hexdigest(),
                "validation": {"A": {"uuid": "A", "name": "Libmpv", "loadAddress": "0x1000"}},
                "symbols": {"A": {"0x1010": "leaf", "0x1020": "recursive"}},
            }
            map_path = root / "supplied-symbol-map.json"
            map_path.write_text(json.dumps(mapping))
            command = [
                sys.executable,
                str(HERE / "analyze_device_profile.py"),
                str(root),
                "--pid",
                "42",
                "--symbol-map",
                str(map_path),
            ]
            for trace_hash in (None, "different-trace"):
                stale = dict(mapping, traceSHA256=trace_hash)
                map_path.write_text(json.dumps(stale))
                rejected = subprocess.run(command, capture_output=True, text=True, cwd=root)
                self.assertNotEqual(rejected.returncode, 0)
                self.assertIn("must match the trace SHA256", rejected.stderr)
            map_path.write_text(json.dumps(mapping))
            completed = subprocess.run(command, capture_output=True, text=True, cwd=root)
            self.assertEqual(completed.returncode, 0, completed.stderr)
            output = root / "analysis/stack-summary.json"
            first = output.read_bytes()
            again = subprocess.run(command, capture_output=True, text=True, cwd=root)
            self.assertNotEqual(again.returncode, 0)
            self.assertEqual(output.read_bytes(), first)
            self.assertEqual(json.loads(map_path.read_text()), mapping)
            self.assertEqual(hashlib.sha256(trace.read_bytes()).hexdigest(), mapping["traceSHA256"])
            help_result = subprocess.run(
                [sys.executable, str(HERE / "capture_device_profile.py"), "--help"],
                capture_output=True,
                text=True,
                cwd=root,
            )
            self.assertEqual(help_result.returncode, 0, help_result.stderr)

    def test_symbol_maps_require_correct_uuid_name_and_load_address(self):
        binaries = {"A": {"name": "Libmpv", "load-addr": "0x1000"}}
        mapping = {
            "symbols": {"A": {"0x1000": "function"}},
            "validation": {"A": {"uuid": "A", "name": "Libmpv", "loadAddress": "0x1000"}},
        }
        analyze.validate_symbol_map(mapping, binaries)
        for field in ("uuid", "name", "loadAddress"):
            for value in ("wrong", None):
                broken = copy.deepcopy(mapping)
                if value is None:
                    del broken["validation"]["A"][field]
                else:
                    broken["validation"]["A"][field] = value
                with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                    analyze.validate_symbol_map(broken, binaries)

    def test_recursive_frames_count_once_inclusive_and_only_first_leaf(self):
        frames = [
            {"name": name, "addr": None, "uuid": None, "binary": "unknown"}
            for name in ("leaf", "recursive", "recursive")
        ]
        records = [{"nanoseconds": 1000, "timeSeconds": 1, "thread": "core", "state": "Running", "frames": frames}]
        summary, _, _ = analyze.aggregate(records, 1, {})
        self.assertEqual(summary["inclusiveNanoseconds"], {"leaf": 1000, "recursive": 1000})
        self.assertEqual(summary["leafNanoseconds"], {"leaf": 1000})
        records[0]["state"] = "Waiting"
        with self.assertRaisesRegex(ValueError, "Running"):
            analyze.aggregate(records, 1, {})

    def test_report_polling_has_independent_arrival_bound_after_steady_interval(self):
        now = [10.0]

        def sleep(seconds):
            now[0] += seconds

        def clock():
            return now[0]

        copies = []

        def copy():
            copies.append(clock())
            return clock() >= 46

        evidence = capture.retrieve_completed_report(copy, 45, 60, clock=clock, sleep=sleep)
        self.assertEqual(copies, [45, 46])
        self.assertEqual(evidence["rawCopyCompleteMonotonic"], 46)
        self.assertEqual(evidence["rawCopyRequestMonotonic"], [45, 46])
        # Recorder serialization can finish much later without changing arrival.
        sleep(100)
        self.assertEqual(evidence["rawCopyCompleteMonotonic"], 46)
        with self.assertRaisesRegex(ValueError, "No completion"):
            capture.retrieve_completed_report(lambda: False, clock(), clock() + 2, clock=clock, sleep=sleep)

    def test_monotonic_bounds_reject_ambiguous_start_and_end_containment(self):
        raw = {
            "phases": {"all": {"wallSeconds": 55}},
            "timeline": [{"phase": "steady", "elapsedSeconds": 7}, {"phase": "steady", "elapsedSeconds": 35}],
        }
        timing = {
            "launchRequestStartMonotonic": 100,
            "rawCopyCompleteMonotonic": 157,
            "traceInvocationMonotonic": 110,
            "traceReturnMonotonic": 133,
        }
        proof = capture.validate_steady_window(raw, timing)
        self.assertTrue(proof["contained"])
        self.assertEqual(proof["appBeginUncertaintySeconds"], 2)
        for field, value in (("rawCopyCompleteMonotonic", 160), ("traceReturnMonotonic", 136)):
            changed = dict(timing, **{field: value})
            self.assertFalse(capture.validate_steady_window(raw, changed)["contained"])
        with self.assertRaises(ValueError):
            capture.validate_steady_window(raw, dict(timing, rawCopyCompleteMonotonic=150))

    def test_recorder_dates_exclude_save_time_with_bounded_host_clock_mapping(self):
        from datetime import datetime, timezone

        def stamp(value):
            return datetime.fromtimestamp(value, timezone.utc).isoformat(timespec="milliseconds")

        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "toc.xml"
            path.write_text(
                "<trace-toc><run number='1'><info><summary><start-date>" + stamp(1111) + "</start-date>"
                "<end-date>" + stamp(1131) + "</end-date><duration>20</duration></summary></info></run></trace-toc>"
            )
            anchor = {"wallMinusMonotonicMinimum": 999.99999, "wallMinusMonotonicMaximum": 1000.00001}
            timing = {
                "traceInvocationMonotonic": 110,
                "traceReturnMonotonic": 150,
                "hostClockBeforeTrace": anchor,
                "hostClockAfterTrace": dict(anchor),
            }
            bounds = capture.recorder_time_bounds(path, timing)
            self.assertAlmostEqual(bounds["traceStartEarliestMonotonic"], 110.99899)
            self.assertAlmostEqual(bounds["traceEndLatestMonotonic"], 131.00101)
            timing["hostClockAfterTrace"]["wallMinusMonotonicMaximum"] += 1
            with self.assertRaisesRegex(ValueError, "offset changed"):
                capture.recorder_time_bounds(path, timing)

    def report(self, cpu):
        return {
            "label": "reference",
            "source": {"sourceSHA256": "source"},
            "runtime": {"appSHA256": "app"},
            "environment": {"comparisonKey": {"protocol": "protocol4", "device": "iPad"}},
            "workloads": [
                {
                    "parameters": {
                        "player": "mpv",
                        "backend": "sampleBuffer",
                        "sampleSeconds": 30,
                        "warmupSeconds": 5,
                        "mediaSHA256": "media",
                        "options": [],
                    },
                    "observations": [{"configuration": {"resolvedBackend": "sampleBuffer"}}],
                    "metrics": {"steadyCpuSecondsPerWallSecond": {"samples": cpu}},
                }
            ],
        }

    def test_overhead_retains_raw_variation_and_rejects_protocol_or_source_mixing(self):
        before, after = self.report([0.04, 0.041, 0.042]), self.report([0.045])
        after["environment"]["comparisonKey"]["instrumentation"] = {"template": "Time Profiler"}
        value = capture.estimate_overhead(after, before)
        self.assertAlmostEqual(value["deltaPercentagePointsOfOneCore"], 0.4)
        self.assertEqual(value["referenceCPUSamplesPerCore"], [0.04, 0.041, 0.042])
        for section, field in (("source", "sourceSHA256"), ("runtime", "appSHA256")):
            wrong = copy.deepcopy(before)
            wrong[section][field] = "different"
            with self.assertRaises(ValueError):
                capture.estimate_overhead(after, wrong)
        wrong = copy.deepcopy(before)
        wrong["environment"]["comparisonKey"]["protocol"] = "protocol3"
        with self.assertRaises(ValueError):
            capture.estimate_overhead(after, wrong)
        wrong = copy.deepcopy(before)
        wrong["environment"]["comparisonKey"]["instrumentation"] = {"template": "Time Profiler"}
        with self.assertRaisesRegex(ValueError, "itself traced"):
            capture.estimate_overhead(after, wrong)

    def test_requested_backend_difference_is_explicit_context_and_options_cannot_be_normalized(self):
        before, after = self.report([0.04]), self.report([0.045])
        before["workloads"][0]["parameters"]["backend"] = "default"
        value = capture.estimate_overhead(after, before)
        self.assertFalse(value["strictlyMatchingRequestedConfiguration"])
        self.assertEqual(value["requestedConfigurationDifferences"], {"backend": ["default", "sampleBuffer"]})
        before["workloads"][0]["parameters"]["options"] = ["something=yes"]
        with self.assertRaises(ValueError):
            capture.estimate_overhead(after, before)


if __name__ == "__main__":
    unittest.main()
