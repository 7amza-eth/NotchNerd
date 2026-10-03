//
//  NotchModsSection.swift
//  NotchNerd
//
//  Settings → Mods → "Notch mods": mods that run inside NotchNerd itself (see NotchModStore).
//  Installed from a link (Settings → Mods → Add a mod, AddedMods.swift) or loaded from a folder.
//

import Defaults
import SwiftUI

struct NotchModsSection: View {
    @ObservedObject private var store = NotchModStore.shared
    @Default(.notchModsEnabled) private var enabledIDs
    @Default(.notchModChipID) private var chipID

    /// Enabled mods that may show a closed-notch chip.
    private var chipMods: [NotchMod] {
        store.mods.filter { enabledIDs.contains($0.id) && $0.manifest.surfaces.closed != nil }
    }

    var body: some View {
        Section {
            ForEach(store.mods) { mod in
                NotchModRow(mod: mod, isEnabled: enabledIDs.contains(mod.id))
            }
            if chipMods.count > 1 {
                Picker("Closed notch shows", selection: $chipID) {
                    Text("First mod with something to show").tag("")
                    ForEach(chipMods) { mod in
                        Text(mod.manifest.name).tag(mod.id)
                    }
                }
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
            Text("Notch mods add tabs and a status chip to the notch. They run in a sandbox: their own files, the network hosts they declare, and only the data you see listed under each one. A mod loaded from a folder reloads as you edit it; inspect its tab with Safari → Develop → NotchNerd, and see its logs in Console.app under mod.<id>.")
        }
    }
}

private struct NotchModRow: View {
    let mod: NotchMod
    let isEnabled: Bool
    @ObservedObject private var store = NotchModStore.shared
    @ObservedObject private var runtimes = NotchModRuntimeManager.shared

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
                ForEach(mod.manifest.declaredPermissions, id: \.self) { permission in
                    Label(permission.summary, systemImage: "checkmark.shield")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !mod.manifest.networkHosts.isEmpty {
                    Label("Connects to \(mod.manifest.networkHosts.joined(separator: ", "))", systemImage: "network")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if isEnabled, let error = runtimes.errors[mod.id] {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(4)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
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
                Divider()
                if mod.isDevelopment {
                    Button("Stop loading this folder", role: .destructive) { store.removeDevelopmentFolder(mod.folder) }
                } else {
                    Button("Uninstall", role: .destructive) { store.uninstall(mod) }
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
