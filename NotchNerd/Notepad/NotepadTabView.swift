//
//  NotepadTabView.swift
//  NotchNerd
//
//  The notepad as an in-notch tab: the notch STAYS OPEN while you use it (we pin it via
//  SharingStateManager.preventNotchClose while this view is on screen), and a pop-out button
//  hands off to the floating NotepadWindowController panel. Both share NotesStore.shared, so the
//  notes + autosave are identical whether you edit inline or in the floating window.
//
//  Text input note: the notch windows are normally non-key (click-through overlays). While this
//  tab is on screen we flip NotepadNotchFocus.allowsNotchKey so the notch window may become key
//  (the .nonactivatingPanel style keeps the app inactive), and we make it key on appear so the
//  TextEditor can receive keystrokes.
//

import AppKit
import SwiftUI

/// Gate read by NotchNerdSkyLightWindow/NotchNerdWindow.canBecomeKey. True only while the in-notch
/// Notepad tab is visible. Main-thread only.
enum NotepadNotchFocus {
    static var allowsNotchKey = false
}

struct NotepadTabView: View {
    @EnvironmentObject var vm: NotchNerdViewModel
    @ObservedObject private var coordinator = NotchNerdViewCoordinator.shared

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "note.text").foregroundStyle(.secondary)
                Text("Notepad").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(action: popOut) {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                }
                .buttonStyle(.plain)
                .help("Pop out to a floating window")
            }
            .padding(.horizontal, 8)

            NotepadView(store: NotesStore.shared, inNotch: true)
        }
        .foregroundStyle(.white)
        .background(NotchKeyMaker())
        .onAppear {
            NotepadNotchFocus.allowsNotchKey = true
            SharingStateManager.shared.preventNotchClose = true
        }
        .onDisappear {
            NotepadNotchFocus.allowsNotchKey = false
            SharingStateManager.shared.preventNotchClose = false
        }
    }

    /// Hand off to the floating notepad window and let the notch collapse.
    private func popOut() {
        NotepadNotchFocus.allowsNotchKey = false
        SharingStateManager.shared.preventNotchClose = false
        NotepadWindowController.shared.show()
        coordinator.currentView = .home
        vm.close()
    }
}

/// Makes the hosting notch window key when the notepad tab appears, so the editor takes focus
/// without the user needing an extra click.
private struct NotchKeyMaker: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            NotepadNotchFocus.allowsNotchKey = true
            view?.window?.makeKey()
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
