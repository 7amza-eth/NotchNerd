//
//  Constants.swift
//  NotchNerd
//
//  Created by Richard Kunkli on 16/08/2024.
//

import KeyboardShortcuts
import SwiftUI

extension KeyboardShortcuts.Name {
    static let toggleSneakPeek = Self("toggleSneakPeek", default: .init(.h, modifiers: [.command, .shift]))
    static let toggleNotchOpen = Self("toggleNotchOpen", default: .init(.i, modifiers: [.command, .shift]))
    // Agent: ⌃⌥⌘ chords so the global defaults don't steal common app shortcuts.
    static let toggleAgentTab = Self("toggleAgentTab", default: .init(.a, modifiers: [.control, .option, .command]))
    static let jumpToNextWaitingAgent = Self("jumpToNextWaitingAgent", default: .init(.j, modifiers: [.control, .option, .command]))
}
