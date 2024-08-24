//
//  File.swift
//  
//
//  Created by Ethan Pippin on 4/17/24.
//

import Combine
import Foundation
import MPVKit

// TODO: async gets
// TODO: status checks
// TODO: rest of values

public extension MPVClient {
    
    // MARK: get
    
    func _getBool(property: String) -> Bool {
        var value = false
        
        mpv_get_property(
            core,
            property,
            MPV_FORMAT_FLAG,
            &value
        )
        
        return value
    }
    
    func _getDouble(property: String) -> Double {
        var value = 0.0
        
        mpv_get_property(
            core,
            property,
            MPV_FORMAT_DOUBLE,
            &value
        )
        
        return value
    }
    
    func _getInt(property: String) -> Int {
        var value: Int64 = 0
        
        mpv_get_property(
            core,
            property,
            MPV_FORMAT_INT64,
            &value
        )
        
        return Int(value)
    }
    
    func _getString(property: String) -> String {
        var value = ""
        
        mpv_get_property(
            core,
            property,
            MPV_FORMAT_STRING,
            &value
        )
        
        return value
    }
    
    // MARK: set
    
    func _set(property: String, to value: Bool) throws {
        var value = value ? 1 : 0
        
        let status = mpv_set_property(
            core,
            property,
            MPV_FORMAT_FLAG,
            &value
        )
        
        if let mpvError = MPVError(status: status) {
            throw mpvError
        }
    }
    
    func _set(property: String, to value: Double) throws {
        var value = value
        
        let status = mpv_set_property(
            core,
            property,
            MPV_FORMAT_DOUBLE,
            &value
        )
        
        if let mpvError = MPVError(status: status) {
            throw mpvError
        }
    }
    
    func _set(property: String, to value: String) throws {
        var value = value
        
        let status = mpv_set_property_string(
            core,
            property,
            &value
        )
        
        if let mpvError = MPVError(status: status) {
            throw mpvError
        }
    }
    
    func _asyncSet(property: String, to value: Bool) {
        var value = value ? 1 : 0
        
        mpv_set_property_async(
            core,
            0,
            property,
            MPV_FORMAT_FLAG,
            &value
        )
    }
    
    // MARK: observe
    
    // TODO: currently private until figure out if we can associate types with properties for subject type
    func _observe(property: String, format: mpv_format) throws -> CurrentValueSubject<Void, Never> {
        
        if let currentObserver = eventObservers.firstValue(where: { $0.key.name == property }) {
            return currentObserver
        }
        
        let id = UInt64(abs(UUID().hashValue))
        let key = EventObserverKey(name: property, id: id)
        let subject: CurrentValueSubject<Void, Never> = .init(())
        
        eventObservers[key] = subject
        
        let status = mpv_observe_property(
            core,
            id,
            property,
            format
        )
        
        if let error = MPVError(status: status) {
            throw error
        }
        
        return subject
    }
}
