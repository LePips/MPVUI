//
//  File.swift
//  
//
//  Created by Ethan Pippin on 4/11/24.
//

import Foundation

extension Collection {
    
    func prepending(_ element: Element) -> [Element] {
        [element] + self
    }
}
