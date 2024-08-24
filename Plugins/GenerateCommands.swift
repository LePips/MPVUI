import Foundation
import PackagePlugin

@main
struct Plugin: CommandPlugin {
    
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        
        try deleteCommandFile(context: context)
        try downloadSourceFiles(context: context)
        
        let commands = try parseCommands(context: context)
        print(commands)
        
        try makeCommandFile(with: commands, context: context)
        
    }
    
    private func downloadSourceFiles(context: PluginContext) throws {
        try runProcess(
            "curl -fsSl https://raw.githubusercontent.com/mpv-player/mpv/master/player/command.c -o command.c",
            context: context
        )
        
        try runProcess(<#T##commandLine: String##String#>, context: <#T##PluginContext#>)
    }
    
    private func deleteCommandFile(context: PluginContext) throws {
        try runProcess(
            "rm command.c",
            context: context
        )
    }
    
    private func parseCommands(context: PluginContext) throws -> [String] {
        let filePath = context
            .package
            .directory
            .appending(["command.c"])
        
        let contents = try String(contentsOfFile: filePath.string)
        let expectedStart = "const struct mp_cmd_def mp_cmds[] = {"
        
        guard let startRange = contents.range(of: expectedStart) else {
            throw GenerationError("Could not find expected command struct array")
        }
        
        var i = startRange.upperBound
        var count = 1
        
        while count > 0 {
            i = contents.index(after: i)
            let c = contents[i]
            
            if c == "{" {
                count += 1
            } else if c == "}" {
                count -= 1
            }
        }
        
        let structArray = contents[startRange.upperBound ... i]
        let regex = #/{ \"(?<command>[a-z\\-]+)\",.*(?![{]*{)/#
        let matches = structArray.matches(of: regex)
        
        return matches
            .map(\.output.command)
            .map(String.init)
    }
    
    private func makeCommandFile(with commands: [String], context: PluginContext) throws {
        
        let cases = commands
            .map { "\tcase \(splitAndCamelCase(value: $0)) = \"\($0)\""}
            .joined(separator: "\n")
        
        
        var contents = """
        enum MPVCommand: String {
        
        \(cases)
        }
        """
        
        let filePath = context
            .package
            .directory
            .appending(["Sources", "MPVUI", "MPVCommand.swift"])
        
        try contents
            .data(using: .utf8)?
            .write(to: URL(fileURLWithPath: filePath.string))
    }
}
