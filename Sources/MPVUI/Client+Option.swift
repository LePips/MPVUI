//
//  File.swift
//  
//
//  Created by Ethan Pippin on 4/17/24.
//

import Foundation
import MPVKit

public extension MPVClient {
    
    func _set(option: String, to value: Bool) throws {
        var value = value
        let status = mpv_set_option(
            core,
            option,
            MPV_FORMAT_FLAG,
            &value
        )
        
        if let mpvError = MPVError(status: status) {
            throw mpvError
        }
    }
    
    func _set(option: String, to value: String) throws {
        let status = mpv_set_option_string(
            core,
            option,
            value
        )
        
        if let mpvError = MPVError(status: status) {
            throw mpvError
        }
    }
    
    func _set(option: String, to value: UnsafeMutableRawPointer) throws {
        var value = value
        
        let status = mpv_set_option(
            core,
            option,
            MPV_FORMAT_INT64,
            &value
        )
        
        if let mpvError = MPVError(status: status) {
            throw mpvError
        }
    }
}
