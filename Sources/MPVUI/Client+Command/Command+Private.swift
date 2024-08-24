//
//  File.swift
//  
//
//  Created by Ethan Pippin on 4/17/24.
//

import Foundation
import MPVKit

public extension MPVClient {
    
    func _command(_ command: MPVCommand, arguments: String...) throws {
        try self.command(command, arguments: arguments)
    }
    
    private func command(_ command: MPVCommand, arguments: [String]) throws {
        
        var cArguments = arguments
            .prepending(command.rawValue)
            .map(Optional.some)
            .map { $0.flatMap { UnsafePointer<CChar>(strdup($0)) }}
        
        defer {
            for argument in cArguments {
                free(UnsafeMutablePointer(mutating: argument))
            }
        }
        
        let status = mpv_command(core, &cArguments)
        
        if let mpvError = MPVError(status: status) {
            throw mpvError
        }
    }
}
