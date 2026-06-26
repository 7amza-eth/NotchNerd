//
//  NotepadPanel.swift
//  NotchNerd (NotchNerd)
//
//  An independent, key-capable, non-activating panel for the always-open
//  notepad. This is NOT one of the click-through notch panels — it is the one
//  window in the app that is *allowed* to take keyboard focus.
//
//  The proven combo for taking text focus from an .accessory (LSUIElement) app
//  WITHOUT flipping the app to .regular or stealing the user's frontmost app:
//      styleMask contains .nonactivatingPanel   (clicking does not activate us)
//      override canBecomeKey = true             (but we can still be the key window)
//
//  Contrast with NotchNerdWindow / NotchNerdSkyLightWindow, which hard-code
//  canBecomeKey=false (they are passive overlays). Do NOT reuse those here.
//

import Cocoa

final class NotepadPanel: NSPanel {
    override init(
        contentRect: NSRect,
        styleMask: NSWindow.StyleMask,
        backing: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        // .nonactivatingPanel is the load-bearing flag. .titled/.closable give a
        // draggable chrome; .resizable + .fullSizeContentView keep it compact.
        var mask = styleMask
        mask.insert(.nonactivatingPanel)

        super.init(
            contentRect: contentRect,
            styleMask: mask,
            backing: backing,
            defer: flag
        )

        isFloatingPanel = true
        // Become key (and thus take text focus) when the user clicks the editor,
        // not merely by existing — keeps interaction explicit.
        becomesKeyOnlyIfNeeded = false
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false

        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true

        // Appear over fullscreen spaces and on every space. When the panel is
        // also inserted into the notch CGS space (see NotepadWindowController),
        // the space's absolute level dominates; these flags are the fallback
        // behavior and keep it sane on normal spaces.
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]

        // Fallback float level (used when NOT joined to the CGS space).
        level = .mainMenu + 2
    }

    // THE override that distinguishes the notepad from every other notch panel.
    override var canBecomeKey: Bool { true }

    // Stay a panel, never the app's "main" window — avoids pulling main-window
    // semantics / document proxy behavior into an .accessory app.
    override var canBecomeMain: Bool { false }
}
