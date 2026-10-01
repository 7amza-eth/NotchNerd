//
//  AgentBridgeManager.swift
//  NotchNerd — Phase 2 native agent driver
//
//  A NotchNerd-native @MainActor ObservableObject singleton that drives the vendored
//  OpenIslandCore engine headless, in-process. It deliberately does NOT port Open Island's
//  AppModel/coordinators — it re-implements only the minimal happy path:
//    • start BridgeServer in-process
//    • observe AgentEvents via a LocalBridgeClient and reduce them into SessionState
//    • install Claude Code hooks pointed at the embedded Contents/Helpers/OpenIslandHooks
//    • round-trip permission approve/deny back to the blocked hook
//    • startup discovery + process-liveness backstop + registry restore/persist
//
//  This feature only OBSERVES Claude Code via hooks. It never calls the Anthropic API and
//  stores no credentials.
//
//  NAMESPACING (plan decision #8): for now this uses OpenIslandCore's default socket + managed
//  paths, which makes the hook round-trip work out of the box (the installed hook command
//  resolves to the same default socket this in-process server binds). Full coexistence with a
//  separately-installed Open Island (a NotchNerd-specific socket + OPEN_ISLAND_SOCKET_PATH baked
//  into the hook command) is a documented vendored-installer patch deferred to Phase 6.
//

import AppKit
import Combine
import Foundation

import Defaults
import OpenIslandCore

enum HookInstallState: Equatable {
    case unknown
    case installed
    case notInstalled
    case failed(String)
}

/// A discrete "this session wants your attention" signal — the notification auto-pop trigger.
/// Mirrors Open Island's `IslandSurface.notificationSurface(for:)`.
struct AgentNotification: Equatable {
    /// `nudge` = a session has been blocked on you (or running) longer than the configured threshold.
    enum Kind { case permission, question, completion, nudge }
    let sessionID: String
    let kind: Kind
    /// Completion notices and nudges auto-collapse; permission/question persist until resolved.
    var autoDismisses: Bool { kind == .completion || kind == .nudge }
}

@MainActor
final class AgentBridgeManager: ObservableObject {
    static let shared = AgentBridgeManager()

    // MARK: Published UI state (derived from the private SessionState reducer)

    /// Sorted, deduplicated sessions — bind the Agent tab list to this.
    @Published private(set) var sessions: [AgentSession] = []
    /// First session that needs the user (approval/answer); nil otherwise.
    @Published private(set) var actionableSession: AgentSession?
    /// Count of sessions in `.waitingForApproval` / `.waitingForAnswer`.
    /// PERSISTENT closed-notch indicator source (never auto-expires).
    @Published private(set) var attentionCount: Int = 0
    @Published private(set) var liveSessionCount: Int = 0
    /// Live sessions whose turn finished and are waiting on your reply (not blocked on a prompt).
    @Published private(set) var yourTurnCount: Int = 0
    /// Sessions hidden by `snooze(sessionID:)` until they do something new.
    @Published private(set) var snoozedCount: Int = 0

    /// Sessions actively *working right now* = mid-turn (`phase == .running`) with a live process.
    ///
    /// We deliberately DON'T time-gate this. Classic hooks fire only at turn/tool boundaries, so during
    /// long silent generation ("thinking") no event lands and `updatedAt` freezes — the old 60s recency
    /// window then flipped "working" OFF mid-turn even though Claude was still going (the user-reported
    /// "thinking doesn't show as working"). Now that liveness is reliable — `Stop`/`StopFailure`/
    /// `SessionEnd` drive `.completed`, and a dead process is ended within ~6s by `markProcessLiveness`
    /// — `phase == .running` is itself the precise on/off signal, matching the Agent tab's row dot.
    var workingCount: Int {
        sessions.filter { $0.phase == .running && $0.isProcessAlive }.count
    }

    @Published private(set) var isBridgeReady: Bool = false
    @Published private(set) var hookInstallState: HookInstallState = .unknown
    /// Deep hook-integrity diagnostic (stale command path / non-executable binary / malformed config /
    /// other hooks present) — catches the failure the simple "managed hooks present" check can't. Drives
    /// the Settings repair affordance; nil until first checked.
    @Published private(set) var hookHealth: HookHealthReport?
    @Published private(set) var lastStatusMessage: String = ""

    // MARK: Notification signals (drive the in-notch auto-pop; observed by the coordinator)

    /// Fires when a session newly needs attention. A discrete event (NOT @Published state) so a
    /// dismissed card can't be re-popped by an unrelated republish.
    let notificationPublisher = PassthroughSubject<AgentNotification, Never>()
    /// Fires (sessionID) when a popped card should self-close (resolved / answered / dismissed).
    let notificationDismissPublisher = PassthroughSubject<String, Never>()

    // MARK: Engine objects (vendored OpenIslandCore)

    private let bridgeServer = BridgeServer()                 // headless; binds the default socket
    private var bridgeClient = LocalBridgeClient()
    private var state = SessionState() {
        didSet {
            // Keep the server's localState in agreement so hasSession()/restore lookups inside
            // BridgeServer match ours (mirrors AppModel.state didSet).
            bridgeServer.updateStateSnapshot(state)
        }
    }

    private lazy var installManager = makeInstallManager()
    private let registry = ClaudeSessionRegistry()
    // Tight window: with the `isVisibleInIsland` publish filter + TTY/cwd liveness match below,
    // discovery's only remaining job is recovering a session that is *still running* but whose hooks
    // we missed (app launched after Claude) — not resurfacing 24h of cleared/finished history.
    private let transcriptDiscovery = ClaudeTranscriptDiscovery(maxAge: 15 * 60, maxFiles: 8)

    // MARK: Task / timer bookkeeping

    private var hasStarted = false
    private var bridgeTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var livenessTimer: DispatchSourceTimer?
    private var persistDebounce: Task<Void, Never>?
    /// Session ids (and `"<cwd>#<count>"` fallback keys) already tried by `recoverUntrackedSessions`.
    private var recoveryAttempts: Set<String> = []
    /// Sessions currently matched to a Claude desktop app chat process (refreshed every liveness poll).
    private var desktopSessionIDs: Set<String> = []
    /// Chat titles (the Claude app sidebar name, or `/rename`) read from each session's transcript,
    /// plus the transcript mtime they were read at so unchanged files aren't re-read every poll.
    private var chatTitles: [String: String] = [:]
    private var chatTitleStamps: [String: Date] = [:]
    /// Titles straight from live processes' `~/.claude/sessions/<pid>.json` — preferred over transcripts.
    private var liveSessionNames: [String: String] = [:]
    /// Claude desktop app chat ids (`local_…`) by session id, for opening the exact chat.
    private var desktopHostSessionIDs: [String: String] = [:]
    /// Monotonic generation guard — defeats reconnect storms.
    private var connectionGeneration = 0
    private var reconnectDelay = AgentBridgeManager.reconnectBaseDelay

    private static let reconnectBaseDelay: Duration = .seconds(2)
    private static let reconnectMaxDelay: Duration = .seconds(30)
    /// Fast cadence — used only while a session is actively working (or a workflow is running), when
    /// we want responsive death-detection / workflow updates.
    private static let livenessInterval: DispatchTimeInterval = .seconds(3)
    /// Idle cadence — when nothing is `.running`, the backstop only needs to notice a session dying
    /// or a new live/bridge process appearing, which tolerates a much slower poll. This is the
    /// single biggest idle-battery win: it turns a fixed 3s `ps -Ao`/`lsof` spawn loop into a ~20s
    /// one whenever nothing is actively happening (most of the time).
    private static let livenessIdleInterval: DispatchTimeInterval = .seconds(20)
    /// Whether the liveness timer is currently on the fast (3s) schedule.
    private var livenessIsFast = false

    private init() {}

    // MARK: - Lifecycle

    /// Called from AppDelegate.applicationDidFinishLaunching. Idempotent.
    func start() {
        guard !hasStarted else { return }
        guard Defaults[.agentEnabled] else { return }
        hasStarted = true

        restoreFromRegistry()        // seed state before the bridge so the panel isn't empty
        startBridge()
        discoverTranscriptsOnce()    // startup recovery from ~/.claude/projects
        startLivenessBackstop()
        refreshHookStatus()
        GrokBotMonitor.shared.start()

        if Defaults[.agentAutoInstallHooks], hookInstallState != .installed {
            installHooks()
        }
    }

    /// Called from AppDelegate.applicationWillTerminate.
    func stop() {
        persistRegistryNow()
        bridgeTask?.cancel(); bridgeTask = nil
        reconnectTask?.cancel(); reconnectTask = nil
        livenessTimer?.cancel(); livenessTimer = nil
        GrokBotMonitor.shared.stop()
        persistDebounce?.cancel(); persistDebounce = nil
        bridgeClient.disconnect()
        // BridgeServer.stop() does a `queue.sync` onto the bridge queue. If that queue is stuck in
        // `writeAll` to an observer whose socket buffer is full (it spins on EAGAIN forever), the
        // sync never returns — seen as Quit hanging with the notch frozen (sampled: main thread in
        // applicationWillTerminate → stop() → _dispatch_sync_f_slow). Stop it off the main thread and
        // stop waiting after a second; on quit the process exits anyway.
        let server = bridgeServer
        let stopped = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            server.stop()
            stopped.signal()
        }
        _ = stopped.wait(timeout: .now() + 1)
        isBridgeReady = false
        hasStarted = false
    }

    // MARK: - Bridge server + observer

    private func startBridge() {
        do {
            try bridgeServer.start()
            connectObserver()
        } catch {
            isBridgeReady = false
            lastStatusMessage = "Failed to start agent bridge: \(error.localizedDescription)"
            // Fail-soft: the music notch is unaffected; hooks still fail-open.
        }
    }

    /// Fresh client per attempt, single task for registration + consumption.
    private func connectObserver() {
        bridgeTask?.cancel()
        bridgeClient.disconnect()

        connectionGeneration += 1
        let generation = connectionGeneration

        let client = LocalBridgeClient()
        bridgeClient = client

        let stream: AsyncThrowingStream<AgentEvent, Error>
        do {
            stream = try client.connect()        // yields .event envelopes only
        } catch {
            isBridgeReady = false
            lastStatusMessage = "Failed to connect agent observer: \(error.localizedDescription)"
            scheduleReconnect()
            return
        }

        bridgeTask = Task { [weak self] in
            guard let self else { return }
            do {
                // connect() does NOT auto-register; announce ourselves as an observer.
                try await client.send(.registerClient(role: .observer))
                guard generation == self.connectionGeneration else { return }
                self.isBridgeReady = true
                self.reconnectDelay = Self.reconnectBaseDelay
                self.lastStatusMessage = "Agent bridge ready. Watching Claude Code hooks."
            } catch {
                guard !Task.isCancelled, generation == self.connectionGeneration else { return }
                self.isBridgeReady = false
                self.scheduleReconnect()
                return
            }

            do {
                for try await event in stream {
                    guard generation == self.connectionGeneration else { return }
                    self.ingest(event)
                }
            } catch { /* stream error → reconnect below */ }

            guard !Task.isCancelled, generation == self.connectionGeneration else { return }
            self.isBridgeReady = false
            self.lastStatusMessage = "Agent bridge disconnected. Reconnecting…"
            self.scheduleReconnect()
        }
    }

    /// One long-lived backoff loop. Single reconnectTask + reset-on-success delay means a late
    /// failure from a superseded connection can't spawn a parallel loop (storm fix).
    private func scheduleReconnect() {
        guard reconnectTask == nil else { return }
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, Self.reconnectMaxDelay)
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.reconnectTask = nil
            self.connectObserver()
        }
    }

    // MARK: - Event ingestion (our slim applyTrackedEvent)

    private func ingest(_ event: AgentEvent) {
        trackActivityFlags(for: event)
        state.apply(event)                       // single source of truth
        // Keep an actively-emitting session marked alive so a transient `ps`/`lsof` hiccup can't
        // force-end a turn that's clearly still running (restores the per-event keep-alive that the
        // slim driver had dropped vs. upstream). Idle-but-alive sessions are kept alive separately by
        // the TTY/cwd process match in `startLivenessBackstop`. We deliberately do NOT revive a
        // session whose terminal already went away (`isSessionEnded`).
        let sid = Self.sessionID(of: event)
        if let session = state.session(id: sid), session.tool == .claudeCode, !session.isSessionEnded {
            state.markSingleSessionAlive(sessionID: sid)
        }
        republish()
        schedulePersist()
        emitNotification(for: event)
        // Keep an expanded row's full detail fresh; collapsed rows only need the cheap ctx tail-read
        // (refreshed from the liveness tick), so don't pay the full ≤12MB scan on every event.
        if expandedSessionIDs.contains(sid) {
            loadTranscriptDetail(for: sid)
        }
        // If this event made a session active, switch the liveness backstop to its fast cadence now
        // rather than waiting out the (up to 20s) idle interval.
        nudgeLivenessIfIdle()
    }

    /// Every `AgentEvent` payload carries the session it concerns.
    private static func sessionID(of event: AgentEvent) -> String {
        switch event {
        case let .sessionStarted(p): return p.sessionID
        case let .activityUpdated(p): return p.sessionID
        case let .permissionRequested(p): return p.sessionID
        case let .questionAsked(p): return p.sessionID
        case let .sessionCompleted(p): return p.sessionID
        case let .jumpTargetUpdated(p): return p.sessionID
        case let .sessionMetadataUpdated(p): return p.sessionID
        case let .claudeSessionMetadataUpdated(p): return p.sessionID
        case let .geminiSessionMetadataUpdated(p): return p.sessionID
        case let .openCodeSessionMetadataUpdated(p): return p.sessionID
        case let .cursorSessionMetadataUpdated(p): return p.sessionID
        case let .actionableStateResolved(p): return p.sessionID
        }
    }

    /// Map an engine event → a notification signal (mirrors IslandSurface.notificationSurface).
    private func emitNotification(for event: AgentEvent) {
        guard Defaults[.agentNotificationsEnabled] else { return }
        switch event {
        case let .permissionRequested(payload):
            notificationPublisher.send(AgentNotification(sessionID: payload.sessionID, kind: .permission))
        case let .questionAsked(payload):
            notificationPublisher.send(AgentNotification(sessionID: payload.sessionID, kind: .question))
        case let .sessionCompleted(payload) where payload.isInterrupt != true:
            if Defaults[.agentNotifyOnCompletion] {
                notificationPublisher.send(AgentNotification(sessionID: payload.sessionID, kind: .completion))
            }
        default:
            break
        }
    }

    // MARK: Derived activity flags (stopped / compacting)

    /// Sessions whose last completion was a user interrupt (ESC / `isInterrupt`). A genuine
    /// StopFailure is NOT detectable observer-side (the engine folds it into a normal
    /// `.sessionCompleted` whose summary is the error text) — that refinement needs a Vendor patch
    /// and is deliberately deferred.
    private var stoppedSessionIDs: Set<String> = []
    /// PreCompact has no matching "compact done" hook; entries expire via `isCompacting`'s TTL.
    private var compactingSessions: [String: Date] = [:]

    func isStopped(_ sessionID: String) -> Bool { stoppedSessionIDs.contains(sessionID) }

    func isCompacting(_ sessionID: String) -> Bool {
        guard let began = compactingSessions[sessionID] else { return false }
        return Date().timeIntervalSince(began) < 12
    }

    private func trackActivityFlags(for event: AgentEvent) {
        switch event {
        case let .sessionCompleted(payload):
            if payload.isInterrupt == true { stoppedSessionIDs.insert(payload.sessionID) }
            compactingSessions.removeValue(forKey: payload.sessionID)
        case let .activityUpdated(payload):
            stoppedSessionIDs.remove(payload.sessionID)
            // The engine's PreCompact handler emits exactly this summary (BridgeServer .preCompact).
            if payload.summary.hasSuffix("is compacting the conversation.") {
                compactingSessions[payload.sessionID] = Date()
            } else {
                compactingSessions.removeValue(forKey: payload.sessionID)
            }
        case let .permissionRequested(payload):
            stoppedSessionIDs.remove(payload.sessionID)
        case let .questionAsked(payload):
            stoppedSessionIDs.remove(payload.sessionID)
        default:
            break
        }
    }

    // MARK: Row expansion (manager-owned)

    /// Rows the user has expanded. Manager-owned (not per-row @State) so expansion survives the
    /// notch reopening / tab switches, which tear down the row views (the old @State +
    /// AgentRowExpansion.userCollapsed approach lost manual expands on every remount). Pruned
    /// against the visible set in republish(); attention rows are seeded expanded on arrival.
    @Published private(set) var expandedSessionIDs: Set<String> = []
    /// Attention rows already auto-expanded once — so a user collapse isn't fought every republish.
    private var attentionSeededIDs: Set<String> = []

    func toggleExpansion(_ sessionID: String) {
        if expandedSessionIDs.contains(sessionID) {
            expandedSessionIDs.remove(sessionID)
        } else {
            expandedSessionIDs.insert(sessionID)
            loadTranscriptDetail(for: sessionID)
            refreshWorkflowActivity(force: true)
        }
    }

    // MARK: Transcript detail (expanded rows)

    /// Per-session transcript-derived detail (timeline / files / stats / plan text). Loaded
    /// off-main on expand and opportunistically on new events for expanded rows; mtime-guarded,
    /// debounced, pruned with the visible set.
    @Published private(set) var transcriptDetails: [String: ClaudeTranscriptDetail] = [:]
    /// Cheap per-session context footprint (tail-read) for the collapsed `ctx` badge — separate from
    /// the full `transcriptDetails` (≤12MB forward scan) which is only loaded for expanded rows.
    @Published private(set) var contextTokensBySession: [String: Int] = [:]
    private var transcriptMTimes: [String: Date] = [:]
    private var transcriptReadAt: [String: Date] = [:]
    private var transcriptLoadsInFlight: Set<String> = []

    func loadTranscriptDetail(for sessionID: String) {
        guard let session = state.session(id: sessionID),
              let path = session.claudeMetadata?.transcriptPath else { return }
        // Debounce event-burst refreshes; the mtime guard below dedupes identical content.
        if let last = transcriptReadAt[sessionID], Date().timeIntervalSince(last) < 5 { return }
        let mtime = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        if let mtime, transcriptMTimes[sessionID] == mtime, transcriptDetails[sessionID] != nil { return }
        guard !transcriptLoadsInFlight.contains(sessionID) else { return }
        transcriptLoadsInFlight.insert(sessionID)
        transcriptReadAt[sessionID] = Date()
        Task.detached(priority: .userInitiated) { [weak self] in
            let detail = ClaudeTranscriptReader.read(transcriptPath: path)
            await MainActor.run {
                guard let self else { return }
                self.transcriptLoadsInFlight.remove(sessionID)
                if let mtime { self.transcriptMTimes[sessionID] = mtime }
                if let detail { self.transcriptDetails[sessionID] = detail }
            }
        }
    }

    private func reconcileExpansion(visible: [AgentSession]) {
        let visibleIDs = Set(visible.map(\.id))
        expandedSessionIDs.formIntersection(visibleIDs)
        attentionSeededIDs.formIntersection(visibleIDs)
        stoppedSessionIDs.formIntersection(visibleIDs)
        compactingSessions = compactingSessions.filter { visibleIDs.contains($0.key) }
        transcriptDetails = transcriptDetails.filter { visibleIDs.contains($0.key) }
        transcriptMTimes = transcriptMTimes.filter { visibleIDs.contains($0.key) }
        transcriptReadAt = transcriptReadAt.filter { visibleIDs.contains($0.key) }
        contextTokensBySession = contextTokensBySession.filter { visibleIDs.contains($0.key) }
        for session in visible {
            if session.phase.requiresAttention {
                // Seed once per attention episode; re-arm after the episode ends.
                if !attentionSeededIDs.contains(session.id) {
                    attentionSeededIDs.insert(session.id)
                    expandedSessionIDs.insert(session.id)
                }
            } else {
                attentionSeededIDs.remove(session.id)
            }
        }
    }

    /// Recompute the @Published projection from the private reducer.
    private func republish() {
        // Only surface sessions that are live in a terminal *right now* (`isVisibleInIsland`:
        // hook-managed & not-ended, process-alive, or needing attention). This is what makes the tab
        // show only what's currently running — it drops /clear'd session-ids (superseded → force-ended
        // by the TTY match), dead processes, and the stale registry/transcript history that the engine
        // otherwise keeps in `state.sessions` forever. The closed-notch counts already use this gate.
        let live = state.sessions.filter(\.isVisibleInIsland)
        let visible = live.filter { !isSnoozed($0) }
        snoozedCount = live.count - visible.count
        // Order by what's waiting on you, preserving recency within each group: blocked on an
        // approval/answer first, then finished turns awaiting your reply, then ones still running.
        let needsAttention = visible.filter { $0.phase.requiresAttention }
        let finished = visible.filter { $0.phase == .completed }
        let running = visible.filter { $0.phase == .running }
        reconcileKeepPlanning()
        reconcileExpansion(visible: visible)
        sessions = (needsAttention + finished + running).map(presented).map(projectedKeepPlanning)
        actionableSession = needsAttention.first.map(presented)
        attentionCount = needsAttention.count
        yourTurnCount = finished.count
        liveSessionCount = visible.count
    }

    // MARK: - Snooze

    /// Hide a session (from the list, counts and pops) until it runs again or asks for something.
    func snooze(sessionID: String) {
        guard let session = state.session(id: sessionID) else { return }
        Defaults[.agentSnoozedSessions][sessionID] = session.updatedAt
        republish()
        notificationDismissPublisher.send(sessionID)
    }

    func unsnoozeAll() {
        Defaults[.agentSnoozedSessions] = [:]
        republish()
    }

    /// Snoozed until the session does something new: a later event that has it running or blocked on
    /// you. (A later event that leaves it idle — e.g. Claude Code's idle reminder — keeps it snoozed.)
    private func isSnoozed(_ session: AgentSession) -> Bool {
        guard let snoozedAt = Defaults[.agentSnoozedSessions][session.id] else { return false }
        let didSomethingNew = session.updatedAt > snoozedAt
            && (session.phase == .running || session.phase.requiresAttention)
        if didSomethingNew {
            Defaults[.agentSnoozedSessions][session.id] = nil
            return false
        }
        return true
    }

    /// Drop snoozes for sessions that are gone, so the stored map doesn't grow forever.
    private func pruneSnoozes() {
        let snoozed = Defaults[.agentSnoozedSessions]
        guard !snoozed.isEmpty else { return }
        let live = Set(state.sessions.filter(\.isVisibleInIsland).map(\.id))
        let kept = snoozed.filter { live.contains($0.key) }
        if kept.count != snoozed.count { Defaults[.agentSnoozedSessions] = kept }
    }

    // MARK: - Stuck nudges

    /// When each running session's current turn started (cleared when it stops running).
    private var runningSince: [String: Date] = [:]
    /// Nudges already sent, keyed by session + the episode they cover, so each fires once.
    private var sentNudges: Set<String> = []
    /// Waits that began before NotchNerd launched aren't nudged — otherwise every relaunch would pop
    /// (then auto-close) the notch for chats you'd already left blocked.
    private let nudgeEpoch = Date()

    /// One pop when a session has been blocked on you for `agentNudgeBlockedMinutes`, or running for
    /// `agentNudgeRunningMinutes` (0 disables either). Snoozed sessions aren't in `sessions`, so they
    /// never nudge.
    private func checkNudges(now: Date = .now) {
        let blockedMinutes = Defaults[.agentNudgeBlockedMinutes]
        let runningMinutes = Defaults[.agentNudgeRunningMinutes]
        var stillRunning: Set<String> = []
        for session in sessions {
            if session.phase == .running {
                stillRunning.insert(session.id)
                let since = runningSince[session.id] ?? now
                runningSince[session.id] = since
                let key = "\(session.id)#running#\(since.timeIntervalSince1970)"
                if runningMinutes > 0, now.timeIntervalSince(since) >= Double(runningMinutes) * 60,
                   sentNudges.insert(key).inserted {
                    sendNudge(for: session.id)
                }
            } else if session.phase.requiresAttention {
                let key = "\(session.id)#blocked#\(session.updatedAt.timeIntervalSince1970)"
                if blockedMinutes > 0, session.updatedAt >= nudgeEpoch,
                   now.timeIntervalSince(session.updatedAt) >= Double(blockedMinutes) * 60,
                   sentNudges.insert(key).inserted {
                    sendNudge(for: session.id)
                }
            }
        }
        runningSince = runningSince.filter { stillRunning.contains($0.key) }
    }

    private func sendNudge(for sessionID: String) {
        guard Defaults[.agentNotificationsEnabled] else { return }
        notificationPublisher.send(AgentNotification(sessionID: sessionID, kind: .nudge))
    }

    // MARK: - Keyboard: jump through waiting sessions

    private var lastJumpedSessionID: String?

    /// Jump to the next session waiting on you (blocked first, then finished), cycling on repeat presses.
    func jumpToNextWaiting() {
        let waiting = sessions.filter { $0.phase != .running && canJump($0) }
        guard !waiting.isEmpty else {
            lastStatusMessage = "No Claude sessions are waiting on you."
            return
        }
        let next: AgentSession
        if let last = lastJumpedSessionID, let index = waiting.firstIndex(where: { $0.id == last }) {
            next = waiting[(index + 1) % waiting.count]
        } else {
            next = waiting[0]
        }
        lastJumpedSessionID = next.id
        jump(sessionID: next.id)
    }

    private func presented(_ session: AgentSession) -> AgentSession {
        var session = Self.debranded(session)
        // "App store pages localization · Zeteo-News" instead of "Claude · Zeteo-News", so several
        // chats in one repo are distinguishable.
        if let title = liveSessionNames[session.id] ?? chatTitles[session.id] {
            let workspace = session.jumpTarget?.workspaceName ?? ""
            session.title = workspace.isEmpty ? title : "\(title) · \(workspace)"
        }
        // Desktop chats have no terminal, so the hook records terminalApp "Unknown" — name the host.
        if desktopSessionIDs.contains(session.id), session.jumpTarget?.terminalApp == "Unknown" {
            session.jumpTarget?.terminalApp = "Claude"
        }
        return session
    }

    /// The vendored engine emits some user-visible summaries still branded "Open Island" (e.g. the
    /// permission-denied line in SessionState.resolvePermission, which ignores our directive's
    /// message). We keep Vendor/ pristine, so rewrite the brand here at the projection boundary
    /// instead of patching the engine (Phase 5.5 audit).
    private static func debranded(_ session: AgentSession) -> AgentSession {
        guard session.summary.contains("Open Island") else { return session }
        var session = session
        session.summary = session.summary.replacingOccurrences(of: "Open Island", with: "NotchNerd")
        return session
    }

    // MARK: - UI callbacks (Agent tab cards)

    func approve(sessionID: String) { resolve(sessionID: sessionID, action: .allowOnce) }
    func deny(sessionID: String)    { resolve(sessionID: sessionID, action: .deny) }

    /// Allow / Allow-with-updates / Deny. Optimistic local clear, then bridge round-trip.
    func resolve(sessionID: String, action: ApprovalAction) {
        guard let session = state.session(id: sessionID) else { return }

        let resolution: PermissionResolution
        switch action {
        case .deny:
            resolution = .deny(message: "Permission denied in NotchNerd.", interrupt: false)
        case .allowOnce:
            resolution = .allowOnce()
        case let .allowWithUpdates(updates):
            resolution = .allowOnce(updatedPermissions: updates)
        }

        // Optimistic: clear the card immediately.
        state.resolvePermission(sessionID: session.id, resolution: resolution)
        republish()

        // Round-trip: BridgeServer routes the directive to the BLOCKED hook, not back to us.
        send(.resolvePermission(sessionID: session.id, resolution: resolution))
        notificationDismissPublisher.send(session.id)
    }

    func answer(sessionID: String, response: QuestionPromptResponse) {
        guard let session = state.session(id: sessionID) else { return }
        state.answerQuestion(sessionID: session.id, response: response)
        republish()
        send(.answerQuestion(sessionID: session.id, response: response))
        notificationDismissPublisher.send(session.id)
    }

    // MARK: Plan mode ("No, keep planning")

    /// Sessions where the user chose "keep planning" on a plan-review card. The engine's deny path
    /// flips the row to `.completed` with a hardcoded "Permission denied…" summary (ignoring our
    /// message), which reads wrong for a keep-planning action — `projectedKeepPlanning` rewrites
    /// the projection until Claude resumes (`.running`) and the flag reconciles away.
    private var keepPlanningSessionIDs: Set<String> = []

    /// "No, keep planning" from the plan-review card: a deny whose message carries the user's plan
    /// feedback back to Claude (it revises the plan and calls ExitPlanMode again).
    func keepPlanning(sessionID: String, feedback: String) {
        guard let session = state.session(id: sessionID) else { return }
        let trimmed = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = trimmed.isEmpty
            ? "Keep planning — the user wants to refine the plan before implementation."
            : trimmed
        let resolution = PermissionResolution.deny(message: message, interrupt: false)
        keepPlanningSessionIDs.insert(session.id)
        state.resolvePermission(sessionID: session.id, resolution: resolution)
        republish()
        send(.resolvePermission(sessionID: session.id, resolution: resolution))
        notificationDismissPublisher.send(session.id)
    }

    private func reconcileKeepPlanning() {
        guard !keepPlanningSessionIDs.isEmpty else { return }
        keepPlanningSessionIDs = keepPlanningSessionIDs.filter { id in
            guard let session = state.session(id: id) else { return false }
            return session.phase != .running
        }
    }

    private func projectedKeepPlanning(_ session: AgentSession) -> AgentSession {
        guard keepPlanningSessionIDs.contains(session.id) else { return session }
        var session = session
        session.summary = "Planning continues — feedback sent to Claude."
        return session
    }

    func dismiss(sessionID: String) {
        state.dismissSession(id: sessionID)
        republish()
        notificationDismissPublisher.send(sessionID)
    }

    /// Bring the session's terminal to the foreground (Ghostty or macOS Terminal.app).
    /// Ghostty uses jumpResolving (no-op if already focused, else re-resolves a stale surface id).
    func jump(sessionID: String) {
        if isDesktopSession(sessionID) {
            // The desktop app's own deep link (also used by its Dock/tray menu) opens the exact chat;
            // it only accepts its `local_…` chat ids. Without one, just bring the app forward.
            if let host = desktopHostSessionIDs[sessionID],
               host.range(of: #"^local_[A-Za-z0-9-]{1,64}$"#, options: .regularExpression) != nil,
               let url = URL(string: "claude://code/continue?session=\(host)") {
                NSWorkspace.shared.open(url)
            } else if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.claudeDesktopBundleID) {
                NSWorkspace.shared.openApplication(at: app, configuration: .init())
            }
            return
        }
        guard let session = state.session(id: sessionID), let target = session.jumpTarget else { return }
        let appName = AgentTerminalJump.appName(for: target)
        Task.detached(priority: .userInitiated) { [weak self] in
            let ok = AgentTerminalJump.jump(to: target)
            await MainActor.run {
                self?.lastStatusMessage = ok
                    ? "Focused the \(appName) terminal."
                    : "Couldn’t find the \(appName) terminal — it may have closed."
            }
        }
    }

    func canJump(_ session: AgentSession) -> Bool {
        isDesktopSession(session.id) || AgentTerminalJump.canJump(to: session.jumpTarget)
    }

    /// True when the session is a Claude desktop app (Code tab) chat rather than a terminal `claude`.
    func isDesktopSession(_ sessionID: String) -> Bool {
        desktopSessionIDs.contains(sessionID)
    }

    static let claudeDesktopBundleID = "com.anthropic.claudefordesktop"

    private func send(_ command: BridgeCommand) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.bridgeClient.send(command)
            } catch {
                self.lastStatusMessage = "Failed to send agent command: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Hook installation

    /// The resolved `~/.claude` config directory (honours the `agentClaudeConfigDir` override).
    private func claudeConfigDirectory() -> URL {
        let overridePath = Defaults[.agentClaudeConfigDir]
        return overridePath.isEmpty
            ? ClaudeConfigDirectory.resolved()
            : URL(fileURLWithPath: (overridePath as NSString).expandingTildeInPath, isDirectory: true)
    }

    private func makeInstallManager() -> ClaudeHookInstallationManager {
        ClaudeHookInstallationManager(claudeDirectory: claudeConfigDirectory(), hookSource: "claude")
    }

    /// The embedded hook binary at <app>/Contents/Helpers/OpenIslandHooks (Phase 1 step 2b).
    private func embeddedHooksBinaryURL() -> URL? {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/OpenIslandHooks")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// Installs the Claude Code hooks. Returns `false` ONLY for the SYNCHRONOUS failure (the embedded
    /// helper is missing); the async outcome is published later via `hookInstallState`. Callers that
    /// need a per-attempt completion signal observe `hookInstallState` — it is reset to a transient
    /// value here first, so a repeated identical result is still an observable Equatable change.
    @discardableResult
    func installHooks() -> Bool {
        guard let source = embeddedHooksBinaryURL() else {
            hookInstallState = .failed("Agent hook helper not found in the app bundle.")
            lastStatusMessage = hookInstallStateMessage
            return false
        }

        // Reset before the async work so an identical repeat result (.installed/.failed with the same
        // value) is still an observable transition for SwiftUI `onChange` observers, not a deduped no-op.
        hookInstallState = .unknown

        Task { [weak self] in
            guard let self else { return }
            do {
                // install() COPIES `source` → the managed bin location, backs up settings.json, and
                // writes hooks pointing at the managed copy. Idempotent.
                let status = try await Task.detached(priority: .userInitiated) { [installManager = self.installManager] in
                    try installManager.install(hooksBinaryURL: source)
                }.value
                self.hookInstallState = status.managedHooksPresent ? .installed : .notInstalled
                self.lastStatusMessage = "Claude Code hooks installed."
                self.checkHookHealth()
            } catch {
                // Never destroy the user's settings.json; the installer already backed it up.
                self.hookInstallState = .failed(error.localizedDescription)
                self.lastStatusMessage = "Hook install failed: \(error.localizedDescription)"
            }
        }
        return true
    }

    func uninstallHooks() {
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await Task.detached(priority: .userInitiated) { [installManager = self.installManager] in
                    try installManager.uninstall()
                }.value
                self.hookInstallState = .notInstalled
                self.lastStatusMessage = "Claude Code hooks removed."
            } catch {
                self.hookInstallState = .failed(error.localizedDescription)
            }
        }
    }

    func refreshHookStatus() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let status = try await Task.detached(priority: .utility) { [installManager = self.installManager] in
                    try installManager.status()
                }.value
                self.hookInstallState = status.managedHooksPresent ? .installed : .notInstalled
            } catch {
                self.hookInstallState = .unknown
            }
            self.checkHookHealth()
        }
    }

    /// Run the deep hook-integrity diagnostic (`HookHealthCheck`) and publish the report. Catches what
    /// the simple "managed hooks present" status can't: a `settings.json` hook command pointing at a
    /// binary that no longer exists (e.g. after the app moved, or a different build wrote the hooks) —
    /// the #1 silent cause of missing live sessions. The repairable issues are all fixed by reinstalling.
    func checkHookHealth() {
        let claudeDir = claudeConfigDirectory()
        let binary = embeddedHooksBinaryURL()
        Task { [weak self] in
            guard let self else { return }
            let report = await Task.detached(priority: .utility) {
                HookHealthCheck.checkClaude(claudeDirectory: claudeDir, hooksBinaryURL: binary)
            }.value
            self.hookHealth = report
        }
    }

    private var hookInstallStateMessage: String {
        switch hookInstallState {
        case .unknown:      return "Hook status unknown."
        case .installed:    return "Claude Code hooks installed."
        case .notInstalled: return "Claude Code hooks not installed."
        case let .failed(m): return "Hook error: \(m)"
        }
    }

    // MARK: - Startup discovery + liveness + registry

    private func restoreFromRegistry() {
        do {
            let records = try registry.load()
            let restored = records.map { $0.restorableSession }  // forces .stale
            if !restored.isEmpty {
                state = SessionState(sessions: restored)
                republish()
            }
        } catch {
            lastStatusMessage = "Could not restore agent sessions: \(error.localizedDescription)"
        }
    }

    /// One-shot transcript recovery so the panel is populated on first open even before any hook
    /// fires. Live bridge events always win (apply only if absent).
    private func discoverTranscriptsOnce() {
        Task { [weak self] in
            guard let self else { return }
            let (discovered, snapshots) = await Task.detached(priority: .utility) { [discovery = self.transcriptDiscovery] in
                (discovery.discoverRecentSessions(), ActiveAgentProcessDiscovery().discover())
            }.value
            self.applyDiscoveredSessions(discovered, liveSnapshots: snapshots)
            self.republish()
        }
    }

    /// Apply recovered transcript sessions, attaching a live `claude` process's TTY (+ terminal app)
    /// when one shares the session's cwd. Without this, a session that was live across an app restart
    /// — or a remote-control/bridge session whose turns don't fire local hooks — is recovered only as
    /// a tty-less `.completed` record that the liveness backstop can't match, so it never becomes
    /// visible even though its process is alive. Attaching the TTY lets the existing liveness path
    /// keep it visible.
    ///
    /// Safe against the deliberately-removed cwd-matching (which used to rescue *dead* sessions via a
    /// sibling terminal in the same repo): only a **live** process's cwd adopts a session, only the
    /// **newest** recovered session per free TTY is adopted, and `ClaudeTranscriptDiscovery`'s 15-min
    /// freshness window already excludes stale transcripts.
    private func applyDiscoveredSessions(
        _ discovered: [AgentSession],
        liveSnapshots: [ActiveAgentProcessDiscovery.ProcessSnapshot]
    ) {
        let newSessions = discovered.filter { state.session(id: $0.id) == nil }
        guard !newSessions.isEmpty else { return }

        // Live claude terminals by cwd, minus TTYs already covered by a tracked (non-ended) session.
        let trackedTTYs = Set(state.sessions
            .filter { $0.tool == .claudeCode && !$0.isSessionEnded }
            .compactMap { $0.jumpTarget?.terminalTTY })
        var liveByCwd: [String: [(tty: String, app: String?)]] = [:]
        for snap in liveSnapshots where snap.tool == .claudeCode {
            guard let cwd = snap.workingDirectory, let tty = snap.terminalTTY,
                  !trackedTTYs.contains(tty) else { continue }
            liveByCwd[cwd, default: []].append((tty, snap.terminalApp))
        }

        // Assign each free TTY to the newest recovered session in the same cwd.
        var ttyForID: [String: (tty: String, app: String?)] = [:]
        let byCwd = Dictionary(grouping: newSessions.filter { $0.jumpTarget?.workingDirectory != nil }) {
            $0.jumpTarget!.workingDirectory!
        }
        for (cwd, sessions) in byCwd {
            var free = liveByCwd[cwd] ?? []
            for session in sessions.sorted(by: { $0.updatedAt > $1.updatedAt }) {
                guard !free.isEmpty else { break }
                ttyForID[session.id] = free.removeFirst()
            }
        }

        for session in newSessions {
            var enriched = session
            if let live = ttyForID[session.id] {
                var jump = enriched.jumpTarget
                    ?? JumpTarget(terminalApp: live.app ?? "", workspaceName: "", paneTitle: "")
                jump.terminalTTY = live.tty
                // The live process authoritatively identifies the terminal (Ghostty/Terminal); the
                // transcript-recovered target only has the "Unknown" placebo, so prefer the process's
                // value — otherwise canJump rejects the adopted session and shows no jump button.
                if let app = live.app, !app.isEmpty { jump.terminalApp = app }
                enriched.jumpTarget = jump
            }
            state.apply(.sessionStarted(SessionStarted(
                sessionID: enriched.id,
                title: enriched.title,
                tool: .claudeCode,
                origin: .live,
                initialPhase: .completed,           // recovered = completed/stale; hooks/liveness refine it
                summary: enriched.summary,
                timestamp: enriched.updatedAt,
                jumpTarget: enriched.jumpTarget,
                claudeMetadata: enriched.claudeMetadata
            )))
        }
    }

    /// Throttle for the liveness-driven orphan rescan (the transcript scan isn't free).
    private var lastOrphanScanAt = Date.distantPast

    // MARK: Dynamic-workflow agents (off-disk, hook-independent)

    /// Per-session running-workflow-agent activity, read from `<sessionDir>/subagents/workflows/`.
    /// The Workflow tool's agents don't fire SubagentStart hooks and aren't in `activeSubagents`, so
    /// this is the only way to show them — and it works for hookless/bridge sessions.
    @Published private(set) var workflowActivity: [String: WorkflowActivity] = [:]
    private var lastWorkflowScanAt = Date.distantPast

    /// Refresh workflow-agent activity for visible sessions (off-main, throttled). Cheap when no
    /// workflow is running (a missing dir / stale journal short-circuits before any parse).
    func refreshWorkflowActivity(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastWorkflowScanAt) > 3 else { return }
        lastWorkflowScanAt = now
        let paths: [(id: String, path: String)] = state.sessions
            .filter { $0.isVisibleInIsland && $0.tool == .claudeCode }
            .compactMap { session in session.claudeMetadata?.transcriptPath.map { (session.id, $0) } }
        guard !paths.isEmpty else {
            if !workflowActivity.isEmpty { workflowActivity = [:] }
            return
        }
        Task.detached(priority: .utility) { [weak self] in
            var result: [String: WorkflowActivity] = [:]
            for (id, path) in paths {
                if let activity = WorkflowAgentReader.read(transcriptPath: path) { result[id] = activity }
            }
            await MainActor.run {
                guard let self, self.workflowActivity != result else { return }
                self.workflowActivity = result   // @Published → rows re-render
            }
        }
    }

    /// Refresh the cheap per-session context footprint (tail-read) for every visible session — for
    /// the collapsed `ctx` badge. Runs off the liveness tick, so it inherits the adaptive cadence
    /// (3s active / 20s idle). Far cheaper than the full `loadTranscriptDetail` scan.
    func refreshContextTokens() {
        let paths: [(id: String, path: String)] = state.sessions
            .filter { $0.isVisibleInIsland && $0.tool == .claudeCode }
            .compactMap { session in session.claudeMetadata?.transcriptPath.map { (session.id, $0) } }
        guard !paths.isEmpty else {
            if !contextTokensBySession.isEmpty { contextTokensBySession = [:] }
            return
        }
        Task.detached(priority: .utility) { [weak self] in
            var result: [String: Int] = [:]
            for (id, path) in paths {
                if let ctx = ClaudeTranscriptReader.readContextTokens(transcriptPath: path) { result[id] = ctx }
            }
            await MainActor.run {
                guard let self, self.contextTokensBySession != result else { return }
                self.contextTokensBySession = result
            }
        }
    }

    /// Self-heal: if a live `claude` terminal has no tracked session (app restarted under a running
    /// session, or a bridge session whose turns never fired a local hook), rediscover its transcript
    /// and adopt it via `applyDiscoveredSessions` so it reappears within a liveness cycle — no user
    /// interaction required. Only runs when an orphan TTY actually exists, throttled to 20s.
    private func adoptOrphansIfNeeded(snapshots: [ActiveAgentProcessDiscovery.ProcessSnapshot]) {
        let trackedTTYs = Set(state.sessions
            .filter { $0.tool == .claudeCode && !$0.isSessionEnded }
            .compactMap { $0.jumpTarget?.terminalTTY })
        let hasOrphan = snapshots.contains { snap in
            snap.tool == .claudeCode && (snap.terminalTTY.map { !trackedTTYs.contains($0) } ?? false)
        }
        guard hasOrphan else { return }
        let now = Date()
        guard now.timeIntervalSince(lastOrphanScanAt) > 20 else { return }
        lastOrphanScanAt = now
        Task { [weak self] in
            guard let self else { return }
            let discovered = await Task.detached(priority: .utility) { [discovery = self.transcriptDiscovery] in
                discovery.discoverRecentSessions()
            }.value
            self.applyDiscoveredSessions(discovered, liveSnapshots: snapshots)
            self.republish()
        }
    }

    /// Process-liveness backstop: if the bridge dies before SessionEnd, missed polls mark a
    /// hook-managed session ended so it stops being stuck-visible.
    private func startLivenessBackstop() {
        // Self-rescheduling one-shot (not a fixed `repeating:`) so the cadence can adapt each tick:
        // 3s while something is actively happening, 20s when idle. The `ps -Ao`/`lsof` subprocess
        // spawns per tick are the cost, so stretching the idle cadence is the main battery win.
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.setEventHandler { [weak self] in
            let snapshots = ActiveAgentProcessDiscovery().discover()  // shells out to ps/lsof (off-actor)
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.recoverUntrackedSessions(from: snapshots)
                let namesChanged = self.updateLiveSessionNames(from: snapshots)
                let previousDesktopIDs = self.desktopSessionIDs
                let aliveClaudeIDs = self.aliveClaudeSessionIDs(from: snapshots)
                let changed = self.state.markProcessLiveness(aliveSessionIDs: aliveClaudeIDs)
                let titlesChanged = await self.refreshChatTitles()
                self.pruneSnoozes()
                // Only republish when something visible actually changed — liveness, chat titles/names,
                // or which sessions are desktop chats. `workingCount` is event-driven (`phase ==
                // .running && isProcessAlive`), and both its inputs already trigger a republish — phase
                // via `ingest`, isProcessAlive via `changed` here — so republishing every tick while a
                // session runs was a redundant per-3s full-tree re-render (a measured idle-battery cost).
                if !changed.isEmpty || titlesChanged || namesChanged || self.desktopSessionIDs != previousDesktopIDs {
                    self.republish()
                }
                self.checkNudges()
                // Re-adopt any live terminal we're not tracking (restart orphan / hookless bridge).
                self.adoptOrphansIfNeeded(snapshots: snapshots)
                // Surface dynamic-workflow agents (the only signal for a hookless session's workflow).
                self.refreshWorkflowActivity()
                // Cheap ctx tail-read for collapsed badges (replaces the full scan on every ingest).
                self.refreshContextTokens()
                // Pick the next tick's cadence from the (possibly just-updated) state.
                self.rescheduleLiveness()
            }
        }
        livenessTimer = timer
        livenessIsFast = true
        timer.schedule(deadline: .now() + Self.livenessInterval)   // first tick soon
        timer.resume()
    }

    /// Re-arm the one-shot liveness timer with the cadence appropriate to current state: fast while
    /// any session is `.running` or a workflow is active, slow otherwise.
    private func rescheduleLiveness() {
        guard let timer = livenessTimer else { return }
        let active = state.sessions.contains { $0.phase == .running } || !workflowActivity.isEmpty
        livenessIsFast = active
        timer.schedule(deadline: .now() + (active ? Self.livenessInterval : Self.livenessIdleInterval))
    }

    /// Pull the next liveness tick forward when state may have just become active, so the fast
    /// cadence (and workingCount/workflow updates) kick in promptly instead of waiting out the idle
    /// interval. Cheap no-op when already fast or nothing is running.
    private func nudgeLivenessIfIdle() {
        guard let timer = livenessTimer, !livenessIsFast,
              state.sessions.contains(where: { $0.phase == .running }) else { return }
        livenessIsFast = true
        timer.schedule(deadline: .now() + .milliseconds(250))
    }

    /// Resolve which tracked Claude sessions are *currently hosted by a live terminal*, for the
    /// `markProcessLiveness` backstop.
    ///
    /// A normally-launched `claude` exposes no session-id to `ps`/`lsof` (no `--session-id`/`--resume`
    /// arg, and the transcript fd is closed between writes), so the old "match the snapshot's
    /// `sessionID`" set was almost always empty — every hook-managed session then accrued misses and
    /// got force-ended ~6s after start (which is why the closed-notch "working/active" indicator never
    /// stuck, and why the heuristic looked unreliable). Instead, match each tracked session to a live
    /// `claude` process by its captured **terminal (TTY)** (`ProcessSnapshot.terminalTTY` from ps/lsof
    /// vs. `AgentSession.jumpTarget.terminalTTY`, which the registry persists so an open-but-idle
    /// session survives a restart), or by an exact session-id a live process happens to advertise.
    ///
    /// `/clear` mints a NEW session-id on the SAME terminal while the old id stops receiving events,
    /// so among sessions sharing a terminal we keep only the most-recently-updated one. The superseded
    /// (cleared) id then misses the alive set and is force-ended within ~6s — which is exactly what
    /// drops it from the Agent tab.
    private func aliveClaudeSessionIDs(
        from snapshots: [ActiveAgentProcessDiscovery.ProcessSnapshot]
    ) -> Set<String> {
        let claudeSnaps = snapshots.filter { $0.tool == .claudeCode }
        guard !claudeSnaps.isEmpty else { desktopSessionIDs = []; return [] }

        let aliveTTYs = Set(claudeSnaps.compactMap(\.terminalTTY))
        let aliveSessionIDs = Set(claudeSnaps.compactMap(\.sessionID))   // rarely available, but definitive

        // Resolve, per terminal, the single "current" session: prefer one whose exact id a live
        // process advertises, else the most-recently-updated session on that terminal. Folding the
        // authoritative match INTO the per-terminal contest (instead of short-circuiting it) is what
        // drops /clear's stale predecessor — same terminal, older — instead of leaving it alive
        // alongside the new session.
        struct LiveCandidate { let id: String; let authoritative: Bool; let updatedAt: Date }
        var byTerminal: [String: LiveCandidate] = [:]

        for session in state.sessions where session.tool == .claudeCode && !session.isSessionEnded {
            let tty = session.jumpTarget?.terminalTTY
            let isAuthoritative = aliveSessionIDs.contains(session.id)
            // A session is "live in a terminal" only if its captured tty still hosts a live `claude`,
            // or a live process advertises its exact id. We deliberately do NOT match by working
            // directory: a finished/cleared/recovered session (a discovered transcript or a restored
            // registry record — both carry no tty) would otherwise be kept alive merely because some
            // *other* terminal is open in the same repo. That cwd overlap is what left 4h/14h-old
            // sessions stuck in the list (e.g. an old transcript rescued by the very session monitoring
            // it). Real terminal sessions always carry a tty (the hook reads the parent `claude`
            // process's controlling tty), so nothing genuinely live is lost.
            let matchesTTY = tty.map(aliveTTYs.contains) ?? false
            guard isAuthoritative || matchesTTY else { continue }

            let key = tty ?? session.id
            let candidate = LiveCandidate(id: session.id, authoritative: isAuthoritative, updatedAt: session.updatedAt)
            guard let existing = byTerminal[key] else { byTerminal[key] = candidate; continue }
            let wins = (candidate.authoritative && !existing.authoritative)
                || (candidate.authoritative == existing.authoritative && candidate.updatedAt > existing.updatedAt)
            if wins { byTerminal[key] = candidate }
        }

        var alive = Set(byTerminal.values.map(\.id))
        desktopSessionIDs = aliveDesktopSessionIDs(from: claudeSnaps, authoritativeIDs: aliveSessionIDs)
        alive.formUnion(desktopSessionIDs)
        return alive
    }

    /// Claude desktop app (Code tab) chats run `claude` with no terminal, so the TTY match above can
    /// never keep them alive — without this, every desktop chat was force-ended ~6s after each hook
    /// event (empty Agent tab, wrong waiting/total counts, notification pops onto an empty notch).
    ///
    /// Exact first: Claude Code's `~/.claude/sessions/<pid>.json` names each process's session id, so a
    /// desktop process that has one keeps exactly that session alive. Only for processes without a
    /// record (older Claude Code) fall back to working directory: each such process keeps one TTY-less
    /// session in its cwd alive, newest first — the cap stops stale same-repo transcripts riding along.
    private func aliveDesktopSessionIDs(
        from claudeSnaps: [ActiveAgentProcessDiscovery.ProcessSnapshot],
        authoritativeIDs: Set<String>
    ) -> Set<String> {
        let desktopSnaps = claudeSnaps.filter { $0.terminalTTY == nil }
        let exactIDs = Set(desktopSnaps.compactMap(\.sessionID))
        var slotsByCwd: [String: Int] = [:]
        for snap in desktopSnaps where snap.sessionID == nil {
            guard let cwd = snap.workingDirectory.map(Self.normalizedPath) else { continue }
            slotsByCwd[cwd, default: 0] += 1
        }

        var alive: Set<String> = []
        var candidatesByCwd: [String: [AgentSession]] = [:]
        for session in state.sessions
        where session.tool == .claudeCode && !session.isSessionEnded && session.jumpTarget?.terminalTTY == nil {
            if exactIDs.contains(session.id) { alive.insert(session.id); continue }
            if authoritativeIDs.contains(session.id) { continue }   // a terminal process owns it
            guard let cwd = session.jumpTarget?.workingDirectory.map(Self.normalizedPath),
                  slotsByCwd[cwd] != nil else { continue }
            candidatesByCwd[cwd, default: []].append(session)
        }
        for (cwd, candidates) in candidatesByCwd {
            let newest = candidates.sorted { $0.updatedAt > $1.updatedAt }.prefix(slotsByCwd[cwd] ?? 0)
            alive.formUnion(newest.map(\.id))
        }
        return alive
    }

    /// Chats that are open but idle (e.g. waiting on your reply) fire no hooks after NotchNerd launches
    /// and are usually older than the 15-min startup transcript window, so they were never tracked.
    /// For every live `claude` whose session id we know but aren't tracking, load that session from its
    /// project's transcripts (`~/.claude/projects/<cwd, non-alphanumerics → "-">/`), or — if the
    /// transcript isn't found — synthesize a minimal entry from the process's session record. Each id
    /// is attempted once, so steady-state polls cost nothing.
    private func recoverUntrackedSessions(from snapshots: [ActiveAgentProcessDiscovery.ProcessSnapshot]) async {
        let claudeSnaps = snapshots.filter { $0.tool == .claudeCode }
        var wantedByCwd: [String: [ActiveAgentProcessDiscovery.ProcessSnapshot]] = [:]
        for snap in claudeSnaps {
            guard let id = snap.sessionID, let cwd = snap.workingDirectory,
                  state.session(id: id) == nil, !recoveryAttempts.contains(id) else { continue }
            recoveryAttempts.insert(id)
            wantedByCwd[Self.normalizedPath(cwd), default: []].append(snap)
        }

        var added = false
        for (cwd, wanted) in wantedByCwd {
            let discovered = await Self.discoverTranscripts(inProjectAt: cwd, maxFiles: wanted.count + 8)
            let byID = Dictionary(discovered.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for snap in wanted {
                guard let id = snap.sessionID, state.session(id: id) == nil else { continue }
                let recovered = byID[id]
                var jumpTarget = recovered?.jumpTarget ?? JumpTarget(
                    terminalApp: "Unknown",
                    workspaceName: WorkspaceNameResolver.workspaceName(for: cwd),
                    paneTitle: "Claude \(id.prefix(8))",
                    workingDirectory: cwd
                )
                // The transcript knows nothing about the host; the live process does.
                if let tty = snap.terminalTTY {
                    jumpTarget.terminalTTY = tty
                    if let app = snap.terminalApp { jumpTarget.terminalApp = app }
                }
                state.apply(.sessionStarted(SessionStarted(
                    sessionID: id,
                    title: recovered?.title ?? "Claude · \(jumpTarget.workspaceName)",
                    tool: .claudeCode,
                    origin: .live,
                    initialPhase: snap.claudeStatus == "busy" ? .running : .completed,
                    summary: recovered?.summary ?? "Open Claude session in \(jumpTarget.workspaceName).",
                    timestamp: recovered?.updatedAt ?? .now,
                    jumpTarget: jumpTarget,
                    claudeMetadata: recovered?.claudeMetadata
                )))
                added = true
            }
        }

        // Older Claude Code without per-pid records: per-cwd newest-transcript fallback for desktop chats.
        var slotsByCwd: [String: Int] = [:]
        for snap in claudeSnaps where snap.terminalTTY == nil && snap.sessionID == nil {
            guard let cwd = snap.workingDirectory.map(Self.normalizedPath) else { continue }
            slotsByCwd[cwd, default: 0] += 1
        }
        for (cwd, slots) in slotsByCwd {
            let attemptKey = "\(cwd)#\(slots)"
            guard !recoveryAttempts.contains(attemptKey) else { continue }
            recoveryAttempts.insert(attemptKey)
            for session in await Self.discoverTranscripts(inProjectAt: cwd, maxFiles: slots)
            where state.session(id: session.id) == nil {
                state.apply(.sessionStarted(SessionStarted(
                    sessionID: session.id,
                    title: session.title,
                    tool: .claudeCode,
                    origin: .live,
                    initialPhase: .completed,
                    summary: session.summary,
                    timestamp: session.updatedAt,
                    jumpTarget: session.jumpTarget,
                    claudeMetadata: session.claudeMetadata
                )))
                added = true
            }
        }
        if added { republish() }
    }

    private static func discoverTranscripts(inProjectAt cwd: String, maxFiles: Int) async -> [AgentSession] {
        let encoded = cwd.replacingOccurrences(of: "[^A-Za-z0-9]", with: "-", options: .regularExpression)
        let discovery = ClaudeTranscriptDiscovery(
            rootURL: ClaudeTranscriptDiscovery.defaultRootURL.appendingPathComponent(encoded, isDirectory: true),
            maxAge: 30 * 86_400,
            maxFiles: maxFiles
        )
        return await Task.detached(priority: .utility) { discovery.discoverRecentSessions() }.value
    }

    private func updateLiveSessionNames(from snapshots: [ActiveAgentProcessDiscovery.ProcessSnapshot]) -> Bool {
        var names: [String: String] = [:]
        var hostIDs: [String: String] = [:]
        for snap in snapshots where snap.tool == .claudeCode {
            if let id = snap.sessionID, let name = snap.sessionName { names[id] = name }
            if let id = snap.sessionID, let host = snap.hostSessionID { hostIDs[id] = host }
        }
        desktopHostSessionIDs = hostIDs
        guard names != liveSessionNames else { return false }
        liveSessionNames = names
        return true
    }

    /// Re-read chat titles for listed sessions whose transcript changed since last poll.
    /// Returns whether any title changed.
    private func refreshChatTitles() async -> Bool {
        let targets = sessions.compactMap { session -> (id: String, path: String)? in
            guard liveSessionNames[session.id] == nil else { return nil }
            return session.claudeMetadata?.transcriptPath.map { (session.id, $0) }
        }
        guard !targets.isEmpty else { return false }
        let stamps = chatTitleStamps
        let results = await Task.detached(priority: .utility) {
            targets.compactMap { target -> (id: String, stamp: Date, title: String?)? in
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: target.path),
                      let stamp = attributes[.modificationDate] as? Date,
                      stamps[target.id] != stamp else { return nil }
                return (target.id, stamp, Self.latestCustomTitle(inTranscriptAt: target.path))
            }
        }.value

        var changed = false
        for result in results {
            chatTitleStamps[result.id] = result.stamp
            if let title = result.title, chatTitles[result.id] != title {
                chatTitles[result.id] = title
                changed = true
            }
        }
        return changed
    }

    /// The newest `{"type":"custom-title","customTitle":…}` entry. Claude Code re-appends it every turn,
    /// so the transcript's tail is enough — and keeps multi-hundred-MB transcripts cheap to read.
    nonisolated private static func latestCustomTitle(inTranscriptAt path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let tailBytes: UInt64 = 512 * 1_024
        guard let size = try? handle.seekToEnd() else { return nil }
        try? handle.seek(toOffset: size > tailBytes ? size - tailBytes : 0)
        guard let data = try? handle.readToEnd() else { return nil }

        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).reversed()
        where line.contains("\"custom-title\"") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["type"] as? String == "custom-title",
                  let title = (object["customTitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else { continue }
            return title
        }
        return nil
    }

    private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    // MARK: - Registry persistence (debounced)

    private func schedulePersist() {
        persistDebounce?.cancel()
        persistDebounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            self.persistRegistryNow()
        }
    }

    private func persistRegistryNow() {
        let records = state.sessions
            // Persist only what's currently live, so a relaunch doesn't re-seed cleared/finished
            // sessions (they'd be filtered out of the UI anyway, but this keeps the registry clean).
            .filter { $0.tool == .claudeCode && $0.origin != .demo && $0.isVisibleInIsland }
            .map { ClaudeTrackedSessionRecord(session: $0) }
        Task.detached(priority: .utility) { [registry] in
            try? registry.save(records)
        }
    }
}
