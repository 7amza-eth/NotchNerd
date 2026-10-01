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
    enum Kind { case permission, question, completion }
    let sessionID: String
    let kind: Kind
    /// Completion notices auto-collapse; permission/question persist until resolved.
    var autoDismisses: Bool { kind == .completion }
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
    /// `"<cwd>#<process count>"` keys already tried by `recoverIdleDesktopSessions`.
    private var desktopRecoveryAttempts: Set<String> = []
    /// Sessions currently matched to a Claude desktop app chat process (refreshed every liveness poll).
    private var desktopSessionIDs: Set<String> = []
    /// Chat titles (the Claude app sidebar name, or `/rename`) read from each session's transcript,
    /// plus the transcript mtime they were read at so unchanged files aren't re-read every poll.
    private var chatTitles: [String: String] = [:]
    private var chatTitleStamps: [String: Date] = [:]
    /// Monotonic generation guard — defeats reconnect storms.
    private var connectionGeneration = 0
    private var reconnectDelay = AgentBridgeManager.reconnectBaseDelay

    private static let reconnectBaseDelay: Duration = .seconds(2)
    private static let reconnectMaxDelay: Duration = .seconds(30)
    private static let livenessInterval: DispatchTimeInterval = .seconds(3)

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
        persistDebounce?.cancel(); persistDebounce = nil
        bridgeClient.disconnect()
        bridgeServer.stop()
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

    /// Recompute the @Published projection from the private reducer.
    private func republish() {
        // Only surface sessions that are live in a terminal *right now* (`isVisibleInIsland`:
        // hook-managed & not-ended, process-alive, or needing attention). This is what makes the tab
        // show only what's currently running — it drops /clear'd session-ids (superseded → force-ended
        // by the TTY match), dead processes, and the stale registry/transcript history that the engine
        // otherwise keeps in `state.sessions` forever. The closed-notch counts already use this gate.
        let visible = state.sessions.filter(\.isVisibleInIsland)
        // Order by what's waiting on you, preserving recency within each group: blocked on an
        // approval/answer first, then finished turns awaiting your reply, then ones still running.
        let needsAttention = visible.filter { $0.phase.requiresAttention }
        let finished = visible.filter { $0.phase == .completed }
        let running = visible.filter { $0.phase == .running }
        sessions = (needsAttention + finished + running).map(presented)
        actionableSession = state.activeActionableSession.map(presented)
        attentionCount = state.attentionCount
        liveSessionCount = state.liveSessionCount
    }

    private func presented(_ session: AgentSession) -> AgentSession {
        var session = Self.debranded(session)
        // "App store pages localization · Zeteo-News" instead of "Claude · Zeteo-News", so several
        // chats in one repo are distinguishable.
        if let title = chatTitles[session.id] {
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

    func dismiss(sessionID: String) {
        state.dismissSession(id: sessionID)
        republish()
        notificationDismissPublisher.send(sessionID)
    }

    /// Bring the session's terminal to the foreground (Ghostty or macOS Terminal.app).
    /// Ghostty uses jumpResolving (no-op if already focused, else re-resolves a stale surface id).
    func jump(sessionID: String) {
        if isDesktopSession(sessionID) {
            // No public deep link to a specific Code-tab chat, so bring the app forward.
            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.claudeDesktopBundleID) {
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

    func installHooks() {
        guard let source = embeddedHooksBinaryURL() else {
            hookInstallState = .failed("Agent hook helper not found in the app bundle.")
            lastStatusMessage = hookInstallStateMessage
            return
        }

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
            let discovered = await Task.detached(priority: .utility) { [discovery = self.transcriptDiscovery] in
                discovery.discoverRecentSessions()
            }.value
            for session in discovered where self.state.session(id: session.id) == nil {
                self.state.apply(.sessionStarted(SessionStarted(
                    sessionID: session.id,
                    title: session.title,
                    tool: .claudeCode,
                    origin: .live,
                    initialPhase: .completed,           // recovered = completed/stale
                    summary: session.summary,
                    timestamp: session.updatedAt,
                    jumpTarget: session.jumpTarget,
                    claudeMetadata: session.claudeMetadata
                )))
            }
            self.republish()
        }
    }

    /// Process-liveness backstop: if the bridge dies before SessionEnd, missed polls mark a
    /// hook-managed session ended so it stops being stuck-visible.
    private func startLivenessBackstop() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + Self.livenessInterval, repeating: Self.livenessInterval)
        timer.setEventHandler { [weak self] in
            let snapshots = ActiveAgentProcessDiscovery().discover()  // shells out to ps/lsof (off-actor)
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.recoverIdleDesktopSessions(from: snapshots)
                let previousDesktopIDs = self.desktopSessionIDs
                let aliveClaudeIDs = self.aliveClaudeSessionIDs(from: snapshots)
                let changed = self.state.markProcessLiveness(aliveSessionIDs: aliveClaudeIDs)
                let titlesChanged = await self.refreshChatTitles()
                // Also refresh while a session is running so the time-based `workingCount` updates
                // (the "Claude working" indicator turns off ~recency-window after events stop).
                if !changed.isEmpty || titlesChanged || self.desktopSessionIDs != previousDesktopIDs
                    || self.state.sessions.contains(where: { $0.phase == .running }) {
                    self.republish()
                }
            }
        }
        timer.resume()
        livenessTimer = timer
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
    /// Match them by working directory instead: each live terminal-less `claude` process in a cwd
    /// keeps one TTY-less session in that cwd alive, most-recently-updated first. Capping by process
    /// count is what stops the old cwd-overlap problem (stale transcripts/cleared ids in the same repo
    /// riding along): a repo with two open chats keeps exactly its two newest sessions.
    private func aliveDesktopSessionIDs(
        from claudeSnaps: [ActiveAgentProcessDiscovery.ProcessSnapshot],
        authoritativeIDs: Set<String>
    ) -> Set<String> {
        // Processes that advertise a session id are matched exactly; only the rest are counted by cwd.
        let trackedIDs = Set(state.sessions.map(\.id))
        var slotsByCwd: [String: Int] = [:]
        for snap in claudeSnaps where snap.terminalTTY == nil {
            if let id = snap.sessionID, trackedIDs.contains(id) { continue }
            guard let cwd = snap.workingDirectory.map(Self.normalizedPath) else { continue }
            slotsByCwd[cwd, default: 0] += 1
        }

        var alive: Set<String> = []
        var candidatesByCwd: [String: [AgentSession]] = [:]
        for session in state.sessions
        where session.tool == .claudeCode && !session.isSessionEnded && session.jumpTarget?.terminalTTY == nil {
            if authoritativeIDs.contains(session.id) { alive.insert(session.id); continue }
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

    /// Desktop chats that are open but idle (e.g. waiting on your reply) fire no hooks after NotchNerd
    /// launches, and are usually older than the 15-min startup transcript window — so they were never
    /// tracked at all. For each cwd hosting more desktop `claude` processes than tracked sessions, load
    /// that project's newest transcripts (`~/.claude/projects/<cwd with non-alphanumerics → "-">`).
    /// Attempted once per cwd per process count, so this costs nothing on steady-state polls.
    private func recoverIdleDesktopSessions(from snapshots: [ActiveAgentProcessDiscovery.ProcessSnapshot]) async {
        var slotsByCwd: [String: Int] = [:]
        for snap in snapshots where snap.tool == .claudeCode && snap.terminalTTY == nil {
            guard let cwd = snap.workingDirectory.map(Self.normalizedPath) else { continue }
            slotsByCwd[cwd, default: 0] += 1
        }
        for (cwd, slots) in slotsByCwd {
            let attemptKey = "\(cwd)#\(slots)"
            guard !desktopRecoveryAttempts.contains(attemptKey) else { continue }
            let tracked = state.sessions.filter {
                $0.tool == .claudeCode && !$0.isSessionEnded && $0.jumpTarget?.terminalTTY == nil
                    && $0.jumpTarget?.workingDirectory.map(Self.normalizedPath) == cwd
            }.count
            guard tracked < slots else { continue }
            desktopRecoveryAttempts.insert(attemptKey)

            let encoded = cwd.replacingOccurrences(of: "[^A-Za-z0-9]", with: "-", options: .regularExpression)
            let discovery = ClaudeTranscriptDiscovery(
                rootURL: ClaudeTranscriptDiscovery.defaultRootURL.appendingPathComponent(encoded, isDirectory: true),
                maxAge: 7 * 86_400,
                maxFiles: slots
            )
            let discovered = await Task.detached(priority: .utility) { discovery.discoverRecentSessions() }.value
            var added = false
            for session in discovered where state.session(id: session.id) == nil {
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
            if added { republish() }
        }
    }

    /// Re-read chat titles for listed sessions whose transcript changed since last poll.
    /// Returns whether any title changed.
    private func refreshChatTitles() async -> Bool {
        let targets = sessions.compactMap { session -> (id: String, path: String)? in
            session.claudeMetadata?.transcriptPath.map { (session.id, $0) }
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
