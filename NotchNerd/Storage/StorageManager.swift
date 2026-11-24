//
//  StorageManager.swift
//  NotchNerd
//
//  The Storage tab's engine: free space on the startup volume, a list of "reclaimable" categories
//  (developer caches, idle node_modules, Cursor's chat history, Docker, Trash) with their sizes, and
//  a cleaner for each. Also a low-space watcher that shows one notch toast when free space drops
//  under the threshold in Settings → Storage.
//
//  Every category here is something that rebuilds itself or is history the user has chosen to drop:
//  nothing touches documents, photos or project source. Sizing and cleaning shell out to du / find /
//  rm / sqlite3 / xcrun / docker on a background queue; the app is unsandboxed, so this works
//  without extra entitlements (Trash sizing may show "—" without Full Disk Access).
//

import AppKit
import Defaults
import Foundation

struct StorageCategory: Identifiable, Equatable {
    enum ID: String, CaseIterable {
        case derivedData, simulators, packageCaches, nodeModules, cursorChats, appCaches, docker, trash
    }

    let id: ID
    var bytes: Int64?          // nil = still measuring or unknown
    var detail: String = ""    // e.g. "12 folders"
    var unavailable: String?   // why it can't be cleaned right now (e.g. "Quit Cursor first")

    var title: String {
        switch id {
        case .derivedData: return "Xcode build cache"
        case .simulators: return "iOS simulators"
        case .packageCaches: return "Package caches"
        case .nodeModules: return "Idle node_modules"
        case .cursorChats: return "Cursor chat history"
        case .appCaches: return "App caches"
        case .docker: return "Docker"
        case .trash: return "Trash"
        }
    }

    var symbol: String {
        switch id {
        case .derivedData: return "hammer"
        case .simulators: return "iphone"
        case .packageCaches: return "shippingbox"
        case .nodeModules: return "folder.badge.minus"
        case .cursorChats: return "bubble.left.and.text.bubble.right"
        case .appCaches: return "internaldrive"
        case .docker: return "cube"
        case .trash: return "trash"
        }
    }

    /// One line on what cleaning does, shown under the row.
    var explainer: String {
        switch id {
        case .derivedData: return "Rebuilt on next build"
        case .simulators: return "Erases devices only"
        case .packageCaches: return "npm, pnpm, uv, Homebrew"
        case .nodeModules: return "Projects idle \(Defaults[.storageIdleDays])+ days"
        case .cursorChats: return "Old chats; sign-in stays"
        case .appCaches: return "Library caches, not Apple's"
        case .docker: return "Unused images and cache"
        case .trash: return "Empties it for good"
        }
    }
}

@MainActor
final class StorageManager: ObservableObject {
    static let shared = StorageManager()

    @Published private(set) var totalBytes: Int64 = 0
    @Published private(set) var freeBytes: Int64 = 0
    @Published private(set) var categories: [StorageCategory] = StorageCategory.ID.allCases.map { StorageCategory(id: $0) }
    @Published private(set) var scanning = false
    @Published private(set) var cleaning: StorageCategory.ID?
    @Published private(set) var lastScan: Date?
    @Published var lastResult: String?

    private var timer: Timer?
    private var lastLowSpaceToast: Date?
    private let queue = DispatchQueue(label: "notchnerd.storage", qos: .utility)

    private init() {}

    var reclaimableBytes: Int64 {
        categories.compactMap(\.bytes).reduce(0, +)
    }

    var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(totalBytes - freeBytes) / Double(totalBytes)))
    }

    var isLow: Bool {
        freeBytes > 0 && freeBytes < Int64(Defaults[.storageLowSpaceGB]) * 1_000_000_000
    }

    // MARK: Lifecycle

    /// Starts the free-space watcher (every 5 minutes). Cheap: it only reads volume capacity.
    func start() {
        refreshFreeSpace()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            Task { @MainActor in
                StorageManager.shared.refreshFreeSpace()
                StorageManager.shared.autoCleanIfDue()
            }
        }
        // Give launch a minute to settle before a due weekly clean.
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { self.autoCleanIfDue() }
    }

    func refreshFreeSpace() {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return }
        totalBytes = Int64(values.volumeTotalCapacity ?? 0)
        // "Important usage" counts purgeable space, like Finder. Fall back to the strict number.
        freeBytes = values.volumeAvailableCapacityForImportantUsage ?? Int64(values.volumeAvailableCapacity ?? 0)
        maybeWarnLowSpace()
    }

    private func maybeWarnLowSpace() {
        guard Defaults[.storageLowSpaceAlerts], isLow else { return }
        if let last = lastLowSpaceToast, Date().timeIntervalSince(last) < 3600 { return }
        lastLowSpaceToast = Date()
        NotchEventInbox.shared.show(NotchToast(
            title: "Disk almost full",
            message: "\(Self.format(freeBytes)) free · open Storage to clean up",
            style: .warning, symbol: "internaldrive.fill", duration: 6))
    }

    // MARK: Scan

    func scan() {
        guard !scanning else { return }
        scanning = true
        refreshFreeSpace()
        categories = StorageCategory.ID.allCases.map { StorageCategory(id: $0) }
        let idleDays = Defaults[.storageIdleDays]
        let roots = Self.projectRoots()
        let group = DispatchGroup()
        for id in StorageCategory.ID.allCases {
            group.enter()
            queue.async {
                let measured = Self.measure(id, idleDays: idleDays, roots: roots)
                DispatchQueue.main.async {
                    if let i = self.categories.firstIndex(where: { $0.id == id }) {
                        self.categories[i] = measured
                    }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) {
            self.scanning = false
            self.lastScan = Date()
            self.categories.sort { ($0.bytes ?? -1) > ($1.bytes ?? -1) }
        }
    }

    // MARK: Clean

    func clean(_ id: StorageCategory.ID) {
        guard cleaning == nil else { return }
        cleaning = id
        let before = freeBytes
        let idleDays = Defaults[.storageIdleDays]
        let roots = Self.projectRoots()
        queue.async {
            let error = Self.performClean(id, idleDays: idleDays, roots: roots)
            let measured = Self.measure(id, idleDays: idleDays, roots: roots)
            DispatchQueue.main.async {
                self.cleaning = nil
                self.refreshFreeSpace()
                if let i = self.categories.firstIndex(where: { $0.id == id }) { self.categories[i] = measured }
                let freed = max(0, self.freeBytes - before)
                self.lastResult = error ?? "Freed \(Self.format(freed)) from \(measured.title.lowercased())"
            }
        }
    }

    // MARK: - Background work (nonisolated)

    nonisolated private static var home: String { NSHomeDirectory() }

    nonisolated private static func projectRoots() -> [String] {
        Defaults[.storageProjectRoots].map { ($0 as NSString).expandingTildeInPath }
            .filter { FileManager.default.fileExists(atPath: $0) }
    }

    nonisolated private static func paths(for id: StorageCategory.ID) -> [String] {
        let h = home
        switch id {
        case .derivedData: return ["\(h)/Library/Developer/Xcode/DerivedData"]
        case .simulators: return ["\(h)/Library/Developer/CoreSimulator/Devices", "\(h)/Library/Developer/CoreSimulator/Caches"]
        case .packageCaches:
            return ["\(h)/.npm/_cacache", "\(h)/Library/pnpm/store", "\(h)/.cache/uv", "\(h)/.bun/install/cache",
                    "\(h)/Library/Caches/Homebrew", "\(h)/.cache/puppeteer", "\(h)/Library/Caches/Yarn",
                    "\(h)/Library/Caches/pip", "\(h)/.cache/pip"]
        case .cursorChats:
            return ["\(h)/Library/Application Support/Cursor/User/globalStorage/state.vscdb",
                    "\(h)/Library/Application Support/Cursor/snapshots",
                    "\(h)/Library/Application Support/Cursor/User/globalStorage/anysphere.cursor-agent-worker"]
        case .appCaches: return appCacheChildren()
        case .trash: return ["\(h)/.Trash"]
        case .nodeModules, .docker: return []
        }
    }

    nonisolated private static func appCacheChildren() -> [String] {
        let dir = "\(home)/Library/Caches"
        let skip: Set<String> = ["Homebrew", "Yarn", "pip"]   // counted under package caches
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return names.filter { !$0.hasPrefix("com.apple.") && !skip.contains($0) && !$0.hasPrefix(".") }
            .map { "\(dir)/\($0)" }
    }

    nonisolated private static func measure(_ id: StorageCategory.ID, idleDays: Int, roots: [String]) -> StorageCategory {
        var cat = StorageCategory(id: id)
        switch id {
        case .nodeModules:
            let dirs = idleNodeModules(idleDays: idleDays, roots: roots)
            cat.bytes = duBytes(dirs)
            cat.detail = dirs.isEmpty ? "" : "\(dirs.count) folder\(dirs.count == 1 ? "" : "s")"
        case .docker:
            guard let docker = which("docker") else { cat.bytes = 0; cat.unavailable = "Docker not installed"; return cat }
            let (code, out) = run(docker, ["system", "df", "--format", "{{.Reclaimable}}"], timeout: 20)
            if code != 0 { cat.bytes = 0; cat.unavailable = "Start Docker to measure"; return cat }
            cat.bytes = out.split(separator: "\n").map { parseDockerSize(String($0)) }.reduce(0, +)
        case .cursorChats:
            let p = paths(for: id)
            // Only the chat share of the DB is reclaimable; the rest (sign-in, settings) stays.
            let dbChats = cursorChatBytes(db: p[0])
            cat.bytes = dbChats + duBytes(Array(p.dropFirst()))
            if isRunning("com.todesktop.230313mzl4w4u92") { cat.unavailable = "Quit Cursor first" }
        default:
            let p = paths(for: id).filter { FileManager.default.fileExists(atPath: $0) }
            cat.bytes = duBytes(p)
            if id == .trash, !FileManager.default.isReadableFile(atPath: "\(home)/.Trash") { cat.bytes = nil; cat.detail = "Needs Full Disk Access to size" }
        }
        return cat
    }

    /// Returns nil on success, or a message.
    nonisolated private static func performClean(_ id: StorageCategory.ID, idleDays: Int, roots: [String]) -> String? {
        let fm = FileManager.default
        switch id {
        case .derivedData, .packageCaches, .appCaches:
            for p in paths(for: id) where fm.fileExists(atPath: p) { try? fm.removeItem(atPath: p) }
            return nil
        case .nodeModules:
            for d in idleNodeModules(idleDays: idleDays, roots: roots) { try? fm.removeItem(atPath: d) }
            return nil
        case .simulators:
            _ = run("/usr/bin/xcrun", ["simctl", "shutdown", "all"], timeout: 60)
            _ = run("/usr/bin/xcrun", ["simctl", "delete", "unavailable"], timeout: 120)
            let (code, _) = run("/usr/bin/xcrun", ["simctl", "erase", "all"], timeout: 300)
            try? fm.removeItem(atPath: "\(home)/Library/Developer/CoreSimulator/Caches")
            return code == 0 ? nil : "Couldn't erase simulators (is Xcode installed?)"
        case .cursorChats:
            if isRunning("com.todesktop.230313mzl4w4u92") { return "Quit Cursor first" }
            let p = paths(for: id)
            let prefixes = ["agentKv:", "bubbleId:", "checkpointId:", "codeBlockDiff:", "composerData:",
                            "codeBlockPartialInlineDiffFates:", "messageRequestContext:"]
            let whereClause = prefixes.map { "key LIKE '\($0)%'" }.joined(separator: " OR ")
            if fm.fileExists(atPath: p[0]) {
                let (code, out) = run("/usr/bin/sqlite3", [p[0], "DELETE FROM cursorDiskKV WHERE \(whereClause); VACUUM;"], timeout: 600)
                if code != 0 { return "Cursor database: \(out.prefix(80))" }
            }
            for extra in p.dropFirst() where fm.fileExists(atPath: extra) { try? fm.removeItem(atPath: extra) }
            return nil
        case .docker:
            guard let docker = which("docker") else { return "Docker not installed" }
            let (code, _) = run(docker, ["system", "prune", "-af"], timeout: 600)
            return code == 0 ? nil : "Start Docker, then try again"
        case .trash:
            var err: NSDictionary?
            NSAppleScript(source: "tell application \"Finder\" to empty trash")?.executeAndReturnError(&err)
            return err == nil ? nil : "Allow NotchNerd to control Finder in System Settings → Privacy → Automation"
        }
    }

    // MARK: Helpers

    /// node_modules folders (up to 4 levels under each root) whose project has no file changed in
    /// `idleDays`, ignoring dependency and build folders.
    nonisolated static func idleNodeModules(idleDays: Int, roots: [String]) -> [String] {
        guard !roots.isEmpty else { return [] }
        let (_, found) = run("/usr/bin/find", roots + ["-maxdepth", "4", "-name", "node_modules", "-type", "d", "-prune"], timeout: 120)
        var result: [String] = []
        var checked: [String: Bool] = [:]
        for nm in found.split(separator: "\n").map(String.init) where !nm.isEmpty {
            let parent = (nm as NSString).deletingLastPathComponent
            let project = repoRoot(of: parent, stopAt: roots) ?? parent
            let idle: Bool
            if let cached = checked[project] { idle = cached } else {
                let (_, recent) = run("/usr/bin/find", [project, "-maxdepth", "4",
                    "(", "-name", "node_modules", "-o", "-name", ".git", "-o", "-name", ".next", "-o", "-name", ".turbo",
                    "-o", "-name", "dist", "-o", "-name", "build", "-o", "-name", ".open-next", ")", "-prune",
                    "-o", "-type", "f", "-mtime", "-\(idleDays)", "-print", "-quit"], timeout: 60)
                idle = recent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                checked[project] = idle
            }
            if idle { result.append(nm) }
        }
        return result
    }

    nonisolated private static func repoRoot(of dir: String, stopAt roots: [String]) -> String? {
        var d = dir
        while d != "/" && !roots.contains(d) {
            if FileManager.default.fileExists(atPath: "\(d)/.git") { return d }
            d = (d as NSString).deletingLastPathComponent
        }
        return nil
    }

    nonisolated private static func duBytes(_ paths: [String]) -> Int64 {
        guard !paths.isEmpty else { return 0 }
        let (_, out) = run("/usr/bin/du", ["-sk"] + paths, timeout: 300)
        return out.split(separator: "\n").compactMap { line in
            line.split(separator: "\t").first.flatMap { Int64($0) }
        }.reduce(0, +) * 1024
    }

    nonisolated private static func cursorChatBytes(db: String) -> Int64 {
        guard FileManager.default.fileExists(atPath: db) else { return 0 }
        let (code, out) = run("/usr/bin/sqlite3", ["-readonly", db,
            "SELECT COALESCE(SUM(LENGTH(value)),0) FROM cursorDiskKV WHERE key LIKE 'agentKv:%' OR key LIKE 'bubbleId:%' OR key LIKE 'checkpointId:%' OR key LIKE 'codeBlockDiff:%' OR key LIKE 'composerData:%' OR key LIKE 'codeBlockPartialInlineDiffFates:%' OR key LIKE 'messageRequestContext:%';"], timeout: 120)
        return code == 0 ? Int64(out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 : 0
    }

    /// "1.2GB (40%)" → bytes.
    nonisolated static func parseDockerSize(_ s: String) -> Int64 {
        let token = s.split(separator: " ").first.map(String.init) ?? ""
        let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("KB", 1e3), ("B", 1)]
        for (u, m) in units where token.hasSuffix(u) {
            return Int64((Double(token.dropLast(u.count)) ?? 0) * m)
        }
        return 0
    }

    nonisolated private static func which(_ tool: String) -> String? {
        ["/opt/homebrew/bin/\(tool)", "/usr/local/bin/\(tool)", "/Applications/Docker.app/Contents/Resources/bin/\(tool)"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    nonisolated private static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    @discardableResult
    nonisolated static func run(_ launchPath: String, _ args: [String], timeout: TimeInterval) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, "") }
        let deadline = DispatchTime.now() + timeout
        DispatchQueue.global().asyncAfter(deadline: deadline) { if p.isRunning { p.terminate() } }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    nonisolated static func format(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = bytes >= 1_000_000_000 ? [.useGB] : [.useMB, .useKB]
        return f.string(fromByteCount: bytes)
    }
}


// MARK: - Weekly auto-clean

@MainActor
extension StorageManager {
    /// What the weekly clean clears: only things that rebuild themselves without losing anything.
    /// (Simulators: only devices for runtimes that are no longer installed, never `erase all`.)
    static let autoCleanCategories: [StorageCategory.ID] = [.derivedData, .packageCaches]
    static let autoCleanInterval: TimeInterval = 7 * 24 * 3600

    var lastAutoClean: Date? {
        let t = Defaults[.storageAutoCleanLastRun]
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    func autoCleanIfDue() {
        guard Defaults[.storageAutoCleanEnabled], cleaning == nil else { return }
        if let last = lastAutoClean, Date().timeIntervalSince(last) < Self.autoCleanInterval { return }
        runAutoClean()
    }

    /// Runs the weekly clean now (also the "Run now" button), then shows one toast with what it freed.
    func runAutoClean() {
        guard cleaning == nil else { return }
        cleaning = .packageCaches
        refreshFreeSpace()
        let before = freeBytes
        let roots = Self.projectRoots()
        let idleDays = Defaults[.storageIdleDays]
        queue.async {
            // Measure what's there first: the volume's free-space number lags deletions and moves
            // with whatever else is writing, so "free after - free before" under-reports.
            let paths = Self.autoCleanCategories.flatMap { Self.paths(for: $0) }
                .filter { FileManager.default.fileExists(atPath: $0) }
            let measured = Self.duBytes(paths)
            for id in Self.autoCleanCategories { _ = Self.performClean(id, idleDays: idleDays, roots: roots) }
            _ = Self.run("/usr/bin/xcrun", ["simctl", "delete", "unavailable"], timeout: 120)
            DispatchQueue.main.async {
                self.cleaning = nil
                self.refreshFreeSpace()
                let freed = max(measured, self.freeBytes - before)
                Defaults[.storageAutoCleanLastRun] = Date().timeIntervalSince1970
                Defaults[.storageAutoCleanLastFreed] = Double(freed)
                self.lastResult = "Weekly clean freed \(Self.format(freed))"
                NotchEventInbox.shared.show(NotchToast(
                    title: "Weekly clean",
                    message: freed > 50_000_000 ? "Freed \(Self.format(freed)) of caches" : "Nothing much to clear",
                    style: .success, symbol: "sparkles", duration: 5))
                self.lastScan = nil   // the tab rescans next time it opens
            }
        }
    }
}
