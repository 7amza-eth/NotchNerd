//
//  NotchModStore.swift
//  NotchNerd
//
//  Finds notch mods and remembers which are on. Mods come from two places:
//    ~/Library/Application Support/NotchNerd/Mods/<id>/   installed (the directory installs here)
//    any folder added with "Load mod from folder…"        developer mode; reloads live as you edit
//  A developer folder wins over an installed mod with the same id. Each mod's saved data lives
//  apart from its code, in ModData/<id>/data.json, so reinstalling or editing keeps it.
//

import AppKit
import Defaults
import Foundation

struct NotchMod: Identifiable, Equatable {
    let manifest: NotchModManifest
    let folder: URL
    /// Loaded from a developer folder rather than installed.
    let isDevelopment: Bool

    var id: String { manifest.id }
}

/// A folder that has a notch-mod.json we couldn't use.
struct NotchModLoadError: Identifiable, Equatable {
    let folder: URL
    let message: String
    var id: String { folder.path }
}

@MainActor
final class NotchModStore: ObservableObject {
    static let shared = NotchModStore()

    @Published private(set) var mods: [NotchMod] = []
    @Published private(set) var loadErrors: [NotchModLoadError] = []
    /// Bumped per mod when a developer folder changes on disk; tab views reload on change.
    @Published private(set) var revisions: [String: Int] = [:]

    private let fm = FileManager.default

    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchNerd", isDirectory: true)
    }
    static var installedDirectory: URL { supportDirectory.appendingPathComponent("Mods", isDirectory: true) }
    static var dataDirectory: URL { supportDirectory.appendingPathComponent("ModData", isDirectory: true) }

    private init() {
        reload()
    }

    // MARK: Reading

    var enabledTabMods: [NotchMod] {
        let enabled = Set(Defaults[.notchModsEnabled])
        return mods.filter { enabled.contains($0.id) && $0.manifest.surfaces.tab != nil && isCompatible($0) }
    }

    func mod(id: String) -> NotchMod? { mods.first { $0.id == id } }

    func isEnabled(_ mod: NotchMod) -> Bool { Defaults[.notchModsEnabled].contains(mod.id) }

    /// False when the mod needs a newer NotchNerd than this one. Developer folders are exempt:
    /// they're usually written against the app version that hasn't shipped yet.
    func isCompatible(_ mod: NotchMod) -> Bool {
        guard !mod.isDevelopment, let needed = mod.manifest.minAppVersion,
              let current = Bundle.main.releaseVersionNumber else { return true }
        return !ModCatalogStore.isVersion(needed, newerThan: current)
    }

    /// Re-scans both sources. Cheap: a handful of small JSON files.
    func reload() {
        var found: [String: NotchMod] = [:]
        var errors: [NotchModLoadError] = []

        let installed = (try? fm.contentsOfDirectory(at: Self.installedDirectory, includingPropertiesForKeys: nil)) ?? []
        for folder in installed where folder.hasDirectoryPath {
            switch load(folder, isDevelopment: false) {
            case .success(let mod): found[mod.id] = mod
            case .failure(let error): errors.append(NotchModLoadError(folder: folder, message: error.localizedDescription))
            case nil: break
            }
        }
        for path in Defaults[.notchModDevelopmentFolders] {
            let folder = URL(fileURLWithPath: path, isDirectory: true)
            switch load(folder, isDevelopment: true) {
            case .success(let mod): found[mod.id] = mod
            case .failure(let error): errors.append(NotchModLoadError(folder: folder, message: error.localizedDescription))
            case nil: errors.append(NotchModLoadError(folder: folder, message: "No \(NotchModManifest.fileName) in this folder."))
            }
        }

        mods = found.values.sorted { $0.manifest.name.localizedCaseInsensitiveCompare($1.manifest.name) == .orderedAscending }
        loadErrors = errors
        leaveTabIfGone()
        updateWatching()
    }

    /// nil when the folder has no manifest at all.
    private func load(_ folder: URL, isDevelopment: Bool) -> Result<NotchMod, Error>? {
        let manifestURL = folder.appendingPathComponent(NotchModManifest.fileName)
        guard let data = try? Data(contentsOf: manifestURL) else { return nil }
        do {
            let manifest = try JSONDecoder().decode(NotchModManifest.self, from: data)
            try manifest.validate()
            return .success(NotchMod(manifest: manifest, folder: folder.standardizedFileURL, isDevelopment: isDevelopment))
        } catch let error as DecodingError {
            return .failure(NSError(domain: "NotchMod", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "\(NotchModManifest.fileName) is invalid: \(Self.describe(error))",
            ]))
        } catch {
            return .failure(error)
        }
    }

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, _): return "missing \"\(key.stringValue)\"."
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            return "wrong type at \"\(context.codingPath.map(\.stringValue).joined(separator: "."))\"."
        case .dataCorrupted(let context): return context.debugDescription
        @unknown default: return error.localizedDescription
        }
    }

    // MARK: Changing

    func setEnabled(_ enabled: Bool, _ mod: NotchMod) {
        var ids = Defaults[.notchModsEnabled]
        ids.removeAll { $0 == mod.id }
        if enabled { ids.append(mod.id) }
        Defaults[.notchModsEnabled] = ids
        objectWillChange.send()
        leaveTabIfGone()
        updateWatching()
    }

    /// Asks for a folder and loads it as a developer mod, turned on.
    func addDevelopmentFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Load Mod"
        panel.message = "Choose a folder that contains \(NotchModManifest.fileName)."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let folder = panel.url?.standardizedFileURL else { return }

        var folders = Defaults[.notchModDevelopmentFolders]
        if !folders.contains(folder.path) { folders.append(folder.path) }
        Defaults[.notchModDevelopmentFolders] = folders
        reload()
        if let mod = mods.first(where: { $0.folder == folder }) { setEnabled(true, mod) }
    }

    func removeDevelopmentFolder(_ folder: URL) {
        Defaults[.notchModDevelopmentFolders].removeAll { $0 == folder.standardizedFileURL.path }
        reload()
    }

    /// Deletes an installed mod's files. Its saved data (ModData/<id>/) stays, so reinstalling keeps it.
    func uninstall(_ mod: NotchMod) {
        guard !mod.isDevelopment else { return }
        if isEnabled(mod) { setEnabled(false, mod) }
        try? fm.removeItem(at: mod.folder)
        reload()
    }

    func reveal(_ mod: NotchMod) {
        NSWorkspace.shared.activateFileViewerSelecting([mod.folder.appendingPathComponent(NotchModManifest.fileName)])
    }

    /// Reloads a mod's open tab (and re-reads its manifest).
    func refresh(_ mod: NotchMod) {
        reload()
        revisions[mod.id, default: 0] += 1
    }

    /// If the open tab's mod was turned off or removed, fall back to Home.
    private func leaveTabIfGone() {
        let coordinator = NotchNerdViewCoordinator.shared
        if case .mod(let id) = coordinator.currentView, !enabledTabMods.contains(where: { $0.id == id }) {
            coordinator.currentView = .home
        }
    }

    // MARK: Live reload (developer folders only)

    private var watchTimer: Timer?
    private var stamps: [String: Date?] = [:]

    /// While any developer mod is turned on, checks its folder once a second and reloads it (tab
    /// page and logic) when a file changes. Nothing runs when no developer mod is on, so installed
    /// mods never cost a timer.
    func updateWatching() {
        let enabled = Set(Defaults[.notchModsEnabled])
        let watched = mods.filter { $0.isDevelopment && enabled.contains($0.id) }
        if watched.isEmpty {
            watchTimer?.invalidate()
            watchTimer = nil
            stamps = [:]
            return
        }
        for mod in watched where stamps[mod.id] == nil {
            stamps[mod.id] = Self.latestModification(in: mod.folder)
        }
        if watchTimer == nil {
            watchTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.checkWatched() }
            }
        }
    }

    private func checkWatched() {
        let enabled = Set(Defaults[.notchModsEnabled])
        for mod in mods where mod.isDevelopment && enabled.contains(mod.id) {
            let stamp = Self.latestModification(in: mod.folder)
            if let previous = stamps[mod.id], previous == stamp { continue }
            let isFirstLook = stamps[mod.id] == nil
            stamps[mod.id] = stamp
            if !isFirstLook { refresh(mod) }
        }
    }

    private static func latestModification(in folder: URL) -> Date? {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys,
                                                           options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        var latest: Date?
        var count = 0
        for case let url as URL in walker {
            count += 1
            if count > 2000 { break }   // someone pointed us at a huge folder; don't spin
            if url.lastPathComponent == "node_modules" { walker.skipDescendants(); continue }
            guard let date = try? url.resourceValues(forKeys: Set(keys)).contentModificationDate else { continue }
            if latest == nil || date > latest! { latest = date }
        }
        return latest
    }
}
