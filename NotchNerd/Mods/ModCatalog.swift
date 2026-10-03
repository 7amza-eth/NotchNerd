//
//  ModCatalog.swift
//  NotchNerd
//
//  Settings → Mods: the open directory of Claude Code mods at github.com/mkbuilds4/mods, modelled
//  on Obsidian's community plugins. The registry repo holds the list (community-mods.json), a
//  removed list, stats, and a Claude Code marketplace generated from the list with every mod
//  pinned to its latest GitHub release. Installing goes through the claude CLI, exactly as
//  `claude plugin install <id>@mkbuilds` would; NotchNerd never edits Claude Code's plugin files.
//
//  Never removes the marketplace: Claude Code deletes every one of its plugins' saved options
//  (prayer-times' location, say) along with it.
//

import AppKit
import Foundation

/// One mod in the directory.
struct ModListing: Identifiable, Equatable {
    let id: String
    let name: String
    let author: String
    let description: String
    /// `owner/repo` on GitHub, when known.
    let repo: String?
    let version: String?
    let homepage: URL?
    let stars: Int?
    /// Published by MK Builds (the registry's own owners) rather than the community.
    let isOfficial: Bool
    /// In the generated marketplace, so `claude plugin install` can find it.
    let isInstallable: Bool
    /// The Claude Code marketplace it installs from: the directory's, or one the user added.
    var marketplace: String = ModCatalogStore.marketplaceName

    /// What `claude plugin …` calls it, and the key for its busy state and messages.
    var pluginID: String { "\(id)@\(marketplace)" }
}

/// A mod taken out of the directory (`community-mods-removed.json`).
struct RemovedMod: Decodable, Equatable {
    let id: String
    let name: String?
    let reason: String
}

/// A plugin Claude Code reports as installed (`claude plugin list --json`).
struct InstalledClaudePlugin: Decodable, Equatable {
    let id: String
    let version: String?
    let enabled: Bool?
    let scope: String?

    var name: String { String(id.split(separator: "@", maxSplits: 1).first ?? Substring(id)) }
    var marketplace: String? { id.split(separator: "@", maxSplits: 1).dropFirst().first.map(String.init) }
}

/// The registry's files, decoded. Field names match the JSON in github.com/mkbuilds4/mods.
private enum Registry {
    struct Entry: Decodable {
        let id: String
        let name: String
        let author: String
        let description: String
        let repo: String
        let path: String?
    }

    struct Marketplace: Decodable {
        struct Plugin: Decodable {
            struct Author: Decodable { let name: String? }
            let name: String
            let description: String?
            let version: String?
            let homepage: String?
            let author: Author?
        }
        let plugins: [Plugin]
    }

    struct Stats: Decodable {
        let stars: Int?
    }

    /// GitHub owners whose mods count as official.
    static let officialOwners: Set<String> = ["mkbuilds4", "7amza-eth"]

    /// Merges the list with the generated marketplace. Before the list exists (or if it fails to
    /// load) the marketplace alone is used, and everything in it is treated as official.
    static func listings(entries: [Entry]?, marketplace: Marketplace, stats: [String: Stats]) -> [ModListing] {
        let published = Dictionary(marketplace.plugins.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        guard let entries else {
            return marketplace.plugins.map { plugin in
                ModListing(id: plugin.name, name: plugin.name, author: plugin.author?.name ?? "MK Builds",
                           description: plugin.description ?? "", repo: nil, version: plugin.version,
                           homepage: plugin.homepage.flatMap(URL.init(string:)), stars: stats[plugin.name]?.stars,
                           isOfficial: true, isInstallable: true)
            }
        }
        return entries.map { entry in
            let plugin = published[entry.id]
            let owner = entry.repo.split(separator: "/").first.map { $0.lowercased() } ?? ""
            let fallbackHome = URL(string: "https://github.com/\(entry.repo)" + (entry.path.map { "/tree/HEAD/\($0)" } ?? ""))
            return ModListing(
                id: entry.id, name: entry.name, author: entry.author, description: entry.description,
                repo: entry.repo, version: plugin?.version,
                homepage: plugin?.homepage.flatMap(URL.init(string:)) ?? fallbackHome,
                stars: stats[entry.id]?.stars, isOfficial: officialOwners.contains(owner),
                isInstallable: plugin != nil)
        }
    }
}

@MainActor
final class ModCatalogStore: ObservableObject {
    static let shared = ModCatalogStore()

    static let marketplaceName = "mkbuilds"
    static let marketplaceRepo = "mkbuilds4/mods"
    /// The registry's raw files. `NOTCHNERD_MODS_REGISTRY` points it at a branch's raw URL or a
    /// local checkout instead, for testing registry changes before they merge.
    static let registryURL: URL = {
        if let override = ProcessInfo.processInfo.environment["NOTCHNERD_MODS_REGISTRY"], !override.isEmpty {
            if override.hasPrefix("/") { return URL(fileURLWithPath: override, isDirectory: true) }
            if let url = URL(string: override.hasSuffix("/") ? override : override + "/") { return url }
        }
        return URL(string: "https://raw.githubusercontent.com/mkbuilds4/mods/main/")!
    }()
    /// The marketplace NotchNerd writes for mods added from a link (AddedMods.swift).
    static let addedMarketplaceName = "notchnerd-added"
    static let browseURL = URL(string: "https://github.com/mkbuilds4/mods")!
    static let submitURL = URL(string: "https://github.com/mkbuilds4/mods/blob/main/CONTRIBUTING.md")!

    enum CLIState: Equatable {
        case unknown
        case missing
        case found(version: String, path: String)
    }

    enum Status: Equatable {
        case notInstalled
        /// Installed from this marketplace.
        case installed(version: String?, enabled: Bool)
        /// Loaded some other way, e.g. a folder via `--plugin-dir` / `CLAUDE_CODE_PLUGIN_DIRS` (`name@inline`).
        case loadedElsewhere(id: String)
    }

    @Published private(set) var listings: [ModListing] = []
    /// Mod id → why it was taken out of the directory.
    @Published private(set) var removed: [String: RemovedMod] = [:]
    @Published private(set) var installed: [InstalledClaudePlugin] = []
    @Published private(set) var cli: CLIState = .unknown
    @Published private(set) var isRefreshing = false
    @Published private(set) var catalogError: String?
    /// Whether the mkbuilds marketplace is already added to Claude Code.
    @Published private(set) var marketplaceAdded = false
    /// Plugin id (`name@marketplace`) → the operation running on it ("Installing…").
    @Published private(set) var busy: [String: String] = [:]
    /// Plugin id → the last CLI message for it (success notes and errors alike).
    @Published private(set) var messages: [String: Message] = [:]
    /// Mods the user added from a link, plus every mod in marketplaces they added that way.
    @Published var addedListings: [ModListing] = []
    /// The link being looked up or added ("Looking up…"), if any.
    @Published var addProgress: String?
    @Published var addMessage: Message?
    /// A looked-up link waiting for the user to confirm.
    @Published var pendingAdd: PendingModAdd?

    struct Message: Equatable {
        let text: String
        let isError: Bool
    }

    struct MarketplaceEntry: Decodable {
        let name: String
        let installLocation: String?
    }

    private var lastRefresh: Date?
    /// Marketplaces Claude Code has, from the last refresh.
    var knownMarketplaces: [MarketplaceEntry] = []

    private init() {}

    // MARK: Reading

    /// Re-reads the catalog and what's installed. Skips if it ran in the last 30s unless forced.
    func refresh(force: Bool = false) async {
        if isRefreshing { return }
        if !force, let lastRefresh, Date().timeIntervalSince(lastRefresh) < 30 { return }
        isRefreshing = true
        defer {
            isRefreshing = false
            lastRefresh = Date()
        }

        async let remote = Self.loadRegistry(from: Self.registryURL)
        await refreshCLIState()
        var localClone: MarketplaceEntry?
        if case .found = cli {
            async let installedPlugins = Self.loadInstalled()
            async let marketplaces = Self.loadMarketplaces()
            let known = try? await marketplaces
            localClone = known?.first { $0.name == Self.marketplaceName }
            marketplaceAdded = localClone != nil
            if let known { knownMarketplaces = known }
            installed = (try? await installedPlugins) ?? installed
        } else {
            installed = []
        }
        addedListings = loadAddedListings()

        do {
            apply(try await remote)
        } catch {
            // Offline: fall back to Claude Code's own clone of the registry repo, if it has one.
            if let path = localClone?.installLocation,
               let registry = try? await Self.loadRegistry(from: URL(fileURLWithPath: path, isDirectory: true)) {
                apply(registry)
            } else if listings.isEmpty {
                catalogError = "Couldn't load the mod list: \(error.localizedDescription)"
            }
        }
    }

    private func apply(_ registry: (listings: [ModListing], removed: [RemovedMod])) {
        listings = registry.listings
        removed = Dictionary(registry.removed.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        catalogError = nil
    }

    /// Installed mods from this marketplace that have since been taken out of the directory.
    var installedRemoved: [RemovedMod] {
        installed.filter { $0.marketplace == Self.marketplaceName }.compactMap { removed[$0.name] }
    }

    func status(of listing: ModListing) -> Status {
        let matches = installed.filter { $0.name == listing.id }
        if let ours = matches.first(where: { $0.marketplace == listing.marketplace }) {
            return .installed(version: ours.version, enabled: ours.enabled ?? true)
        }
        if let other = matches.first { return .loadedElsewhere(id: other.id) }
        return .notInstalled
    }

    /// True when the catalog lists a newer version than the installed one.
    func hasUpdate(_ listing: ModListing) -> Bool {
        guard case .installed(let version?, _) = status(of: listing), let latest = listing.version else { return false }
        return Self.isVersion(latest, newerThan: version)
    }

    // MARK: Changing

    func install(_ listing: ModListing) {
        perform(listing.pluginID, label: "Installing…") {
            try await self.ensureMarketplace(listing.marketplace)
            return try await Self.runJSON(["plugin", "install", listing.pluginID, "--json"])
        }
    }

    func update(_ listing: ModListing) {
        perform(listing.pluginID, label: "Updating…") {
            try await self.ensureMarketplace(listing.marketplace)
            return try await Self.runJSON(["plugin", "update", listing.pluginID, "--json"])
        }
    }

    /// Uninstalls but keeps the plugin's data folder (prayer-times' tracker, say), so reinstalling
    /// restores it. A mod added from a link also leaves NotchNerd's marketplace.
    func uninstall(pluginID: String) {
        perform(pluginID, label: "Removing…") {
            let note = try await Self.runJSON(["plugin", "uninstall", pluginID, "--keep-data", "--json"])
            try await self.forgetAddedEntry(pluginID: pluginID)
            return note
        }
    }

    /// Drops a link-added mod that never installed (or was removed elsewhere) from NotchNerd's marketplace.
    func forget(_ listing: ModListing) {
        perform(listing.pluginID, label: "Removing…") {
            try await self.forgetAddedEntry(pluginID: listing.pluginID)
            return nil
        }
    }

    func setEnabled(_ enabled: Bool, _ listing: ModListing) {
        perform(listing.pluginID, label: enabled ? "Enabling…" : "Disabling…") {
            try await Self.runJSON(["plugin", enabled ? "enable" : "disable", listing.pluginID])
        }
    }

    /// Adds the marketplace if Claude Code doesn't have it yet, otherwise pulls its latest list,
    /// so a mod published since the last update can be found.
    func ensureMarketplace(_ name: String) async throws {
        switch name {
        case Self.marketplaceName:
            if marketplaceAdded {
                _ = try await Self.runJSON(["plugin", "marketplace", "update", name])
            } else {
                _ = try await Self.runJSON(["plugin", "marketplace", "add", Self.marketplaceRepo])
                marketplaceAdded = true
            }
        case Self.addedMarketplaceName where !knownMarketplaces.contains(where: { $0.name == name }):
            _ = try await Self.runJSON(["plugin", "marketplace", "add", AddedMods.marketplaceDirectory.path, "--json"])
            knownMarketplaces = (try? await Self.loadMarketplaces()) ?? knownMarketplaces
        default:
            _ = try await Self.runJSON(["plugin", "marketplace", "update", name])
        }
    }

    private func perform(_ id: String, label: String, _ operation: @escaping () async throws -> String?) {
        guard busy[id] == nil else { return }
        busy[id] = label
        messages[id] = nil
        Task {
            do {
                let note = try await operation()
                messages[id] = note.map { Message(text: $0, isError: false) }
            } catch {
                messages[id] = Message(text: error.localizedDescription, isError: true)
            }
            busy[id] = nil
            await refresh(force: true)
        }
    }

    // MARK: CLI plumbing

    private struct CommandError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Runs a claude command and returns anything worth showing beyond "it worked" (e.g. options
    /// still to set). Throws with the CLI's own message when it fails.
    static func runJSON(_ arguments: [String]) async throws -> String? {
        let output = try await ClaudeCLI.run(arguments)
        let result = output.resultLine
        let message = (result?["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let failed = output.status != 0 || (result?["outcome"] as? String).map { $0 != "ok" } ?? false
        if failed {
            let text = message ?? lastLine(output.stderr) ?? lastLine(output.stdoutText)
                ?? "claude exited with status \(output.status)."
            throw CommandError(message: text)
        }
        // The first line just restates success; keep follow-up notes like unset options.
        guard let message else { return nil }
        let notes = message.split(separator: "\n").dropFirst().joined(separator: "\n")
        return notes.isEmpty ? nil : notes
    }

    private static func lastLine(_ text: String) -> String? {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty }
    }

    private func refreshCLIState() async {
        guard let output = try? await ClaudeCLI.run(["--version"], timeout: 20), output.status == 0,
              let path = ClaudeCLI.locate()?.path else {
            cli = .missing
            return
        }
        let version = output.stdoutText.split(separator: " ").first.map(String.init) ?? "?"
        cli = .found(version: version, path: path)
    }

    private static func loadInstalled() async throws -> [InstalledClaudePlugin] {
        let output = try await ClaudeCLI.run(["plugin", "list", "--json"], timeout: 60)
        return try JSONDecoder().decode([InstalledClaudePlugin].self, from: output.stdout)
    }

    static func loadMarketplaces() async throws -> [MarketplaceEntry] {
        let output = try await ClaudeCLI.run(["plugin", "marketplace", "list", "--json"], timeout: 60)
        return try JSONDecoder().decode([MarketplaceEntry].self, from: output.stdout)
    }

    /// Reads the registry from the repo's raw URL, or from a local clone of it. The list and the
    /// marketplace are required; the removed list and stats are optional.
    private static func loadRegistry(from base: URL) async throws -> (listings: [ModListing], removed: [RemovedMod]) {
        async let marketplaceData = read(".claude-plugin/marketplace.json", from: base)
        async let entriesData = try? read("community-mods.json", from: base)
        async let removedData = try? read("community-mods-removed.json", from: base)
        async let statsData = try? read("community-mod-stats.json", from: base)

        let decoder = JSONDecoder()
        let marketplace = try decoder.decode(Registry.Marketplace.self, from: try await marketplaceData)
        let entries = await entriesData.flatMap { try? decoder.decode([Registry.Entry].self, from: $0) }
        let removed = await removedData.flatMap { try? decoder.decode([RemovedMod].self, from: $0) } ?? []
        let stats = await statsData.flatMap { try? decoder.decode([String: Registry.Stats].self, from: $0) } ?? [:]
        let removedIDs = Set(removed.map(\.id))
        let listings = Registry.listings(entries: entries, marketplace: marketplace, stats: stats)
            .filter { !removedIDs.contains($0.id) }
        return (listings, removed)
    }

    private static func read(_ path: String, from base: URL) async throws -> Data {
        let url = base.appendingPathComponent(path)
        if url.isFileURL { return try Data(contentsOf: url) }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw URLError(.badServerResponse)
        }
        return data
    }

    /// Compares dotted numeric versions (1.10.0 > 1.9.2). Anything else (a git sha) never counts as newer.
    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        func parts(_ version: String) -> [Int]? {
            let pieces = version.split(separator: ".").map { Int($0) }
            return pieces.contains(nil) || pieces.isEmpty ? nil : pieces.compactMap { $0 }
        }
        guard let a = parts(candidate), let b = parts(current) else { return false }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
