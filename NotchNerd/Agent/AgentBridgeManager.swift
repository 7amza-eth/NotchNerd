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
    @Published private(set) var runningCount: Int = 0
    @Published private(set) var liveSessionCount: Int = 0

    /// Sessions that look like they're actively *working right now*: running, process alive, and
    /// emitting events recently. The classic hooks only mark turn boundaries (UserPromptSubmit→Stop),
    /// so a session whose Stop didn't fire — or one idle "waiting for you" — can linger in `.running`;
    /// the recency guard filters those. A precise real-time signal awaits the Phase-6 http hooks.
    var workingCount: Int {
        let now = Date.now
        return sessions.filter {
            $0.phase == .running && $0.isProcessAlive
                && now.timeIntervalSince($0.updatedAt) < Self.workingRecencyWindow
        }.count
    }
    private static let workingRecencyWindow: TimeInterval = 60

    @Published private(set) var isBridgeReady: Bool = false
    @Published private(set) var hookInstallState: HookInstallState = .unknown
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
    private let transcriptDiscovery = ClaudeTranscriptDiscovery()

    // MARK: Task / timer bookkeeping

    private var hasStarted = false
    private var bridgeTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var livenessTimer: DispatchSourceTimer?
    private var persistDebounce: Task<Void, Never>?
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
        republish()
        schedulePersist()
        emitNotification(for: event)
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
        sessions = state.sessions.map(Self.debranded)
        actionableSession = state.activeActionableSession.map(Self.debranded)
        attentionCount = state.attentionCount
        runningCount = state.runningCount
        liveSessionCount = state.liveSessionCount
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
        AgentTerminalJump.canJump(to: session.jumpTarget)
    }

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

    private func makeInstallManager() -> ClaudeHookInstallationManager {
        let overridePath = Defaults[.agentClaudeConfigDir]
        let claudeDir: URL = overridePath.isEmpty
            ? ClaudeConfigDirectory.resolved()
            : URL(fileURLWithPath: (overridePath as NSString).expandingTildeInPath, isDirectory: true)
        return ClaudeHookInstallationManager(claudeDirectory: claudeDir, hookSource: "claude")
    }

    /// The embedded hook binary at <app>/Contents/Helpers/OpenIslandHooks (Phase 1 step 2b).
    private func embeddedHooksBinaryURL() -> URL? {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/OpenIslandHooks")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    func installHooks() {
        guard let source = embeddedHooksBinaryURL() else {
            hookInstallState = .failed("Embedded OpenIslandHooks binary not found in app bundle.")
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
            let snapshots = ActiveAgentProcessDiscovery().discover()  // shells out to ps/lsof
            let aliveClaudeIDs = Set(snapshots.compactMap { snap -> String? in
                snap.tool == .claudeCode ? snap.sessionID : nil
            })
            Task { @MainActor [weak self] in
                guard let self else { return }
                let changed = self.state.markProcessLiveness(aliveSessionIDs: aliveClaudeIDs)
                // Also refresh while a session is running so the time-based `workingCount` updates
                // (the "Claude working" indicator turns off ~recency-window after events stop).
                if !changed.isEmpty || self.state.sessions.contains(where: { $0.phase == .running }) {
                    self.republish()
                }
            }
        }
        timer.resume()
        livenessTimer = timer
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
            .filter { $0.tool == .claudeCode && $0.origin != .demo }
            .map { ClaudeTrackedSessionRecord(session: $0) }
        Task.detached(priority: .utility) { [registry] in
            try? registry.save(records)
        }
    }
}
