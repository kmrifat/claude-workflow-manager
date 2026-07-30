//
//  Item.swift
//  workflow-manager
//
//  Created by rifat on 31/7/26.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
