#!/usr/bin/env python3
"""Run a command to completion and emit one JSON validation result, retaining full logs.

Use the public Make targets, such as `make test-unit`; Make invokes this runner.
Stdout is one RFC 8259 JSON document; result.schema.json defines its contract.
Commands run without a shell. Progress and full diagnostics stay in the run directory.
"""

import argparse
from collections import deque
from datetime import datetime, timezone
import json
import math
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
EVIDENCE_ENV = "MPVUI_VALIDATION_EVIDENCE"
ANSI = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
ERROR = re.compile(r"\berror:|\bfatal error\b|recorded an issue|Expectation failed|\b\w+(?:Error|Exception):|Traceback \(most recent", re.I)
WARNING = re.compile(r"\bwarning:|\[[\w-]+-warn\]", re.I)
LOCATION = re.compile(r"(?P<path>[^\s\"<>]+\.(?:swift|c|h|cc|cpp|m|mm|py)):(?P<line>\d+)(?::(?P<column>\d+))?")


def reject_constant(value):
    raise ValueError(f"Non-finite JSON number: {value}")


class CommandInterrupted(Exception):
    def __init__(self, signum):
        self.signum = signum


def write_json(path, value):
    """Atomically replace an owned result; never publish partial or non-finite JSON."""
    path = Path(path)
    temporary = path.with_name(path.name + "." + uuid.uuid4().hex + ".tmp")
    try:
        temporary.write_text(json.dumps(value, ensure_ascii=False, allow_nan=False, indent=2) + "\n", encoding="utf-8")
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def publish_evidence(*, summary=None, artifacts=None):
    """Give the parent validation runner typed evidence without printing large reports."""
    destination = os.environ.get(EVIDENCE_ENV)
    if not destination:
        return
    path = Path(destination)
    evidence = json.loads(path.read_text(), parse_constant=reject_constant) if path.exists() else {"summary": {}, "artifacts": {}}
    evidence["summary"].update(summary or {})
    evidence["artifacts"].update({key: str(Path(value).resolve()) for key, value in (artifacts or {}).items()})
    write_json(path, evidence)


def diagnostics(paths):
    """Find diagnostics throughout logs, retaining locations and nearby lines, with deduplication."""
    found = {}
    for path in dict.fromkeys(map(Path, paths)):
        if not path.is_file():
            continue
        previous = deque(maxlen=1)
        pending = []
        with path.open(errors="replace") as stream:
            for number, raw in enumerate(stream, 1):
                line = ANSI.sub("", raw.rstrip())
                for item, remaining in pending:
                    item["context"].append(line)
                pending = [(item, remaining - 1) for item, remaining in pending if remaining > 1]
                severity = "error" if ERROR.search(line) else "warning" if WARNING.search(line) else None
                if severity:
                    key = (severity, line.strip())
                    if key in found:
                        found[key]["occurrences"] += 1
                    else:
                        item = dict(
                            severity=severity,
                            message=line.strip(),
                            log=str(path),
                            logLine=number,
                            occurrences=1,
                            context=list(previous) + [line],
                        )
                        location = LOCATION.search(line)
                        if location and int(location["line"]) > 0:
                            item["location"] = dict(path=location["path"], line=int(location["line"]))
                            if location["column"] and int(location["column"]) > 0:
                                item["location"]["column"] = int(location["column"])
                        found[key] = item
                        pending.append((item, 2))
                previous.append(line)
    return list(found.values())


def bounded_diagnostics(items, *, failed):
    selected = []
    omitted = 0
    for severity, limit in (("error", 20), ("warning", 10)):
        group = [item for item in items if item["severity"] == severity and (failed or severity != "error")]
        omitted += max(0, len(group) - limit)
        for item in group[:limit]:
            item = dict(item)
            message, context = item["message"], "\n".join(item["context"])
            item["message"] = message[:2000]
            item["context"] = context[:3000].splitlines()
            item["truncated"] = len(message) > 2000 or len(context) > 3000
            selected.append(item)
    return dict(items=selected, omitted=omitted)


def failure_excerpt(path):
    """Human CLI fallback: show actual errors first, not just the end of a noisy log."""
    errors = [item for item in diagnostics([path]) if item["severity"] == "error"]
    if errors:
        selected = bounded_diagnostics(errors, failed=True)
        text = "\n\n".join(f"{item['log']}:{item['logLine']}\n" + "\n".join(item["context"]) for item in selected["items"])
        return text + (f"\n{selected['omitted']} more diagnostics; see full log: {path}" if selected["omitted"] else "")
    with Path(path).open(errors="replace") as stream:
        return "".join(deque(stream, maxlen=30))[-6000:]


def test_summary(path):
    """Prefer Swift Testing's footer over XCTest's often-empty compatibility suite."""
    result, skipped, python_count, python_outcome, python_skips = {}, [], None, None, 0
    with Path(path).open(errors="replace") as stream:
        for raw in stream:
            line = ANSI.sub("", raw.strip())
            match = re.search(r"Test run with (\d+) tests?(?: in (\d+) suites?)? (passed|failed)\b", line)
            if match:
                result = dict(framework="Swift Testing", count=int(match[1]), outcome=match[3])
                if match[2]:
                    result["suites"] = int(match[2])
                issues = re.search(r"with (\d+) issues?", line)
                result["issues"] = int(issues[1]) if issues else 0
            elif not result or result.get("framework") == "XCTest":
                match = re.search(r"Executed (\d+) tests?, with (\d+) failures?", line)
                if match:
                    result = dict(
                        framework="XCTest", count=int(match[1]), failures=int(match[2]), outcome="failed" if int(match[2]) else "passed"
                    )
            if re.search(r"\bTest .+ skipped\b", line) and line not in skipped:
                skipped.append(line)
            match = re.fullmatch(r"Ran (\d+) tests? in .+", line)
            if match:
                python_count = int(match[1])
            if python_count is not None and (line == "OK" or line.startswith(("OK (", "FAILED ("))):
                python_outcome = "passed" if line.startswith("OK") else "failed"
                match = re.search(r"skipped=(\d+)", line)
                python_skips = int(match[1]) if match else 0
    if not result and python_count is not None and python_outcome:
        return dict(framework="unittest", count=python_count, outcome=python_outcome, skippedCount=python_skips)
    if result:
        result.update(skipped=skipped[:20], skippedCount=len(skipped), omittedSkipped=max(0, len(skipped) - 20))
    return result


def positive_seconds(value):
    seconds = float(value)
    if not math.isfinite(seconds) or seconds <= 0:
        raise argparse.ArgumentTypeError("must be a finite positive number")
    return seconds


def stop_process(process):
    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()
    # The group leader may exit before a descendant that ignored SIGTERM.
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


def run(command, *, kind, directory, timeout=None):
    directory = Path(directory).resolve()
    directory.mkdir(parents=True, exist_ok=False)
    log, result_path, evidence_path = (directory / name for name in ("command.log", "result.json", "evidence.json"))
    started = time.monotonic()
    result = dict(
        schemaVersion=1,
        kind=kind,
        status="running",
        command=command,
        cwd=str(Path.cwd()),
        startedAt=datetime.now(timezone.utc).isoformat(),
        durationSeconds=0,
        exitCode=None,
        summary={},
        diagnostics=dict(items=[], omitted=0),
        artifacts=dict(commandLog=str(log), result=str(result_path)),
    )
    write_json(result_path, result)
    exit_code, status, failure = 1, "failed", None
    process = None
    previous_handler = signal.getsignal(signal.SIGTERM)

    def interrupted(signum, frame):
        raise CommandInterrupted(signum)

    try:
        signal.signal(signal.SIGTERM, interrupted)
        with log.open("w") as stream:
            process = subprocess.Popen(
                command,
                stdout=stream,
                stderr=subprocess.STDOUT,
                env=dict(os.environ, **{EVIDENCE_ENV: str(evidence_path)}),
                start_new_session=True,
            )
            code = process.wait(timeout=timeout)
        exit_code = code if code >= 0 else 128 - code
        status = "succeeded" if exit_code == 0 else "failed"
    except subprocess.TimeoutExpired:
        status, exit_code, failure = "timed_out", 124, f"Command exceeded {timeout} seconds"
    except KeyboardInterrupt:
        status, exit_code, failure = "interrupted", 130, "Command interrupted"
    except CommandInterrupted as error:
        status, exit_code, failure = "interrupted", 128 + error.signum, f"Command interrupted by signal {error.signum}"
    except OSError as error:
        failure = str(error)
        exit_code = 127
    finally:
        # Stop the complete process group before publishing a terminal result.
        if process is not None and process.poll() is None:
            stop_process(process)
        signal.signal(signal.SIGTERM, previous_handler)

    paths = [log]
    try:
        if evidence_path.exists():
            evidence = json.loads(evidence_path.read_text(), parse_constant=reject_constant)
            if not isinstance(evidence.get("summary"), dict) or not isinstance(evidence.get("artifacts"), dict):
                raise ValueError("Evidence summary and artifacts must be objects")
            if not all(isinstance(value, str) for value in evidence["artifacts"].values()):
                raise ValueError("Evidence artifact paths must be strings")
            if {"result", "commandLog", "diagnostics"} & evidence["artifacts"].keys():
                raise ValueError("Evidence must not replace runner-owned artifacts")
            result["summary"].update(evidence["summary"])
            result["artifacts"].update(evidence["artifacts"])
            paths += [Path(value) for key, value in evidence["artifacts"].items() if key.endswith("Log")]
            if "nativeLogs" in evidence["artifacts"]:
                native = Path(evidence["artifacts"]["nativeLogs"])
                paths += sorted(native.glob("*.log")) + sorted(native.glob("*.log.stdout"))
            if "benchmarkLogs" in evidence["artifacts"]:
                paths += sorted(Path(evidence["artifacts"]["benchmarkLogs"]).glob("*.log"))
        paths = list(dict.fromkeys(paths))
        if kind == "test" and "tests" not in result["summary"]:
            tests = test_summary(log)
            if tests:
                result["summary"]["tests"] = tests
        tests = result["summary"].get("tests", {})
        if kind == "test" and tests and (tests.get("outcome") == "failed" or tests.get("count") == 0) and not exit_code:
            status, exit_code, failure = "failed", 1, "Test result reports failure or zero executed tests"
        items = diagnostics(paths)
        diagnostic_path = directory / "diagnostics.json"
        write_json(diagnostic_path, items)
        result["artifacts"]["diagnostics"] = str(diagnostic_path)
        result["diagnostics"] = bounded_diagnostics(items, failed=exit_code != 0)
        if exit_code and not any(item["severity"] == "error" for item in items):
            result["summary"]["failureExcerpt"] = failure_excerpt(log)
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as error:
        failure = f"Cannot collect validation evidence: {error}"
        if not exit_code:
            exit_code, status = 1, "failed"
    if failure:
        result["summary"]["runnerError"] = failure
    result.update(status=status, exitCode=exit_code, durationSeconds=round(time.monotonic() - started, 3))
    write_json(result_path, result)
    print(json.dumps(result, ensure_ascii=False, allow_nan=False, separators=(",", ":")), flush=True)
    return exit_code


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kind", choices=("build", "test", "benchmark", "command"), required=True)
    parser.add_argument("--output-dir", type=Path, help="New directory for immutable run artifacts")
    parser.add_argument("--timeout", type=positive_seconds, help="Stop the process group after this many seconds")
    parser.add_argument("command", nargs=argparse.REMAINDER, help="Executable and arguments after --")
    args = parser.parse_args(argv)
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("a command is required after --")
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:8]
    return run(command, kind=args.kind, directory=args.output_dir or ROOT / ".build/validation" / stamp, timeout=args.timeout)


if __name__ == "__main__":
    raise SystemExit(main())
