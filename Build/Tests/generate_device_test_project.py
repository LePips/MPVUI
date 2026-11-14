#!/usr/bin/env python3
"""Generate an iOS or tvOS test bundle for the package without editing its manifest."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess


SCHEME = "MPVUIRegressionTests"
TEAM_ENVIRONMENT = "MPVUI_DEVELOPMENT_TEAM"
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


def project_spec(repository: Path, output: Path, team: str | None, platform: str = "iOS") -> dict:
    if platform not in ("iOS", "tvOS"):
        raise ValueError("Test platform must be iOS or tvOS")
    television = platform == "tvOS"
    simulator_sdk, device_sdk = ("appletvsimulator", "appletvos") if television else ("iphonesimulator", "iphoneos")
    signing = {
        f"CODE_SIGNING_ALLOWED[sdk={simulator_sdk}*]": "NO",
        f"CODE_SIGNING_ALLOWED[sdk={device_sdk}*]": "YES" if team else "NO",
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
                "TVOS_DEPLOYMENT_TARGET" if television else "IPHONEOS_DEPLOYMENT_TARGET": "18.0",
            }
        },
        "targets": {
            HOST_TARGET: {
                "type": "application",
                "platform": platform,
                "sources": [{"path": str(output / "TestHost.swift")}],
                "info": {
                    "path": str(output / "TestHost-Info.plist"),
                    "properties": {
                        "CADisableMinimumFrameDurationOnPhone": True,
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
                        "TARGETED_DEVICE_FAMILY": "3" if television else "1,2",
                        **signing,
                    }
                },
            },
            "MPVUITests": {
                "type": "bundle.unit-test",
                "platform": platform,
                "sources": [
                    {"path": str(repository / "Tests"), "excludes": ["Core"]},
                    {"path": str(output / "TestBundle.swift")},
                    {"path": str(output / "GeneratedMedia"), "type": "folder", "buildPhase": "resources"},
                ],
                "dependencies": [{"target": HOST_TARGET}, {"package": "MPVUI"}],
                "settings": {
                    "base": {
                        "PRODUCT_BUNDLE_IDENTIFIER": "com.lepips.MPVUIRegressionTests.Tests",
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "TEST_HOST": f"$(BUILT_PRODUCTS_DIR)/{HOST_TARGET}.app/{HOST_TARGET}",
                        "BUNDLE_LOADER": "$(TEST_HOST)",
                        "MPVUI_PACKAGE_ID": repository.name.removesuffix(".git").lower(),
                        "OTHER_SWIFT_FLAGS": "$(inherited) -package-name $(MPVUI_PACKAGE_ID:c99extidentifier)",
                        **signing,
                    }
                },
            },
        },
        "schemes": {
            SCHEME: {
                "build": {"targets": {HOST_TARGET: ["test"], "MPVUITests": ["test"]}},
                "test": {
                    "targets": ["MPVUITests"],
                    "parallelizable": False,
                    "environmentVariables": {
                        "MPVUI_RUN_NATIVE_AUDIO_TESTS": os.environ.get("MPVUI_RUN_NATIVE_AUDIO_TESTS", "0"),
                        **(
                            {"MPVUI_DOLBY_AUDIO_REFERENCE": os.environ["MPVUI_DOLBY_AUDIO_REFERENCE"]}
                            if "MPVUI_DOLBY_AUDIO_REFERENCE" in os.environ
                            else {}
                        ),
                    },
                },
            }
        },
    }


def add_team_argument(parser):
    """Accept the Apple development team as --team, or from MPVUI_DEVELOPMENT_TEAM."""
    parser.add_argument(
        "--team",
        default=os.environ.get(TEAM_ENVIRONMENT),
        help=f"Apple development team for signed physical-device runs. Defaults to {TEAM_ENVIRONMENT}",
    )


def generate(repository: Path, output: Path, team: str | None = None, platform: str = "iOS") -> Path:
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
        raise RuntimeError("XcodeGen is required. Run brew bundle.")
    # A folder reference includes fixtures prepared later by the test runner.
    (output / "GeneratedMedia").mkdir(parents=True, exist_ok=True)
    (output / "TestBundle.swift").write_text(BUNDLE_ACCESSOR)
    (output / "TestHost.swift").write_text(HOST_SOURCE)
    spec = output / "project.json"
    specification = project_spec(repository, output, team, platform)
    environment = specification["schemes"][SCHEME]["test"]["environmentVariables"]
    reference = environment.get("MPVUI_DOLBY_AUDIO_REFERENCE")
    if reference and Path(reference).is_absolute():
        source = Path(reference).resolve()
        if not source.is_file():
            raise ValueError(f"Dolby audio reference does not exist: {source}")
        destination = output / "GeneratedMedia" / f"dolby-audio-reference{source.suffix}"
        if source != destination.resolve():
            shutil.copy2(source, destination)
        environment["MPVUI_DOLBY_AUDIO_REFERENCE"] = destination.name
    spec.write_text(json.dumps(specification, indent=2) + "\n")
    subprocess.run([xcodegen, "generate", "--spec", str(spec), "--project", str(output)], check=True)
    return output / f"{SCHEME}.xcodeproj"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--output", type=Path, help="Build-owned output; default: .build/device-tests")
    parser.add_argument("--os", choices=("iOS", "tvOS"), default="iOS", help="Apple test platform")
    add_team_argument(parser)
    args = parser.parse_args()
    repository = args.repository.resolve()
    output = (args.output or repository / ".build/device-tests").resolve()
    try:
        project = generate(repository, output, args.team, args.os)
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
