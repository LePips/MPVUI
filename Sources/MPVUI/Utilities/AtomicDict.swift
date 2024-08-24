//
//  File.swift
//  
//
//  Created by Ethan Pippin on 4/18/24.
//

import Foundation

// https://www.donnywals.com/why-your-atomic-property-wrapper-doesnt-work-for-collection-types/

class AtomicDict<Key: Hashable, Value>: CustomDebugStringConvertible {
    
    private var dictStorage = [Key: Value]()

    private let queue = DispatchQueue(
        label: "com.mpvui.\(UUID().uuidString)",
        qos: .utility,
        attributes: .concurrent,
        autoreleaseFrequency: .inherit,
        target: .global()
    )

    init() {}

    subscript(key: Key) -> Value? {
        get { queue.sync { dictStorage[key] }}
        set { queue.async(flags: .barrier) { [weak self] in self?.dictStorage[key] = newValue } }
    }

    var debugDescription: String {
        return dictStorage.debugDescription
    }
    
    func firstValue(where predicate: ((key: Key, value: Value)) -> Bool) -> Value? {
        queue.sync { dictStorage.first(where: predicate)?.value }
    }
}
