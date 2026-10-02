//
//  NotchModTabView.swift
//  NotchNerd
//
//  A notch mod's tab in the open notch. Hosts the mod's page (NotchModWebView) while the tab is
//  on screen. A mod whose manifest sets "keyboard": true gets key focus and keeps the notch open
//  while its tab shows, the same way the Notes tab does.
//

import SwiftUI

struct NotchModTabView: View {
    let modID: String
    @EnvironmentObject var vm: NotchNerdViewModel
    @ObservedObject private var store = NotchModStore.shared

    static func takesKeyboard(_ view: NotchViews) -> Bool {
        guard case .mod(let id) = view else { return false }
        return NotchModStore.shared.mod(id: id)?.manifest.surfaces.tab?.keyboard == true
    }

    var body: some View {
        Group {
            if let mod = store.mod(id: modID) {
                NotchModWebView(mod: mod, revision: store.revisions[mod.id] ?? 0) { vm.close() }
                    .onAppear { appeared(mod) }
                    .onDisappear { disappeared(mod) }
            } else {
                Text("This mod isn't available any more.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 4)
    }

    private func appeared(_ mod: NotchMod) {
        if mod.manifest.surfaces.tab?.keyboard == true {
            NotepadNotchFocus.allowsNotchKey = true
            SharingStateManager.shared.preventNotchClose = true
        }
    }

    private func disappeared(_ mod: NotchMod) {
        if mod.manifest.surfaces.tab?.keyboard == true {
            NotepadNotchFocus.allowsNotchKey = false
            SharingStateManager.shared.preventNotchClose = false
        }
    }
}
