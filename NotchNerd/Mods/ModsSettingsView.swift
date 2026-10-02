//
//  ModsSettingsView.swift
//  NotchNerd
//
//  Settings → Mods. Lists the Claude Code mods in the MK Builds marketplace and installs,
//  updates or removes them through the claude CLI. See ModCatalog.swift.
//

import Defaults
import SwiftUI

struct ModsSettings: View {
    @ObservedObject private var store = ModCatalogStore.shared
    @Default(.modsShowCommunity) private var showCommunity
    @State private var search = ""

    private func matches(_ listing: ModListing) -> Bool {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return [listing.name, listing.id, listing.author, listing.description]
            .contains { $0.localizedCaseInsensitiveContains(query) }
    }

    private var official: [ModListing] { store.listings.filter { $0.isOfficial && matches($0) } }
    private var community: [ModListing] { store.listings.filter { !$0.isOfficial && matches($0) } }

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Claude Code")
                    Spacer()
                    cliStatus
                }
            } header: {
                Text("Claude Code mods")
            } footer: {
                Text("Mods run inside Claude Code sessions, in the terminal or the desktop app's Code tab. Installing here is the same as running `claude plugin install <id>@\(ModCatalogStore.marketplaceName)`. New sessions pick up the change.")
            }

            if !store.installedRemoved.isEmpty {
                Section {
                    ForEach(store.installedRemoved, id: \.id) { mod in
                        RemovedModRow(mod: mod)
                    }
                } header: {
                    Text("Removed from the directory")
                } footer: {
                    Text("These are still installed, but the directory no longer lists them.")
                }
            }

            Section {
                if store.listings.isEmpty {
                    loadingRow
                } else if official.isEmpty {
                    Text("No matches.").foregroundStyle(.secondary)
                } else {
                    ForEach(official) { ModRow(listing: $0) }
                }
            } header: {
                HStack {
                    Text("By MK Builds")
                    Spacer()
                    TextField("Search mods", text: $search, prompt: Text("Search"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                    Button {
                        Task { await store.refresh(force: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .disabled(store.isRefreshing)
                    .help("Refresh")
                }
            }

            Section {
                Defaults.Toggle(key: .modsShowCommunity) { Text("Show community mods") }
                if showCommunity {
                    if community.isEmpty {
                        Text(search.isEmpty ? "No community mods yet. Yours could be the first." : "No matches.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(community) { ModRow(listing: $0) }
                    }
                }
            } header: {
                Text("Community")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Community mods are made by other people. They run code on your Mac as you, inside Claude Code, and are checked automatically and read by a maintainer before they're listed, but that isn't a guarantee. Install only mods you trust.")
                    HStack(spacing: 12) {
                        Link("Submit a mod", destination: ModCatalogStore.submitURL)
                        Link("Browse on GitHub", destination: ModCatalogStore.browseURL)
                    }
                    if let error = store.catalogError, !store.listings.isEmpty {
                        Text(error)
                    }
                }
            }

            NotchModsSection()
        }
        .accentColor(.effectiveAccent)
        .navigationTitle("Mods")
        .task { await store.refresh() }
    }

    @ViewBuilder private var loadingRow: some View {
        HStack {
            if store.isRefreshing {
                ProgressView().controlSize(.small)
                Text("Loading mods…").foregroundStyle(.secondary)
            } else {
                Text(store.catalogError ?? "No mods listed.").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var cliStatus: some View {
        switch store.cli {
        case .unknown:
            ProgressView().controlSize(.small)
        case .missing:
            HStack(spacing: 6) {
                Label("Not found", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Link("Get Claude Code", destination: URL(string: "https://claude.com/claude-code")!)
            }
        case .found(let version, let path):
            Text("\(version)")
                .foregroundStyle(.secondary)
                .help(path)
        }
    }
}

private struct RemovedModRow: View {
    let mod: RemovedMod
    @ObservedObject private var store = ModCatalogStore.shared

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(mod.name ?? mod.id).font(.headline)
                Label(mod.reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                if let message = store.messages[mod.id] {
                    Text(message.text).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let label = store.busy[mod.id] {
                ProgressView().controlSize(.small)
                Text(label).font(.caption).foregroundStyle(.secondary)
            } else {
                Button("Remove") { store.uninstall(id: mod.id) }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ModRow: View {
    let listing: ModListing
    @ObservedObject private var store = ModCatalogStore.shared

    private var status: ModCatalogStore.Status { store.status(of: listing) }
    private var cliReady: Bool { if case .found = store.cli { return true } else { return false } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(listing.name).font(.headline).help(listing.id)
                        if let version = listing.version {
                            Text(version).font(.caption).foregroundStyle(.secondary)
                        }
                        badge
                    }
                    HStack(spacing: 6) {
                        Text("by \(listing.author)")
                        if let stars = listing.stars, stars > 0 {
                            Label("\(stars)", systemImage: "star").labelStyle(.titleAndIcon)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Text(listing.description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                actions
            }
            if let message = store.messages[listing.name] {
                Label(message.text, systemImage: message.isError ? "exclamationmark.triangle.fill" : "info.circle")
                    .font(.caption)
                    .foregroundStyle(message.isError ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var badge: some View {
        switch status {
        case .installed(_, let enabled):
            Text(enabled ? "Installed" : "Disabled")
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(enabled ? Color.green.opacity(0.18) : Color.secondary.opacity(0.18)))
                .foregroundStyle(enabled ? Color.green : Color.secondary)
        case .loadedElsewhere:
            Text("Loaded from a folder")
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.secondary.opacity(0.18)))
                .foregroundStyle(.secondary)
        case .notInstalled:
            EmptyView()
        }
    }

    @ViewBuilder private var actions: some View {
        if let label = store.busy[listing.name] {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
        } else {
            switch status {
            case .notInstalled:
                if listing.isInstallable {
                    Button("Install") { store.install(listing) }
                        .disabled(!cliReady)
                } else {
                    Text("Coming soon")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Listed, but not in the marketplace yet. It appears after the next build or its first release.")
                }
            case .installed(_, let enabled):
                HStack(spacing: 6) {
                    if store.hasUpdate(listing) {
                        Button("Update") { store.update(listing) }
                    }
                    Menu {
                        Button(enabled ? "Disable" : "Enable") { store.setEnabled(!enabled, listing) }
                        Button("Remove", role: .destructive) { store.uninstall(id: listing.id) }
                        if let homepage = listing.homepage {
                            Divider()
                            Button("Open homepage") { NSWorkspace.shared.open(homepage) }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                .disabled(!cliReady)
            case .loadedElsewhere(let id):
                Text(id)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .help("Claude Code loads this mod from a folder (--plugin-dir or CLAUDE_CODE_PLUGIN_DIRS). Stop loading it that way before installing it here, or it will load twice.")
            }
        }
    }
}
