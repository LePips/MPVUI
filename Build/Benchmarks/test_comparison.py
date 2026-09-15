"""Contract tests for report validation, comparison, and threshold behavior."""

import copy
import json
import unittest

from comparison import compare_reports, render_markdown


def report(samples=None, *, label="baseline", direction="lower"):
    return {
        "label": label,
        "createdAt": "2026-01-01T00:00:00Z",
        "environment": {"comparisonKey": {"host": "test-host", "architecture": "arm64"}},
        "configuration": {"repetitions": 3},
        "source": {"revision": "a"},
        "workloads": [{
            "id": "decode",
            "parameters": {"frames": 100, "mediaSHA256": "abc"},
            "metrics": {"elapsed": {"unit": "ms", "direction": direction,
                                     "samples": [8, 10, 12] if samples is None else samples}},
        }],
    }


def metric(comparison):
    return comparison["workloads"][0]["metrics"]["elapsed"]


class ComparisonTests(unittest.TestCase):
    def test_median_range_delta_and_sample_count(self):
        before = report([2, 100, 8, 4])
        after = report([7, 11, 12], label="candidate")
        comparison = compare_reports(before, after)
        result = metric(comparison)
        self.assertEqual(result["baseline"], {"median": 6, "min": 2, "max": 100, "sampleCount": 4})
        self.assertEqual(result["candidate"]["median"], 11)
        self.assertEqual(result["delta"], 5)
        self.assertAlmostEqual(result["percentChange"], 100 * 5 / 6)
        self.assertTrue(comparison["comparable"])
        self.assertFalse(comparison["hasRegressions"])
        self.assertIsNone(result["regression"])
        self.assertFalse(comparison["thresholdsEvaluated"])

    def test_metadata_and_sample_counts_may_differ(self):
        before, after = report(), report([1, 2, 3, 4])
        after.update(label="other", createdAt="later", source={"revision": "b"})
        after["configuration"]["repetitions"] = 4
        after["environment"]["recordedAt"] = "later"
        comparison = compare_reports(before, after)
        self.assertTrue(comparison["comparable"])
        self.assertEqual(metric(comparison)["candidate"]["sampleCount"], 4)

    def test_comparison_does_not_modify_or_alias_inputs(self):
        before, after = report(), report()
        original = copy.deepcopy(before)
        comparison = compare_reports(before, after)
        comparison["baseline"]["environment"]["comparisonKey"]["host"] = "changed"
        comparison["workloads"][0]["parameters"]["frames"] = 999
        self.assertEqual(before, original)

    def test_runtime_and_native_build_details_are_preserved_but_may_differ(self):
        before, after = report(), report()
        before["runtime"] = {"librarySHA256": "before-library", "libraryKind": "dynamic-library"}
        after["runtime"] = {"librarySHA256": "after-library", "libraryKind": "dynamic-library"}
        before["native"] = {"patchFingerprint": "before-patch", "compiler": {"version": "clang"}}
        after["native"] = {"patchFingerprint": "after-patch", "compiler": {"version": "clang"}}
        comparison = compare_reports(before, after)
        self.assertTrue(comparison["comparable"])
        for key in ("runtime", "native"):
            self.assertEqual(comparison["baseline"][key], before[key])
            self.assertEqual(comparison["candidate"][key], after[key])
        comparison["baseline"]["runtime"]["librarySHA256"] = "changed"
        comparison["candidate"]["native"]["compiler"]["version"] = "changed"
        self.assertEqual(before["runtime"]["librarySHA256"], "before-library")
        self.assertEqual(after["native"]["compiler"]["version"], "clang")

    def test_reordered_workloads_metrics_and_parameters_are_comparable(self):
        before, after = report(), report()
        second = copy.deepcopy(before["workloads"][0])
        second["id"] = "encode"
        before["workloads"].append(second)
        after["workloads"].insert(0, copy.deepcopy(second))
        after["workloads"][1]["parameters"] = {"mediaSHA256": "abc", "frames": 100}
        after["environment"]["comparisonKey"] = {"architecture": "arm64", "host": "test-host"}
        self.assertTrue(compare_reports(before, after)["comparable"])

    def test_identity_and_parameter_mismatches(self):
        before, after = report(), report()
        after["environment"]["comparisonKey"]["host"] = "another-host"
        after["workloads"][0]["parameters"]["frames"] = 200
        with self.assertRaisesRegex(ValueError, "comparisonKey differs") as raised:
            compare_reports(before, after)
        self.assertIn("parameters differ", str(raised.exception))

    def test_missing_workload_and_metric_are_explicit(self):
        before, after = report(), report()
        second = copy.deepcopy(before["workloads"][0])
        second["id"] = "encode"
        before["workloads"].append(second)
        after["workloads"][0]["metrics"]["other"] = after["workloads"][0]["metrics"].pop("elapsed")
        with self.assertRaises(ValueError) as raised:
            compare_reports(before, after)
        message = str(raised.exception)
        self.assertIn("workload 'encode' is missing from candidate", message)
        self.assertIn("metric 'elapsed' is missing from candidate", message)
        self.assertIn("metric 'other' is missing from baseline", message)

    def test_mismatch_override_is_marked_and_does_not_gate(self):
        before, after = report([10]), report([20])
        after["environment"]["comparisonKey"]["host"] = "another-host"
        comparison = compare_reports(before, after, allow_mismatch=True, regression_percent=5)
        self.assertFalse(comparison["comparable"])
        self.assertTrue(comparison["nonComparable"])
        self.assertEqual(comparison["mismatches"], ["environment.comparisonKey differs"])
        self.assertFalse(comparison["thresholdsEvaluated"])
        self.assertFalse(comparison["hasRegressions"])
        self.assertFalse(metric(comparison)["comparable"])
        self.assertIsNone(metric(comparison)["regression"])
        markdown = render_markdown(comparison)
        self.assertIn("Non-comparable", markdown)
        self.assertIn("comparisonKey differs", markdown)
        self.assertIn("disabled (mismatch)", markdown)

    def test_units_and_direction_must_agree(self):
        for field, value in (("unit", "s"), ("direction", "higher")):
            with self.subTest(field=field):
                before, after = report(), report()
                after["workloads"][0]["metrics"]["elapsed"][field] = value
                with self.assertRaisesRegex(ValueError, field + " differs"):
                    compare_reports(before, after)
                comparison = compare_reports(before, after, allow_mismatch=True)
                self.assertFalse(metric(comparison)["definitionsMatch"])
                self.assertIsNone(metric(comparison)["percentChange"])
                self.assertIsNone(metric(comparison)["delta"])

    def test_zero_baseline_percent_and_threshold(self):
        for candidate, expected in (([0], 0), ([1], None)):
            with self.subTest(candidate=candidate):
                comparison = compare_reports(report([0]), report(candidate), regression_percent=0)
                self.assertEqual(metric(comparison)["percentChange"], expected)
                self.assertIsNone(metric(comparison)["regression"])
                self.assertFalse(comparison["hasRegressions"])

    def test_threshold_direction_and_strict_boundary(self):
        for direction, value, expected in (
            ("lower", 111, True), ("lower", 110, False), ("lower", 89, False),
            ("higher", 89, True), ("higher", 90, False), ("higher", 111, False),
            ("neutral", 200, None),
        ):
            with self.subTest(direction=direction, value=value):
                comparison = compare_reports(
                    report([100], direction=direction), report([value], direction=direction),
                    regression_percent=10,
                )
                self.assertIs(metric(comparison)["regression"], expected)
                self.assertEqual(comparison["hasRegressions"], expected is True)

    def test_threshold_uses_median_not_outlier(self):
        comparison = compare_reports(report([100, 100, 100]), report([100, 100, 9000]), regression_percent=1)
        self.assertFalse(comparison["hasRegressions"])

    def test_signed_baseline_preserves_change_direction(self):
        comparison = compare_reports(report([-10]), report([-5]), regression_percent=10)
        self.assertEqual(metric(comparison)["percentChange"], 50)
        self.assertTrue(comparison["hasRegressions"])

    def test_invalid_samples_are_rejected_even_with_override(self):
        for samples in ([], [float("nan")], [float("inf")], [-float("inf")], [True], ["1"], [None], [10 ** 1000], "123"):
            with self.subTest(samples=str(samples)[:50]):
                with self.assertRaisesRegex(ValueError, "samples"):
                    compare_reports(report(), report(samples), allow_mismatch=True)

    def test_missing_samples_is_rejected(self):
        invalid = report()
        del invalid["workloads"][0]["metrics"]["elapsed"]["samples"]
        with self.assertRaisesRegex(ValueError, "samples must be a nonempty array"):
            compare_reports(report(), invalid)

    def test_invalid_report_structure_is_rejected(self):
        mutations = (
            lambda value: value.pop("workloads"),
            lambda value: value.update(label=None),
            lambda value: value.update(configuration=[]),
            lambda value: value["environment"].pop("comparisonKey"),
            lambda value: value["workloads"].append(copy.deepcopy(value["workloads"][0])),
            lambda value: value["workloads"][0].update(metrics={}),
            lambda value: value["workloads"][0]["metrics"]["elapsed"].update(direction=[]),
            lambda value: value["workloads"][0]["parameters"].update(frames=float("nan")),
        )
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                invalid = report()
                mutation(invalid)
                with self.assertRaises(ValueError):
                    compare_reports(report(), invalid)

    def test_invalid_thresholds_are_rejected(self):
        for threshold in (-1, float("nan"), float("inf"), True, "5"):
            with self.subTest(threshold=threshold):
                with self.assertRaisesRegex(ValueError, "regression_percent"):
                    compare_reports(report(), report(), regression_percent=threshold)

    def test_large_finite_even_median_and_overflow_handling(self):
        comparison = compare_reports(report([1e308, 1e308]), report([1e308, 1e308]))
        self.assertEqual(metric(comparison)["baseline"]["median"], 1e308)
        json.dumps(comparison, allow_nan=False)
        with self.assertRaisesRegex(ValueError, "delta overflows"):
            compare_reports(report([-1e308]), report([1e308]))
        with self.assertRaisesRegex(ValueError, "percent change overflows"):
            compare_reports(report([1e-308]), report([1e308]))

    def test_tiny_finite_even_median_does_not_underflow(self):
        tiny = float.fromhex("0x0.0000000000001p-1022")
        comparison = compare_reports(report([tiny, tiny]), report([tiny, tiny]))
        self.assertEqual(metric(comparison)["baseline"]["median"], tiny)

    def test_markdown_contains_ranges_counts_signs_and_escaped_names(self):
        before, after = report([10]), report([12, 20])
        before["workloads"][0]["id"] = after["workloads"][0]["id"] = "decode|special\nline"
        markdown = render_markdown(compare_reports(before, after, regression_percent=10))
        self.assertIn("decode\\|special line", markdown)
        self.assertIn("16 [12, 20]", markdown)
        self.assertIn("1 / 2", markdown)
        self.assertIn("+60.00%", markdown)
        self.assertIn("exceeded", markdown)
        self.assertIn("> 10% degradation", markdown)


if __name__ == "__main__":
    unittest.main()
