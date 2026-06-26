//
//  NotepadWindowController.swift
//  boringNotch (NotchNerd)
//
//  Owns the always-open notepad panel's lifecycle. Modeled on
//  SettingsWindowController (singleton + NSWindowController), but CRITICALLY
//  different in activation handling: the notepad must NEVER call
//  setActivationPolicy(.regular) or NSApp.activate — that is what keeps the
//  user's frontmost app in the foreground. Settings flips to .regular on
//  purpose; the notepad must not.
//
//  Created in applicationDidFinishLaunching. Visibility gated by its own Defaults
//  key + a MenuBarExtra item + a KeyboardShortcuts global hotkey — never bound to
//  BoringViewModel.notchState.
//
//  Float-over-fullscreen strategy:
//    GO path      — insert the panel into NotchSpaceManager.shared.notchSpace
//                   (the max-level CGS space). Validate first with the harness.
//    Fallback     — leave the panel OUT of the CGS space; it floats at
//                   level .mainMenu+2 with .canJoinAllSpaces. Selected by the
//                   Defaults[.notepadFloatStrategy] switch so we can ship the
//                   fallback without code changes if the spike says NO-GO.
//

import AppKit
import Combine
import Defaults
import KeyboardShortcuts
import SwiftUI

// MARK: - Defaults keys (add to the app's Defaults.Keys extension)

extension Defaults.Keys {
    /// Whether the notepad panel is currently shown. Persisted so it reopens.
    static let notepadVisible = Key<Bool>("notepadVisible", default: false)
    /// GO vs fallback float strategy (see header). Default .cgsSpace once GO.
    static let notepadFloatStrategy = Key<NotepadFloatStrategy>(
        "notepadFloatStrategy", default: .cgsSpace)
}

enum NotepadFloatStrategy: String, Defaults.Serializable {
    case cgsSpace   // GO: join NotchSpaceManager.shared.notchSpace
    case floating   // NO-GO fallback: high-level floating panel, normal spaces
}

// MARK: - Global hotkey name

extension KeyboardShortcuts.Name {
    static let toggleNotepad = Self("toggleNotepad")
}

// MARK: - Controller

@MainActor
final class NotepadWindowController: NSWindowController, NSWindowDelegate {
    static let shared = NotepadWindowController()

    private var notepadPanel: NotepadPanel { window as! NotepadPanel }
    private var cancellables: Set<AnyCancellable> = []
    private let store = NotesStore.shared

    private static let defaultSize = NSSize(width: 380, height: 300)

    private init() {
        let panel = NotepadPanel(
            contentRect: NSRect(origin: .zero, size: NotepadWindowController.defaultSize),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init(window: panel)
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: NotepadView(store: store))
        panel.identifier = NSUserInterfaceItemIdentifier("NotchNerdNotepadPanel")

        registerHotkey()
        observeScreenChanges()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Show / hide / toggle (the public surface)

    func toggle() { Defaults[.notepadVisible] ? hide() : show() }

    func show() {
        positionNearNotch()
        applyFloatStrategy()
        // orderFrontRegardless + makeKey, but NEVER NSApp.activate: the panel
        // becomes the key window for text without activating the .accessory app.
        notepadPanel.orderFrontRegardless()
        notepadPanel.makeKey()
        Defaults[.notepadVisible] = true
    }

    func hide() {
        // Leave the CGS space so a hidden panel isn't pinned in it.
        NotchSpaceManager.shared.notchSpace.windows.remove(notepadPanel)
        notepadPanel.orderOut(nil)
        Defaults[.notepadVisible] = false
    }

    /// Called from applicationDidFinishLaunching to restore last visibility.
    func restoreIfNeeded() {
        if Defaults[.notepadVisible] { show() }
    }

    // MARK: Float strategy

    private func applyFloatStrategy() {
        switch Defaults[.notepadFloatStrategy] {
        case .cgsSpace:
            notepadPanel.level = .mainMenu + 2
            // GO path: join the same max-level space the notch floats in.
            NotchSpaceManager.shared.notchSpace.windows.insert(notepadPanel)
        case .floating:
            // Fallback: ensure we are NOT in the CGS space; rely on level + flags.
            NotchSpaceManager.shared.notchSpace.windows.remove(notepadPanel)
            notepadPanel.level = .mainMenu + 2
        }
    }

    // MARK: Positioning (mirrors AppDelegate.positionWindow conventions)

    private func positionNearNotch() {
        guard let screen = preferredScreen() else { return }
        let vf = screen.visibleFrame
        let size = notepadPanel.frame.size
        // Top-center, just under the menu bar / notch, offset right of center so
        // it doesn't sit directly under an open notch.
        let origin = NSPoint(
            x: vf.midX - size.width / 2,
            y: vf.maxY - size.height - 6
        )
        notepadPanel.setFrameOrigin(origin)
    }

    private func preferredScreen() -> NSScreen? {
        if let uuid = BoringViewCoordinator.shared.selectedScreenUUID,
           let s = NSScreen.screen(withUUID: uuid) { return s }
        return NSScreen.main ?? NSScreen.screens.first
    }

    private func observeScreenChanges() {
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                guard let self, Defaults[.notepadVisible] else { return }
                self.positionNearNotch()
            }
            .store(in: &cancellables)
    }

    private func registerHotkey() {
        KeyboardShortcuts.onKeyDown(for: .toggleNotepad) { [weak self] in
            self?.toggle()
        }
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()        // treat the red close button as "hide", keep notes alive
        return false  // we manage ordering; do not destroy the panel
    }

    // No windowDidBecomeKey → setActivationPolicy(.regular) here. That is the
    // whole point: becoming key must NOT activate the app.
}
