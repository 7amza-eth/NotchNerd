//
//  AgentUsageManager.swift
//  NotchNerd — Claude usage HUD
//
//  Installs the vendored statusline shim (which tees Claude Code's `rate_limits`
//  into /tmp/open-island-rl.json) and polls ClaudeUsageLoader for the 5h / 7d
//  quota windows. CALLS OpenIslandCore only; never edits it.
//
//  NAMESPACING: the cache path and statusline script name are baked into the
//  vendored manager (default `/tmp/open-island-rl.json`, `~/.open-island/bin/...`).
//  NotchNerd reuses them as-is — per-app namespacing is deferred to Phase 6,
//  matching AgentBridgeManager's socket note. If a separate Open Island is also
//  installed both apps share that cache file harmlessly (identical rate-limit JSON).
//

import Combine
import Defaults
import Foundation
import OpenIslandCore

enum UsageInstallState: Equatable {
    case unknown
    case installed          // managed statusline present (direct or wrapper)
    case notInstalled
    case failed(String)
}

@MainActor
final class AgentUsageManager: ObservableObject {
    static let shared = AgentUsageManager()

    @Published private(set) var snapshot: ClaudeUsageSnapshot?
    @Published private(set) var installState: UsageInstallState = .unknown
    @Published private(set) var lastStatusMessage: String = ""

    private var hasStarted = false
    private var pollTimer: DispatchSourceTimer?
    private static let pollInterval: DispatchTimeInterval = .seconds(5)

    private init() {}

    /// Honor a user-overridden Claude dir (mirrors AgentBridgeManager.makeInstallManager).
    private func makeManager() -> ClaudeStatusLineInstallationManager {
        let override = Defaults[.agentClaudeConfigDir]
        guard !override.isEmpty else { return ClaudeStatusLineInstallationManager() }
        let dir = URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        return ClaudeStatusLineInstallationManager(claudeDirectory: dir)
    }

    // MARK: - Lifecycle (called from AppDelegate; idempotent)

    func start() {
        guard !hasStarted else { return }
        guard Defaults[.agentUsageEnabled] else { return }
        hasStarted = true

        installIfNeeded()
        loadSnapshotNow()       // show cached data immediately if present
        startPolling()
    }

    func stop() {
        pollTimer?.cancel(); pollTimer = nil
        hasStarted = false
    }

    // MARK: - Install / uninstall (try direct, fall back to wrapper)

    func installIfNeeded() {
        let manager = makeManager()
        Task { [weak self] in
            guard let self else { return }
            do {
                let status = try await Task.detached(priority: .userInitiated) {
                    let current = try manager.status()
                    if current.managedStatusLineInstalled, !current.managedStatusLineNeedsRepair {
                        return current
                    }
                    do {
                        return try manager.install()
                    } catch ClaudeStatusLineInstallationError.existingStatusLineConflict {
                        // Preserve the user's existing statusline; tee rate_limits via a wrapper.
                        return try manager.installAsWrapper()
                    }
                }.value
                self.installState = status.managedStatusLineInstalled ? .installed : .notInstalled
                self.lastStatusMessage = status.managedStatusLineIsWrapper
                    ? "Usage statusline installed (wrapping your existing one)."
                    : "Usage statusline installed."
                // Pick up data from the freshly-installed bridge once Claude next renders.
                self.loadSnapshotNow()
            } catch {
                self.installState = .failed(error.localizedDescription)
                self.lastStatusMessage = "Usage install failed: \(error.localizedDescription)"
            }
        }
    }

    func uninstall() {
        let manager = makeManager()
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await Task.detached(priority: .userInitiated) { try manager.uninstall() }.value
                self.installState = .notInstalled
                self.snapshot = nil
                self.lastStatusMessage = "Usage statusline removed."
            } catch {
                self.installState = .failed(error.localizedDescription)
            }
        }
    }

    func refreshStatus() {
        let manager = makeManager()
        Task { [weak self] in
            guard let self else { return }
            let status = try? await Task.detached(priority: .utility) { try manager.status() }.value
            self.installState = (status?.managedStatusLineInstalled == true)
                ? .installed
                : (status == nil ? .unknown : .notInstalled)
        }
    }

    // MARK: - Polling

    private func startPolling() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + Self.pollInterval, repeating: Self.pollInterval)
        timer.setEventHandler {
            let snap = try? ClaudeUsageLoader.load()
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.snapshot != snap { self.snapshot = snap }   // ClaudeUsageSnapshot is Equatable
            }
        }
        timer.resume()
        pollTimer = timer
    }

    private func loadSnapshotNow() {
        Task { [weak self] in
            let snap = await Task.detached(priority: .utility) { try? ClaudeUsageLoader.load() }.value
            await MainActor.run { [weak self] in self?.snapshot = snap }
        }
    }
}
