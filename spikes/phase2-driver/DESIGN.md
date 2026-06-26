# Phase-2 Native Agent Driver — `AgentBridgeManager`

*Design spike, 2026-06-25. Verified against the real OpenIslandCore + OpenIslandApp source. Every type signature below is cited `file:line` from `sources/open-vibe-island/`.*

---

## 0. The thesis (restating the plan's reframe)

Direction A does **not** port Open Island's `AppModel`. We **vendor the headless Core + the hook CLI** and write one small boring.notch-native driver — `AgentBridgeManager` — that:

- starts `BridgeServer` **headless, in-process** (it already has a UI-free `init`/`start`),
- connects a single `LocalBridgeClient` observer and feeds a `SessionState` reducer,
- installs Claude Code hooks pointed at the embedded hook binary,
- round-trips permission approve/deny back through the bridge to the blocked hook,
- does startup discovery + a process-liveness backstop + registry restore/persist,

…and surfaces all of that as a normal boring.notch `ObservableObject` singleton (`@Published` + sindresorhus/Defaults), instantiated from `AppDelegate`, bound by an Agent tab and a persistent closed-notch indicator.

`AppModel` is read **only as a reference implementation** of the minimal happy path; none of its 2000+ lines of overlay/discovery/coordinator glue are ported.

---

## 1. The exact OpenIslandCore public surface we consume

These are the *only* Core symbols the driver touches. All verified by reading the files.

### 1.1 Bridge transport — `BridgeServer.swift`, `BridgeTransport.swift`, `BridgeCommandClient.swift`

| Symbol | Signature | Cite |
|---|---|---|
| `BridgeServer` | `public final class BridgeServer: @unchecked Sendable` | `BridgeServer.swift:5` |
| init | `public init(socketURL: URL = BridgeSocketLocation.defaultURL)` | `BridgeServer.swift:84` |
| start | `public func start() throws` | `BridgeServer.swift:95` |
| stop | `public func stop()` | `BridgeServer.swift:162` |
| snapshot push | `public func updateStateSnapshot(_ snapshot: SessionState)` | `BridgeServer.swift:174` |
| `BridgeSocketLocation.defaultURL` | `~/Library/Application Support/OpenIsland/bridge.sock` | `BridgeTransport.swift:13` |
| `BridgeSocketLocation.legacyURL` | `/tmp/open-island-<uid>.sock` (bound too, for in-flight hook binaries) | `BridgeTransport.swift:18`, bound at `BridgeServer.swift:106-111` |
| `BridgeSocketLocation.currentURL(environment:)` | resolves `OPEN_ISLAND_SOCKET_PATH`/`VIBE_ISLAND_SOCKET_PATH` else default | `BridgeTransport.swift:22` |
| `LocalBridgeClient` | `public final class LocalBridgeClient: @unchecked Sendable` | `LocalBridgeClient.swift:5` |
| init | `public init(socketURL: URL = BridgeSocketLocation.defaultURL)` | `LocalBridgeClient.swift:14` |
| connect | `public func connect() throws -> AsyncThrowingStream<AgentEvent, Error>` | `LocalBridgeClient.swift:18` |
| send | `public func send(_ command: BridgeCommand) async throws` | `LocalBridgeClient.swift:71` |
| disconnect | `public func disconnect()` | `LocalBridgeClient.swift:100` |
| `BridgeCommand` | enum incl. `.registerClient(role:)`, `.resolvePermission(sessionID:resolution:)`, `.answerQuestion(sessionID:response:)` | `BridgeTransport.swift:82-91` |
| `BridgeClientRole` | `public enum BridgeClientRole: String { case observer }` | `BridgeTransport.swift:78` |

> **`LocalBridgeClient.connect()` does NOT auto-register.** It only yields `.event` envelopes (`LocalBridgeClient.swift:130-132`). The consumer must explicitly `send(.registerClient(role: .observer))` after connecting — exactly what `AppModel.connectBridgeObserver` does at `AppModel.swift:1147`.

> **`BridgeCommandClient`** (`BridgeCommandClient.swift:4`, `init(socketURL:) :7`, `send(_:timeout:) throws -> BridgeResponse? :11`) is used **only inside the hook CLI**, not the app. The app never instantiates it. Listed here only so we don't confuse the two clients.

### 1.2 Session model & reducer — `SessionState.swift`, `AgentEvent.swift`, `AgentSession.swift`

| Symbol | Signature | Cite |
|---|---|---|
| `SessionState` | `public struct SessionState: Equatable, Sendable` | `SessionState.swift:3` |
| init | `public init(sessions: [AgentSession] = [])` | `SessionState.swift:6` |
| **reducer** | `public mutating func apply(_ event: AgentEvent)` | `SessionState.swift:56` |
| local resolve | `public mutating func resolvePermission(sessionID:resolution:at:)` | `SessionState.swift:227` |
| local answer | `public mutating func answerQuestion(sessionID:response:at:)` | `SessionState.swift:264` |
| liveness | `public mutating func markProcessLiveness(aliveSessionIDs:isCodexAppRunning:) -> Set<String>` | `SessionState.swift:345` |
| single-alive | `public mutating func markSingleSessionAlive(sessionID:)` | `SessionState.swift:334` |
| GC | `public mutating func removeInvisibleSessions() -> Bool` | `SessionState.swift:443` |
| sorted list | `public var sessions: [AgentSession]` | `SessionState.swift:10` |
| lookups | `session(id:)`, `activeActionableSession`, `attentionCount`, `runningCount`, `liveSessionCount`, `liveAttentionCount` | `SessionState.swift:20-54` |
| `AgentEvent` | `public enum AgentEvent: Equatable, Codable, Sendable` (12 cases) | `AgentEvent.swift:241` |
| `AgentSession` | `public struct AgentSession: Equatable, Identifiable, Codable, Sendable` | `AgentSession.swift:355` |
| visibility rule | `var isVisibleInIsland: Bool` | `AgentSession.swift:525` |
| `SessionPhase` | `.running / .waitingForApproval / .waitingForAnswer / .completed`; `.requiresAttention`, `.displayName` | `AgentSession.swift:109-135` |
| `AgentTool` | `.claudeCode` …; `.displayName`, `.brandColorHex` | `AgentSession.swift:3-92` |
| `PermissionResolution` | `.allowOnce(updatedInput:updatedPermissions:)` / `.deny(message:interrupt:)`; `.isApproved` | `AgentSession.swift:341-353` |
| `ApprovalAction` | `.deny / .allowOnce / .allowWithUpdates([ClaudePermissionUpdate])` | `AgentSession.swift:335-339` |
| `PermissionRequest` | `title/summary/affectedPath/primary..Title/toolName/suggestedUpdates` | `AgentSession.swift:178` |
| `QuestionPrompt` / `QuestionPromptResponse` | `AgentSession.swift:255 / 295` |

`SessionState.apply` is the single source of truth for mutations (Open Island's own convention, `CLAUDE.md`). We never hand-mutate sessions.

### 1.3 Hook install — `ClaudeHookInstaller.swift`, `ClaudeHookInstallationManager.swift`, `HooksBinaryLocator.swift`, `ClaudeConfigDirectory.swift`

| Symbol | Signature | Cite |
|---|---|---|
| `ClaudeHookInstallationManager` | `public final class …: @unchecked Sendable` | `ClaudeHookInstallationManager.swift:31` |
| init | `public init(claudeDirectory: URL = ClaudeConfigDirectory.resolved(), managedHooksBinaryURL: URL = ManagedHooksBinary.defaultURL(), hookSource: String = "claude", fileManager: .default)` | `…Manager.swift:38` |
| install | `@discardableResult public func install(hooksBinaryURL: URL) throws -> ClaudeHookInstallationStatus` | `…Manager.swift:75` |
| status | `public func status(hooksBinaryURL: URL? = nil) throws -> ClaudeHookInstallationStatus` | `…Manager.swift:50` |
| uninstall | `@discardableResult public func uninstall() throws -> ClaudeHookInstallationStatus` | `…Manager.swift:113` |
| event list | `ClaudeHookInstaller.eventSpecs` — 14 events | `ClaudeHookInstaller.swift:49-64` |
| 24h block | `ClaudeHookInstaller.managedTimeout = 86_400` | `ClaudeHookInstaller.swift:47` |
| command shape | `hookCommand(for:source:) -> "'<path>' --source claude"` | `ClaudeHookInstaller.swift:66` |
| managed copy path | `ManagedHooksBinary.defaultURL()` = `~/Library/Application Support/OpenIsland/bin/OpenIslandHooks` | `HooksBinaryLocator.swift:7` |
| bundle locator | `HooksBinaryLocator.locate(executableDirectory:…)` — finds `…/Contents/Helpers/OpenIslandHooks` | `HooksBinaryLocator.swift:88,105` |
| config dir | `ClaudeConfigDirectory.resolved(environment:)` = custom-UserDefaults > `CLAUDE_CONFIG_DIR` > `~/.claude` | `ClaudeConfigDirectory.swift:27` |

**Events installed** (`ClaudeHookInstaller.swift:49-64`): `UserPromptSubmit, SessionStart, SessionEnd, Stop, StopFailure, SubagentStart, SubagentStop, Notification(*), PreToolUse(*), PermissionRequest(* + 86400s timeout), PostToolUse(*), PostToolUseFailure(*), PermissionDenied(*), PreCompact`. This is exactly the plan's requirement (PreToolUse + PermissionRequest + the classic lifecycle), and already handles the v2.1.186 `StopFailure`/`PostToolUseFailure`/`PermissionDenied` splits from `_hooks_research.md §9`.

> **Install path subtlety (call this out loudly):** `install(hooksBinaryURL:)` does **not** point `settings.json` at the bundle. It **copies** the bundle binary (`hooksBinaryURL` = `Contents/Helpers/OpenIslandHooks`) out to `~/Library/Application Support/OpenIsland/bin/OpenIslandHooks` via `ManagedHooksBinary.install` (`…Manager.swift:82-86`) and writes `settings.json` pointing at that **managed copy** (`…Manager.swift:87-88`). So hooks survive app moves and quarantine-strip. The driver's job is only to **locate the bundle source** and pass it in. It also backs up the existing `settings.json` (`…Manager.swift:93-95`) and merges idempotently (sanitises prior managed hooks, `ClaudeHookInstaller.swift:78-91`).

### 1.4 Discovery & registry — `ClaudeTranscriptDiscovery.swift`, `ClaudeSessionRegistry.swift`

| Symbol | Signature | Cite |
|---|---|---|
| `ClaudeTranscriptDiscovery` | `public init(rootURL: = ~/.claude/projects, maxAge: 86_400, maxFiles: 40)` | `ClaudeTranscriptDiscovery.swift:19` |
| discover | `public func discoverRecentSessions(now:) -> [AgentSession]` (streamed, OOM-safe) | `…Discovery.swift:31` |
| `ClaudeSessionRegistry` | `public init(fileURL: = …/claude-session-registry.json)` | `ClaudeSessionRegistry.swift:136` |
| load | `public func load() throws -> [ClaudeTrackedSessionRecord]` | `ClaudeSessionRegistry.swift:144` |
| save | `public func save(_ records: [ClaudeTrackedSessionRecord]) throws` | `ClaudeSessionRegistry.swift:155` |
| record | `ClaudeTrackedSessionRecord(session:)` + `.restorableSession` (forces `.stale`) | `ClaudeSessionRegistry.swift:39,70` |

---

## 2. Files that must be VENDORED/REWRITTEN vs. pure-Core

### 2.1 Pure Core — copy verbatim into `Vendor/OpenIslandEngine/Sources/OpenIslandCore/`
Zero edits. Pure Foundation/Darwin/Dispatch, no UI, no external deps. The driver only needs this subset, but per locked decision **#6 we vendor Core whole** (clean re-pull):

`BridgeServer.swift`, `BridgeTransport.swift`, `BridgeCommandClient.swift`, `LocalBridgeClient.swift`, `SessionState.swift`, `AgentEvent.swift`, `AgentSession.swift`, `ClaudeHooks.swift`, `ClaudeHookInstaller.swift`, `ClaudeHookInstallationManager.swift`, `HooksBinaryLocator.swift`, `ClaudeConfigDirectory.swift`, `ClaudeTranscriptDiscovery.swift`, `ClaudeSessionRegistry.swift`, `WorkspaceNameResolver.swift`, and the Codex/Gemini/Cursor/OpenCode payload+metadata files they transitively reference (the `BridgeCommand`/`AgentEvent`/`AgentSession` Codable graph pulls them all in — they compile as inert types we never exercise).

### 2.2 App-layer — must be VENDORED & ADAPTED into the boring.notch app target
These live in `Sources/OpenIslandApp/` (the module we are explicitly **not** porting), but the Phase-2 driver needs them. Copy the file, strip the `import OpenIslandCore` only if co-located, keep the logic:

- **`ActiveAgentProcessDiscovery.swift`** (`OpenIslandApp/ActiveAgentProcessDiscovery.swift:4`) — the liveness backstop. `struct`, `init(commandRunner:)`, `func discover() -> [ProcessSnapshot]`. Spawns `/bin/ps -Ao …` (`:194`) and `/usr/sbin/lsof` (`:481`) → **requires the unsandboxed posture from Phase 0**. Adapt: it is otherwise self-contained; only depends on Core types (`AgentTool`). Copy as-is into the app target.

### 2.3 App-layer — deliberately NOT ported (rebuilt fresh in Phase 3, or dropped)
`AppModel.swift` (reference only), `SessionDiscoveryCoordinator.swift`, `ProcessMonitoringCoordinator.swift`, `OverlayUICoordinator.swift`, `OverlayPanelController.swift`, `IslandPanelView.swift` and the whole `Views/` tree, `TerminalJumpService.swift` (Phase 4, Ghostty path only). The driver re-implements the *minimal* slices of `SessionDiscoveryCoordinator`/`ProcessMonitoringCoordinator` it needs (restore, persist, liveness tick) in ~40 lines — see §6.

---

## 3. `AgentBridgeManager` public API

```swift
@MainActor
final class AgentBridgeManager: ObservableObject {
    static let shared = AgentBridgeManager()

    // Published UI state (derived from the private SessionState reducer)
    @Published private(set) var sessions: [AgentSession]
    @Published private(set) var actionableSession: AgentSession?   // first needs-attention
    @Published private(set) var attentionCount: Int                // needs approval/answer
    @Published private(set) var runningCount: Int
    @Published private(set) var liveSessionCount: Int
    @Published private(set) var isBridgeReady: Bool
    @Published private(set) var hookInstallState: HookInstallState  // .unknown/.installed/.notInstalled/.failed(String)
    @Published private(set) var lastStatusMessage: String

    // Lifecycle (called from AppDelegate)
    func start()                       // idempotent; gated by Defaults[.agentEnabled]
    func stop()                        // persist + tear down; called in applicationWillTerminate

    // UI callbacks (Agent tab Allow/Deny/question cards)
    func approve(sessionID: String)
    func deny(sessionID: String)
    func resolve(sessionID: String, action: ApprovalAction)   // Allow / Allow-with-updates / Deny
    func answer(sessionID: String, response: QuestionPromptResponse)
    func dismiss(sessionID: String)

    // Hook management (Agent settings pane buttons)
    func installHooks()
    func uninstallHooks()
    func refreshHookStatus()
}
```

`HookInstallState` is a local boring.notch enum, not a Core type.

---

## 4. Lifecycle & threading model

**Actor isolation.** The class is `@MainActor` (boring.notch convention; `BoringViewCoordinator` is `@MainActor` too). All `@Published` writes happen on main. `BridgeServer`, `LocalBridgeClient`, and `BridgeCommandClient` each own a private serial `DispatchQueue` (`BridgeServer.swift:63`, `LocalBridgeClient.swift:7`) and are `Sendable`, so it is safe to call their methods from the main actor — they hop to their own queues internally.

**Owned objects.**
```
private let bridgeServer = BridgeServer()                 // headless, in-process
private var bridgeClient = LocalBridgeClient()            // recreated per connect attempt
private var state = SessionState()                        // the reducer; private, republished
private let installManager = ClaudeHookInstallationManager(...)
private var bridgeTask: Task<Void, Never>?                // registration + event consumption
private var reconnectTask: Task<Void, Never>?            // single backoff loop (storm fix)
private var livenessTimer: DispatchSourceTimer?           // process backstop tick
private var connectionGeneration = 0                      // guards stale reconnects
```

**`start()` sequence** (mirrors `AppModel.startIfNeeded` `:1050` + `connectBridgeObserver` `:1118`, minus overlay/harness):
1. `guard !hasStarted, Defaults[.agentEnabled] else { return }`.
2. **Restore** registry off-main, apply on-main (§6.1). Push `bridgeServer.updateStateSnapshot(state)` so the server's `localState` agrees.
3. `try bridgeServer.start()` (`:1104`). On throw → `lastStatusMessage`, bail (fail-soft; hooks still fail-open).
4. `connectObserver()` — fresh `LocalBridgeClient`, `connect()`, then a single `Task` that `send(.registerClient(role:.observer))` (`:1147`) and `for try await event in stream { ingest(event) }` (`:1164`).
5. Kick a one-shot **transcript discovery** task (§6.2) and start the **liveness timer** (§6.3).
6. If `Defaults[.agentAutoInstallHooks]` and not installed → `installHooks()`.

**`ingest(event)`** (our slimmed `applyTrackedEvent`, cf. `AppModel.swift:1461`): on main, `state.apply(event)` (`SessionState.swift:56`), then `republish()`, then `bridgeServer.updateStateSnapshot(state)`, then schedule registry persist (debounced), then drive the closed-notch indicator (§7).

**`stop()`** (from `applicationWillTerminate`, `boringNotchApp.swift:75`): persist registry synchronously, `bridgeTask?.cancel()`, `reconnectTask?.cancel()`, `livenessTimer?.cancel()`, `bridgeClient.disconnect()`, `bridgeServer.stop()`.

---

## 5. Event → UI flow

```
Claude Code  ──hook──▶  OpenIslandHooks CLI  ──unix socket──▶  BridgeServer (in-proc)
   (PreToolUse,           (BridgeCommandClient,                  emit(): localState.apply +
    PermissionRequest,     blocks up to 24h on                   broadcast .event to all clients)
    Stop, …)               PermissionRequest)                          │
                                                                       ▼
                                          LocalBridgeClient.connect() AsyncThrowingStream<AgentEvent>
                                                                       │  (observer)
                                                                       ▼
                                      AgentBridgeManager.ingest(event): state.apply(event)
                                                                       │
                                       @Published sessions/attentionCount/actionableSession
                                                                       ▼
                                   AgentView (tab)  +  AgentLiveActivity (closed-notch indicator)
```

The server keeps its **own** `SessionState localState` (`BridgeServer.swift:82`) updated via `emit()` (`:2564`) and broadcasts every event; the observer keeps **our** `SessionState` in sync by applying the same events. Two copies, one event log — they converge. We additionally push `updateStateSnapshot` back so the server can answer `hasSession`/restore lookups (`BridgeServer.swift:569`, used by `requestQuestion`/notification-phase logic).

---

## 6. Startup discovery, liveness, registry

### 6.1 Registry restore/persist (`ClaudeSessionRegistry`)
- **Restore** (in `start()`): `registry.load()` (`:144`) → `record.restorableSession` (forces `.stale`, `:70`) → seed `SessionState(sessions:)`. These restored sessions are `.completed/.stale`; `isVisibleInIsland` keeps them only if hook-managed-and-not-ended or process-alive (`AgentSession.swift:525`) — so stale restores fade unless a live hook or `ps` re-attaches them.
- **Persist** (debounced after each `ingest`): map current Claude sessions → `ClaudeTrackedSessionRecord(session:)` (`:39`) → `registry.save(_:)` (`:155`), off-main.

### 6.2 Transcript discovery (`ClaudeTranscriptDiscovery`) — startup recovery
One-shot in `start()`, off-main: `discoverRecentSessions()` (`:31`) returns `.completed` Claude sessions parsed from `~/.claude/projects/**.jsonl` (≤40 files, ≤24h). On main, apply each as a synthetic `.sessionStarted` **only if not already present** so a live bridge event always wins. Gives the user a populated panel on first open even before any hook fires.

### 6.3 Process-liveness backstop (`ActiveAgentProcessDiscovery`, vendored from App)
A `DispatchSourceTimer` (~3 s) runs `ActiveAgentProcessDiscovery().discover()` (`OpenIslandApp/ActiveAgentProcessDiscovery.swift:58`) off-main → collect Claude `snapshot.sessionID`s into a `Set<String>` → on main `state.markProcessLiveness(aliveSessionIDs:)` (`SessionState.swift:345`). This is the *fallback* the plan calls for: if the bridge dies before `SessionEnd`, two consecutive missed polls mark a hook-managed session ended (`SessionState.swift:393-402`) so it stops being stuck-visible. Matching is best-effort (lsof may not expose a Claude sessionID); it is a backstop, not the primary signal.

---

## 7. Approve/deny round-trip (the flagship)

Verified path through `BridgeServer`:

1. Hook fires `PermissionRequest` → CLI sends `.processClaudeHook(payload)` and **blocks** (24h timeout, `OpenIslandHooksCLI.swift:75`). Server stores `pendingClaudeInteractions[sessionID] = (clientID: <hook fd>, kind: .permission(payload))` (`BridgeServer.swift:757`) and `emit(.permissionRequested(...))` (`:738`) → broadcast.
2. Observer receives `.permissionRequested` → `state.apply` sets phase `.waitingForApproval`, stores `permissionRequest` (`SessionState.swift:115-125`) → `actionableSession`/`attentionCount` update → Agent card + closed-notch dot light up.
3. User taps **Allow**/**Deny** → `AgentBridgeManager.resolve(sessionID:action:)`:
   - **optimistic** local `state.resolvePermission(sessionID:resolution:)` (`SessionState.swift:227`) so the UI clears instantly — exactly `AppModel.approvePermission(for:action:)` `:1386`;
   - then `bridgeClient.send(.resolvePermission(sessionID:, resolution:))` over the **observer** socket (`AppModel.swift:1390`).
4. Server `.resolvePermission` handler (`BridgeServer.swift:330`) → `resolvePendingClaudeInteraction` (`:2402`): builds `ClaudeHookDirective.permissionRequest(.allow(updatedInput:updatedPermissions:))` or `.deny(message:interrupt:)` (`:2415-2444`), emits a UI `.activityUpdated`/`.sessionCompleted` (broadcast), and **`send(.response(.claudeHookDirective(directive)), to: pendingInteraction.clientID)`** (`:2466`) — i.e. to the **blocked hook**, not the observer.
5. The blocked CLI unblocks, `ClaudeHookOutputEncoder` writes the directive JSON to stdout, exits 0 (`OpenIslandHooksCLI.swift:84-86`); Claude Code reads it and allows/denies.

`ApprovalAction.allowWithUpdates([ClaudePermissionUpdate])` → `.allowOnce(updatedPermissions:)` (`AppModel.swift:1381`) gives the "Always allow" affordance, mapping to Claude's `updatedPermissions` (e.g. `setMode`/`addRules`, `ClaudeHooks.swift:38-43`). Questions take the same shape via `.answerQuestion` → `resolvePendingClaudeQuestion` (`BridgeServer.swift:2469`).

**`PermissionRequest` does not fire under `-p`, and `defaultMode:"auto"` self-approves many calls** (`_hooks_research.md §8`, this machine's settings) — so `PreToolUse` is the steadier "needs attention" beat; it's installed too (`ClaudeHookInstaller.swift:58`) and lands as `.activityUpdated(phase:.running)` (`BridgeServer.swift:703`). The approve/deny showcase only lights up when Claude actually raises a `PermissionRequest`.

---

## 8. Error handling / fail-open

- **Bridge down** → hooks `try?` the send and `return` (`OpenIslandHooksCLI.swift:79-82`); Claude runs unchanged. Core invariant ("Hooks fail open", `CLAUDE.md`). We inherit it for free by shipping the unmodified CLI.
- **`bridgeServer.start()` throws** (e.g. socket path too long, EADDRINUSE) → catch, set `lastStatusMessage`, do **not** crash; the app's music notch is unaffected. Retry on next `start()`.
- **Observer stream ends/errors** → single `reconnectTask` with exponential backoff 2→30 s (`AppModel.swift:1115-1116,1182-1189`), guarded by `connectionGeneration` so a late failure can't spawn a second loop (**reconnect-storm fix**, §10).
- **Hook install throws** (bad JSON in user `settings.json`, `ClaudeHookInstaller.invalidSettingsJSON` `:36`) → surface to `hookInstallState = .failed(msg)`; never delete the user's file (installer already backs it up, `…Manager.swift:93-95`).
- **Discovery subprocess timeout** → `ActiveAgentProcessDiscovery.commandOutput` self-terminates at 0.5 s/0.2 s (`:715-730`) and returns `nil`; liveness simply skips that tick.

---

## 9. Where it's instantiated, and how the notch binds

**Instantiation** — `boringNotch/boringNotchApp.swift`, `AppDelegate.applicationDidFinishLaunching` (`:282`), after windows exist, near the other `.shared` wires:
```swift
if Defaults[.agentEnabled] { AgentBridgeManager.shared.start() }
```
**Teardown** — `applicationWillTerminate` (`:75`):
```swift
AgentBridgeManager.shared.stop()
```

**Agent tab** — follow the map digest's 9-step recipe (`_map_digest.md` lines 47-67): `NotchViews.agent` (`enums/generic.swift:27`), `case .agent: AgentView()` in `ContentView.NotchLayout()` (`:347`), `TabModel(label:"Agent",icon:"sparkles",view:.agent)` (`TabSelectionView.swift:17`), widen the `BoringHeader` gate (`:19`) so the tab shows with the shelf off, and `Defaults[.agentPanelEnabled]`. `AgentView` reads `@ObservedObject var agent = AgentBridgeManager.shared` and renders `agent.sessions` cards with Allow/Deny calling `agent.resolve(...)`.

**Closed-notch indicator** — per the digest's STEP 9 caveat (`_map_digest.md:65`): **do not** reuse the auto-expiring `expandingView`/`sneakPeek` (they self-dismiss in 1.5-3 s, `BoringViewCoordinator.swift:280-295`). The driver already exposes a **persistent** `@Published attentionCount`/`actionableSession`; add a dedicated render branch in the closed-state chain of `ContentView.NotchLayout()` (`:287-301`) that shows a small per-tool brand-colored dot (`AgentTool.brandColorHex`, `AgentSession.swift:78`) whenever `AgentBridgeManager.shared.attentionCount > 0`. No coordinator timer involved → it stays lit until resolved.

**Defaults keys** (add to `boringNotch/models/Constants.swift`, new `// MARK: Agent` near `:165`):
```swift
static let agentEnabled        = Key<Bool>("agentEnabled", default: false)   // master switch
static let agentPanelEnabled   = Key<Bool>("agentPanelEnabled", default: true)
static let agentAutoInstallHooks = Key<Bool>("agentAutoInstallHooks", default: false)
static let agentClaudeConfigDir  = Key<String>("agentClaudeConfigDir", default: "") // "" = ~/.claude
```
No secrets stored (this feature **never calls the Anthropic API**, only observes Claude Code via hooks), so the Keychain caveat from `_map_digest.md` Risks does not apply here.

---

## 10. Inherited Open Island bugs to FIX (don't port them)

1. **Parallel pending-interaction overwrite.** `pendingClaudeInteractions[payload.sessionID]` is keyed by **sessionID only** (`BridgeServer.swift:731,757`; same for `pendingApprovals` `:542,570` and `pendingClaudeToolContexts` via `permissionCorrelationKey`). If a single session raises two concurrent `PermissionRequest`s (rapid back-to-back tool calls, or a future parallel-permission Claude build), the second store **overwrites the first hook's `clientID`**; the first hook never gets a directive and hangs until its 24h timeout (fail-open but degraded UX). **Fix in vendored Core:** key pending interactions by a composite `sessionID + toolUseID` (the payload already carries `toolUseID`, surfaced via `claudeToolUseID(for:)` `:2511`), and have `resolvePermission` carry the `toolUseID` so the UI resolves the exact request. Subagent hooks are already suppressed unless `subagentStart/Stop` (`:618-623`), so this is specifically the same-session concurrency case.
2. **Reconnect storms.** In `AppModel`, `scheduleBridgeReconnect` re-enters `connectBridgeObserver`, which itself can call `scheduleBridgeReconnect` on failure (`AppModel.swift:1159,1175,1186`). The `?.cancel()` at the top mostly serialises it, but a connect that fails *after* registration races. **Fix in the driver:** one long-lived `reconnectTask` owning the whole backoff loop, plus a monotonic `connectionGeneration` captured per attempt; an event-stream task whose generation != current is ignored, so a stale failure can't start a parallel loop. Never call the reconnect scheduler from inside `connect`.

---

## 11. What we deliberately leave for later phases
- Terminal jump-back (`jumpTo`) is a Phase-4 stub here — only the Ghostty path ships (locked decision #1).
- The Watch relay, Codex/Gemini/Cursor/OpenCode handlers in `BridgeServer` stay compiled-but-dormant (we install only Claude hooks; their pending-maps simply never populate).
- `http`-transport hook is a Phase-6 spike; socket+CLI ships first (locked decision #5).
