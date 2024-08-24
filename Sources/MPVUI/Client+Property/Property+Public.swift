//
//  File.swift
//  
//
//  Created by Ethan Pippin on 4/17/24.
//

import Foundation
import MPVKit

// MARK: public

// TODO: come up with organization structure

public extension MPVClient {
    
    var isPaused: Bool {
        get {
            _getBool(property: "pause")
        }
        set {
            _asyncSet(property: "pause", to: newValue)
        }
    }
    
    func play() {
        isPaused = false
    }
    
    func pause() {
        isPaused = true
    }
}
