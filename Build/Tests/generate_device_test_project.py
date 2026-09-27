#!/usr/bin/env python3
"""Generate a real iOS test bundle for the package without editing its manifest."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys


SCHEME = "MPVUIRegressionTests"
HOST_TARGET = "MPVUITestHost"
HOST_SOURCE = """import SwiftUI
import UIKit

@main
struct MPVUITestHost: App {
    @Environment(\\.scenePhase) private var scenePhase
    @State private var priorIdleTimerDisabled: Bool?

    var body: some Scene {
        WindowGroup {
            Color.black.ignoresSafeArea()
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active {
                if priorIdleTimerDisabled == nil {
                    priorIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
                }
                UIApplication.shared.isIdleTimerDisabled = true
            } else if let previous = priorIdleTimerDisabled {
                UIApplication.shared.isIdleTimerDisabled = previous
                priorIdleTimerDisabled = nil
            }
        }
    }
}
"""
BUNDLE_ACCESSOR = """import Foundation
private final class MPVTestBundleToken {}
extension Bundle {
    static let module = Bundle(for: MPVTestBundleToken.self)
}
"""


def project_spec(repository: Path, output: Path, team: str | None) -> dict:
    signing = {
        "CODE_SIGNING_ALLOWED[sdk=iphonesimulator*]": "NO",
        "CODE_SIGNING_ALLOWED[sdk=iphoneos*]": "YES" if team else "NO",
    }
    if team:
        signing.update({"CODE_SIGN_STYLE": "Automatic", "DEVELOPMENT_TEAM": team})
    return {
        "name": SCHEME,
        "packages": {"MPVUI": {"path": str(repository)}},
        "settings": {
            "base": {
                "SWIFT_VERSION": "6.0",
                "ENABLE_TESTABILITY": "YES",
                "IPHONEOS_DEPLOYMENT_TARGET": "18.0",
            }
        },
        "targets": {
            HOST_TARGET: {
                "type": "application",
                "platform": "iOS",
                "sources": [{"path": str(output / "TestHost.swift")}],
                "info": {
                    "path": str(output / "TestHost-Info.plist"),
                    "properties": {
                        "NSLocalNetworkUsageDescription": "Connect to a local media server for playback regression tests.",
                        "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True},
                    },
                },
                "settings": {
                    "base": {
                        "PRODUCT_BUNDLE_IDENTIFIER": "com.lepips.MPVUIRegressionTests.Host",
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "INFOPLIST_KEY_UILaunchScreen_Generation": "YES",
                        "INFOPLIST_KEY_UIApplicationSceneManifest_Generation": "YES",
                        "INFOPLIST_KEY_UISupportedInterfaceOrientations": (
                            "UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown "
                            "UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight"
                        ),
                        "TARGETED_DEVICE_FAMILY": "1,2",
                        **signing,
                    }
                },
            },
            "MPVUITests": {
                "type": "bundle.unit-test",
                "platform": "iOS",
                "sources": [
                    {"path": str(repository / "Tests")},
                    {"path": str(output / "TestBundle.swift")},
                    {"path": str(output / "GeneratedMedia"), "buildPhase": "resources"},
                ],
                "dependencies": [{"target": HOST_TARGET}, {"package": "MPVUI"}],
                "settings": {
                    "base": {
                        "PRODUCT_BUNDLE_IDENTIFIER": "com.lepips.MPVUIRegressionTests.Tests",
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "TEST_HOST": f"$(BUILT_PRODUCTS_DIR)/{HOST_TARGET}.app/{HOST_TARGET}",
                        "BUNDLE_LOADER": "$(TEST_HOST)",
                        **signing,
                    }
                },
            },
        },
        "schemes": {
            SCHEME: {
                "build": {"targets": {HOST_TARGET: ["test"], "MPVUITests": ["test"]}},
                "test": {"targets": ["MPVUITests"], "parallelizable": False},
            }
        },
    }


def generate(repository: Path, output: Path, team: str | None = None) -> Path:
    repository, output = repository.resolve(), output.resolve()
    generated_root = repository / ".build"
    if output == generated_root or not output.is_relative_to(generated_root):
        raise ValueError("Output must be a subdirectory of the repository's .build directory")
    if not (repository / "Package.swift").is_file() or not (repository / "Tests").is_dir():
        raise ValueError("Repository must contain Package.swift and Tests")
    if team and not re.fullmatch(r"[A-Z0-9]{10}", team):
        raise ValueError("Development team must be the 10-character Apple team identifier")
    xcodegen = shutil.which("xcodegen")
    if not xcodegen:
        raise RuntimeError("XcodeGen is required; install it with brew install xcodegen")
    output.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        [
            sys.executable,
            str(repository / "Build/Tests/prepare_test_media.py"),
            "--output",
            str(output / "GeneratedMedia"),
        ],
        check=True,
    )
    (output / "TestBundle.swift").write_text(BUNDLE_ACCESSOR)
    (output / "TestHost.swift").write_text(HOST_SOURCE)
    spec = output / "project.json"
    spec.write_text(json.dumps(project_spec(repository, output, team), indent=2) + "\n")
    subprocess.run([xcodegen, "generate", "--spec", str(spec), "--project", str(output)], check=True)
    return output / f"{SCHEME}.xcodeproj"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--output", type=Path, help="Build-owned output; default: .build/device-tests")
    parser.add_argument("--team", help="Apple development team; required for signed physical-device runs")
    args = parser.parse_args()
    repository = args.repository.resolve()
    output = (args.output or repository / ".build/device-tests").resolve()
    try:
        project = generate(repository, output, args.team)
    except (ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"{error}\n")
    print(
        json.dumps(
            {
                "project": str(project),
                "scheme": SCHEME,
                "derivedData": str(output / "DerivedData"),
                "physicalDeviceSigning": bool(args.team),
            },
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
