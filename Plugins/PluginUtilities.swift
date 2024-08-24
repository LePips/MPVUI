//
//  File.swift
//  
//
//  Created by Ethan Pippin on 4/11/24.
//

import Foundation
import PackagePlugin

struct GenerationError: LocalizedError {
    
    var errorDescription: String?
    
    init(_ message: String) {
        self.errorDescription = message
    }
}

func splitAndCamelCase(value: String) -> String {
    
    var s = value.split(separator: "-")
        .map(String.init)
    
    guard s.count > 1 else { return value }
    
    for i in 1 ..< s.count {
        s[i] = s[i].capitalized
    }
    
    return s.joined()
}

func runProcess(_ commandLine: String, context: PluginContext, workingDirectory: String? = nil) throws {

    var arguments = commandLine.split(separator: " ").map { String($0) }
    let commandName = arguments.removeFirst()

    let command = try context.tool(named: commandName)

    let actualWorkingDirectory: Path

    if let workingDirectory {
        actualWorkingDirectory = context.package.directory.appending(workingDirectory)
    } else {
        actualWorkingDirectory = context.package.directory
    }

    let process = Process()
    process.currentDirectoryURL = URL(fileURLWithPath: actualWorkingDirectory.string)
    process.executableURL = URL(fileURLWithPath: command.path.string)
    process.arguments = arguments

    try process.run()
    process.waitUntilExit()
}
