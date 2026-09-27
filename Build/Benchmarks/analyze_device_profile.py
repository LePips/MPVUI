"""PID-only xctrace Time Profiler aggregation with UUID checked symbolication."""

import argparse
import hashlib
from collections import Counter, defaultdict
import json
from pathlib import Path
import re
import subprocess
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]


def parse(path, pid):
    root = ET.parse(path).getroot()
    ids = {e.get("id"): e for e in root.iter() if e.get("id")}

    def resolve(e):
        seen = set()
        while e is not None and e.get("ref"):
            ref = e.get("ref")
            if ref in seen or ref not in ids:
                raise ValueError("Invalid or cyclic XML reference")
            seen.add(ref)
            e = ids[ref]
        return e

    records = []
    binaries = {}
    for row in root.iter("row"):
        values = list(row)
        if len(values) != 7:
            raise ValueError("Unexpected time-profile schema")
        proc = resolve(values[2])
        identity = resolve(proc.find("pid"))
        if int(identity.text) != pid:
            continue
        frames = []
        stack = resolve(values[6])
        for ref in stack.findall("frame"):
            f = resolve(ref)
            b = resolve(f.find("binary"))
            uid = b.get("UUID") if b is not None else None
            if uid:
                if uid in binaries and any(binaries[uid].get(k) != b.get(k) for k in ("name", "path", "load-addr")):
                    raise ValueError("One UUID has conflicting binary/load-address records")
                binaries[uid] = b.attrib
            frames.append(
                {
                    "name": f.get("name") or f.get("addr") or "unknown",
                    "addr": f.get("addr"),
                    "uuid": uid,
                    "binary": b.get("name", "unknown") if b is not None else "unknown",
                }
            )
        timestamp, weight = int(resolve(values[0]).text), int(resolve(values[5]).text)
        if timestamp < 0 or weight <= 0:
            raise ValueError("Time Profiler samples require nonnegative time and positive CPU weight")
        records.append(
            {
                "timeSeconds": timestamp / 1e9,
                "nanoseconds": weight,
                "thread": resolve(values[1]).get("fmt"),
                "state": resolve(values[4]).text,
                "frames": frames,
            }
        )
    if not records:
        raise ValueError("No target process samples")
    return records, binaries


def symbolicate(records, binaries, products, symbols):
    addresses = defaultdict(set)
    for s in records:
        for f in s["frames"]:
            if f["uuid"] and f["addr"]:
                addresses[f["uuid"]].add(f["addr"])
    names, validation = {}, {}
    for uid, b in binaries.items():
        if b["name"] == "MPVUIExample":
            path = products / "MPVUIExample.app.dSYM/Contents/Resources/DWARF/MPVUIExample"
        elif b["name"] == "Libmpv":
            path = products / "Libmpv.framework/Libmpv"
        else:
            path = symbols / b["path"].lstrip("/")
            if not path.exists():
                path = symbols / b["path"].replace("/Versions/A/", "/").lstrip("/")
        if not path.exists():
            validation[uid] = {"name": b["name"], "status": "missing symbols"}
            continue
        dump = subprocess.run(["dwarfdump", "--uuid", str(path)], capture_output=True, text=True, check=True).stdout
        matches = re.findall(r"UUID: ([A-Fa-f0-9-]+) \(([^)]+)\)", dump)
        arch = next((a for u, a in matches if u.upper() == uid.upper()), None)
        if not arch:
            validation[uid] = {"name": b["name"], "status": "UUID mismatch; not used"}
            continue
        addr = sorted(addresses[uid])
        output = subprocess.run(
            ["atos", "-arch", arch, "-o", str(path), "-l", b["load-addr"], *addr],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.splitlines()
        if len(output) != len(addr):
            raise ValueError("Unexpected atos output length")
        names[uid] = dict(zip(addr, output))
        validation[uid] = {
            "name": b["name"],
            "uuid": uid,
            "loadAddress": b["load-addr"],
            "addresses": len(addr),
            "resolved": sum(not v.startswith("0x") for v in output),
        }
    return {"validation": validation, "symbols": names}


def aggregate(records, pid, symbols):
    threads, inclusive, leaf, states, stacks, leaf_binaries = (Counter() for _ in range(6))
    by_thread = defaultdict(Counter)
    samples = []
    for s in records:
        if s["state"] != "Running":
            raise ValueError("CPU aggregation requires Running samples; analyze waiting states separately")
        ns = s["nanoseconds"]
        frames = []
        for f in s["frames"]:
            name = symbols.get(f["uuid"], {}).get(f["addr"], f["name"])
            name = re.split(r" \(in [^)]+\)", name)[0]
            frames.append(name)
        threads[s["thread"]] += ns
        states[s["state"]] += ns
        for name in set(frames):
            inclusive[name] += ns
            by_thread[s["thread"]][name] += ns
        if frames:
            leaf[frames[0]] += ns
            leaf_binaries[s["frames"][0]["binary"]] += ns
        stacks[tuple(frames)] += ns
        samples.append({**{k: v for k, v in s.items() if k != "frames"}, "frames": frames})
    summary = {
        "pid": pid,
        "samples": len(records),
        "weightedSeconds": sum(states.values()) / 1e9,
        "firstSampleSeconds": min(s["timeSeconds"] for s in records),
        "lastSampleSeconds": max(s["timeSeconds"] for s in records),
        "states": states,
        "threads": dict(threads.most_common()),
        "inclusiveNanoseconds": dict(inclusive.most_common()),
        "leafNanoseconds": dict(leaf.most_common()),
        "leafBinaryNanoseconds": dict(leaf_binaries.most_common()),
        "threadInclusiveNanoseconds": {k: dict(v.most_common()) for k, v in by_thread.items()},
        "limitations": [
            "Inclusive stack timings overlap; never add nested costs.",
            "Sampling CPU weights are attribution, not uninstrumented performance estimates.",
        ],
    }
    return summary, samples, [{"nanoseconds": n, "frames": list(s)} for s, n in stacks.most_common()]


def validate_symbol_map(mapping, binaries):
    """A name map must carry UUID validation for every binary whose names it uses."""
    for uid, entries in mapping.get("symbols", {}).items():
        if uid not in binaries:
            continue
        proof = mapping.get("validation", {}).get(uid, {})
        binary = binaries[uid]
        if proof.get("uuid", "").upper() != uid.upper() or proof.get("name") != binary["name"]:
            raise ValueError("Symbol map has no matching UUID/name validation for " + binary["name"])
        if proof.get("loadAddress") != binary["load-addr"]:
            raise ValueError("Symbol map load address does not match this trace")
        if not isinstance(entries, dict) or any(not isinstance(value, str) for value in entries.values()):
            raise ValueError("Invalid symbol name map")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("directory", type=Path)
    p.add_argument(
        "--output", type=Path, help="New output directory; defaults to input/analysis and never overwrites evidence"
    )
    p.add_argument("--pid", type=int)
    p.add_argument("--products", type=Path, default=ROOT / ".build/device-benchmark/Build/Products/Release-iphoneos")
    p.add_argument("--symbols", type=Path, help="DeviceSupport Symbols directory when building a fresh symbol map")
    p.add_argument("--symbol-map", type=Path)
    a = p.parse_args()
    if not a.symbol_map and not a.symbols:
        p.error("Use --symbols or a provenance-checked --symbol-map")
    pid = a.pid or json.loads((a.directory / "provenance.json").read_text())["pid"]
    trace = a.directory / "time-profile.xml"
    trace_hash = hashlib.sha256(trace.read_bytes()).hexdigest()
    records, binaries = parse(trace, pid)
    if a.symbol_map:
        mapping = json.loads(a.symbol_map.read_text())
        if mapping.get("traceSHA256") != trace_hash:
            raise ValueError("Symbol map must match the trace SHA256")
    else:
        mapping = symbolicate(records, binaries, a.products, a.symbols)
    validate_symbol_map(mapping, binaries)
    summary, samples, stacks = aggregate(records, pid, mapping["symbols"])
    mapping = dict(mapping, traceSHA256=trace_hash)
    summary["traceSHA256"] = trace_hash
    out = a.output or a.directory / "analysis"
    out.mkdir(parents=True, exist_ok=False)
    for name, value in (
        ("stack-summary", summary),
        ("app-samples", samples),
        ("app-stacks", stacks),
        ("symbol-map", mapping),
    ):
        with (out / (name + ".json")).open("x") as stream:
            stream.write(json.dumps(value, indent=2) + "\n")
    print(
        json.dumps(
            {
                "output": str(out),
                "samples": summary["samples"],
                "weightedSeconds": summary["weightedSeconds"],
                "threads": summary["threads"],
            },
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
