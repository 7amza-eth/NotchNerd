# NotchNerd — Spec / Hydration Doc

> Canonical orientation doc for a fresh coding session. Everything here is verified against the
> repo at `/Users/hamza/Developer/NotchNerd`. When in doubt, the authoritative roadmap is
> [`NotchNerd-PLAN.md`](./NotchNerd-PLAN.md).

## Overview

**NotchNerd** is a macOS menu-bar SwiftUI app that draws a borderless floating panel over the
physical notch. It is a **rebrand/fork of [boring.notch](https://github.com/TheBoredTeam/boring.notch)**
(TheBoredTeam, GPL v3): the entire notch shell — music, file shelf, calendar, HUD replacement,
webcam mirror, live activities — is inherited from boring.notch with types renamed
`Boring*` → `NotchNerd*`.

On top of that base, NotchNerd adds two new surfaces:

1. A **Claude Code agent monitor** — an observe-only, in-process driver over a vendored slice of
   the [Open Island](https://github.com/Octane0411/open-vibe-island) engine (`OpenIslandCore`,
   GPL v3). It watches local Claude Code sessions via Claude Code hooks, surfaces session
   status / permission prompts in the notch, and round-trips Allow/Deny back to the agent. It
   **never calls the Anthropic API and stores no credentials**.
2. An **always-open Notepad** — a floating, key-capable, non-activating panel (plus an in-notch
   Notes tab) backed by a multi-note on-disk store, designed to take keyboard focus without
   stealing your frontmost app.

> **Identity note:** the rebrand is half-done by design. Code/types are `NotchNerd` and data lives
> under `~/Library/Application Support/NotchNerd/`, but build artifacts are still named
> `build/boringNotch.build`, source headers credit the boring.notch authors (Harsh Vardhan
> Goswami), and the bridge socket is deliberately still `~/Library/Application Support/OpenIsland/
> bridge.sock` (full socket namespacing is deferred to Phase 6). Treat boring.notch as the
> upstream base and Open Island as the vendored engine.

## Stack

| Concern | Detail |
|---|---|
| Language | Swift. **Dual language mode**: app + XPC targets compile in **Swift 5** mode (`SWIFT_VERSION = 5.0`, `SWIFT_STRICT_CONCURRENCY = targeted`); vendored `OpenIslandEngine` compiles in **Swift 6** mode (`swift-tools-version:6.0`, `swiftLanguageModes: [.v6]`). |
| UI | SwiftUI hosted in AppKit `NSPanel`s; `MenuBarExtra` scene; SwiftUIIntrospect. |
| Min OS | **macOS 14.0 (Sonoma)** (`MACOSX_DEPLOYMENT_TARGET = 14.0`, `platforms: [.macOS(.v14)]`). |
| Toolchain | **Full Xcode required** (not just Command Line Tools). `xcode-select -p` → `/Applications/Xcode.app/Contents/Developer`. A run-script build phase shells out to `swift build`. |
| Version | `MARKETING_VERSION = 2.7.3`, `CURRENT_PROJECT_VERSION = 271`. |
| License | **GNU GPL v3** (both boring.notch and Open Island are GPL v3 → merged work is GPL v3). |
| Bundle IDs | App `eth.7amza.notchnerd`; XPC helper `eth.7amza.notchnerd.XPCHelper`. |

**SPM dependencies (remote):** LaunchAtLogin-Modern, **Sparkle (exact 2.9.1)**, KeyboardShortcuts,
swift-collections, Defaults, swiftui-introspect, SkyLightWindow (Lakr233), lottie-spm,
AsyncXPCConnection (ChimeHQ), MacroVisionKit (TheBoredTeam). **Pow** is declared but **not linked**
(dead weight). MacroVisionKit appears 3× (duplicate refs).

**SPM dependencies (local):** `OpenIslandEngine` at `Vendor/OpenIslandEngine` — the app links its
`OpenIslandCore` library product. Pure Foundation/Darwin, zero external deps.

**Non-SPM embeds:** `MediaRemoteAdapter.framework` (Embed Frameworks, CodeSignOnCopy) for
now-playing; `NotchNerdXPCHelper.xpc` (Embed XPC Services → `Contents/XPCServices`); and the
`OpenIslandHooks` CLI built+copied into `Contents/Helpers/OpenIslandHooks` by a run-script phase.

## Repo structure

Annotated tree (excludes `build/`, `Vendor/OpenIslandEngine/.build`, `Vendor/OpenIslandEngine/build`
— large generated artifacts).

```
NotchNerd/                          repo root
├─ NotchNerd/                       app source root (Xcode "NotchNerd" target)
│  ├─ NotchNerdApp.swift            @main App (MenuBarExtra) + AppDelegate (all real lifecycle)
│  ├─ ContentView.swift             panel root SwiftUI view (28KB); open/close, gestures, view switch
│  ├─ NotchNerdViewCoordinator.swift  @MainActor singleton: currentView, sneakPeek, selected screen
│  ├─ Agent/                        Claude Code monitor (NEW)
│  │  ├─ AgentBridgeManager.swift   headless OpenIslandCore driver (singleton) + notification signals
│  │  ├─ AgentView.swift            in-notch Agent tab UI + AgentClosedIndicator + AgentSettings
│  │  ├─ AgentSessionPresentation.swift  verbatim OI presentation extension (spotlight*/island* props)
│  │  ├─ AgentSessionDetails.swift  status palette, subagent/task detail view, overview counts, status dot
│  │  ├─ AgentNotificationSound.swift  NSSound system-sound alerts (Defaults-bound)
│  │  ├─ AgentUsageManager.swift    statusline-wrapper install + ClaudeUsageLoader polling (5h/7d)
│  │  ├─ UsageChip.swift            usage chip view for the Agent tab header
│  │  ├─ ActiveAgentProcessDiscovery.swift  ps/lsof/tmux liveness probe
│  │  └─ GhosttyJumpService.swift   osascript jump into a Ghostty pane (focus short-circuit + re-resolution)
│  ├─ Notepad/                      always-open notepad (NEW)
│  │  ├─ NotepadWindowController.swift  floating panel singleton; CGS-space float strategy
│  │  ├─ NotepadPanel.swift         nonactivating, canBecomeKey NSPanel
│  │  ├─ NotepadView.swift          tab strip + TextEditor
│  │  ├─ NotepadTabView.swift       in-notch Notes tab; pins notch open; NotchKeyMaker focus
│  │  └─ NotesStore.swift           multi-note store (index.json + notes/<uuid>.md)
│  ├─ components/                   Notch/ Calendar/ Live activities/ Music/ Onboarding/
│  │                                Settings/ Shelf/ Tabs/ Tips/ Webcam/
│  │  └─ Notch/                     NotchNerdSkyLightWindow (runtime), NotchNerdWindow (legacy),
│  │                                NotchShape, NotchHomeView, NotchNerdHeader, NotchNerdExtrasMenu
│  ├─ managers/                     BatteryActivity, Brightness, Calendar, ImageService, Music,
│  │                                NotchSpaceManager (max-level CGS space), Volume, Webcam
│  ├─ models/                       NotchNerdViewModel (per-window open/close state machine),
│  │                                Constants.swift (primary Defaults.Keys incl. agentEnabled),
│  │                                CalendarModel, BatteryStatusViewModel, SharingStateManager…
│  ├─ MediaControllers/             MediaControllerProtocol, AppleMusic, NowPlaying, Spotify, YT Music
│  ├─ observers/                    DragDetector, FullscreenMediaDetection (MacroVisionKit), MediaKeyInterceptor
│  ├─ XPCHelperClient/              app-side XPC client + copy of the protocol
│  ├─ private/CGSSpace.swift        private SkyLight/CoreGraphics Space wrapper (float-over-fullscreen)
│  ├─ enums/generic.swift           NotchState, NotchViews { home, shelf, agent, notepad }, ContentType…
│  ├─ extensions/ helpers/ menu/ metal/ sizing/ utils/ Shortcuts/ Providers/ animations/
│  ├─ Assets.xcassets  Info.plist  NotchNerd.entitlements  Localizable.xcstrings (600KB)
│  └─ notchnerd-welcome.m4a
├─ NotchNerdXPCHelper/              XPC service target (5 files)
│  ├─ main.swift                    NSXPCListener.service() + ServiceDelegate
│  ├─ NotchNerdXPCHelper.swift      impl
│  ├─ NotchNerdXPCHelperProtocol.swift  vended API (accessibility auth + CoreBrightness brightness)
│  ├─ Info.plist  NotchNerdXPCHelper.entitlements
├─ Vendor/OpenIslandEngine/         vendored SwiftPM package (local ref)
│  ├─ Package.swift                 tools 6.0, Swift-6 mode, 2 products, zero deps (locally authored)
│  ├─ Sources/OpenIslandCore/       45 files copied VERBATIM from open-vibe-island (GPL v3)
│  ├─ Sources/OpenIslandHooks/OpenIslandHooksCLI.swift  @main hook CLI (embedded into the app)
│  └─ VENDORED-FROM.md              upstream commit 1e26dfc, copied 2026-06-26, re-pull steps
├─ NotchNerd.xcodeproj/             2 native targets + "Embed OpenIslandHooks CLI" run-script phase
├─ sources/                         reference clones + research (read-only)
│  ├─ open-vibe-island/             full Open Island clone (~141 Swift files) — re-pull source
│  ├─ _map_digest.md                160KB dual-codebase map (boringNotch + OVI)
│  └─ _hooks_research.md            Claude Code hooks brief (vs Claude Code v2.1.186)
├─ tooling/
│  ├─ docs/deferred-work-notes.md   Phase-6/7 impl reference (inherited-bug fix recipe, Cowork formats)
│  └─ scripts/                      setup-dev-signing.sh (stable TCC identity) + add_agent_files.rb (xcodeproj add)
├─ mediaremote-adapter/             MediaRemoteAdapter.framework + perl adapter (now-playing)
├─ Configuration/dmg/               DMG packaging (create_dmg.sh)
├─ updater/                         appcast.xml + Sparkle (feed currently disabled)
├─ NotchNerd-PLAN.md                authoritative phased build plan / decision log
├─ README.md  SECURITY.md  crowdin.yml
├─ LICENSE (GPL v3)  THIRD_PARTY_LICENSES
└─ .github/  .devcontainer/  build/ (ignored Xcode output incl. boringNotch.build)
```

## Features

**Inherited from boring.notch (renamed):**
- **Music notch + now-playing** — `MusicManager` + `MediaControllers/`. `NowPlayingController`
  dynamically loads private `MediaRemote.framework` AND spawns the bundled
  `MediaRemoteAdapter.framework` helper to stream now-playing across macOS versions. Closed-notch
  `MusicLiveActivity` (album art + marquee + spectrogram/Lottie visualizer); open `NotchHomeView`
  player (scrubber, control slots, volume, favorite, synced lyrics).
- **File shelf + AirDrop/share** — `components/Shelf/`, drop targets in `ContentView`,
  NSSharingService via `SharingStateManager`.
- **Calendar** — `components/Calendar/NotchNerdCalendar.swift`, shown when `Defaults[.showCalendar]`.
- **HUD replacement** — `components/Live activities/` (InlineHUD, OpenNotchHUD,
  SystemEventIndicator) driven by `coordinator.sneakPeek` (volume/brightness/backlight/mic) plus
  battery/power notifications.
- **Webcam mirror** — `components/Webcam/`, toggled by `Defaults[.showMirror]`.
- **Live activities** — closed-notch expanding views (music, battery, download).

**New in NotchNerd:**
- **Claude Code agent monitor** — observe-only, in-notch. Agent tab with an overview-counts row,
  pulsing per-phase status dots, **expandable session rows** (live subagents + task/todo checklists
  from `ClaudeSessionMetadata`), Allow Once/Deny permission cards, question option buttons, and a
  Ghostty jump button (already-focused short-circuit + live re-resolution). **In-notch notification
  mode** auto-pops the notch on permission/question/completion events (never hijacks an open notch;
  completion auto-collapses after 10s) with optional **system-sound** alerts. **Usage HUD** chips
  (5h/7d Claude quotas) via a vendored statusline wrapper. Closed-notch `AgentClosedIndicator` when
  `attentionCount > 0`. **Off by default** (each surface independently gated in Settings → Agent).
- **Always-open Notepad** — floating key-capable panel + in-notch Notes tab over one shared
  multi-note store; toggled via menu-bar button and a global hotkey.

## Architecture

### Notch window + CGS space

The notch is an `NSPanel` overlay inserted into a **max-level CGS space**
(`NotchSpaceManager.shared.notchSpace`, wrapping `private/CGSSpace.swift`) so it floats over
fullscreen apps. `ContentView` is the root with a closed/open `notchState`, hover-to-open, pan
gestures, and a `NotchShape` clip.

Two notch window classes exist; **only `NotchNerdSkyLightWindow` is instantiated at runtime** (in
`AppDelegate.createNotchNerdWindow`). It uses the `SkyLightWindow` SPM package plus a manual
`dlsym` of `SLSRemoveWindowsFromSpaces` for lock-screen display. `NotchNerdWindow.swift` is a
simpler legacy variant, **not on the launch path**. Both gate `canBecomeKey` on
`NotepadNotchFocus.allowsNotchKey` (normally false → click-through overlay).

**`AppDelegate` (not the SwiftUI `App` body) holds essentially all logic.** `NotchNerdApp`'s only
Scene is a `MenuBarExtra`. `applicationDidFinishLaunching` creates the notch window(s) (one per
screen or single), positions them, sets up drag detectors / screen-lock-notification observers /
KeyboardShortcuts / onboarding, then calls `AgentBridgeManager.shared.start()` and
`NotepadWindowController.shared.restoreIfNeeded()`. `applicationWillTerminate` calls
`AgentBridgeManager.shared.stop()` + `NotesStore.shared.flush()`.

### Claude Code agent pipeline (the new native feature)

NotchNerd drives the vendored `OpenIslandCore` **headless, in-process**, as an **observe-only**
client. ASCII flow:

```
  Claude Code (CLI)
      │  fires hook event (UserPromptSubmit, PreToolUse, PermissionRequest,
      │   Stop, SessionStart/End, Notification, PostToolUse, …)
      ▼
  OpenIslandHooks CLI          ("<binary> --source claude", embedded in
  (Contents/Helpers/…)          Contents/Helpers/, installed into ~/.claude/settings.json)
      │  connects to Unix socket
      │  ~/Library/Application Support/OpenIsland/bridge.sock
      │  (legacy: /tmp/open-island-<uid>.sock)
      │  sends BridgeCommand.processClaudeHook(ClaudeHookPayload)
      ▼
  BridgeServer  (in-process, owned by AgentBridgeManager)
      │  handleClaudeHook → reduces into BridgeServer.localState: SessionState
      │  stores PendingClaudeInteraction{ clientID, kind } for blocking hooks
      │  broadcast([.event(...)]) to registered observers
      ▼
  LocalBridgeClient  (registered as .observer — receives .event envelopes ONLY)
      │  state.apply(event) into AgentBridgeManager's OWN SessionState
      ▼
  AgentBridgeManager.republish()
      │  @Published sessions / actionableSession / attentionCount / runningCount / liveSessionCount
      ▼
  AgentView (Agent tab)  +  AgentClosedIndicator (closed-notch, when attentionCount > 0)
```

**Approve/deny round-trip (the subtle part):** user taps Allow/Deny → `AgentBridgeManager.resolve(...)`
**optimistically clears the card locally**, then `send(.resolvePermission(...))` over the SAME
socket. The Claude `PermissionRequest` hook process **blocks** holding its connection open;
`BridgeServer.resolvePendingClaudeInteraction` builds a `ClaudeHookDirective` (`.allow(...)` /
`.deny(message, interrupt)`) and routes it **back to the blocked hook process's clientID — NOT back
to the observer**. The observer only learns the real outcome via a later broadcast
(`activityUpdated`/`sessionCompleted`). Questions (`AskUserQuestion`) follow the same path via
`answerQuestion` / `resolvePendingClaudeQuestion`.

**Two `SessionState`s coexist:** `BridgeServer.localState` (server-side, holds
`pendingClaudeInteractions`) and `AgentBridgeManager.state` (observer-side, projected to UI). The
manager mirrors its state into the server (`bridgeServer.updateStateSnapshot` in `didSet`) so
`hasSession()`/restore lookups agree.

**Backstops in `AgentBridgeManager`:** on start it `restoreFromRegistry()` (seeds `.stale`
sessions from `ClaudeSessionRegistry`), `discoverTranscriptsOnce()` (recovers `~/.claude/projects`
sessions as `.completed`; live events win), and `startLivenessBackstop()` — a 3s timer running
`ActiveAgentProcessDiscovery().discover()` which shells out to `/bin/ps` + `/usr/sbin/lsof` (+tmux)
to find alive `claude` PIDs. `SessionState.markProcessLiveness` force-ends a hook-managed session
after `processNotSeenCount >= 2` so sessions can't get stuck-visible if the SessionEnd hook never
arrives. Registry persistence is debounced 2s; reconnect uses a single 2s→30s backoff with a
`connectionGeneration` guard against reconnect storms.

**Ghostty jump** (`GhosttyJumpService`, Ghostty-only): `osascript` against
`com.mitchellh.ghostty` matching `terminalSessionID` → `workingDirectory` → `paneTitle`. Requires
the Automation TCC grant for Ghostty.

**Gating:** the bridge/hooks are gated entirely by `Defaults[.agentEnabled]` (default **false**) —
`start()` early-returns otherwise. Auto-install of hooks is gated by `agentAutoInstallHooks`
(default false). **The Agent _tab_ visibility is a separate key, `agentPanelEnabled` (default
true)** read by `TabSelectionView` — so the tab can appear (empty "no active sessions" state) even
while monitoring is disabled. Settings UI is `AgentSettings` (Settings → Agent) with
Install/Remove/Refresh hooks.

**Scope:** the vendored Core is multi-agent (Codex/Cursor/Gemini/Kimi/OpenCode/Warp types + a hook
CLI advertising ~10 tools), but NotchNerd wires **only the Claude Code path** — it filters/persists
`tool == .claudeCode`, `AgentView` is Claude-only, `GhosttyJumpService` is Ghostty-only. The rest is
dormant surface area (broadening it is To-do — PLAN §13).

**Notification mode + sounds (batch-1 port, PLAN §13).** Beyond the persistent `AgentClosedIndicator`,
agent events drive a transient auto-pop: `AgentBridgeManager.ingest` maps each `AgentEvent` →
`emitNotification` → `notificationPublisher` (a `PassthroughSubject`, *not* `@Published` state, so a
dismissed card can't be re-popped). `NotchNerdViewCoordinator.presentAgentNotification` plays the
optional sound (`AgentNotificationSound`), stores `agentNotification`, and posts
`.agentNotificationOpenRequested`; the visible `ContentView` opens the notch **only from
`notchState == .closed`** (never hijacks an open notch / the Notes editor). Permission/question pops
persist until resolved (closed via `notificationDismissPublisher` on resolve/answer/dismiss + a
`$actionableSession` reconcile); completion pops auto-collapse after 10s (deferred while
`AgentNotchHover.isPointerInside`). `ContentView.onChange(notchState→.closed)` calls
`coordinator.notchDidClose()` to clear finished pops. Frontmost-suppression skips the pop when the
session's Ghostty terminal is already focused.

**Usage HUD (batch-1 port).** `AgentUsageManager` (own AppDelegate-driven lifecycle, gated by
`agentUsageEnabled`) installs the vendored `ClaudeStatusLineInstallationManager.installAsWrapper()`
(wraps any existing statusline; tees Claude Code's `rate_limits` into `/tmp/open-island-rl.json`),
polls `ClaudeUsageLoader` on a 5s timer, and publishes a `ClaudeUsageSnapshot` rendered as 5h/7d
`UsageChip`s in the Agent tab header. **No credentials / no API** — the quota data rides the local
statusline payload (Claude Code ≥ 2.1.132 for context fields; `rate_limits` is Pro/Max-only).

### Notepad

Three surfaces over one shared `NotesStore.shared`:

1. **Floating window** — `NotepadWindowController` (singleton `NSWindowController`) owns a
   `NotepadPanel`: a `.nonactivatingPanel` with `canBecomeKey = true` / `canBecomeMain = false` —
   the one window in this `.accessory`/LSUIElement app allowed to take keyboard focus **without
   activating the app** (it never calls `setActivationPolicy(.regular)` or `NSApp.activate`).
   Float strategy `Defaults[.notepadFloatStrategy]` (default `.cgsSpace`) inserts the panel into
   `NotchSpaceManager.shared.notchSpace` at `level = .mainMenu+2`; fallback `.floating` stays out
   of the space. Toggled via menu-bar button, the `.toggleNotepad` global hotkey, and
   `Defaults[.notepadVisible]`. Red close button = hide (notes survive).
2. **In-notch Notes tab** — `NotepadTabView` (`NotchViews.notepad`, key `notepadTabEnabled` default
   true). On appear it pins the notch open (`SharingStateManager.shared.preventNotchClose = true`)
   and flips `NotepadNotchFocus.allowsNotchKey = true` so the normally non-key notch window may
   become key; `NotchKeyMaker` calls `window?.makeKey()` so the `TextEditor` takes focus without an
   extra click. Pop-out button hands off to `NotepadWindowController.shared.show()`.
3. **Swipe-up override** — in `ContentView.handleUpGesture`, when `currentView == .notepad` a
   swipe-up clears `allowsNotchKey` + `preventNotchClose` so the pinned notch can close.

`NotesStore` (`@MainActor ObservableObject`) is multi-note with a split on-disk format under
`~/Library/Application Support/NotchNerd/Notepad/`: `index.json` (ordered metadata + selectedID;
bodies excluded via CodingKeys) + `notes/<uuid>.md` (plain-text body). Debounced autosave (0.6s);
`flush()` from `applicationWillTerminate`. Title derives from the first non-empty line; deleting
the last note auto-creates a new one (never empty). Assumes the app is unsandboxed.

### XPC helper

`NotchNerdXPCHelper/` (5 files) is a separate XPC service `eth.7amza.notchnerd.XPCHelper`, built as
`NotchNerdXPCHelper.xpc` and embedded into the app. It vends accessibility-authorization checks +
keyboard/screen brightness (CoreBrightness). App-side client is `XPCHelperClient/`.

## Build & run

**Exact command:**

```sh
xcodebuild -project NotchNerd.xcodeproj -scheme NotchNerd -configuration Debug -derivedDataPath build build
```

Swap `-configuration Release` for a release build (project `defaultConfigurationName = Release`).

- **Full Xcode is mandatory** (not just Command Line Tools). The last build phase of the app
  target, **"Embed OpenIslandHooks CLI"**, runs `swift build --package-path Vendor/OpenIslandEngine
  --product OpenIslandHooks -c release`, copies the binary to `Contents/Helpers/OpenIslandHooks`,
  `chmod 0755`, then codesigns it (ad-hoc fallback `codesign --force -s -`). It has empty
  input/output paths → **re-runs on every build**. The app target sets
  `ENABLE_USER_SCRIPT_SANDBOXING = NO` so this `swift build` can reach the network/filesystem.
- **No shared scheme** exists in `xcshareddata` — `-scheme NotchNerd` relies on Xcode
  auto-generating the implicit scheme on first open / first `xcodebuild`. In a clean/CI checkout
  you may need to let xcodebuild autocreate it or use `-target NotchNerd`.
- **Dev signing:** signing is effectively **ad-hoc** (`CODE_SIGN_IDENTITY[sdk=macosx*] = "-"`,
  `DEVELOPMENT_TEAM = ""`, empty provisioning profile, no notarization config). Hardened runtime is
  on the **app target only**. Run `tooling/scripts/setup-dev-signing.sh` to create a stable
  self-signed "NotchNerd Dev" identity so TCC Automation/Accessibility grants survive rebuilds.
- **The agent is OFF by default** (`Defaults[.agentEnabled] = false`). Enable it in
  **Settings → Agent** (and Install hooks there). The Agent tab itself is visible by default
  (`agentPanelEnabled = true`) but shows nothing until monitoring is enabled.
- **App is non-sandboxed** (`com.apple.security.app-sandbox = false`) with apple-events automation +
  temporary exceptions for `com.spotify.client` / `com.apple.Music` — required for media control,
  but blocks Mac App Store distribution.
- **Sparkle 2.9.1 is linked but the update feed is disabled** (`SUEnableAutomaticChecks = false`,
  no `SUFeedURL`/`SUPublicEDKey` anywhere). Updates won't fetch until a feed is configured.

## Key files (entry points)

| File | Role |
|---|---|
| `NotchNerd/NotchNerdApp.swift` | `@main` App (MenuBarExtra) + `AppDelegate` — all lifecycle, window creation, agent start, notepad restore |
| `NotchNerd/ContentView.swift` | panel root SwiftUI view; open/close, gestures, view switching, closed-notch indicators |
| `NotchNerd/NotchNerdViewCoordinator.swift` | `@MainActor` global view coordinator singleton (currentView, sneakPeek, screen) |
| `NotchNerd/models/NotchNerdViewModel.swift` | per-window open/close state machine (`notchState`) |
| `NotchNerd/models/Constants.swift` | primary `Defaults.Keys` (incl. `agentEnabled` default false) |
| `NotchNerd/enums/generic.swift` | `NotchState`, `NotchViews { home, shelf, agent, notepad }` |
| `NotchNerd/components/Notch/NotchNerdSkyLightWindow.swift` | the runtime notch `NSPanel` (instantiated) |
| `NotchNerd/components/Notch/NotchNerdWindow.swift` | legacy notch panel (NOT on launch path) |
| `NotchNerd/managers/NotchSpaceManager.swift` | max-level CGS space owner |
| `NotchNerd/private/CGSSpace.swift` | private SkyLight Space wrapper |
| `NotchNerd/Agent/AgentBridgeManager.swift` | headless OpenIslandCore driver (singleton) + notification signals |
| `NotchNerd/Agent/AgentView.swift` | in-notch Agent tab UI (overview/rows/cards/chips) + AgentClosedIndicator + AgentSettings |
| `NotchNerd/Agent/AgentSessionPresentation.swift` | verbatim OI presentation extension (spotlight*/island* computed props) |
| `NotchNerd/Agent/AgentUsageManager.swift` | usage-HUD: statusline-wrapper install + `ClaudeUsageLoader` polling |
| `NotchNerd/NotchNerdViewCoordinator.swift` (agent notifications) | owns the in-notch notification auto-pop / auto-collapse |
| `NotchNerd/Notepad/NotepadWindowController.swift` | floating notepad singleton |
| `NotchNerd/Notepad/NotepadTabView.swift` | in-notch Notes tab + key-focus trick |
| `NotchNerd/Notepad/NotesStore.swift` | shared multi-note store |
| `NotchNerd/XPCHelperClient/XPCHelperClient.swift` | app-side XPC client |
| `NotchNerdXPCHelper/main.swift` | XPC service bootstrap |
| `Vendor/OpenIslandEngine/Package.swift` | vendored SPM manifest (2 products, zero deps) |
| `Vendor/OpenIslandEngine/Sources/OpenIslandCore/BridgeServer.swift` | socket server + hook routing + round-trip |
| `Vendor/OpenIslandEngine/Sources/OpenIslandHooks/OpenIslandHooksCLI.swift` | embedded hook CLI |
| `NotchNerd.xcodeproj/project.pbxproj` | targets, SPM refs, "Embed OpenIslandHooks CLI" phase |

## Project status

Per `NotchNerd-PLAN.md` §10/§11, the app is **feature-complete** — all implementation phases are
shipped and the comprehensive rename to NotchNerd is done.

- **Done:** Phase 0 (sandbox-off regression baseline), Phase 1 (vendor engine as local SPM), Phase 2
  (agent driver `AgentBridgeManager` — bridge + observer + reducer + hook install + approve/deny
  round-trip), Phase 3 (Agent tab UI), Phase 4 (Ghostty jump), Phase 5 (notepad — both surfaces,
  spike validated GO on-device), the rebrand identity work (Phase 9: bundle id `eth.7amza.notchnerd`,
  Sparkle disabled, violet icon), **Phase 5.5 (loose-thread audit & fixes — PLAN §12)**, and
  **OI-feature-port batch 1 (PLAN §13: notification mode + sounds, expanded session panel, usage HUD,
  Ghostty hardening)**.
- **Remaining:**
  - **Phase 6** — finish socket/hook namespacing off bundle id `eth.7amza.notchnerd` (the bridge
    socket is still the shared `~/Library/Application Support/OpenIsland/bridge.sock` by deliberate
    interim design; locked decision #8 requires namespacing so NotchNerd can't clobber a running
    Open Island). Also complete the user-facing rebrand (README, attribution, residual "Open
    Island" strings).
  - **More terminals / more agents** (remainder of the OI feature review — PLAN §13 To-do): the rest
    of `TerminalJumpService` (Terminal.app/iTerm2/tmux/Warp/…) and the other vendored agents
    (Codex/Gemini/Kimi/OpenCode/Cursor/Claude-forks). Engine support is already vendored — these are
    wiring jobs.
  - **Phase 7** — optional beta: a read-only live-status watcher for Cowork / local-agent-mode
    desktop surfaces (file formats + scope in `tooling/docs/deferred-work-notes.md §2`). Hard limit:
    approve/deny remains CLI-only.

## Conventions / gotchas

- **Fork identity is half-renamed.** Code/types are `NotchNerd`; build output is still
  `build/boringNotch.build`; vendored-engine user strings still say "Open Island" (e.g.
  `SessionState`/`BridgeServer` emit *"Permission denied in Open Island."* while
  `AgentBridgeManager` sends *"Permission denied in NotchNerd."*). The socket path is intentionally
  still `OpenIsland/bridge.sock` until Phase 6.
- **Don't edit `Vendor/OpenIslandEngine/Sources/`.** Those 45 files are copied **verbatim** from
  open-vibe-island (GPL v3, commit `1e26dfc`, 2026-06-26) and kept pristine for clean re-pull
  (PLAN decision #6). Only `Package.swift` is locally authored. Re-pull steps are in `VENDORED-FROM.md`.
- **`Defaults.Keys` are split across two files** — most in `models/Constants.swift`, but
  `notepadVisible` / `notepadFloatStrategy` live in `Notepad/NotepadWindowController.swift`.
- **`AppDelegate`, not the App body, owns lifecycle.** Don't look for window/agent/notepad wiring
  in the SwiftUI scene.
- **Two notch window classes; only `NotchNerdSkyLightWindow` is live.** Editing `NotchNerdWindow.swift`
  has no runtime effect.
- **Notepad focus is a fragile AppKit trick** — `.nonactivatingPanel` + `canBecomeKey`, plus the
  `NotepadNotchFocus.allowsNotchKey` gate for the in-notch tab. Never call
  `setActivationPolicy(.regular)` / `NSApp.activate` for the notepad or it steals the frontmost app.
- **Notch close paths all check `preventNotchClose`** (hover-out, sharingDidFinish, battery popover,
  drop debounce, swipe-up). Swipe-up is the explicit override that also clears the pin.
- **Pre-rename paths in docs:** PLAN §3–9 and `sources/_map_digest.md` still cite `boringNotch/*`
  paths — map them 1:1 onto `NotchNerd/*`.
- **`sources/boring.notch` is NOT on disk** — `_map_digest.md` references it, but only
  `sources/open-vibe-island/` exists.
- **Attribution gap (open):** `THIRD_PARTY_LICENSES` omits Open Island / open-vibe-island despite
  the verbatim vendor (same license, GPL v3). Provenance is recorded only in `VENDORED-FROM.md`.
- **When listing the tree, exclude** `build/`, `Vendor/OpenIslandEngine/.build`, and
  `Vendor/OpenIslandEngine/build` (large generated artifacts).

## References

| Doc | Why read it |
|---|---|
| [`NotchNerd-PLAN.md`](./NotchNerd-PLAN.md) | The authoritative roadmap + decision log — Direction-A decision, the 4 engineering decisions, phased roadmap (0–7), locked decisions (incl. #8 socket namespacing), spike outcomes, rebrand identity. The single most important source. |
| [`Vendor/OpenIslandEngine/VENDORED-FROM.md`](./Vendor/OpenIslandEngine/VENDORED-FROM.md) | GPL provenance for the vendored engine — upstream commit `1e26dfc`, copied 2026-06-26, "kept pristine," and the rsync re-pull procedure. |
| [`tooling/docs/deferred-work-notes.md`](./tooling/docs/deferred-work-notes.md) | Implementation reference for not-yet-built work — the Phase-6 pending-interaction fix recipe and the Phase-7 Cowork watcher file formats (consolidated from the now-removed Phase-2/notepad spikes + desktop-surfaces research). |
| [`sources/_map_digest.md`](./sources/_map_digest.md) | Dual-codebase architecture map (boring.notch host + Open Island engine) — notch window/CGS-space system, the "add an Agent tab" recipe, Defaults persistence, music subsystem boundary. Pre-rename paths. |
| [`sources/_hooks_research.md`](./sources/_hooks_research.md) | Claude Code hook-integration contract — event schema (9 classic → ~30 current), `PermissionRequest` vs `PreToolUse` vs `Notification`, the `defaultMode:"auto"` self-approve gotcha, transcript `.jsonl` structure. Pinned to Claude Code v2.1.186. |
| [`LICENSE`](./LICENSE) | GNU GPL v3 full text — preserve verbatim. |
| [`THIRD_PARTY_LICENSES`](./THIRD_PARTY_LICENSES) | Third-party credits (note: no `.md` extension; missing Open Island attribution). |

## Credits & license

NotchNerd is **GPL v3**. It is a fork of **[boring.notch](https://github.com/TheBoredTeam/boring.notch)**
by **TheBoredTeam** (GPL v3) and vendors a slice of **[Open Island / open-vibe-island](https://github.com/Octane0411/open-vibe-island)**
by **Octane0411** (GPL v3). Both upstreams being GPL v3 is exactly why the merged work stays GPL v3
and runs non-sandboxed. Also bundled: MediaRemoteAdapter (BSD-3), NotchDrop (MIT), Calendr /
DynamicNotchKit (MIT), Parrot (MPL-2.0) — see `THIRD_PARTY_LICENSES`.

