//
//  AgentReplyChannel.swift
//  NotchNerd — reply to a Claude Code session from the notch
//
//  Hooks can't put a prompt into a Claude Code session, but the NotchNerd Claude Code mod
//  (tooling/claude-code-mod) runs inside each session and can. The two meet in files under
//  ~/Library/Application Support/NotchNerd/Agent/:
//
//    mod-sessions/<sessionID>.json        the mod rewrites it every ~20s while its session is open
//                                         ({ sessionId, cwd, surface, updatedAt, ended? }); Reply is
//                                         offered only for a session with a fresh, un-ended one
//    outbox/<sessionID>/<ms>-<rand>.json  one reply ({ version: 1, text }), written here atomically;
//                                         the mod polls its own session's folder each second, deletes
//                                         the file and submits the text as the user's prompt (queued
//                                         until the session is idle)
//
//  Off by default (Defaults[.agentReplyEnabled]): with it on the agent monitor can start turns, not
//  only observe them. Local files only — no API, no credentials. Polling runs only while the Agent
//  tab is on screen (AgentView drives refresh()).
//

import Defaults
import Foundation

@MainActor
final class AgentReplyChannel: ObservableObject {
    static let shared = AgentReplyChannel()

    enum Delivery: Equatable {
        case sending        // written; the mod hasn't taken it yet
        case delivered      // the mod took it (submitted, or queued behind a running turn)
        case waiting        // not taken after a few seconds; stays in the outbox until it is
        case failed(String)
    }

    /// Sessions with a mod listening right now.
    @Published private(set) var connectedSessionIDs: Set<String> = []
    /// Last reply's delivery state per session, cleared a few seconds after it lands.
    @Published private(set) var delivery: [String: Delivery] = [:]
    /// Unsent text per session, so a draft survives the row being torn down (notch close, tab switch).
    /// Not @Published: it changes per keystroke and nothing else draws from it.
    var drafts: [String: String] = [:]

    private let fm = FileManager.default
    private var deliveryTasks: [String: Task<Void, Never>] = [:]

    private static let presenceTTL: TimeInterval = 60
    private static let staleFileAge: TimeInterval = 24 * 60 * 60
    private static let firstCheck: Duration = .seconds(3)    // mod polls every second
    private static let recheck: Duration = .seconds(2)
    private static let giveUpAfter: TimeInterval = 10 * 60
    private static let clearDeliveredAfter: Duration = .seconds(6)

    private init() {}

    private var rootDir: URL {
        fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchNerd/Agent", isDirectory: true)
    }
    private var presenceDir: URL { rootDir.appendingPathComponent("mod-sessions", isDirectory: true) }
    private var outboxDir: URL { rootDir.appendingPathComponent("outbox", isDirectory: true) }

    private struct Presence: Decodable {
        let sessionId: String
        let ended: Bool?
    }

    private struct Reply: Encodable {
        let version = 1
        let text: String
    }

    /// Claude Code session ids are UUIDs; refuse anything that could leave the outbox folder.
    private static func isSafeID(_ id: String) -> Bool {
        id.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil
    }

    // MARK: Presence

    /// Re-reads which sessions have a mod listening. Cheap (one small directory); AgentView calls it
    /// on appear and every few seconds while visible.
    func refresh() {
        guard Defaults[.agentReplyEnabled] else {
            if !connectedSessionIDs.isEmpty { connectedSessionIDs = [] }
            return
        }
        let files = (try? fm.contentsOfDirectory(
            at: presenceDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let now = Date()
        var connected: Set<String> = []
        for url in files where url.pathExtension == "json" {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let age = now.timeIntervalSince(modified)
            if age > Self.staleFileAge {
                try? fm.removeItem(at: url)   // the mod can't delete; keep the folder small
                continue
            }
            guard age < Self.presenceTTL,
                  let data = try? Data(contentsOf: url),
                  let presence = try? JSONDecoder().decode(Presence.self, from: data),
                  presence.ended != true else { continue }
            connected.insert(presence.sessionId)
        }
        if connected != connectedSessionIDs { connectedSessionIDs = connected }
        if !didPruneOutbox { pruneOutbox() }
    }

    private var didPruneOutbox = false

    /// Once per launch: drop replies stranded for a day (their session ended before its mod took
    /// them), so one can't surface in a resumed session much later.
    private func pruneOutbox() {
        didPruneOutbox = true
        let now = Date()
        for dir in (try? fm.contentsOfDirectory(at: outboxDir, includingPropertiesForKeys: nil)) ?? [] {
            let files = (try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            var kept = 0
            for file in files {
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                if now.timeIntervalSince(modified) > Self.staleFileAge {
                    try? fm.removeItem(at: file)
                } else {
                    kept += 1
                }
            }
            if kept == 0 { try? fm.removeItem(at: dir) }
        }
    }

    func isConnected(_ sessionID: String) -> Bool { connectedSessionIDs.contains(sessionID) }

    // MARK: Sending

    func send(_ text: String, to sessionID: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, Self.isSafeID(sessionID) else { return }
        let dir = outboxDir.appendingPathComponent(sessionID, isDirectory: true)
        let name = "\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(8).lowercased())"
        let staged = dir.appendingPathComponent(name + ".tmp")
        let final = dir.appendingPathComponent(name + ".json")
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            // The mod only takes *.json, and a rename is atomic: it never sees a half-written reply.
            try JSONEncoder().encode(Reply(text: trimmed)).write(to: staged)
            try fm.moveItem(at: staged, to: final)
        } catch {
            try? fm.removeItem(at: staged)
            setDelivery(.failed(error.localizedDescription), for: sessionID)
            return
        }
        drafts[sessionID] = nil
        setDelivery(.sending, for: sessionID)
        trackDelivery(of: final, for: sessionID)
    }

    private func trackDelivery(of file: URL, for sessionID: String) {
        deliveryTasks[sessionID]?.cancel()
        deliveryTasks[sessionID] = Task { [weak self] in
            let started = Date()
            try? await Task.sleep(for: Self.firstCheck)
            while let self, !Task.isCancelled {
                if !self.fm.fileExists(atPath: file.path) {
                    self.setDelivery(.delivered, for: sessionID)
                    try? await Task.sleep(for: Self.clearDeliveredAfter)
                    if !Task.isCancelled, self.delivery[sessionID] == .delivered {
                        self.delivery[sessionID] = nil
                    }
                    return
                }
                // Still in the outbox: the session's mod is gone or busy. Leave it there — it is sent
                // whenever that session's mod next polls — and stop watching after a while.
                self.setDelivery(.waiting, for: sessionID)
                if Date().timeIntervalSince(started) > Self.giveUpAfter { return }
                try? await Task.sleep(for: Self.recheck)
            }
        }
    }

    private func setDelivery(_ state: Delivery, for sessionID: String) {
        if delivery[sessionID] != state { delivery[sessionID] = state }
    }
}
