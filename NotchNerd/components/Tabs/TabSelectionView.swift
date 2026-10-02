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
    /// The header gives the tabs only the space left of the physical notch (NotchNerdHeader). Mod tabs
    /// can push past it and slide under the notch, so pick the first layout that fits: normal spacing,
    /// then tighter, then the built-in tabs plus one menu holding the mod tabs.
    var body: some View {
        let all = displayedTabs
        let builtIn = all.filter { if case .mod = $0.view { return false } else { return true } }
        let mods = all.filter { if case .mod = $0.view { return true } else { return false } }
        ViewThatFits(in: .horizontal) {
            tabBar(all, padding: 15)
            tabBar(all, padding: 10)
            tabBar(all, padding: 6)
            if !mods.isEmpty {
                HStack(spacing: 2) {
                    tabBar(builtIn, padding: 6)
                    modMenu(mods)
                }
            }
        }
    }

    /// Mod tabs folded into one button; it shows the open mod's icon while one is selected.
    private func modMenu(_ mods: [TabModel]) -> some View {
        let selected = mods.first { $0.view == coordinator.currentView }
        return Menu {
            ForEach(mods) { tab in
                Button {
                    withAnimation(.smooth) { coordinator.currentView = tab.view }
                } label: {
                    Label(tab.label, systemImage: tab.icon)
                }
            }
        } label: {
            Image(systemName: selected?.icon ?? "puzzlepiece.extension")
                .padding(.horizontal, 6)
                .frame(height: 26)
                .foregroundStyle(selected != nil ? .white : .gray)
                .background(Capsule().fill(selected != nil ? Color(nsColor: .secondarySystemFill) : .clear))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Mod tabs")
    }

    private func tabBar(_ shown: [TabModel], padding: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(shown) { tab in
                    TabButton(label: tab.label, icon: tab.icon, selected: coordinator.currentView == tab.view,
                              horizontalPadding: padding) {
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
