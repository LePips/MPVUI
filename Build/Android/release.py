#!/usr/bin/env python3
"""Create a local Android release bundle with Maven metadata and corresponding sources."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import zipfile
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from native_inputs import LOCK_PATH, fingerprint, inputs_for, load
from Android.swift_core import source_fingerprint
from validation import publish_evidence

ROOT = Path(__file__).resolve().parents[2]


def configured_version(root=ROOT):
    """Use the same default Maven version as the library's Gradle build."""
    properties = (root / "Android/gradle.properties").read_text()
    match = re.search(r"^mpvuiVersion\s*=\s*(\S+)\s*$", properties, re.M)
    if match is None:
        raise ValueError("Set mpvuiVersion in Android/gradle.properties")
    return match[1]


def sha(path):
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def verify_native(root):
    native = root / ".build/android/native"
    expected_inputs = fingerprint(inputs_for(load(root), "android"))
    expected_jni = sha(root / "Android/mpvui/src/main/cpp/mpvui.cpp")
    for abi in ("arm64-v8a", "x86_64"):
        manifest = json.loads((native / "assets/mpvui" / f"build-{abi}.json").read_text())
        if (
            manifest["inputs"] != expected_inputs
            or manifest["jniSource"] != expected_jni
            or manifest.get("swift", {}).get("sources") != source_fingerprint(root)
        ):
            raise ValueError(f"Rebuild {abi}: native sources changed")
        for name, checksum in manifest["libraries"].items():
            if sha(native / "jniLibs" / abi / name) != checksum:
                raise ValueError(f"Rebuild {abi}: checksum mismatch for {name}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", default=configured_version())
    parser.add_argument("--verify-only", action="store_true")
    args = parser.parse_args()
    if not args.verify_only and (not args.version or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?", args.version)):
        parser.error("Use a semantic version, for example 0.7.0")
    try:
        verify_native(ROOT)
    except ValueError as error:
        parser.error(str(error))
    if args.verify_only:
        return
    repository = ROOT / "Android/build/repository"
    # Snapshot publications otherwise accumulate old timestamped AARs in bundles.
    shutil.rmtree(repository / "io/github/lepips/mpvui" / args.version, ignore_errors=True)
    subprocess.run(
        [
            str(ROOT / "Android/gradlew"),
            ":mpvui:assembleRelease",
            ":mpvui:publishReleasePublicationToLocalBundleRepository",
            f"-PmpvuiVersion={args.version}",
        ],
        cwd=ROOT / "Android",
        check=True,
    )
    destination = ROOT / ".build/android/releases" / args.version
    destination.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(destination / f"mpvui-android-{args.version}-maven.zip", "w", zipfile.ZIP_DEFLATED) as archive:
        for source in (repository / "io/github/lepips/mpvui" / args.version).rglob("*"):
            if source.is_file():
                archive.write(source, source.relative_to(repository))
    shutil.copy2(ROOT / "Android/mpvui/build/outputs/aar/mpvui-release.aar", destination / f"mpvui-{args.version}.aar")
    shutil.copy2(ROOT / LOCK_PATH, destination)

    def source_filter(member):
        parts = Path(member.name).parts
        if any(
            p in {".git", "build", "target", ".gradle", ".kotlin", ".cxx", "autom4te.cache", "__pycache__"} or p.startswith("_build")
            for p in parts
        ):
            return None
        if member.name.endswith((".o", ".a", ".so", ".lo", ".pyc")) or Path(member.name).name == "local.properties":
            return None
        return member

    with tarfile.open(destination / f"mpvui-android-{args.version}-sources.tar.gz", "w:gz") as archive:
        for relative in (
            "Makefile",
            "Brewfile",
            "Android",
            "Build/Makefile",
            "Build/Android",
            "Build/native_inputs.py",
            "Build/Patches",
            "Build/Inputs.lock.json",
            "Build/validation.py",
            "Package.swift",
            "Sources/CMPV",
            "Sources/MPVCore",
            "Sources/MPVCoreAndroid",
            "Tests/Core",
            "LICENSE",
        ):
            archive.add(ROOT / relative, arcname=relative, filter=source_filter)
        archive.add(ROOT / ".build/android/native/assets/mpvui", arcname="provenance")
        scripts = ROOT / ".build/android/upstream/buildscripts"
        for source in (scripts / "deps").iterdir():
            archive.add(source, arcname=f"native-sources/{source.name}", filter=source_filter)
        for relative in ("include", "scripts", "buildall.sh"):
            archive.add(scripts / relative, arcname=f"native-recipes/{relative}", filter=source_filter)
        archive.add(scripts.parent / "LICENSE", arcname="native-recipes/LICENSE")
        archive.add(ROOT / ".build/android/rust-vendor", arcname="native-sources/rust-vendor", filter=source_filter)
    artifacts = sorted(p for p in destination.iterdir() if p.name != "SHA256SUMS")
    (destination / "SHA256SUMS").write_text("".join(f"{sha(p)}  {p.name}\n" for p in artifacts))
    publish_evidence(
        summary={"version": args.version, "abis": ["arm64-v8a", "x86_64"]},
        artifacts={"androidPublicationBundle": str(destination), "checksums": str(destination / "SHA256SUMS")},
    )
    print(f"Local publication bundle: {destination}")


if __name__ == "__main__":
    main()
