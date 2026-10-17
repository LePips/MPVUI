import Foundation
import MPVBuildCore

do { try CLI.run(Array(CommandLine.arguments.dropFirst())) }
catch {
    let description = (error as? BuildError)?.localizedDescription ?? error.localizedDescription
    FileHandle.standardError.write(Data("error: \(description)\n".utf8))
    exit(1)
}
