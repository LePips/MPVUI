//
//  File.swift
//  
//
//  Created by Ethan Pippin on 4/18/24.
//

import Foundation

struct EventObserverKey: Hashable {
    
    /// Name of the observed property
    let name: String
    
    /// The ID
    let id: UInt64
}
