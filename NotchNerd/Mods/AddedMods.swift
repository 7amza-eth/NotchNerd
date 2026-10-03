//
//  AddedMods.swift
//  NotchNerd
//
//  Settings → Mods → "Add a mod": install a mod from a link (a GitHub repo, a folder in one, or any
//  git URL) without the directory listing it and without loading a folder.
//
//  The link is shallow-cloned and looked at in this order:
//    notch-mod.json               a notch mod (runs inside NotchNerd): copied into Mods/<id>/ and
//                                 switched on. Adding the same link again updates it.
//    .claude-plugin/plugin.json   a Claude Code mod, installed as below
//    .claude-plugin/marketplace.json  a Claude Code marketplace, added and its mods listed
//
//  Claude Code only installs plugins from marketplaces, so NotchNerd keeps its own small one,
//  `notchnerd-added`, in Application Support. Adding a link shallow-clones it to read its
//  `.claude-plugin/plugin.json`, asks the user to confirm, writes an entry pointing at the repo, and
//  installs `<name>@notchnerd-added` through the CLI, so it updates and uninstalls like any other.
//  A link that is itself a marketplace (`.claude-plugin/marketplace.json`) is added as one, and its
//  mods are listed for install. Like the directory, this never removes a marketplace.
//

import Defaults
import Foundation

/// A link the user pasted, parsed.
struct ModLink: Equatable {
    /// What git clones.
    let cloneURL: String
    /// `owner/repo` when it's on GitHub.
    let githubRepo: String?
    /// Branch or tag from a `/tree/<ref>/…` link.
    let ref: String?
    /// The mod's folder inside the repo, from a `/tree/<ref>/<path>` link.
    let path: String?

    var display: String {
        let base = githubRepo ?? cloneURL
        return [base, ref.map { "@\($0)" }, path.map { "/\($0)" }].compactMap { $0 }.joined()
    }

    /// Accepts `owner/repo`, `github.com/owner/repo[/tree/<ref>[/<path>]]`, or any https/ssh git URL.
    static func parse(_ raw: String) -> ModLink? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard !text.isEmpty, !text.contains(" ") else { return nil }

        func github(_ owner: String, _ repo: String, ref: String? = nil, path: String? = nil) -> ModLink? {
            let repo = repo.hasSuffix(".git") ? String(repo.dropLast(4)) : repo
            guard isSafeName(owner), isSafeName(repo) else { return nil }
            return ModLink(cloneURL: "https://github.com/\(owner)/\(repo).git", githubRepo: "\(owner)/\(repo)",
                           ref: ref, path: path)
        }

        let pieces = text.split(separator: "/").map(String.init)
        if pieces.count == 2, !text.contains(":"), !text.hasPrefix(".") {
            return github(pieces[0], pieces[1])
        }

        var githubPath = text
        for prefix in ["https://", "http://"] where githubPath.hasPrefix(prefix) { githubPath.removeFirst(prefix.count) }
        if githubPath.hasPrefix("www.") { githubPath.removeFirst(4) }
        if githubPath.hasPrefix("github.com/") {
            let parts = githubPath.dropFirst("github.com/".count).split(separator: "/").map(String.init)
            guard parts.count >= 2 else { return nil }
            if parts.count >= 4, parts[2] == "tree" {
                let path = parts.dropFirst(4).joined(separator: "/")
                guard path.split(separator: "/").allSatisfy({ $0 != ".." }) else { return nil }
                return github(parts[0], parts[1], ref: parts[3], path: path.isEmpty ? nil : path)
            }
            return parts.count == 2 ? github(parts[0], parts[1]) : nil
        }

        if ["https://", "http://", "ssh://", "git@"].contains(where: text.hasPrefix) {
            return ModLink(cloneURL: text, githubRepo: nil, ref: nil, path: nil)
        }
        return nil
    }

    /// Plugin, repo and marketplace names: no paths, no leading dot or dash.
    static func isSafeName(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil
    }

    /// The marketplace entry's `source` for a mod at this link.
    var pluginSource: [String: Any] {
        var source: [String: Any]
        if let path {
            source = ["source": "git-subdir", "url": cloneURL, "path": path]
        } else if let githubRepo {
            source = ["source": "github", "repo": githubRepo]
        } else {
            source = ["source": "url", "url": cloneURL]
        }
        if let ref { source["ref"] = ref }
        return source
    }
}

/// A looked-up link the user still has to confirm.
struct PendingModAdd: Equatable {
    enum Kind: Equatable {
        /// One mod; installs as `<name>@notchnerd-added`.
        case mod(name: String, description: String?, author: String?, version: String?)
        /// A marketplace; `argument` is what `claude plugin marketplace add` takes.
        case marketplace(name: String, argument: String, plugins: [String])
        /// A notch mod, checked and copied to `staged`, waiting to be moved into Mods/<id>/.
        /// `replaces` is the installed version it would update, if any.
        case notchMod(manifest: NotchModManifest, staged: URL, replaces: String?)
    }

    let link: ModLink
    let kind: Kind
}

/// NotchNerd's own marketplace file for mods added from a link.
enum AddedMods {
    /// Not under Mods/: that folder holds installed notch mods, one per id.
    static let marketplaceDirectory: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("NotchNerd/ClaudeMods/added", isDirectory: true)

    /// Notch mods are a few web files; anything bigger is likely the wrong folder.
    static let maxNotchModBytes = 25 * 1024 * 1024

    private static var manifestURL: URL {
        marketplaceDirectory.appendingPathComponent(".claude-plugin/marketplace.json")
    }

    /// The plugin entries, as written (unknown fields kept).
    static func entries() -> [[String: Any]] {
        guard let data = try? Data(contentsOf: manifestURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return object["plugins"] as? [[String: Any]] ?? []
    }

    /// Adds the entry, replacing one with the same name.
    static func upsert(name: String, link: ModLink, description: String?, author: String?) throws {
        var entry: [String: Any] = ["name": name, "source": link.pluginSource]
        if let description, !description.isEmpty { entry["description"] = description }
        if let author, !author.isEmpty { entry["author"] = ["name": author] }
        if let repo = link.githubRepo {
            let tree = link.path.map { "/tree/\(link.ref ?? "HEAD")/\($0)" } ?? link.ref.map { "/tree/\($0)" } ?? ""
            entry["homepage"] = "https://github.com/\(repo)\(tree)"
        }
        try write(entries().filter { $0["name"] as? String != name } + [entry])
    }

    static func remove(name: String) throws {
        let current = entries()
        let kept = current.filter { $0["name"] as? String != name }
        if kept.count != current.count { try write(kept) }
    }

    private static func write(_ plugins: [[String: Any]]) throws {
        let manifest: [String: Any] = [
            "name": ModCatalogStore.addedMarketplaceName,
            "owner": ["name": NSFullUserName().isEmpty ? "You" : NSFullUserName()],
            "description": "Mods added from a link in NotchNerd (Settings → Mods).",
            "plugins": plugins,
        ]
        try FileManager.default.createDirectory(at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: manifestURL, options: .atomic)
    }

    /// The plugin entries of a marketplace checkout or folder.
    static func marketplacePlugins(at directory: URL) -> [(name: String, description: String?, author: String?, homepage: String?)] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(".claude-plugin/marketplace.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plugins = object["plugins"] as? [[String: Any]] else { return [] }
        return plugins.compactMap { plugin in
            guard let name = plugin["name"] as? String else { return nil }
            return (name, plugin["description"] as? String,
                    (plugin["author"] as? [String: Any])?["name"] as? String, plugin["homepage"] as? String)
        }
    }
}

private struct PluginManifest: Decodable {
    struct Author: Decodable { let name: String? }
    let name: String
    let description: String?
    let version: String?
    let author: Author?
}

private struct MarketplaceManifest: Decodable {
    struct Plugin: Decodable { let name: String }
    let name: String
    let plugins: [Plugin]
}

private struct AddError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

extension ModCatalogStore {
    /// Fetches the link and, if it holds a mod or a marketplace, sets `pendingAdd` for the user to confirm.
    func lookUp(_ input: String) {
        guard addProgress == nil else { return }
        addMessage = nil
        cancelAdd()
        guard let link = ModLink.parse(input) else {
            addMessage = Message(text: "Paste a GitHub repo (owner/repo), a link to a folder in one, or a git URL.", isError: true)
            return
        }
        addProgress = "Looking up \(link.display)…"
        Task {
            do {
                pendingAdd = try await resolve(link)
            } catch {
                addMessage = Message(text: error.localizedDescription, isError: true)
            }
            addProgress = nil
        }
    }

    private func resolve(_ link: ModLink) async throws -> PendingModAdd {
        let checkout = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchnerd-mod-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: checkout) }

        var arguments = ["clone", "--depth", "1", "--quiet"]
        if let ref = link.ref { arguments += ["--branch", ref] }
        arguments += ["--", link.cloneURL, checkout.path]
        let output = try await ClaudeCLI.runTool("git", arguments)
        if output.status != 0 {
            let reason = output.stderr.split(separator: "\n").last.map(String.init) ?? "git exited with status \(output.status)."
            throw AddError(message: "Couldn't fetch \(link.display): \(reason)")
        }

        let base = link.path.map { checkout.appendingPathComponent($0, isDirectory: true) } ?? checkout
        let decoder = JSONDecoder()
        if let data = try? Data(contentsOf: base.appendingPathComponent(NotchModManifest.fileName)) {
            return try stageNotchMod(data, from: base, link: link)
        }
        if let data = try? Data(contentsOf: base.appendingPathComponent(".claude-plugin/plugin.json")) {
            guard let manifest = try? decoder.decode(PluginManifest.self, from: data), ModLink.isSafeName(manifest.name) else {
                throw AddError(message: "Its .claude-plugin/plugin.json has no usable name.")
            }
            if let other = installed.first(where: { $0.name == manifest.name && $0.marketplace != Self.addedMarketplaceName }) {
                throw AddError(message: "\(manifest.name) is already installed as \(other.id). Remove that first, or it will load twice.")
            }
            return PendingModAdd(link: link, kind: .mod(name: manifest.name, description: manifest.description,
                                                        author: manifest.author?.name, version: manifest.version))
        }
        if let data = try? Data(contentsOf: base.appendingPathComponent(".claude-plugin/marketplace.json")),
           let manifest = try? decoder.decode(MarketplaceManifest.self, from: data) {
            if manifest.name == Self.marketplaceName {
                throw AddError(message: "That's the NotchNerd mod directory. Its mods are already listed here.")
            }
            guard link.path == nil, ModLink.isSafeName(manifest.name), manifest.name != Self.addedMarketplaceName else {
                throw AddError(message: "That marketplace can't be added from here. Link to the repository itself.")
            }
            return PendingModAdd(link: link, kind: .marketplace(name: manifest.name,
                                                                argument: link.githubRepo ?? link.cloneURL,
                                                                plugins: manifest.plugins.map(\.name)))
        }
        throw AddError(message: "No mod at \(link.display): there's no notch-mod.json or .claude-plugin/plugin.json there.")
    }

    /// Checks a notch mod's manifest and moves its folder out of the checkout so it survives until
    /// the user confirms. The folder becomes the installed mod as is, minus git metadata.
    private func stageNotchMod(_ data: Data, from base: URL, link: ModLink) throws -> PendingModAdd {
        let manifest: NotchModManifest
        do {
            manifest = try JSONDecoder().decode(NotchModManifest.self, from: data)
            try manifest.validate()
        } catch let error as NotchModManifest.Problem {
            throw AddError(message: "Its notch-mod.json can't be used: \(error.localizedDescription)")
        } catch {
            throw AddError(message: "Its notch-mod.json can't be read.")
        }
        let fm = FileManager.default
        var size = 0
        if let files = fm.enumerator(at: base, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let file as URL in files {
                size += (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            }
        }
        guard size <= AddedMods.maxNotchModBytes else {
            throw AddError(message: "That folder is over 25 MB, too big for a notch mod. Link to the mod's own folder.")
        }
        let staged = fm.temporaryDirectory.appendingPathComponent("notchnerd-notchmod-\(UUID().uuidString)", isDirectory: true)
        try fm.moveItem(at: base, to: staged)
        try? fm.removeItem(at: staged.appendingPathComponent(".git"))
        let installed = NotchModStore.shared.mod(id: manifest.id)
        return PendingModAdd(link: link, kind: .notchMod(manifest: manifest, staged: staged,
                                                          replaces: installed.map { $0.manifest.version }))
    }

    /// Drops a looked-up link without installing it.
    func cancelAdd() {
        if case .notchMod(_, let staged, _) = pendingAdd?.kind { try? FileManager.default.removeItem(at: staged) }
        pendingAdd = nil
    }

    private func installNotchMod(_ manifest: NotchModManifest, from staged: URL) {
        let fm = FileManager.default
        let store = NotchModStore.shared
        let destination = NotchModStore.installedDirectory.appendingPathComponent(manifest.id, isDirectory: true)
        do {
            try fm.createDirectory(at: NotchModStore.installedDirectory, withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: staged)
            } else {
                try fm.moveItem(at: staged, to: destination)
            }
        } catch {
            try? fm.removeItem(at: staged)
            addMessage = Message(text: "Couldn't install \(manifest.name): \(error.localizedDescription)", isError: true)
            return
        }
        store.reload()
        guard let mod = store.mod(id: manifest.id) else { return }
        if mod.isDevelopment {
            addMessage = Message(text: "Installed \(manifest.name), but a developer folder with the same id is loaded and wins.", isError: false)
        } else if !store.isCompatible(mod) {
            addMessage = Message(text: "Installed \(manifest.name). It needs a newer NotchNerd, so it stays off.", isError: false)
        } else {
            if !store.isEnabled(mod) { store.setEnabled(true, mod) }
            addMessage = Message(text: "Installed \(manifest.name) \(manifest.version). It's on: see Notch mods below.", isError: false)
        }
    }

    /// Installs what `pendingAdd` describes.
    func confirmAdd() {
        guard let pending = pendingAdd else { return }
        pendingAdd = nil
        switch pending.kind {
        case .notchMod(let manifest, let staged, _):
            installNotchMod(manifest, from: staged)
        case .mod(let name, let description, let author, _):
            do {
                try AddedMods.upsert(name: name, link: pending.link, description: description, author: author)
            } catch {
                addMessage = Message(text: "Couldn't save the mod's entry: \(error.localizedDescription)", isError: true)
                return
            }
            addedListings = loadAddedListings()
            guard let listing = addedListings.first(where: { $0.pluginID == "\(name)@\(Self.addedMarketplaceName)" }) else { return }
            install(listing)
        case .marketplace(let name, let argument, let plugins):
            addProgress = "Adding \(name)…"
            Task {
                do {
                    if !knownMarketplaces.contains(where: { $0.name == name }) {
                        _ = try await Self.runJSON(["plugin", "marketplace", "add", argument, "--json"])
                    }
                    if !Defaults[.modsAddedMarketplaces].contains(name) { Defaults[.modsAddedMarketplaces].append(name) }
                    if plugins.count == 1 {
                        _ = try await Self.runJSON(["plugin", "install", "\(plugins[0])@\(name)", "--json"])
                    }
                    addMessage = Message(text: plugins.count == 1 ? "Installed \(plugins[0])." : "Added \(name). Install its mods below.", isError: false)
                } catch {
                    addMessage = Message(text: error.localizedDescription, isError: true)
                }
                addProgress = nil
                await refresh(force: true)
            }
        }
    }

    /// Mods in NotchNerd's own marketplace, then every mod in marketplaces the user added from a link.
    func loadAddedListings() -> [ModListing] {
        func listing(_ name: String, _ description: String?, _ author: String?, _ homepage: String?, in marketplace: String) -> ModListing {
            let version = installed.first { $0.name == name && $0.marketplace == marketplace }?.version
            return ModListing(id: name, name: name, author: author ?? "Unknown", description: description ?? "",
                              repo: nil, version: version, homepage: homepage.flatMap(URL.init(string:)), stars: nil,
                              isOfficial: false, isInstallable: true, marketplace: marketplace)
        }
        var result = AddedMods.entries().compactMap { entry -> ModListing? in
            guard let name = entry["name"] as? String else { return nil }
            return listing(name, entry["description"] as? String, (entry["author"] as? [String: Any])?["name"] as? String,
                           entry["homepage"] as? String, in: Self.addedMarketplaceName)
        }
        for name in Defaults[.modsAddedMarketplaces] {
            guard let location = knownMarketplaces.first(where: { $0.name == name })?.installLocation else { continue }
            result += AddedMods.marketplacePlugins(at: URL(fileURLWithPath: location, isDirectory: true))
                .map { listing($0.name, $0.description, $0.author, $0.homepage, in: name) }
        }
        return result
    }

    /// Takes a link-added mod out of NotchNerd's marketplace. Other marketplaces are left alone.
    func forgetAddedEntry(pluginID: String) async throws {
        let parts = pluginID.split(separator: "@", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[1] == Self.addedMarketplaceName else { return }
        try AddedMods.remove(name: parts[0])
        if knownMarketplaces.contains(where: { $0.name == Self.addedMarketplaceName }) {
            _ = try? await Self.runJSON(["plugin", "marketplace", "update", Self.addedMarketplaceName])
        }
    }
}
