import Foundation
import PackagePlugin

@main
struct GenerateTestMedia: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        let script = context.package.directoryURL.appendingPathComponent("Build/Tests/prepare_test_media.py")
        let output = context.pluginWorkDirectoryURL.appendingPathComponent("GeneratedMedia")
        return [.prebuildCommand(
            displayName: "Prepare MPVUI test media",
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["python3", script.path, "--output", output.path],
            outputFilesDirectory: output
        )]
    }
}
