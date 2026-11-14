#!/usr/bin/env python3
"""Stage pinned playback references from the local sample directory."""

import argparse
import hashlib
import json
from pathlib import Path
import shutil
from tempfile import TemporaryDirectory

from derive_reference_media import PREPARATIONS


CATALOG = Path(__file__).with_name("reference_media_cases.json")


def verified_sample(source, sample, expected_digest):
    path = (source / sample).resolve()
    if not path.is_relative_to(source):
        raise ValueError(f"Invalid source path in {CATALOG.name}: {sample}")
    if not path.is_file():
        raise FileNotFoundError(f"Missing local playback sample: {sample}")
    with path.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    if digest != expected_digest:
        raise ValueError(f"Unexpected content in local playback sample: {sample}")
    return path


def prepare(source, output):
    cases = json.loads(CATALOG.read_text())
    source = source.resolve()
    output.mkdir(parents=True, exist_ok=True)

    with TemporaryDirectory(prefix="reference-media-", dir=output.parent) as temporary:
        staging = Path(temporary)
        for case in cases:
            name = case["file"]
            if Path(name).name != name or not name.startswith("reference-"):
                raise ValueError(f"Invalid reference path in {CATALOG.name}: {name}")
            media = verified_sample(source, case["sample"], case["sha256"])
            target = staging / name
            if preparation := case.get("preparation"):
                supplemental = [
                    verified_sample(source, sample["sample"], sample["sha256"]) for sample in case.get("supplementalSamples", [])
                ]
                derived = PREPARATIONS[preparation](media, *supplemental, **case.get("preparationOptions", {}))
                if hashlib.sha256(derived).hexdigest() != case["preparedSha256"]:
                    raise ValueError(f"Unexpected derived fixture content: {name}")
                target.write_bytes(derived)
            else:
                shutil.copyfile(media, target)

        for case in cases:
            name = case["file"]
            (staging / name).replace(output / name)
        catalog = staging / "reference-media.json"
        shutil.copyfile(CATALOG, catalog)
        catalog.replace(output / catalog.name)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--source",
        type=Path,
        required=True,
        help="Local directory containing the paths listed in reference_media_cases.json",
    )
    parser.add_argument("--output", type=Path, required=True, help="Directory for MPVUI_REFERENCE_TEST_MEDIA")
    args = parser.parse_args()
    prepare(args.source, args.output)
