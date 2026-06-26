//
//  AgentBridgeManager.swift
//  boringNotch  (NotchNerd fork — Phase 2 native agent driver)
//
//  A boring.notch-native @MainActor ObservableObject singleton that drives the
//  VENDORED OpenIslandCore engine headless, in-process. It does NOT port Open
//  Island's AppModel/coordinators — it re-implements only the minimal happy path:
//    • start BridgeServer in-process
//    • observe AgentEvents via a LocalBridgeClient and reduce them into SessionState
//    • install Claude Code hooks pointed at the embedded Contents/Helpers/OpenIslandHooks
//    • round-trip permission approve/deny back to the blocked hook
//    • startup discovery + process-liveness backstop + registry restore/persist
//
//  IMPORTANT: This feature only OBSERVES Claude Code via hooks. It never calls the
//  Anthropic API and stores no credentials.
//
//  ⚠️ This file is COMPILE-INTENT correct against the real OpenIslandCore surface
//  (verified type signatures), but it will not compile until the engine is vendored.
//  Every `TODO(vendor)` marks a dependency on the vendored package / app-layer copy.
//

import AppKit
import Combine
import Foundation

import Defaults

// TODO(vendor): add the local SwiftPM package `Vendor/OpenIslandEngine` (product
// "OpenIslandCore") to the Xcode project, then this import resolves.
import OpenIslandCore

// TODO(vendor): `ActiveAgentProcessDiscovery` lives in Open Island's *App* target
// (Sources/OpenIslandApp/ActiveAgentProcessDiscovery.swift). Copy that file into the
// boring.notch app target as-is (it only depends on OpenIslandCore + Foundation and
// shells out to /bin/ps + /usr/sbin/lsof — requires the unsandboxed Phase-0 posture).

// MARK: - Defaults keys (add these to boringNotch/models/Constants.swift, MARK: Agent)
//
//  static let agentEnabled          = Key<Bool>("agentEnabled", default: false)
//  static let agentPanelEnabled     = Key<Bool>("agentPanelEnabled", default: true)
//  static let agentAutoInstallHooks = Key<Bool>("agentAutoInstallHooks", default: false)
//  static let agentClaudeConfigDir  = Key<String>("agentClaudeConfigDir", default: "")
//
//  They are referenced below via `Defaults[.agentEnabled]` etc.

enum HookInstallState: Equatable {
    case unknown
    case installed
    case notInstalled
    case failed(String)
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
    /// This is the PERSISTENT closed-notch indicator source (never auto-expires).
    @Published private(set) var attentionCount: Int = 0
    @Published private(set) var runningCount: Int = 0
    @Published private(set) var liveSessionCount: Int = 0
    @Published private(set) var isBridgeReady: Bool = false
    @Published private(set) var hookInstallState: HookInstallState = .unknown
    @Published private(set) var lastStatusMessage: String = ""

    // MARK: Engine objects (vendored OpenIslandCore)

    private let bridgeServer = BridgeServer()              // headless; init(socketURL:) :BridgeServer.swift:84
    private var bridgeClient = LocalBridgeClient()         // recreated per connect attempt
    private var state = SessionState() {                   // the reducer; SessionState.swift:3
        didSet {
            // Keep the server's localState in agreement so hasSession()/restore
            // lookups inside BridgeServer match ours (mirrors AppModel.state didSet).
            bridgeServer.updateStateSnapshot(state)        // BridgeServer.swift:174
        }
    }

    private lazy var installManager = makeInstallManager()
    private let registry = ClaudeSessionRegistry()         // ClaudeSessionRegistry.swift:136
    private let transcriptDiscovery = ClaudeTranscriptDiscovery() // ClaudeTranscriptDiscovery.swift:19

    // MARK: Task / timer bookkeeping

    private var hasStarted = false
    private var bridgeTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var livenessTimer: DispatchSourceTimer?
    private var persistDebounce: Task<Void, Never>?
    /// Monotonic generation guard — defeats reconnect storms (see DESIGN §10).
    private var connectionGeneration = 0

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
        bridgeClient.disconnect()    // LocalBridgeClient.swift:100
        bridgeServer.stop()          // BridgeServer.swift:162
        isBridgeReady = false
        hasStarted = false
    }

    // MARK: - Bridge server + observer

    private func startBridge() {
        do {
            try bridgeServer.start()             // BridgeServer.swift:95 (binds default + legacy socket)
            connectObserver()
        } catch {
            isBridgeReady = false
            lastStatusMessage = "Failed to start agent bridge: \(error.localizedDescription)"
            // Fail-soft: the music notch is unaffected; hooks still fail-open.
        }
    }

    /// Fresh client per attempt (avoids stale fd state), single task for
    /// registration + consumption (mirrors AppModel.connectBridgeObserver :1118).
    private func connectObserver() {
        bridgeTask?.cancel()
        bridgeClient.disconnect()

        connectionGeneration += 1
        let generation = connectionGeneration

        let client = LocalBridgeClient()         // LocalBridgeClient.swift:14
        bridgeClient = client

        let stream: AsyncThrowingStream<AgentEvent, Error>
        do {
            stream = try client.connect()        // LocalBridgeClient.swift:18 — yields .event only
        } catch {
            isBridgeReady = false
            lastStatusMessage = "Failed to connect agent observer: \(error.localizedDescription)"
            scheduleReconnect(after: generation)
            return
        }

        bridgeTask = Task { [weak self] in
            guard let self else { return }
            do {
                // connect() does NOT auto-register; we must announce ourselves.
                try await client.send(.registerClient(role: .observer))  // BridgeTransport.swift:83
                guard generation == self.connectionGeneration else { return }
                self.isBridgeReady = true
                self.lastStatusMessage = "Agent bridge ready. Watching Claude Code hooks."
            } catch {
                guard !Task.isCancelled, generation == self.connectionGeneration else { return }
                self.isBridgeReady = false
                self.scheduleReconnect(after: generation)
                return
            }

            do {
                for try await event in stream {                          // LocalBridgeClient.swift:130
                    guard generation == self.connectionGeneration else { return }
                    self.ingest(event)
                }
            } catch { /* stream error → fall through to reconnect */ }

            guard !Task.isCancelled, generation == self.connectionGeneration else { return }
            self.isBridgeReady = false
            self.lastStatusMessage = "Agent bridge disconnected. Reconnecting…"
            self.scheduleReconnect(after: generation)
        }
    }

    /// One long-lived backoff loop. The `expectedGeneration` guard means a late
    /// failure from a superseded connection can't spawn a parallel loop.
    private func scheduleReconnect(after expectedGeneration: Int) {
        guard expectedGeneration == connectionGeneration else { return }
        guard reconnectTask == nil || reconnectTask!.isCancelled else { return }

        reconnectTask = Task { [weak self] in
            var delay = Self.reconnectBaseDelay
            while !Task.isCancelled {
                try? await Task.sleep(for: delay)
                guard let self, !Task.isCancelled else { return }
                self.reconnectTask = nil
                self.connectObserver()
                if self.isBridgeReady { return }
                delay = min(delay * 2, Self.reconnectMaxDelay)
                self.reconnectTask = Task { /* placeholder; replaced next loop */ }
            }
        }
    }

    // MARK: - Event ingestion (our slim applyTrackedEvent; cf. AppModel.swift:1461)

    private func ingest(_ event: AgentEvent) {
        state.apply(event)                       // SessionState.swift:56 — single source of truth
        republish()
        schedulePersist()
        // Closed-notch indicator and Agent-tab live activity bind to @Published
        // attentionCount/actionableSession — no coordinator timer (DESIGN §9).
    }

    /// Recompute the @Published projection from the private reducer.
    private func republish() {
        sessions = state.sessions                // SessionState.swift:10 (sorted)
        actionableSession = state.activeActionableSession // SessionState.swift:20
        attentionCount = state.attentionCount    // SessionState.swift:28
        runningCount = state.runningCount        // SessionState.swift:24
        liveSessionCount = state.liveSessionCount // SessionState.swift:32
    }

    // MARK: - UI callbacks (Agent tab cards)

    func approve(sessionID: String) { resolve(sessionID: sessionID, action: .allowOnce) }
    func deny(sessionID: String)    { resolve(sessionID: sessionID, action: .deny) }

    /// Allow / Allow-with-updates / Deny. Optimistic local clear, then bridge round-trip.
    /// Mirrors AppModel.approvePermission(for:action:) :1365.
    func resolve(sessionID: String, action: ApprovalAction) {
        guard let session = state.session(id: sessionID) else { return }

        let resolution: PermissionResolution     // AgentSession.swift:341
        switch action {
        case .deny:
            resolution = .deny(message: "Permission denied in NotchNerd.", interrupt: false)
        case .allowOnce:
            resolution = .allowOnce()
        case let .allowWithUpdates(updates):
            resolution = .allowOnce(updatedPermissions: updates)
        }

        // Optimistic: clear the card immediately (SessionState.swift:227).
        state.resolvePermission(sessionID: session.id, resolution: resolution)
        republish()

        // Round-trip: BridgeServer routes the directive to the BLOCKED hook,
        // not back to us (BridgeServer.swift:330 → :2402 → :2466).
        send(.resolvePermission(sessionID: session.id, resolution: resolution))
    }

    func answer(sessionID: String, response: QuestionPromptResponse) {
        guard let session = state.session(id: sessionID) else { return }
        state.answerQuestion(sessionID: session.id, response: response) // SessionState.swift:264
        republish()
        send(.answerQuestion(sessionID: session.id, response: response)) // BridgeTransport.swift:86
    }

    func dismiss(sessionID: String) {
        state.dismissSession(id: sessionID)      // SessionState.swift:435
        republish()
    }

    private func send(_ command: BridgeCommand) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.bridgeClient.send(command) // LocalBridgeClient.swift:71
            } catch {
                self.lastStatusMessage = "Failed to send agent command: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Hook installation

    private func makeInstallManager() -> ClaudeHookInstallationManager {
        // ClaudeHookInstallationManager.swift:38. Respect an optional Defaults
        // override of the Claude config dir; "" means use ClaudeConfigDirectory.resolved().
        let overridePath = Defaults[.agentClaudeConfigDir]
        let claudeDir: URL = overridePath.isEmpty
            ? ClaudeConfigDirectory.resolved()   // ClaudeConfigDirectory.swift:27 (~/.claude default)
            : URL(fileURLWithPath: (overridePath as NSString).expandingTildeInPath, isDirectory: true)
        return ClaudeHookInstallationManager(claudeDirectory: claudeDir, hookSource: "claude")
    }

    /// Resolve the EMBEDDED hook binary at Contents/Helpers/OpenIslandHooks.
    /// HooksBinaryLocator's candidate `<execDir>/../Helpers/OpenIslandHooks` matches
    /// our Copy-Files phase destination (HooksBinaryLocator.swift:105).
    private func embeddedHooksBinaryURL() -> URL? {
        // TODO(vendor): confirm the Copy-Files phase lands the tool at
        // boringNotch.app/Contents/Helpers/OpenIslandHooks (Phase 1).
        if let located = HooksBinaryLocator.locate(
            executableDirectory: Bundle.main.executableURL?.deletingLastPathComponent()
        ) {
            return located                       // HooksBinaryLocator.swift:88
        }
        // Direct fallback if the locator's heuristics miss.
        return Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/OpenIslandHooks")
    }

    func installHooks() {
        guard let source = embeddedHooksBinaryURL() else {
            hookInstallState = .failed("Embedded OpenIslandHooks binary not found in app bundle.")
            return
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                // install() COPIES `source` → ~/Library/Application Support/OpenIsland/bin/
                // OpenIslandHooks, backs up settings.json, and writes hooks pointing at the
                // managed copy (ClaudeHookInstallationManager.swift:75-110). Idempotent.
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
                    try installManager.uninstall() // ClaudeHookInstallationManager.swift:113
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
                    try installManager.status()    // ClaudeHookInstallationManager.swift:50
                }.value
                self.hookInstallState = status.managedHooksPresent ? .installed : .notInstalled
            } catch {
                self.hookInstallState = .unknown
            }
        }
    }

    // MARK: - Startup discovery + liveness + registry

    private func restoreFromRegistry() {
        do {
            let records = try registry.load()    // ClaudeSessionRegistry.swift:144
            let restored = records.map { $0.restorableSession } // forces .stale (:70)
            if !restored.isEmpty {
                state = SessionState(sessions: restored) // SessionState.swift:6
                republish()
            }
        } catch {
            lastStatusMessage = "Could not restore agent sessions: \(error.localizedDescription)"
        }
    }

    /// One-shot transcript recovery so the panel is populated on first open even
    /// before any hook fires. Live bridge events always win (apply only if absent).
    private func discoverTranscriptsOnce() {
        Task { [weak self] in
            guard let self else { return }
            let discovered = await Task.detached(priority: .utility) { [discovery = self.transcriptDiscovery] in
                discovery.discoverRecentSessions()  // ClaudeTranscriptDiscovery.swift:31
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
                )))                                     // AgentEvent.swift:3 (SessionStarted)
            }
            self.republish()
        }
    }

    /// Process-liveness backstop: if the bridge dies before SessionEnd, two missed
    /// polls mark a hook-managed session ended (SessionState.swift:393-402).
    private func startLivenessBackstop() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + Self.livenessInterval, repeating: Self.livenessInterval)
        timer.setEventHandler { [weak self] in
            // TODO(vendor): ActiveAgentProcessDiscovery copied from OpenIslandApp.
            let snapshots = ActiveAgentProcessDiscovery().discover() // :58 — shells out to ps/lsof
            let aliveClaudeIDs = Set(snapshots.compactMap { snap -> String? in
                snap.tool == .claudeCode ? snap.sessionID : nil
            })
            Task { @MainActor [weak self] in
                guard let self else { return }
                let changed = self.state.markProcessLiveness(aliveSessionIDs: aliveClaudeIDs) // :345
                if !changed.isEmpty { self.republish() }
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
            .map { ClaudeTrackedSessionRecord(session: $0) } // ClaudeSessionRegistry.swift:39
        Task.detached(priority: .utility) { [registry] in
            try? registry.save(records)                      // ClaudeSessionRegistry.swift:155
        }
    }
}
