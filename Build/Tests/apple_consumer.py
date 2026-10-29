#!/usr/bin/env python3
"""Build and run an independent Apple consumer with the currently selected native artifact."""

import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from validation import publish_evidence

ROOT = Path(__file__).resolve().parents[2]


def main():
    package = json.loads(subprocess.check_output(["swift", "package", "--package-path", ROOT, "dump-package"], text=True))
    binary = next(target for target in package["targets"] if target["name"] == "Libmpv-GPL")
    with tempfile.TemporaryDirectory(prefix="mpvui-apple-consumer-") as temporary:
        consumer = Path(temporary)
        library = consumer / "mpvui"
        shutil.copytree(ROOT / "Sources", library / "Sources")
        # Test target directories must exist during manifest validation, but no
        # test sources or repository build caches are dependencies of the app.
        for folder in ("Tests", "Tests/Core"):
            destination = library / folder
            destination.mkdir(parents=True, exist_ok=True)
            (destination / "Placeholder.swift").write_text("import Foundation\n")
        manifest = (ROOT / "Package.swift").read_text()
        if binary.get("path"):
            artifact = (ROOT / binary["path"]).resolve()
            shutil.copytree(artifact, library / "Native/Libmpv.xcframework", symlinks=True)
            manifest = re.sub(
                r"// MPVBUILD_BINARY_TARGETS_BEGIN.*?// MPVBUILD_BINARY_TARGETS_END",
                'private let binaryTargets: [Target] = [.binaryTarget(name: "Libmpv-GPL", path: "Native/Libmpv.xcframework")]',
                manifest,
                flags=re.S,
            )
        (library / "Package.swift").write_text(manifest)
        (consumer / "Package.swift").write_text("""// swift-tools-version: 6.3
import PackageDescription
let package = Package(name: "Consumer", platforms: [.macOS(.v15)],
    dependencies: [.package(path: "mpvui")],
    targets: [.executableTarget(name: "Consumer", dependencies: [.product(name: "MPVUI", package: "mpvui")])])
""")
        source = consumer / "Sources/Consumer"
        source.mkdir(parents=True)
        (source / "Consumer.swift").write_text("""import Foundation
import MPVUI
@main struct Consumer {
    @MainActor static func main() async {
        let configuration = MPVPlayerConfiguration(
            automaticallyPlays: false,
            initialBufferDuration: .seconds(2),
            isLoopingEnabled: true,
            networkCacheDuration: .seconds(8),
            renderingQuality: .init(isDebandingEnabled: true)
        )
        let player = MPVPlayer(configuration: configuration)
        precondition(!player.configuration.automaticallyPlays)
        precondition(player.configuration.isLoopingEnabled)
        precondition(player.configuration.initialBufferDuration == .seconds(2))
        precondition(player.configuration.networkCacheDuration == .seconds(8))
        precondition(player.bufferStatus.bufferedDurationAhead == .zero)
        precondition(player.videoFeatureCapabilities.requestResult(for: [.inlineOverlays]).outcome == .available)
        player.setVolume(25)
        precondition(player.volume == 25)
        precondition(player.state == .idle)
        let error: any Error = MPVPlayerError.clientUnavailable
        precondition((error as? MPVPlayerError)?.message == "mpv is not available.")
        let plan: MPVExternalPlaybackPlan? = player.externalPlayback.preparationPlan
        precondition(plan == nil && !player.externalPlayback.isTranscoding)
        do {
            _ = try await player.externalPlayback.makePreparationPlan()
            preconditionFailure("Unloaded media cannot produce a preparation plan.")
        } catch let failure as MPVPlayerError {
            guard case .externalPlaybackFailed = failure else { preconditionFailure(failure.message) }
        } catch {
            preconditionFailure(String(describing: error))
        }
        print("Independent Apple consumer loaded the shared core and selected native artifact.")
    }
}
""")
        subprocess.run(["swift", "run", "--package-path", consumer, "-c", "release", "Consumer"], check=True)
        publish_evidence(summary={"independentAppleConsumer": "passed", "nativeSelection": binary})


if __name__ == "__main__":
    main()
