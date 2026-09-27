import tempfile
from pathlib import Path
import unittest
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Benchmarks"))
from analyze_device_system_trace import aggregate, read_rows


def interval(start, duration, state, tid=20, pid=7):
    return {
        "start": start,
        "duration": duration,
        "state": state,
        "thread": {"tid": tid, "pid": pid, "name": "worker"},
        "process": {"pid": pid},
        "made-runnable-by-thread": None,
    }


def events_for(states):
    return [
        {"time": row["start"], "event": row["state"], "thread": row["thread"], "process": row["process"]}
        for row in states
        if row["state"] in ("Running", "Runnable")
    ]


class SchedulerTests(unittest.TestCase):
    def test_wakeups_exclude_interrupts_preemption_and_priority_splits(self):
        states = []
        start = 0
        for state, duration in [
            ("Blocked", 10),
            ("Runnable", 5),
            ("Running", 10),
            ("Interrupted", 2),
            ("Running", 5),
            ("Preempted", 3),
            ("Running", 5),
            ("Running", 5),
            ("Idle", 10),
            ("Runnable", 5),
            ("Running", 5),
            ("Blocked", 5),
            ("Running", 5),
        ]:
            states.append(interval(start, duration, state))
            start += duration
        events = events_for(states)
        events.append({"time": 16, "event": "Runnable", "thread": states[0]["thread"], "process": {"pid": 7}})
        result = aggregate(states, events, 7)
        self.assertEqual(result["counts"]["blockedActivations"], 2)
        self.assertEqual(result["counts"]["dispatchParkActivations"], 1)
        self.assertEqual(result["counts"]["offCPUThreadActivations"], 3)
        self.assertEqual(result["counts"]["CPUDispatchesFromOffCPU"], 4)
        self.assertEqual(result["counts"]["interruptReturns"], 1)
        self.assertEqual(result["counts"]["preemptions"], 1)
        self.assertEqual(result["counts"]["runningIntervalSplits"], 1)
        self.assertEqual(result["rawRunnableEventsByModeledState"], {"Runnable": 2, "Running": 1})
        self.assertTrue(result["validation"]["runningStartsMatchAcrossTables"])
        clipped = aggregate(states, events, 7, start_ns=5, end_ns=25)
        self.assertEqual(clipped["stateDurationNanoseconds"], {"Blocked": 5, "Runnable": 5, "Running": 10})
        self.assertEqual(clipped["counts"]["blockedActivations"], 1)

    def test_gaps_and_capture_initial_state_never_invent_wakeups(self):
        states = [interval(0, 10, "Blocked"), interval(20, 10, "Running")]
        result = aggregate(states, events_for(states), 7)
        self.assertEqual(result["counts"].get("offCPUThreadActivations", 0), 0)
        self.assertEqual(result["counts"]["missingIntervalGaps"], 1)
        initial = [interval(0, 10, "Running")]
        result = aggregate(initial, events_for(initial), 7)
        self.assertEqual(result["counts"].get("CPUDispatchesFromOffCPU", 0), 0)

    def test_overlap_foreign_pid_and_missing_state_are_rejected(self):
        with self.assertRaisesRegex(ValueError, "Overlapping"):
            aggregate([interval(0, 20, "Blocked"), interval(10, 20, "Running")], [], 7)
        with self.assertRaisesRegex(ValueError, "Foreign PID"):
            aggregate([interval(0, 20, "Blocked", pid=8)], [], 7)
        events = [{"time": 1, "event": "Running", "thread": {"pid": 7, "tid": 21}, "process": {"pid": 7}}]
        with self.assertRaisesRegex(ValueError, "no state"):
            aggregate([interval(0, 20, "Blocked")], events, 7)

    def test_pid_filter_resolves_nested_and_shared_definitions(self):
        xml = """<trace-query-result><node><schema name="thread-state">
        <col><mnemonic>start</mnemonic></col><col><mnemonic>thread</mnemonic></col>
        <col><mnemonic>state</mnemonic></col><col><mnemonic>duration</mnemonic></col>
        <col><mnemonic>process</mnemonic></col></schema>
        <row><start-time id="t">0</start-time><thread id="wrong"><tid>1</tid><process id="p8"><pid>8</pid></process></thread>
        <thread-state id="s">Blocked</thread-state><duration id="d">10</duration><process ref="p8"/></row>
        <row><start-time ref="t"/><thread id="right"><tid>20</tid><process id="p7"><pid>7</pid></process></thread>
        <thread-state ref="s"/><duration ref="d"/><process ref="p7"/></row>
        <row><start-time>10</start-time><thread ref="right"/><thread-state>Running</thread-state>
        <duration ref="d"/><process ref="p7"/></row></node></trace-query-result>"""
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "export.xml"
            path.write_text(xml)
            info, rows = read_rows(path, "thread-state", 7)
            self.assertEqual(info["exportedRows"], 3)
            self.assertEqual(info["targetRows"], 2)
            self.assertEqual([row["thread"]["tid"] for row in rows], [20, 20])
            path.write_text(xml.replace('thread ref="right"', 'thread ref="missing"'))
            with self.assertRaisesRegex(ValueError, "Missing/forward"):
                read_rows(path, "thread-state", 7)


if __name__ == "__main__":
    unittest.main()
