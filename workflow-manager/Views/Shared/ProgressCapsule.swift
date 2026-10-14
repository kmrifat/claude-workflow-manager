//
//  ProgressCapsule.swift
//  workflow-manager
//

import SwiftUI

/// Thin progress bar: the Overview, the scope bar, the project sheet.
struct ProgressCapsule: View {
    let progress: Double
    var tint: Color = .accentColor
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(tint)
                    .frame(width: max(0, min(1, progress)) * geometry.size.width)
            }
        }
        .frame(height: height)
    }
}
