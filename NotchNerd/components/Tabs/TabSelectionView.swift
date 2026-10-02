//
//  TabSelectionView.swift
//  NotchNerd
//
//  Created by Hugo Persson on 2024-08-25.
//

import Defaults
import SwiftUI

struct TabModel: Identifiable {
    let id = UUID()
    let label: String
    let icon: String
    let view: NotchViews
}

let tabs = [
    TabModel(label: "Home", icon: "house.fill", view: .home),
    TabModel(label: "Shelf", icon: "tray.fill", view: .shelf)
]

struct TabSelectionView: View {
    @ObservedObject var coordinator = NotchNerdViewCoordinator.shared
    @Default(.agentPanelEnabled) var agentPanelEnabled
    @Default(.notepadTabEnabled) var notepadTabEnabled
    @Default(.notchModsEnabled) var notchModsEnabled
    @ObservedObject var notchMods = NotchModStore.shared
    @Namespace var animation
    private var displayedTabs: [TabModel] {
        var result = tabs
        if agentPanelEnabled { result.append(TabModel(label: "Agent", icon: "sparkles", view: .agent)) }
        if notepadTabEnabled { result.append(TabModel(label: "Notes", icon: "note.text", view: .notepad)) }
        _ = notchModsEnabled   // re-render when mods are turned on or off
        for mod in notchMods.enabledTabMods {
            let icon = mod.manifest.surfaces.tab?.icon.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil ? $0 : nil }
            result.append(TabModel(label: mod.manifest.surfaces.tab?.title ?? mod.manifest.name,
                                   icon: icon ?? "puzzlepiece.extension", view: .mod(mod.id)))
        }
        return result
    }
    var body: some View {
        HStack(spacing: 0) {
            ForEach(displayedTabs) { tab in
                    TabButton(label: tab.label, icon: tab.icon, selected: coordinator.currentView == tab.view) {
                        withAnimation(.smooth) {
                            coordinator.currentView = tab.view
                        }
                    }
                    .frame(height: 26)
                    .foregroundStyle(tab.view == coordinator.currentView ? .white : .gray)
                    .background {
                        if tab.view == coordinator.currentView {
                            Capsule()
                                .fill(coordinator.currentView == tab.view ? Color(nsColor: .secondarySystemFill) : Color.clear)
                                .matchedGeometryEffect(id: "capsule", in: animation)
                        } else {
                            Capsule()
                                .fill(coordinator.currentView == tab.view ? Color(nsColor: .secondarySystemFill) : Color.clear)
                                .matchedGeometryEffect(id: "capsule", in: animation)
                                .hidden()
                        }
                    }
            }
        }
        .clipShape(Capsule())
    }
}

#Preview {
    NotchNerdHeader().environmentObject(NotchNerdViewModel())
}
