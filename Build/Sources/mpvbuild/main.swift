import Foundation
import MPVBuildCore

do { try CLI.run(Array(CommandLine.arguments.dropFirst())) }
catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
