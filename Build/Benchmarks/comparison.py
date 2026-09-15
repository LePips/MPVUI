"""Validate and compare local benchmark reports without statistical claims."""

from __future__ import annotations

import copy
import json
import math
from typing import Any


_DIRECTIONS = {"lower", "higher", "neutral"}


def _finite_number(value: Any) -> bool:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return False
    try:
        return math.isfinite(value)
    except OverflowError:
        return False


def _identity(value: Any, path: str) -> str:
    """Compare JSON values consistently, including objects with reordered keys."""
    try:
        return json.dumps(value, sort_keys=True, allow_nan=False, separators=(",", ":"))
    except (TypeError, ValueError, OverflowError) as error:
        raise ValueError(f"{path} must contain valid JSON values: {error}") from error


def _validate_report(report: dict, name: str) -> dict[str, dict]:
    if not isinstance(report, dict):
        raise ValueError(f"{name} must be a report object")
    if not isinstance(report.get("label"), str):
        raise ValueError(f"{name}.label must be a string")
    for field in ("environment", "configuration", "source"):
        if not isinstance(report.get(field), dict):
            raise ValueError(f"{name}.{field} must be an object")
    if "comparisonKey" not in report["environment"]:
        raise ValueError(f"{name}.environment.comparisonKey is required")
    _identity(report["environment"]["comparisonKey"], f"{name}.environment.comparisonKey")
    workloads = report.get("workloads")
    if not isinstance(workloads, list) or not workloads:
        raise ValueError(f"{name}.workloads must be a nonempty array")
    indexed = {}
    for index, workload in enumerate(workloads):
        path = f"{name}.workloads[{index}]"
        if not isinstance(workload, dict):
            raise ValueError(f"{path} must be an object")
        workload_id = workload.get("id")
        if not isinstance(workload_id, str) or not workload_id:
            raise ValueError(f"{path}.id must be a nonempty string")
        if workload_id in indexed:
            raise ValueError(f"{name} has duplicate workload id {workload_id!r}")
        path = f"{name}.workloads[{workload_id!r}]"
        if not isinstance(workload.get("parameters"), dict):
            raise ValueError(f"{path}.parameters must be an object")
        _identity(workload["parameters"], f"{path}.parameters")
        metrics = workload.get("metrics")
        if not isinstance(metrics, dict) or not metrics:
            raise ValueError(f"{path}.metrics must be a nonempty object")
        for metric_name, metric in metrics.items():
            if not isinstance(metric_name, str) or not metric_name:
                raise ValueError(f"{path}.metrics keys must be nonempty strings")
            metric_path = f"{path}.metrics[{metric_name!r}]"
            if not isinstance(metric, dict):
                raise ValueError(f"{metric_path} must be an object")
            if not isinstance(metric.get("unit"), str) or not metric["unit"]:
                raise ValueError(f"{metric_path}.unit must be a nonempty string")
            if not isinstance(metric.get("direction"), str) or metric["direction"] not in _DIRECTIONS:
                raise ValueError(f"{metric_path}.direction must be lower, higher, or neutral")
            samples = metric.get("samples")
            if not isinstance(samples, list) or not samples:
                raise ValueError(f"{metric_path}.samples must be a nonempty array")
            for sample_index, sample in enumerate(samples):
                if not _finite_number(sample):
                    raise ValueError(f"{metric_path}.samples[{sample_index}] must be a finite number")
        indexed[workload_id] = workload
    return indexed


def _summary(samples: list[int | float]) -> dict:
    ordered = sorted(samples)
    middle = len(ordered) // 2
    if len(ordered) % 2:
        median = ordered[middle]
    else:
        left, right = ordered[middle - 1], ordered[middle]
        total = left + right
        # Avoid overflow for huge samples without rounding tiny samples to zero.
        median = total / 2 if _finite_number(total) else left / 2 + right / 2
    return {
        "median": median,
        "min": ordered[0],
        "max": ordered[-1],
        "sampleCount": len(ordered),
    }


def _metadata(report: dict) -> dict:
    return copy.deepcopy({
        key: report[key]
        for key in ("label", "source", "environment", "configuration", "createdAt", "runtime", "native")
        if key in report
    })


def compare_reports(
    baseline: dict,
    candidate: dict,
    *,
    allow_mismatch: bool = False,
    regression_percent: float | None = None,
) -> dict:
    """Compare metric medians; percent change is (candidate-baseline)/|baseline|.

    Report identity comes from environment.comparisonKey, workload parameters,
    and metric definitions. Source, labels, timestamps, and sampling counts may
    differ. An explicit mismatch override retains visible mismatch details and
    disables threshold checking. Invalid data is never overridden.

    A threshold marks relative degradation strictly greater than the supplied
    percentage. It is a practical guard, not a statistical significance test.
    """
    if regression_percent is not None and (
        not _finite_number(regression_percent) or regression_percent < 0
    ):
        raise ValueError("regression_percent must be a finite, nonnegative number")
    before = _validate_report(baseline, "baseline")
    after = _validate_report(candidate, "candidate")
    mismatches = []
    if _identity(baseline["environment"]["comparisonKey"], "baseline.environment.comparisonKey") != _identity(
        candidate["environment"]["comparisonKey"], "candidate.environment.comparisonKey"
    ):
        mismatches.append("environment.comparisonKey differs")
    for workload_id in sorted(before.keys() - after.keys()):
        mismatches.append(f"workload {workload_id!r} is missing from candidate")
    for workload_id in sorted(after.keys() - before.keys()):
        mismatches.append(f"workload {workload_id!r} is missing from baseline")
    common_ids = sorted(before.keys() & after.keys())
    metric_definition_matches = {}
    for workload_id in common_ids:
        left, right = before[workload_id], after[workload_id]
        prefix = f"workload {workload_id!r}"
        if _identity(left["parameters"], prefix) != _identity(right["parameters"], prefix):
            mismatches.append(f"{prefix} parameters differ")
        left_metrics, right_metrics = left["metrics"], right["metrics"]
        for metric in sorted(left_metrics.keys() - right_metrics.keys()):
            mismatches.append(f"{prefix} metric {metric!r} is missing from candidate")
        for metric in sorted(right_metrics.keys() - left_metrics.keys()):
            mismatches.append(f"{prefix} metric {metric!r} is missing from baseline")
        for metric in sorted(left_metrics.keys() & right_metrics.keys()):
            matches = True
            for field in ("unit", "direction"):
                if left_metrics[metric][field] != right_metrics[metric][field]:
                    mismatches.append(f"{prefix} metric {metric!r} {field} differs")
                    matches = False
            metric_definition_matches[workload_id, metric] = matches
    if mismatches and not allow_mismatch:
        raise ValueError("Reports are not comparable:\n- " + "\n- ".join(mismatches))

    comparable = not mismatches
    result = {
        "baseline": _metadata(baseline),
        "candidate": _metadata(candidate),
        "comparable": comparable,
        "nonComparable": not comparable,
        "mismatches": mismatches,
        "percentConvention": "100 * (candidate median - baseline median) / abs(baseline median)",
        "regressionPercent": regression_percent,
        "thresholdsEvaluated": comparable and regression_percent is not None,
        "hasRegressions": False,
        "workloads": [],
    }
    for workload_id in common_ids:
        left, right = before[workload_id], after[workload_id]
        workload = {
            "id": workload_id,
            "parameters": copy.deepcopy(left["parameters"]),
            "candidateParameters": copy.deepcopy(right["parameters"]),
            "metrics": {},
        }
        for metric_name in sorted(left["metrics"].keys() & right["metrics"].keys()):
            left_metric, right_metric = left["metrics"][metric_name], right["metrics"][metric_name]
            left_summary, right_summary = _summary(left_metric["samples"]), _summary(right_metric["samples"])
            base, current = left_summary["median"], right_summary["median"]
            definitions_match = metric_definition_matches[workload_id, metric_name]
            delta = current - base if definitions_match else None
            if delta is not None and not _finite_number(delta):
                raise ValueError(f"workload {workload_id!r} metric {metric_name!r} delta overflows")
            percent = None
            if delta is not None:
                if base == 0:
                    percent = 0.0 if current == 0 else None
                else:
                    percent = (delta / abs(base)) * 100
                    if not _finite_number(percent):
                        raise ValueError(f"workload {workload_id!r} metric {metric_name!r} percent change overflows")
            direction = left_metric["direction"]
            regression = None
            if result["thresholdsEvaluated"] and direction != "neutral" and base != 0 and percent is not None:
                degradation = percent if direction == "lower" else -percent
                regression = degradation > regression_percent
                result["hasRegressions"] |= regression
            workload["metrics"][metric_name] = {
                "unit": left_metric["unit"],
                "candidateUnit": right_metric["unit"],
                "direction": direction,
                "candidateDirection": right_metric["direction"],
                "definitionsMatch": definitions_match,
                "comparable": comparable,
                "baseline": left_summary,
                "candidate": right_summary,
                "delta": delta,
                "percentChange": percent,
                "regression": regression,
            }
        result["workloads"].append(workload)
    return result


def _escape(value: Any) -> str:
    return str(value).replace("\\", "\\\\").replace("|", "\\|").replace("\n", " ").replace("\r", " ")


def _format(value: int | float | None, *, signed: bool = False) -> str:
    if value is None:
        return "n/a"
    return format(value, "+.6g" if signed else ".6g")


def render_markdown(comparison: dict) -> str:
    """Render comparison settings and measurements as compact tables."""
    threshold = ("disabled" if comparison["regressionPercent"] is None
                 else f"> {_format(comparison['regressionPercent'])}% degradation")
    lines = [
        "| Baseline | Candidate | Status | Regression threshold |",
        "| --- | --- | --- | --- |",
        f"| {_escape(comparison['baseline']['label'])} | {_escape(comparison['candidate']['label'])} | "
        f"{'Non-comparable' if comparison['nonComparable'] else 'Comparable'} | "
        f"{'disabled (mismatch)' if comparison['nonComparable'] else threshold} |",
        "",
    ]
    if comparison["nonComparable"]:
        lines += ["| Mismatch |", "| --- |"]
        lines += [f"| {_escape(mismatch)} |" for mismatch in comparison["mismatches"]]
        lines.append("")
    lines += [
        "| Workload / metric | Unit | Better | Baseline median [min, max] | Candidate median [min, max] | Samples B / C | Δ (C − B) | Δ / ∣B∣ (%) | Threshold |",
        "| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | --- |",
    ]
    for workload in comparison["workloads"]:
        for name, metric in workload["metrics"].items():
            left, right = metric["baseline"], metric["candidate"]
            unit = _escape(metric["unit"])
            direction = _escape(metric["direction"])
            if not metric["definitionsMatch"]:
                unit += f" → {_escape(metric['candidateUnit'])}"
                direction += f" → {_escape(metric['candidateDirection'])}"
            status = "exceeded" if metric["regression"] else "within" if metric["regression"] is False else "not checked"
            left_text = f"{_format(left['median'])} [{_format(left['min'])}, {_format(left['max'])}]"
            right_text = f"{_format(right['median'])} [{_format(right['min'])}, {_format(right['max'])}]"
            percent = "n/a" if metric["percentChange"] is None else f"{metric['percentChange']:+.2f}%"
            lines.append(
                f"| {_escape(workload['id'])} / {_escape(name)} | {unit} | {direction} | "
                f"{left_text} | {right_text} | {left['sampleCount']} / {right['sampleCount']} | "
                f"{_format(metric['delta'], signed=True)} | {percent} | {status} |"
            )
    return "\n".join(lines) + "\n"
