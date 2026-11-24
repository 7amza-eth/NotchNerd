//
//  ProjectParking.swift
//  NotchNerd
//
//  Storage offloading for code: "parks" projects nobody has touched in a while by deleting the
//  folders that an install or build brings back (node_modules, .next, .turbo, Pods, .build, …).
//  Source, .git, env files and local dev state (.wrangler) are never touched. Each park is
//  recorded in ~/Library/Application Support/NotchNerd/parked-projects.json, nothing is written
//  into the repo, and Wake runs the recorded install commands in a login shell.
//
//  A project is idle when no file outside those folders changed in `storageIdleDays` days and no
//  running process has its working directory inside it (a dev server, an agent, a shell).
//

import AppKit
import Defaults
import Foundation

struct IdleProject: Identifiable, Equatable {
    var id: String { path }
    let path: String
    let removable: [String]      // absolute paths that parking deletes
    let bytes: Int64
    let lastTouched: Date?
    let inUse: Bool
    let restore: [String]        // shell commands, run from `path`

    var name: String { (path as NSString).lastPathComponent }
    /// The folder it lives in, minus the leading dot ("move-agent-worktrees"); empty for ~/Projects.
    var rootLabel: String {
        let parent = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        if parent == "Projects" { return "" }
        return parent.hasPrefix(".") ? String(parent.dropFirst()) : parent
    }
}

struct ParkedProject: Codable, Identifiable, Equatable {
    var id: String { path }
    let path: String
    let parkedAt: Date
    let bytes: Int64
    let removed: [String]        // relative to path
    let restore: [String]

    var name: String { (path as NSString).lastPathComponent }
}

@MainActor
final class ProjectParking: ObservableObject {
    static let shared = ProjectParking()

    @Published private(set) var idle: [IdleProject] = []
    @Published private(set) var parked: [ParkedProject] = []
    @Published private(set) var scanning = false
    @Published private(set) var busy: Set<String> = []   // paths being parked or woken
    @Published var lastResult: String?

    private let queue = DispatchQueue(label: "notchnerd.parking", qos: .utility)

    private init() { parked = Self.loadRegistry() }

    var idleBytes: Int64 { idle.filter { !$0.inUse }.map(\.bytes).reduce(0, +) }

    // MARK: Scan

    func scan(completion: (() -> Void)? = nil) {
        guard !scanning else { return }
        scanning = true
        let idleDays = Defaults[.storageIdleDays]
        let roots = Self.roots()
        queue.async {
            let found = Self.findIdle(idleDays: idleDays, roots: roots)
            let registry = Self.pruneRegistry(Self.loadRegistry())
            DispatchQueue.main.async {
                self.idle = found
                self.parked = registry
                self.scanning = false
                completion?()
            }
        }
    }

    // MARK: Park / wake

    func park(_ project: IdleProject) {
        guard !busy.contains(project.path) else { return }
        busy.insert(project.path)
        queue.async {
            let result = Self.performPark(project)
            DispatchQueue.main.async {
                self.busy.remove(project.path)
                self.idle.removeAll { $0.path == project.path }
                switch result {
                case .success(let entry):
                    self.parked.removeAll { $0.path == entry.path }
                    self.parked.insert(entry, at: 0)
                    self.lastResult = "Parked \(project.name), freed \(StorageManager.format(project.bytes))"
                case .failure(let error):
                    self.lastResult = "\(project.name): \(error.localizedDescription)"
                }
                StorageManager.shared.refreshFreeSpace()
            }
        }
    }

    func parkAll() {
        for p in idle where !p.inUse { park(p) }
    }

    func wake(_ entry: ParkedProject) {
        guard !busy.contains(entry.path) else { return }
        busy.insert(entry.path)
        lastResult = "Waking \(entry.name)…"
        queue.async {
            let error = Self.performWake(entry)
            DispatchQueue.main.async {
                self.busy.remove(entry.path)
                if let error {
                    self.lastResult = "\(entry.name): \(error)"
                    NotchEventInbox.shared.show(NotchToast(
                        title: "Couldn't wake \(entry.name)", message: error,
                        style: .warning, symbol: "exclamationmark.triangle.fill", duration: 6))
                } else {
                    self.parked.removeAll { $0.path == entry.path }
                    Self.saveRegistry(self.parked)
                    self.lastResult = "\(entry.name) is ready"
                    NotchEventInbox.shared.show(NotchToast(
                        title: "\(entry.name) is ready", message: "Dependencies reinstalled",
                        style: .success, symbol: "checkmark.circle.fill", duration: 4))
                }
                StorageManager.shared.refreshFreeSpace()
            }
        }
    }

    /// Opens the project in Finder (for a parked one whose path moved, this just fails quietly).
    func reveal(_ path: String) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    // MARK: - Background work

    /// Folders an install or build recreates. `.wrangler` (local D1/KV state), `.vercel` (project
    /// link), `dist` and `build` (sometimes committed or hand-made) are deliberately not here.
    nonisolated static let rebuildableNames = [
        "node_modules", ".next", ".turbo", ".open-next", ".expo", ".svelte-kit", ".parcel-cache",
        ".nuxt", ".output", ".angular", "Pods", ".build", "DerivedData", ".gradle",
    ]

    nonisolated static func roots() -> [String] {
        var roots = Defaults[.storageProjectRoots].map { ($0 as NSString).expandingTildeInPath }
        // Agent worktree folders (~/.something-worktrees) are picked up automatically.
        let home = NSHomeDirectory()
        let dots = (try? FileManager.default.contentsOfDirectory(atPath: home)) ?? []
        roots += dots.filter { $0.hasPrefix(".") && $0.hasSuffix("worktrees") }.map { "\(home)/\($0)" }
        var seen = Set<String>()
        return roots.filter { FileManager.default.fileExists(atPath: $0) && seen.insert($0).inserted }
    }

    nonisolated static func findIdle(idleDays: Int, roots: [String]) -> [IdleProject] {
        let busyDirs = processWorkingDirectories()
        let fm = FileManager.default
        var projects: [IdleProject] = []
        for root in roots {
            let children = (try? fm.contentsOfDirectory(atPath: root)) ?? []
            for child in children where !child.hasPrefix(".") {
                let path = "\(root)/\(child)"
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
                let removable = rebuildableDirs(in: path)
                guard !removable.isEmpty else { continue }
                guard !recentlyChanged(path, days: idleDays) else { continue }
                let bytes = duBytes(removable)
                guard bytes >= 20_000_000 else { continue }   // not worth a row
                let inUse = busyDirs.contains { $0 == path || $0.hasPrefix(path + "/") }
                projects.append(IdleProject(path: path, removable: removable, bytes: bytes,
                                            lastTouched: lastTouched(path), inUse: inUse,
                                            restore: restoreCommands(for: path, removable: removable)))
            }
        }
        return projects.sorted { $0.bytes > $1.bytes }
    }

    nonisolated static func rebuildableDirs(in project: String) -> [String] {
        var args = [project, "-maxdepth", "6", "-name", ".git", "-prune", "-o", "-type", "d", "("]
        for (i, n) in rebuildableNames.enumerated() {
            if i > 0 { args.append("-o") }
            args += ["-name", n]
        }
        args += [")", "-prune", "-print"]
        let (_, out) = StorageManager.run("/usr/bin/find", args, timeout: 120)
        return out.split(separator: "\n").map(String.init).filter { dir in
            // Skip anything inside .git, and Swift's .build only next to a Package.swift.
            guard !dir.contains("/.git/") else { return false }
            if dir.hasSuffix("/.build") {
                let parent = (dir as NSString).deletingLastPathComponent
                return FileManager.default.fileExists(atPath: "\(parent)/Package.swift")
            }
            return true
        }
    }

    /// True if any file outside the rebuildable folders and .git changed in the last `days` days.
    nonisolated static func recentlyChanged(_ project: String, days: Int) -> Bool {
        var args = [project, "-maxdepth", "6", "("]
        for (i, n) in (rebuildableNames + [".git", ".wrangler", "dist", "build"]).enumerated() {
            if i > 0 { args.append("-o") }
            args += ["-name", n]
        }
        // Finder and TypeScript touch these on their own; they aren't the user working.
        args += [")", "-prune", "-o", "-type", "f", "!", "-name", ".DS_Store", "!", "-name", "*.tsbuildinfo",
                 "-mtime", "-\(days)", "-print", "-quit"]
        let (_, out) = StorageManager.run("/usr/bin/find", args, timeout: 60)
        return !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Newest of the last commit/checkout and the git index; nil for non-git folders.
    nonisolated static func lastTouched(_ project: String) -> Date? {
        let fm = FileManager.default
        var gitDir = "\(project)/.git"
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: gitDir, isDirectory: &isDir) else { return nil }
        if !isDir.boolValue,   // a worktree: ".git" is a file pointing at the real gitdir
           let text = try? String(contentsOfFile: gitDir, encoding: .utf8),
           let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) {
            gitDir = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        }
        return ["\(gitDir)/logs/HEAD", "\(gitDir)/index"].compactMap {
            (try? fm.attributesOfItem(atPath: $0))?[.modificationDate] as? Date
        }.max()
    }

    /// One install per package root: each removed node_modules maps to the nearest folder at or
    /// above it (inside the project) that has a lockfile, so monorepos install once at the top and
    /// a folder holding several repos gets one install per repo.
    nonisolated static func restoreCommands(for project: String, removable: [String]) -> [String] {
        let fm = FileManager.default
        func installer(_ dir: String) -> String? {
            func has(_ f: String) -> Bool { fm.fileExists(atPath: "\(dir)/\(f)") }
            if has("pnpm-lock.yaml") { return "pnpm install" }
            if has("bun.lock") || has("bun.lockb") { return "bun install" }
            if has("yarn.lock") { return "yarn install" }
            if has("package-lock.json") { return "npm install" }
            return nil
        }
        func rel(_ dir: String) -> String { dir == project ? "." : String(dir.dropFirst(project.count + 1)) }
        func cmd(_ dir: String, _ tool: String) -> String { dir == project ? tool : "(cd '\(rel(dir))' && \(tool))" }

        var cmds: [String] = []
        var seen = Set<String>()
        for nm in removable where nm.hasSuffix("/node_modules") {
            let start = (nm as NSString).deletingLastPathComponent
            var dir = start
            var found: (String, String)?
            while dir.hasPrefix(project) {
                if let tool = installer(dir) { found = (dir, tool); break }
                if dir == project { break }
                dir = (dir as NSString).deletingLastPathComponent
            }
            if found == nil, fm.fileExists(atPath: "\(start)/package.json") { found = (start, "npm install") }
            if let (d, tool) = found, seen.insert(d).inserted { cmds.append(cmd(d, tool)) }
        }
        // CocoaPods folders get their own `pod install` from the Podfile's folder.
        for pods in removable where pods.hasSuffix("/Pods") {
            let dir = (pods as NSString).deletingLastPathComponent
            if fm.fileExists(atPath: "\(dir)/Podfile"), seen.insert(dir).inserted { cmds.append(cmd(dir, "pod install")) }
        }
        return cmds
    }

    /// Working directories of every running process the user owns.
    nonisolated static func processWorkingDirectories() -> [String] {
        let (_, out) = StorageManager.run("/usr/sbin/lsof", ["-a", "-d", "cwd", "-u", NSUserName(), "-Fn"], timeout: 20)
        return out.split(separator: "\n").filter { $0.hasPrefix("n/") }.map { String($0.dropFirst()) }
    }

    enum ParkError: LocalizedError {
        case inUse, nothingRemoved
        var errorDescription: String? {
            switch self {
            case .inUse: return "something is running in it now"
            case .nothingRemoved: return "couldn't remove anything"
            }
        }
    }

    nonisolated static func performPark(_ project: IdleProject) -> Result<ParkedProject, ParkError> {
        // Re-check right before deleting: a dev server or agent may have started since the scan.
        let cwds = processWorkingDirectories()
        if cwds.contains(where: { $0 == project.path || $0.hasPrefix(project.path + "/") }) { return .failure(.inUse) }
        let fm = FileManager.default
        var removed: [String] = []
        for dir in project.removable where fm.fileExists(atPath: dir) {
            if (try? fm.removeItem(atPath: dir)) != nil {
                removed.append(String(dir.dropFirst(project.path.count + 1)))
            }
        }
        guard !removed.isEmpty else { return .failure(.nothingRemoved) }
        let entry = ParkedProject(path: project.path, parkedAt: Date(), bytes: project.bytes,
                                  removed: removed, restore: project.restore)
        var registry = loadRegistry().filter { $0.path != entry.path }
        registry.insert(entry, at: 0)
        saveRegistry(registry)
        return .success(entry)
    }

    /// Runs the restore commands in a login shell (so Homebrew/rbenv paths resolve). nil = success.
    nonisolated static func performWake(_ entry: ParkedProject) -> String? {
        guard FileManager.default.fileExists(atPath: entry.path) else { return "the folder is gone" }
        guard !entry.restore.isEmpty else { return nil }   // only build output was removed; it rebuilds itself
        let script = "cd \"$1\" && " + entry.restore.joined(separator: " && ")
        let (code, _) = StorageManager.run("/bin/zsh", ["-lc", script, "notchnerd-wake", entry.path], timeout: 1200)
        return code == 0 ? nil : "Run \(entry.restore.joined(separator: " && ")) in the project"
    }

    // MARK: Registry

    nonisolated static var registryURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchNerd", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("parked-projects.json")
    }

    nonisolated static func loadRegistry() -> [ParkedProject] {
        guard let data = try? Data(contentsOf: registryURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([ParkedProject].self, from: data)) ?? []
    }

    nonisolated static func saveRegistry(_ entries: [ParkedProject]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(entries) { try? data.write(to: registryURL, options: .atomic) }
    }

    /// Drops entries whose folder is gone or that were woken by hand (node_modules is back).
    nonisolated static func pruneRegistry(_ entries: [ParkedProject]) -> [ParkedProject] {
        let fm = FileManager.default
        let kept = entries.filter { e in
            guard fm.fileExists(atPath: e.path) else { return false }
            if let nm = e.removed.first(where: { $0.hasSuffix("node_modules") }) {
                return !fm.fileExists(atPath: "\(e.path)/\(nm)")
            }
            return true
        }
        if kept.count != entries.count { saveRegistry(kept) }
        return kept
    }

    nonisolated private static func duBytes(_ paths: [String]) -> Int64 {
        guard !paths.isEmpty else { return 0 }
        let (_, out) = StorageManager.run("/usr/bin/du", ["-sk"] + paths, timeout: 300)
        return out.split(separator: "\n").compactMap { $0.split(separator: "\t").first.flatMap { Int64($0) } }
            .reduce(0, +) * 1024
    }
}
