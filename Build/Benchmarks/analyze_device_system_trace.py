"""Offline PID-scoped xctrace scheduler export reader (no device operations)."""

from __future__ import annotations
from collections import Counter, defaultdict
from pathlib import Path
import argparse
import bisect
import hashlib
import json
import xml.etree.ElementTree as ET

SCALARS = {
    "start-time",
    "event-time",
    "duration",
    "duration-on-core",
    "duration-waiting",
    "pid",
    "tid",
    "core",
    "sched-priority",
    "thread-state",
    "sched-event",
    "boolean",
    "uint32",
    "weight",
    "narrative",
}
INTEGERS = {
    "start-time",
    "event-time",
    "duration",
    "duration-on-core",
    "duration-waiting",
    "pid",
    "tid",
    "core",
    "sched-priority",
    "uint32",
    "weight",
}


def read_rows(path: Path, expected_schema: str, pid: int):
    """Resolve xctrace shared values while streaming; retain only target PID rows."""
    refs = {}
    columns = None
    stack = []
    rows = []
    total = 0

    def decode(e):
        if e.tag not in SCALARS | {"thread", "process", "sentinel"}:
            for child in e:
                decode(child)
            return None
        ref = e.get("ref")
        if ref:
            if ref not in refs:
                raise ValueError(f"Missing/forward xctrace reference {ref} in {path}")
            tag, value = refs[ref]
            if tag != e.tag:
                raise ValueError(f"Reference tag mismatch: {e.tag} != {tag}")
            return value
        children = {child.tag: decode(child) for child in e}
        if e.tag == "sentinel":
            value = None
        elif e.tag == "process":
            value = {"pid": children.get("pid"), "name": e.get("fmt")}
        elif e.tag == "thread":
            process = children.get("process")
            value = {"tid": children.get("tid"), "pid": process.get("pid") if process else None, "name": e.get("fmt")}
        elif e.tag in INTEGERS:
            value = int(e.text) if e.text else None
        elif e.tag == "narrative":
            value = e.get("fmt")
        else:
            value = e.text or e.get("fmt")
        if e.get("id"):
            if e.get("id") in refs:
                raise ValueError(f"Duplicate xctrace id {e.get('id')}")
            refs[e.get("id")] = (e.tag, value)
        return value

    for action, e in ET.iterparse(path, events=("start", "end")):
        if action == "start":
            stack.append(e)
            continue
        if e.tag == "schema":
            if e.get("name") != expected_schema:
                raise ValueError(f"Unexpected schema {e.get('name')}")
            columns = [col.findtext("mnemonic") for col in e.findall("col")]
        elif e.tag == "row":
            if columns is None or len(e) != len(columns):
                raise ValueError("Missing/unexpected column definition")
            values = [decode(child) for child in e]
            row = dict(zip(columns, values))
            total += 1
            process = row.get("process")
            if process and process.get("pid") == pid:
                thread = row.get("thread")
                if not thread or thread.get("pid") != pid or thread.get("tid") is None:
                    raise ValueError("Target process/thread identity mismatch")
                rows.append(row)
            if len(stack) > 1:
                stack[-2].remove(e)
            e.clear()
        stack.pop()
    if not rows:
        raise ValueError(f"No PID {pid} rows in {path}")
    return {
        "schema": expected_schema,
        "columns": columns,
        "exportedRows": total,
        "pid": pid,
        "targetRows": len(rows),
    }, rows


def schema_columns(path: Path):
    for _, element in ET.iterparse(path, events=("end",)):
        if element.tag == "schema":
            return {"name": element.get("name"), "columns": [x.findtext("mnemonic") for x in element.findall("col")]}
    raise ValueError("No schema")


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def distribution(values):
    if not values:
        return {"count": 0}
    values = sorted(values)
    return {
        "count": len(values),
        "medianNanoseconds": values[(len(values) - 1) // 2],
        "p95Nanoseconds": values[min(len(values) - 1, int(len(values) * 0.95))],
        "maximumNanoseconds": values[-1],
    }


def aggregate(states, events, pid, start_ns=None, end_ns=None):
    if not states:
        raise ValueError("No intervals")
    groups, event_groups = defaultdict(list), defaultdict(list)
    for row in states:
        if row["process"]["pid"] != pid or row["thread"]["pid"] != pid:
            raise ValueError("Foreign PID in target intervals")
        if row["start"] < 0 or row["duration"] < 0:
            raise ValueError("Negative interval")
        groups[row["thread"]["tid"]].append(row)
    for row in events:
        if row["process"]["pid"] != pid or row["thread"]["pid"] != pid:
            raise ValueError("Foreign PID in target events")
        event_groups[row["thread"]["tid"]].append(row)
    model_start = min(row["start"] for row in states)
    model_end = max(row["start"] + row["duration"] for row in states)
    start = model_start if start_ns is None else start_ns
    end = model_end if end_ns is None else end_ns
    if start < model_start or end > model_end or end <= start:
        raise ValueError("Requested window is empty or outside modeled intervals")
    totals = Counter()
    durations, transitions, raw_events, runnable_states = (Counter() for _ in range(4))
    threads = []
    for tid, sequence in groups.items():
        sequence.sort(key=lambda row: row["start"])
        starts = [row["start"] for row in sequence]
        names = sorted({row["thread"]["name"] for row in sequence})
        times, counts, edge_counts, raw_counts, raw_runnable_states, wakers = (Counter() for _ in range(6))
        wake_latencies = []
        gaps = []
        for index, current in enumerate(sequence):
            left, right = current["start"], current["start"] + current["duration"]
            overlap = max(0, min(end, right) - max(start, left))
            if overlap:
                times[current["state"]] += overlap
            if index == 0:
                if start <= left < end:
                    counts["initialStateIntervals"] += 1
                continue
            previous = sequence[index - 1]
            previous_end = previous["start"] + previous["duration"]
            if left < previous_end:
                raise ValueError(f"Overlapping intervals on tid {tid}; cannot sum durations")
            if left > previous_end:
                if start <= left < end:
                    gaps.append({"fromNanoseconds": previous_end, "toNanoseconds": left})
                continue  # Never infer a wakeup across missing data.
            if not start <= left < end:
                continue
            a, b = previous["state"], current["state"]
            edge_counts[f"{a} -> {b}"] += 1
            if a in ("Blocked", "Idle") and b in ("Runnable", "Running"):
                key = "blockedActivations" if a == "Blocked" else "dispatchParkActivations"
                counts[key] += 1
                counts["offCPUThreadActivations"] += 1
                if b == "Running":
                    counts["activationsWithoutRunnableInterval"] += 1
                    wake_latencies.append(0)
                elif index + 1 < len(sequence):
                    following = sequence[index + 1]
                    if following["state"] == "Running" and following["start"] == right:
                        wake_latencies.append(current["duration"])
                maker = current.get("made-runnable-by-thread")
                if maker:
                    note = current.get("note") or ""
                    kind = "interrupt context" if "interrupt handler" in note else "thread context"
                    wakers[f"{kind}: {maker['name']}"] += 1
                else:
                    counts["activationsWithoutWakerAttribution"] += 1
            if b == "Preempted":
                counts["preemptions"] += 1
            if b == "Running":
                if a in ("Blocked", "Idle", "Runnable", "Preempted"):
                    counts["CPUDispatchesFromOffCPU"] += 1
                elif a == "Interrupted":
                    counts["interruptReturns"] += 1
                elif a == "Running":
                    counts["runningIntervalSplits"] += 1
                else:
                    counts["otherRunningTransitions"] += 1
            if a == "Running" and b == "Runnable":
                counts["runningToRunnableWithoutBlocking"] += 1
        for row in event_groups.get(tid, []):
            time = row["time"]
            if not start <= time < end:
                continue
            raw_counts[row["event"]] += 1
            if row["event"] == "Runnable":
                index = bisect.bisect_right(starts, time) - 1
                state = "uncovered"
                if index >= 0:
                    current = sequence[index]
                    if time < current["start"] + current["duration"]:
                        state = current["state"]
                raw_runnable_states[state] += 1
        counts["missingIntervalGaps"] = len(gaps)
        totals.update(counts)
        durations.update(times)
        transitions.update(edge_counts)
        raw_events.update(raw_counts)
        runnable_states.update(raw_runnable_states)
        threads.append(
            {
                "tid": tid,
                "name": names[0],
                "observedNames": names,
                "stateDurationNanoseconds": dict(times),
                "counts": dict(counts),
                "transitionCounts": dict(edge_counts),
                "contextEventCounts": dict(raw_counts),
                "rawRunnableEventsByModeledState": dict(raw_runnable_states),
                "activationToCPULatency": distribution(wake_latencies),
                "madeRunnableBy": dict(wakers.most_common()),
                "gaps": gaps,
                "offCPUThreadActivationsPerSecond": counts["offCPUThreadActivations"] * 1e9 / (end - start),
            }
        )
    unknown_event_threads = set(event_groups) - set(groups)
    if unknown_event_threads:
        raise ValueError(f"Context events have no state intervals: {unknown_event_threads}")
    # State and raw-event tables should contain the same Running starts even
    # though many starts are interrupt returns or priority changes, not dispatches.
    running_intervals = Counter(
        (row["thread"]["tid"], row["start"])
        for row in states
        if row["state"] == "Running" and start <= row["start"] < end
    )
    running_events = Counter(
        (row["thread"]["tid"], row["time"])
        for row in events
        if row["event"] == "Running" and start <= row["time"] < end
    )
    validation = {
        "runningStartsMatchAcrossTables": running_intervals == running_events,
        "runningStateStarts": sum(running_intervals.values()),
        "rawRunningEvents": sum(running_events.values()),
        "stateStartsMissingRawRunningEvents": sum((running_intervals - running_events).values()),
        "rawRunningEventsMissingStateStarts": sum((running_events - running_intervals).values()),
    }
    return {
        "pid": pid,
        "modelWindowNanoseconds": [model_start, model_end],
        "analysisWindowNanoseconds": [start, end],
        "analysisDurationSeconds": (end - start) / 1e9,
        "threadCount": len(threads),
        "stateDurationNanoseconds": dict(durations),
        "counts": dict(totals),
        "transitionCounts": dict(transitions),
        "contextEventCounts": dict(raw_events),
        "rawRunnableEventsByModeledState": dict(runnable_states),
        "runningTimePercentageOfOneCore": durations["Running"] / (end - start) * 100,
        "validation": validation,
        "threads": sorted(threads, key=lambda item: item["stateDurationNanoseconds"].get("Running", 0), reverse=True),
    }


LIMITATIONS = [
    "This measures scheduler thread-state transitions, not hardware CPU low-power exits or energy wakeups.",
    "Off-CPU thread activations are contiguous Blocked/Idle -> Runnable/Running transitions; no activation is inferred for the first interval or across gaps.",
    "Idle here means an app dispatch worker parked for work; it is reported separately from Blocked.",
    "Raw Runnable events can occur while a thread is Running (a preposted wake); they are not interchangeable with off-CPU activations.",
    "Running entries include interrupt returns and same-state priority splits; do not label their count as wakeups or context switches.",
    "Preempted -> Running resumes remain CPU dispatches but are not unblock activations.",
    "ThreadActivity overlays syscall/fault/interrupt intervals and repeats full state weights; its rows must not be summed for CPU/state time.",
    "Instruments made-runnable-by can identify the interrupted thread for interrupt-context wakeups, not a user-space caller.",
    "Durations are modeled thread-state time in an instrumented process. Only disjoint Running intervals are additive CPU attribution; blocked totals across threads exceed wall time naturally.",
    "Capture edges may be inferred by Instruments; counts exclude unobserved preceding transitions, and no missing events are invented.",
]


def markdown(summary):
    lines = [
        "# PID-scoped System Trace scheduler analysis",
        "",
        f"PID {summary['pid']}; {summary['analysisDurationSeconds']:.6f} s modeled window; {summary['threadCount']} threads.",
        "",
        "**Exploratory: capture did not establish steady-phase containment.**"
        if not summary["steadyPhaseContained"]
        else "Recorder provenance establishes steady-phase containment; this remains an instrumented attribution run.",
        "",
        "Counts distinguish off-CPU thread activation from interrupt return, preemption and repeated Running entries.",
        "",
        "| Thread | Running ms | Blocked→ready/run | Parked→ready/run | CPU dispatches | Interrupt returns | Preemptions |",
        "|---|---:|---:|---:|---:|---:|---:|",
    ]
    for thread in summary["threads"]:
        c = thread["counts"]
        name = thread["name"].replace("|", r"\|")
        lines.append(
            f"| {name} | {thread['stateDurationNanoseconds'].get('Running', 0)/1e6:.3f} | "
            f"{c.get('blockedActivations', 0)} | {c.get('dispatchParkActivations', 0)} | "
            f"{c.get('CPUDispatchesFromOffCPU', 0)} | {c.get('interruptReturns', 0)} | {c.get('preemptions', 0)} |"
        )
    lines += [
        "",
        "Exact totals and all state durations/transition types are in `kernel-summary.json`.",
        "",
        "| Metric | Count |",
        "|---|---:|",
    ]
    for key, value in summary["counts"].items():
        lines.append(f"| {key} | {value} |")
    lines += [
        "",
        "Raw Runnable events classified by contemporaneous modeled state: "
        + json.dumps(summary["rawRunnableEventsByModeledState"])
        + ".",
        "",
        "Cross-table Running-start validation: " + json.dumps(summary["validation"]) + ".",
        "",
    ]
    lines.extend("- " + text for text in summary["limitations"])
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path, help="Contains xctrace XML exports and recorder provenance.json")
    parser.add_argument("--pid", type=int, required=True)
    parser.add_argument(
        "--output", type=Path, required=True, help="New directory; existing results are never overwritten"
    )
    parser.add_argument("--start-seconds", type=float)
    parser.add_argument("--end-seconds", type=float)
    args = parser.parse_args()
    provenance_path = args.directory / "provenance.json"
    provenance = json.loads(provenance_path.read_text()) if provenance_path.exists() else {}
    if provenance.get("pid") not in (None, args.pid):
        raise ValueError("PID conflicts with recorder provenance")
    table_data = {}
    export_info = {}
    for schema in ("thread-state", "context-switch"):
        path = args.directory / f"{schema}.xml"
        info, rows = read_rows(path, schema, args.pid)
        export_info[schema] = {**info, "sha256": digest(path)}
        table_data[schema] = rows
    summary = aggregate(
        table_data["thread-state"],
        table_data["context-switch"],
        args.pid,
        None if args.start_seconds is None else round(args.start_seconds * 1e9),
        None if args.end_seconds is None else round(args.end_seconds * 1e9),
    )
    summary["schemaVersion"] = 1
    summary["exports"] = export_info
    summary["steadyPhaseContained"] = provenance.get("steadyWindow", {}).get("contained") is True
    summary["limitations"] = LIMITATIONS
    summary["provenanceSHA256"] = digest(provenance_path) if provenance_path.exists() else None
    summary["appSHA256"] = provenance.get("appSHA256")
    activity = args.directory / "ThreadActivity.xml"
    if activity.exists():
        summary["ThreadActivityInspection"] = {
            **schema_columns(activity),
            "sha256": digest(activity),
            "usedForDurationAggregation": False,
            "reason": "Overlay table with repeated state weights; canonical thread-state intervals used instead.",
        }
    args.output.mkdir(parents=True, exist_ok=False)
    for schema, rows in table_data.items():
        (args.output / f"{schema}-pid.json").write_text(
            json.dumps({"info": export_info[schema], "rows": rows}, indent=2) + "\n"
        )
    (args.output / "kernel-summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    (args.output / "analysis.md").write_text(markdown(summary))
    print(
        json.dumps(
            {
                key: summary[key]
                for key in (
                    "pid",
                    "steadyPhaseContained",
                    "analysisDurationSeconds",
                    "threadCount",
                    "counts",
                    "contextEventCounts",
                    "rawRunnableEventsByModeledState",
                    "validation",
                )
            },
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
