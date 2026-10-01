//
//  GrokBotMonitor.swift
//  NotchNerd — Grok Bot chip for the Agent tab
//
//  Grok Bot (Anysphere's desktop agent app, bundle `com.anysphere.sand`) runs its agents in the
//  cloud and keeps per-chat running/waiting state in memory only — there are no hooks, processes or
//  status files to watch. The one stable local signal is its Dock badge, which counts chats that
//  finished or need input (unread, notifications on, not hidden). We read it with `lsappinfo` and show
//  it as a chip; clicking opens the app. It can't tell "finished" from "needs you", or show running.
//

import AppKit
import Combine
import Defaults

@MainActor
final class GrokBotMonitor: ObservableObject {
    static let shared = GrokBotMonitor()
    static let bundleIdentifier = "com.anysphere.sand"

    @Published private(set) var isRunning = false
    /// The Dock badge text (usually a count); nil when there's no badge.
    @Published private(set) var badge: String?

    private var timer: Timer?
    private static let pollInterval: TimeInterval = 5

    private init() {}

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { _ in
            Task { @MainActor in GrokBotMonitor.shared.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func open() {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleIdentifier) else { return }
        NSWorkspace.shared.openApplication(at: app, configuration: .init())
    }

    private func refresh() {
        guard Defaults[.agentGrokChipEnabled] else {
            isRunning = false
            badge = nil
            return
        }
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).isEmpty
        guard running else {
            isRunning = false
            badge = nil
            return
        }
        Task.detached(priority: .utility) {
            let label = Self.dockBadge()
            await MainActor.run {
                let monitor = GrokBotMonitor.shared
                monitor.isRunning = true
                if monitor.badge != label { monitor.badge = label }
            }
        }
    }

    /// `lsappinfo info -only StatusLabel -app <bundle>` → `"StatusLabel"={ "label"="3" }`
    /// (or `[ NULL ]` / an empty label when there's no badge).
    nonisolated private static func dockBadge() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/lsappinfo")
        process.arguments = ["info", "-only", "StatusLabel", "-app", bundleIdentifier]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        guard let match = output.range(of: #""label"="([^"]*)""#, options: .regularExpression) else { return nil }
        let label = output[match]
            .replacingOccurrences(of: #""label"=""#, with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            .trimmingCharacters(in: .whitespaces)
        return label.isEmpty ? nil : label
    }
}
