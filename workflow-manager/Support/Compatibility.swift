//
//  Compatibility.swift
//  workflow-manager
//
//  The app runs from macOS 14 Sonoma, so every Intel Mac from 2018 on can use
//  it — the 2019 MacBook Air stops at Sonoma, and most 2019 Intel Macs at
//  Sequoia. It is *designed* on macOS 26, and these wrappers are where a newer
//  API meets an older system: on Tahoe they apply, earlier they fall back to
//  the plain behaviour rather than to a look of our own.
//
//  Anything newer than macOS 14 goes behind `#available` here or at its call
//  site, and the deployment target stays where it is — raising it would quietly
//  drop those Macs again.
//

import SwiftUI

extension View {
    /// Drops the window title from the toolbar (macOS 15+). Earlier, the title
    /// stays — a repeated title is the lesser cost.
    @ViewBuilder
    func hidingToolbarTitle() -> some View {
        if #available(macOS 15, *) {
            toolbar(removing: .title)
        } else {
            self
        }
    }
}
