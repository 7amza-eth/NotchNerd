//
//  NotepadTabView.swift
//  NotchNerd
//
//  The notepad as an in-notch tab: the notch STAYS OPEN while you use it (we pin it via
//  SharingStateManager.preventNotchClose while this view is on screen), and a pop-out button
//  hands off to the floating NotepadWindowController panel. Both share NotesStore.shared, so the
//  notes + autosave are identical whether you edit inline or in the floating window.
//

import SwiftUI

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
        // Keep the notch open while editing inline; release when leaving the tab.
        .onAppear { SharingStateManager.shared.preventNotchClose = true }
        .onDisappear { SharingStateManager.shared.preventNotchClose = false }
    }

    /// Hand off to the floating notepad window and let the notch collapse.
    private func popOut() {
        SharingStateManager.shared.preventNotchClose = false
        NotepadWindowController.shared.show()
        coordinator.currentView = .home
        vm.close()
    }
}
