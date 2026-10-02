//
//  NotchModsSection.swift
//  NotchNerd
//
//  Settings → Mods → "Notch mods": mods that run inside NotchNerd itself (see NotchModStore).
//  For now they're loaded from a folder; the mod directory will install them too.
//

import Defaults
import SwiftUI

struct NotchModsSection: View {
    @ObservedObject private var store = NotchModStore.shared
    @Default(.notchModsEnabled) private var enabledIDs

    var body: some View {
        Section {
            ForEach(store.mods) { mod in
                NotchModRow(mod: mod, isEnabled: enabledIDs.contains(mod.id))
            }
            ForEach(store.loadErrors) { problem in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(problem.folder.lastPathComponent).font(.headline)
                        Label(problem.message, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Remove") { store.removeDevelopmentFolder(problem.folder) }
                }
            }
            HStack {
                Button("Load mod from folder…") { store.addDevelopmentFolder() }
                Spacer()
                Button {
                    store.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Look for mods again")
            }
        } header: {
            Text("Notch mods")
        } footer: {
            Text("Notch mods add tabs to the notch. They run in a sandbox: their own files, the network hosts they declare, and nothing else on your Mac. A mod loaded from a folder reloads as you edit it; inspect it with Safari → Develop → NotchNerd.")
        }
    }
}

private struct NotchModRow: View {
    let mod: NotchMod
    let isEnabled: Bool
    @ObservedObject private var store = NotchModStore.shared

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(mod.manifest.name).font(.headline).help(mod.id)
                    Text(mod.manifest.version).font(.caption).foregroundStyle(.secondary)
                    if mod.isDevelopment {
                        Text("Developer")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.orange.opacity(0.18)))
                            .foregroundStyle(.orange)
                    }
                }
                if let author = mod.manifest.author {
                    Text("by \(author)").font(.caption).foregroundStyle(.secondary)
                }
                if let description = mod.manifest.description {
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !mod.manifest.networkHosts.isEmpty {
                    Label("Connects to \(mod.manifest.networkHosts.joined(separator: ", "))", systemImage: "network")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !store.isCompatible(mod), let needed = mod.manifest.minAppVersion {
                    Label("Needs NotchNerd \(needed) or later", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(get: { isEnabled }, set: { store.setEnabled($0, mod) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(!store.isCompatible(mod))
            Menu {
                Button("Reload") { store.refresh(mod) }
                Button("Show in Finder") { store.reveal(mod) }
                if mod.isDevelopment {
                    Divider()
                    Button("Stop loading this folder", role: .destructive) { store.removeDevelopmentFolder(mod.folder) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 4)
    }
}
