#!/usr/bin/env python3
"""Cross-compile the shared Swift playback core with the pinned Android SDK."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from native_inputs import inputs_for, load
from validation import publish_evidence
from native_inputs import fingerprint

ROOT = Path(__file__).resolve().parents[2]
ANDROID = load(ROOT)["android"]
MINIMUM_API = ANDROID["minimumAPI"]
SWIFT = ANDROID["swift"]
VERSION = SWIFT["version"]
SDK = SWIFT["sdk"]
ARCHITECTURES = {"arm64-v8a": "aarch64", "x86_64": "x86_64"}
SYSTEM_LIBRARIES = {
    "libandroid.so",
    "liblog.so",
    "libc.so",
    "libm.so",
    "libdl.so",
    "libz.so",
    "libEGL.so",
    "libGLESv2.so",
    "libGLESv3.so",
    "libOpenSLES.so",
    "libvulkan.so",
    "libmediandk.so",
    "libnativewindow.so",
    "libjnigraphics.so",
}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def sdk_resource_fingerprint(abi):
    """Hash compile-time modules and headers separately from the runtime inventory."""
    root = sdk_root() / "swift-resources/usr"
    files = [
        path
        for folder in ("include", f"lib/swift-{ARCHITECTURES[abi]}")
        for path in (root / folder).rglob("*")
        if path.is_file() and path.suffix != ".so"
    ]
    return fingerprint({str(path.relative_to(root)): digest(path) for path in sorted(files)})


def source_fingerprint(root=ROOT):
    sources = [root / "Package.swift"]
    sources.extend(path for name in ("build.py", "swift_core.py") if (path := root / "Build/Android" / name).is_file())
    for folder in ("Sources/CMPV", "Sources/MPVCore", "Sources/MPVCoreAndroid"):
        sources.extend(path for path in (root / folder).rglob("*") if path.is_file())
    # Apple artifact selection is not an Android compiler input.
    entries = {str(path.relative_to(root)): digest(path) for path in sorted(sources) if path.name != "Package.swift"}
    manifest = (root / "Package.swift").read_text()
    manifest = re.sub(r"// MPVBUILD_BINARY_TARGETS_BEGIN.*?// MPVBUILD_BINARY_TARGETS_END", "", manifest, flags=re.S)
    entries["Package.swift"] = hashlib.sha256(manifest.encode()).hexdigest()
    return fingerprint(entries)


def validate_toolchain(abi):
    host = SWIFT["compiler"].get(sys.platform)
    if host is None:
        raise RuntimeError(f"No verified Swift {VERSION} host compiler for {sys.platform}")
    binary = Path(compiler()).resolve().parent
    for name, checksum in host["files"].items():
        if digest(binary / name) != checksum:
            raise RuntimeError(f"Swift compiler checksum mismatch: {binary / name}")
    root = sdk_root()
    for name, checksum in SWIFT["sdkFiles"].items():
        if digest(root / name) != checksum:
            raise RuntimeError(f"Swift SDK checksum mismatch: {name}")
    runtime = root / f"swift-resources/usr/lib/swift-{ARCHITECTURES[abi]}/android"
    for name, checksum in SWIFT["runtime"][abi].items():
        if digest(runtime / name) != checksum:
            raise RuntimeError(f"Swift runtime checksum mismatch: {abi}/{name}")
    if sdk_resource_fingerprint(abi) != SWIFT["sdkResources"][abi]:
        raise RuntimeError(f"Swift SDK module/header checksum mismatch: {abi}")


def provenance(abi):
    return {
        "version": VERSION,
        "sdk": SDK,
        "minimumAPI": MINIMUM_API,
        "toolchain": fingerprint(SWIFT),
        "sources": source_fingerprint(),
        "runtimeInputs": SWIFT["runtime"][abi],
    }


def stage_licenses(destination):
    for name, record in SWIFT["licenses"].items():
        target = destination / name
        if not target.is_file() or digest(target) != record["sha256"]:
            data = urllib.request.urlopen(record["url"], timeout=30).read()
            if hashlib.sha256(data).hexdigest() != record["sha256"]:
                raise RuntimeError(f"Swift license checksum mismatch: {name}")
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)


def sdk_root():
    base = Path(os.environ.get("MPVUI_SWIFT_SDKS", Path.home() / "Library/org.swift.swiftpm/swift-sdks"))
    if not base.is_dir():
        base = Path.home() / ".swiftpm/swift-sdks"
    return base / f"{SDK}.artifactbundle/swift-android"


def native_paths(abi):
    arch = ARCHITECTURES[abi]
    android_sdk = Path(os.environ.get("ANDROID_HOME", Path.home() / "Library/Android/sdk"))
    lock = inputs_for(load(ROOT), "android")
    ndk = Path(os.environ.get("ANDROID_NDK_HOME", android_sdk / "ndk" / lock["toolchain"]["ndk"]))
    toolchain = next((ndk / "toolchains/llvm/prebuilt").iterdir())
    prefix = ROOT / ".build/android/upstream/buildscripts/prefix" / ("arm64" if arch == "aarch64" else arch)
    return android_sdk, toolchain, prefix


def elf_symbols(toolchain, library):
    """Return exported symbols and strong imports, without ELF version suffixes."""
    symbols = subprocess.check_output([toolchain / "bin/llvm-readelf", "--dyn-syms", "--wide", library], text=True)
    exports, imports = set(), set()
    for line in symbols.splitlines():
        fields = line.split()
        if len(fields) < 8 or not fields[0].endswith(":") or fields[4] not in {"GLOBAL", "WEAK"}:
            continue
        name = fields[7].split("@", 1)[0]
        if fields[6] != "UND":
            exports.add(name)
        elif fields[4] == "GLOBAL":
            imports.add(name)
    return exports, imports


def validate_api_symbols(abi, libraries):
    """Require every strong import to exist in the closure or minimum-API NDK stubs."""
    _, toolchain, _ = native_paths(abi)
    system = toolchain / f"sysroot/usr/lib/{ARCHITECTURES[abi]}-linux-android/{MINIMUM_API}"
    exports, imports = set(), {}
    for library in libraries:
        provided, required = elf_symbols(toolchain, library)
        exports.update(provided)
        imports[library.name] = required
    for name in SYSTEM_LIBRARIES:
        stub = system / name
        if stub.is_file():
            exports.update(elf_symbols(toolchain, stub)[0])
    for name, required in imports.items():
        missing = required - exports
        if missing:
            raise RuntimeError(f"{abi}/{name} imports symbols unavailable at API {MINIMUM_API}: {', '.join(sorted(missing))}")


def stage_dependencies(abi, binaries, destination):
    """Stage the transitive ELF dependency closure, rejecting incomplete or unaligned inputs."""
    arch = ARCHITECTURES[abi]
    _, toolchain, prefix = native_paths(abi)
    runtime = sdk_root() / f"swift-resources/usr/lib/swift-{arch}/android"
    search = [*(path.parent for path in binaries), runtime, prefix / "lib", toolchain / f"sysroot/usr/lib/{arch}-linux-android"]
    pending, copied = list(binaries), set()
    destination.mkdir(parents=True, exist_ok=True)
    while pending:
        source = pending.pop()
        if source.name in copied:
            continue
        copied.add(source.name)
        identity = subprocess.check_output([toolchain / "bin/llvm-readelf", "-h", "-n", source], text=True)
        machine = "AArch64" if abi == "arm64-v8a" else "Advanced Micro Devices X86-64"
        if not re.search(r"Machine:\s+" + re.escape(machine) + r"\s*$", identity, re.M):
            raise RuntimeError(f"Wrong ELF architecture for {abi}: {source}")
        note = re.search(r"NT_ANDROID_TYPE_IDENT\s+description data: ((?:[0-9a-f]{2} ){3}[0-9a-f]{2})", identity)
        if note and int.from_bytes(bytes.fromhex(note[1]), "little") > MINIMUM_API:
            raise RuntimeError(f"{source} requires a newer Android API than {MINIMUM_API}")
        headers = subprocess.check_output([toolchain / "bin/llvm-readelf", "-lW", source], text=True)
        for line in headers.splitlines():
            if line.strip().startswith("LOAD") and int(line.split()[-1], 16) < 16384:
                raise RuntimeError(f"{source} is not 16 KB page compatible")
        target = destination / source.name
        if source.resolve() != target.resolve():
            shutil.copy2(source, target)
        dynamic = subprocess.check_output([toolchain / "bin/llvm-readelf", "-dW", source], text=True)
        for name in re.findall(r"\(NEEDED\).*\[([^]]+)\]", dynamic):
            if name in SYSTEM_LIBRARIES or name in copied:
                continue
            dependency = next((folder / name for folder in search if (folder / name).is_file()), None)
            if dependency is None:
                raise RuntimeError(f"Missing runtime dependency {name} required by {source.name}")
            pending.append(dependency)
    validate_api_symbols(abi, [destination / name for name in copied])
    return copied


def device_abi(device):
    if not device:
        raise ValueError("Select the connected Android test device with --device SERIAL")
    adb = Path(os.environ.get("ANDROID_HOME", Path.home() / "Library/Android/sdk")) / "platform-tools/adb"
    return subprocess.check_output([adb, "-s", device, "shell", "getprop", "ro.product.cpu.abi"], text=True).strip()


def execute_tests(abi, device):
    android_sdk, _, _ = native_paths(abi)
    adb = android_sdk / "platform-tools/adb"
    architecture = device_abi(device)
    if architecture != abi:
        raise ValueError(f"Device {device} runs {architecture}, but tests were built for {abi}")
    products = ROOT / ".build/android/swift" / abi / f"out/Products/Release-android-{ARCHITECTURES[abi]}"
    runners = [path for pattern in ("*.xctest", "*-test-runner") for path in products.rglob(pattern) if path.is_file()]
    if not runners:
        raise RuntimeError(f"No Android test executables in {products}")
    with tempfile.TemporaryDirectory(prefix="mpvui-core-") as directory:
        staging = Path(directory)
        stage_dependencies(abi, runners, staging)
        remote = "/data/local/tmp/" + staging.name
        try:
            subprocess.run([adb, "-s", device, "push", str(staging), remote], check=True)
            for runner in runners:
                subprocess.run([adb, "-s", device, "shell", f"chmod 700 {remote}/{runner.name}"], check=True)
                subprocess.run(
                    [adb, "-s", device, "shell", f"LD_LIBRARY_PATH={remote} {remote}/{runner.name} --testing-library swift-testing"],
                    check=True,
                )
        finally:
            subprocess.run([adb, "-s", device, "shell", "rm", "-rf", remote], check=True)
    publish_evidence(summary={"androidABI": abi, "androidDevice": device})


def compiler():
    candidates = [
        os.environ.get("MPVUI_SWIFT"),
        str(Path.home() / f"Library/Developer/Toolchains/swift-{VERSION}-RELEASE.xctoolchain/usr/bin/swift"),
        shutil.which("swift"),
    ]
    for candidate in candidates:
        if not candidate or not Path(candidate).is_file():
            continue
        version = subprocess.check_output([candidate, "--version"], text=True)
        if f"swift-{VERSION}-RELEASE" in version:
            return candidate
    raise RuntimeError(f"Install the Swift {VERSION} release compiler or set MPVUI_SWIFT to its swift executable")


def build(abi, *, product=None, tests=False):
    validate_toolchain(abi)
    arch = ARCHITECTURES[abi]
    prefix = ROOT / ".build/android/upstream/buildscripts/prefix" / ("arm64" if arch == "aarch64" else arch)
    if not (prefix / "include/mpv/client.h").is_file():
        raise RuntimeError(f"Build the native {abi} inputs first with make build PLATFORM=android")
    command = [
        compiler(),
        "build",
        "--package-path",
        str(ROOT),
        "--scratch-path",
        str(ROOT / ".build/android/swift" / abi),
        "--swift-sdk",
        SDK,
        "--triple",
        f"{arch}-unknown-linux-android{MINIMUM_API}",
        "-c",
        "release",
        *(["--build-tests"] if tests else ["--product" if product else "--target", product or "MPVCore"]),
        "-Xcc",
        f"-I{prefix / 'include'}",
        "-Xlinker",
        f"-L{prefix / 'lib'}",
    ]
    subprocess.run(command, cwd=ROOT, env=dict(os.environ, TARGET_OS_ANDROID="1"), check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--abi", choices=ARCHITECTURES, action="append", help="Defaults to every ABI, or the device ABI with --test")
    parser.add_argument("--test", action="store_true")
    parser.add_argument("--device")
    args = parser.parse_args()
    abis = args.abi or ([device_abi(args.device)] if args.test else list(ARCHITECTURES))
    if not set(abis) <= ARCHITECTURES.keys():
        parser.error(f"Unsupported device ABI: {', '.join(abis)}")
    for abi in abis:
        build(abi, product="MPVCoreAndroid", tests=args.test)
        if args.test:
            execute_tests(abi, args.device)


if __name__ == "__main__":
    main()
