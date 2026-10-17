#!/usr/bin/env python3
"""Build Skip's native UI against the same Swift core and runtime as the AAR."""

import json
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile

import swift_core


def main():
    command = shlex.split(sys.argv[1])
    archive = Path(command[command.index("-d") + 1])
    for abi, architecture in swift_core.ARCHITECTURES.items():
        arguments = command.copy()
        arguments[arguments.index("--arch") + 1] = architecture
        arguments[arguments.index("--configuration") + 1] = "release"
        _, toolchain, prefix = swift_core.native_paths(abi)
        native = swift_core.ROOT / ".build/android/native"
        manifest = json.loads((native / f"assets/mpvui/build-{abi}.json").read_text())
        if manifest.get("swift", {}).get("sources") != swift_core.source_fingerprint():
            raise ValueError(f"Rebuild {abi} with make build-android before building the example")
        swift_core.validate_toolchain(abi)
        arguments += [
            "--swift-version",
            swift_core.VERSION,
            "--android-api-level",
            str(swift_core.MINIMUM_API),
            "--disable-build-manifest-caching",
            "-Xcc",
            f"-I{prefix / 'include'}",
            "-Xlinker",
            f"-L{prefix / 'lib'}",
        ]
        subprocess.run(arguments, check=True)
        # SwiftPM links the core dynamically. The AAR is its single runtime owner;
        # use its optimized core built from these exact sources and compiler.
        for name in manifest["libraries"]:
            generated = archive / abi / name
            if not generated.exists():
                continue
            packaged = native / "jniLibs" / abi / name
            if name != "libMPVCoreAndroid.so":
                with tempfile.TemporaryDirectory() as directory:
                    stripped = Path(directory) / name
                    subprocess.run([toolchain / "bin/llvm-strip", "--strip-unneeded", generated, "-o", stripped], check=True)
                    if swift_core.digest(stripped) != swift_core.digest(packaged):
                        raise ValueError(f"Conflicting Swift/NDK runtime {abi}/{name}")
            generated.unlink()


if __name__ == "__main__":
    main()
