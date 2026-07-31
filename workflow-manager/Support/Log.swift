//
//  Log.swift
//  workflow-manager
//

import OSLog

nonisolated enum Log {
    /// Drag and drop is the one path where a failure is otherwise completely
    /// silent — a rejected drop just looks like "nothing happened".
    static let dragAndDrop = Logger(
        subsystem: "com.binarycastle.workflow-manager",
        category: "dnd"
    )
}
