//
//  File.swift
//  
//
//  Created by Ethan Pippin on 4/17/24.
//

import Foundation
import MPVKit

extension MPVClient {
    
    func waitForEvents() {
        eventQueue.async { [weak self] in
            while let mpv = self?.core {
                let event = mpv_wait_event(mpv, 0)!
                
                guard event.pointee.event_id != MPV_EVENT_NONE else { break }
                guard let self else { return }
                
                if let mpvEvent = MPVEvent(event: event.pointee.event_id.rawValue) {
                    
                    eventPublisher.send(mpvEvent)
                    
                    if mpvEvent == .propertyChange, 
                        let name = propertyChangeName(from: event.pointee.data),
                        let observer = eventObservers.firstValue(where: { $0.key.name == name }) {
                        
                        observer.send(())
                    }
                    
                    if mpvEvent == .logMessage {
                        let message = UnsafeMutablePointer<mpv_event_log_message>(OpaquePointer(event.pointee.data))!
                        let prefix = String(cString: message.pointee.prefix)
                        let level = LogLevel(rawValue: String(cString: message.pointee.level)) ?? .debug
                        let text = String(cString: message.pointee.text)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        
                        let logMessage = LogMessage(
                            prefix: prefix,
                            level: level,
                            text: text
                        )
                        
                        print(logMessage)
                    }
                }
            }
        }
    }
    
    private func propertyChangeName(from data: UnsafeMutableRawPointer!) -> String? {
        let opaquePointer = OpaquePointer(data)
        
        if let property = UnsafePointer<mpv_event_property>(opaquePointer)?.pointee {
            let propertyName = String(cString: property.name)
            return propertyName
        } else {
            return nil
        }
    }
}
