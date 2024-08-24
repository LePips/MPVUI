//
//  File.swift
//  
//
//  Created by Ethan Pippin on 5/28/24.
//

import Foundation
import MPVKit

public enum LogLevel: String {
    
    case fatal
    case error
    case warn
    case info
    case v
    case debug
    case trace
}

struct LogMessage: CustomStringConvertible {
    
    let prefix: String
    let level: LogLevel
    let text: String
    
    var description: String {
        "\(level.rawValue.uppercased()) - \(prefix) - \(text)"
    }
}
