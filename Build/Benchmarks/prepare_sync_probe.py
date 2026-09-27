#!/usr/bin/env python3
"""Prepare and recheck opt-in sync-probe fixtures against protocol4 media identities."""

from __future__ import annotations
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import shutil
import sys
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Build/Benchmarks"))
from device_playback import digest, media_identity


def reference_identity(path):
    report = json.loads(Path(path).read_text())
    workloads = [w for w in report["workloads"] if w["parameters"]["player"] == "mpv"]
    if len(workloads) != 1 or not workloads[0]["observations"]:
        raise ValueError("Reference must contain one MPV workload with observations")
    if any(r.get("schemaVersion") != 4 or r.get("status") != "passed" for r in workloads[0]["observations"]):
        raise ValueError("Reference must contain passed protocol4 observations")
    identity = report["runtime"]["media"]
    if workloads[0]["parameters"]["mediaSHA256"] != identity["sha256"]:
        raise ValueError("Reference workload media hash disagrees with its manifest")
    return identity, report["environment"]["comparisonKey"], digest(path)


def verify_media(path, expected):
    identity = media_identity(Path(path))
    if identity != expected:
        raise ValueError("Fixture content/filenames differ from the reference manifest: " + Path(path).name)
    return identity


def validate_url(url, playlist):
    parts = urlsplit(url)
    if (
        parts.scheme not in ("http", "https")
        or not parts.hostname
        or parts.username
        or parts.password
        or parts.query
        or parts.fragment
    ):
        raise ValueError("HLS URL must be an explicit HTTP(S) URL without credentials, query or fragment")
    if unquote(parts.path).split("/")[-1] != playlist.name:
        raise ValueError("HLS URL must name the verified playlist")


def prepare(direct, hls, direct_report, hls_report, hls_url, output):
    direct, hls, output = Path(direct).resolve(), Path(hls).resolve(), Path(output).resolve()
    if direct.suffix.lower() != ".mp4" or hls.suffix.lower() != ".m3u8":
        raise ValueError("Expected direct MP4 and HLS playlist")
    validate_url(hls_url, hls)
    expected_direct, direct_key, direct_ref_hash = reference_identity(direct_report)
    expected_hls, hls_key, hls_ref_hash = reference_identity(hls_report)
    if direct_key != hls_key:
        raise ValueError("Reference protocol/device/environment keys differ")
    direct_identity = verify_media(direct, expected_direct)
    hls_identity = verify_media(hls, expected_hls)
    config_path = output / "native-sync-configuration.json"
    if config_path.exists():
        raise FileExistsError("Configuration exists; preserve it and use a new output directory")
    output.mkdir(parents=True, exist_ok=True)
    copied = output / direct.name
    if copied.exists():
        if digest(copied) != direct_identity["files"][direct.name]:
            raise ValueError("Existing bundled direct fixture differs; refusing overwrite")
    else:
        with direct.open("rb") as source, copied.open("xb") as target:
            shutil.copyfileobj(source, target)
    # Verify the actual copied bytes, then rehash server assets after copying.
    verify_media(copied, direct_identity)
    verify_media(hls, hls_identity)
    config = {
        "directFilename": direct.name,
        "hlsURL": hls_url,
        "directFileSHA256": digest(copied),
        "directMediaSHA256": direct_identity["sha256"],
        "hlsMediaSHA256": hls_identity["sha256"],
        "hostVerification": {
            "createdAt": datetime.now(timezone.utc).isoformat(),
            "method": "device_playback.media_identity; compared exact manifests to passed protocol4 reports",
            "directReferenceSHA256": direct_ref_hash,
            "hlsReferenceSHA256": hls_ref_hash,
            "directIdentity": direct_identity,
            "hlsIdentity": hls_identity,
            "hlsScope": "host-served directory identity; device does not independently hash HLS responses",
        },
    }
    with config_path.open("x") as stream:
        json.dump(config, stream, indent=2, sort_keys=True)
        stream.write("\n")
    return config_path


def recheck(direct, hls, configuration):
    config = json.loads(Path(configuration).read_text())
    proof = config["hostVerification"]
    direct_identity = verify_media(direct, proof["directIdentity"])
    hls_identity = verify_media(hls, proof["hlsIdentity"])
    copied = Path(configuration).parent / config["directFilename"]
    verify_media(copied, direct_identity)
    if (
        digest(copied) != config["directFileSHA256"]
        or direct_identity["sha256"] != config["directMediaSHA256"]
        or hls_identity["sha256"] != config["hlsMediaSHA256"]
    ):
        raise ValueError("Configuration identity fields disagree")
    return {
        "status": "passed",
        "checkedAt": datetime.now(timezone.utc).isoformat(),
        "configurationSHA256": digest(configuration),
        "directMediaSHA256": direct_identity["sha256"],
        "hlsMediaSHA256": hls_identity["sha256"],
        "scope": "host source directory and bundled direct copy; no device HLS response hashing",
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    prep = sub.add_parser("prepare")
    prep.add_argument("--direct-report", type=Path, required=True)
    prep.add_argument("--hls-report", type=Path, required=True)
    prep.add_argument("--hls-url", required=True)
    prep.add_argument("--output", type=Path, required=True, help="GeneratedMedia directory; config must not exist")
    check = sub.add_parser("recheck")
    check.add_argument("--configuration", type=Path, required=True)
    check.add_argument("--output", type=Path, required=True, help="New JSON evidence file")
    for command in (prep, check):
        command.add_argument("--direct", type=Path, required=True)
        command.add_argument("--hls", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "prepare":
        print(prepare(args.direct, args.hls, args.direct_report, args.hls_report, args.hls_url, args.output))
    else:
        if args.output.exists():
            raise FileExistsError("Recheck output exists")
        result = recheck(args.direct, args.hls, args.configuration)
        with args.output.open("x") as stream:
            json.dump(result, stream, indent=2, sort_keys=True)
            stream.write("\n")
        print(args.output)


if __name__ == "__main__":
    main()
