# NotchNerd — Spec / Hydration Doc

> Canonical orientation doc for a fresh coding session — the **single** comprehensive doc for this
> repo: reference (Part I below), plus roadmap, decision log, consolidated TODO, and deferred-work
> implementation reference (**Part II**). Everything here is verified against the repo at
> `/Users/hamza/Developer/NotchNerd`. When in doubt about remaining work, see Part II's
> "Roadmap & TODO".

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
| Version | `MARKETING_VERSION = 0.2.1`, `CURRENT_PROJECT_VERSION = 271` — local dev-build values; the release workflow overrides both from the git tag (latest release: `v0.2.1`). |
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
│  │  ├─ GhosttyJumpService.swift   osascript jump into a Ghostty pane (focus short-circuit + re-resolution)
│  │  └─ TerminalAppJumpService.swift  Terminal.app jump + `enum AgentTerminalJump` dispatcher (canJump/jump/appName)
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
│  └─ _hooks_research.md            Claude Code hooks brief (point-in-time, vs Claude Code v2.1.186)
├─ tooling/
│  └─ scripts/                      setup-dev-signing.sh (stable TCC identity) + add_agent_files.rb (xcodeproj add)
├─ mediaremote-adapter/             MediaRemoteAdapter.framework + perl adapter (now-playing)
├─ Configuration/dmg/               DMG packaging (create_dmg.sh)
├─ spec.md                          this doc — reference + roadmap + decisions + TODO + deferred reference
├─ README.md  SECURITY.md
├─ LICENSE (GPL v3)  THIRD_PARTY_LICENSES
├─ .github/workflows/release.yml    CI release: build + Sparkle-sign + appcast + GitHub Release (on a v* tag)
└─ .github/  .devcontainer/  build/ (ignored Xcode output incl. boringNotch.build)
```

## Features

**Inherited from boring.notch (renamed):**
- **Music notch + now-playing** — `MusicManager` + `MediaControllers/`. `NowPlayingController`
  dynamically loads private `MediaRemote.framework` AND spawns the bundled
  `MediaRemoteAdapter.framework` helper to stream now-playing across macOS versions. Closed-notch
  `MusicLiveActivity` (album art + marquee + spectrogram/Lottie visualizer); open `NotchHomeView`
  player (scrubber, control slots, volume, favorite, synced lyrics). Ships built-in
  **music-visualizer presets** — real Equalizer / Spectrum / Sound Bars Lottie animations plus a
  restored "Visualizer 4" (`components/Music/LottieAnimationView.swift`), version-seeded via Defaults
  `visualizerPresetVersion` + `CustomVisualizer.presetVersion` (re-seeds new presets each version,
  deduped by URL) with a Lottie sizing fix (`LottieView.sizeThatFits` + `scaleAspectFit` so animations
  fit the tiny closed-notch visualizer slot).
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
  terminal jump button (already-focused short-circuit + live re-resolution; Ghostty **or**
  Terminal.app via the `AgentTerminalJump` dispatcher). **In-notch notification mode** auto-pops the
  notch on permission/question/completion events (never hijacks an open notch; frontmost-suppression;
  completion auto-collapses after 10s) with optional **system-sound** alerts. **Usage HUD** chips
  (5h/7d Claude quotas) via a vendored statusline wrapper. **Closed-notch Claude status:**
  `AgentClosedIndicator` when `attentionCount > 0`, plus `AgentBridgeManager.workingCount`
  ("N working", pulsing — `running && process-alive && ~60s recency`) and `liveSessionCount`
  ("N active" presence). An active session takes the music **visualizer slot** (the music notch never
  disappears); the standalone status pill shows only when no music is playing. **Off by default**
  (each surface independently gated in Settings → Agent: `agentNotificationsEnabled` /
  `agentSoundEnabled` / `agentUsageEnabled`).
- **Always-open Notepad** — floating key-capable panel + in-notch Notes tab over one shared
  multi-note store; toggled via menu-bar button and a global hotkey.
- **First-run onboarding + feature tour** — a guided wizard (welcome → camera/calendar/reminders/
  accessibility/music → an Automation explainer → an opt-in **agent-monitor consent** that installs
  hooks and enables monitoring only on a *confirmed* install) + a re-runnable 7-card feature tour
  (menu-bar item + Settings → General; auto-shown once to upgraders via `hasSeenFeatureTour`).
- **Redesigned Settings** — an enum-driven (`SettingsTab`) grouped sidebar (General/Appearance · Notch
  features · Advanced · About), with **Notepad** + **Webcam** tabs and **Reset-to-defaults**.

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

**Per-tab open height** (`NotchNerd/sizing/matters.swift`): the **Agent tab opens taller**
(`agentNotchSize` 640×320) than music/home/shelf (`openNotchSize` 640×190). The window itself is
created at the larger size (`windowSize` = `max(openNotchSize.height, agentNotchSize.height) +
shadowPadding`) and **top-anchored**, so growing for the Agent tab leaves the music notch visually
unchanged.

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

**Terminal jump** (no longer Ghostty-only): `AgentBridgeManager` routes through the
`AgentTerminalJump` dispatcher (`TerminalAppJumpService.swift`), which dispatches to
`GhosttyJumpService` **or** `TerminalAppJumpService` (canJump/jump/appName). Both use `osascript`
(Ghostty matches `com.mitchellh.ghostty` by `terminalSessionID` → `workingDirectory` → `paneTitle`;
Terminal.app matches `com.apple.Terminal`) and require the Automation TCC grant for the target app.
**Ghostty hardening** (`jumpResolving`): already-focused/frontmost short-circuit (no flicker),
pre-jump live re-resolution recovering a stale/nil `terminalSessionID` from cwd→title, cwd-path
normalization, and a bounded/concurrently-drained `osascript` runner.

**Gating:** the bridge/hooks are gated entirely by `Defaults[.agentEnabled]` (default **false**) —
`start()` early-returns otherwise. Auto-install of hooks is gated by `agentAutoInstallHooks`
(default false). **The Agent _tab_ visibility is a separate key, `agentPanelEnabled` (default
true)** read by `TabSelectionView` — so the tab can appear (empty "no active sessions" state) even
while monitoring is disabled. Settings UI is `AgentSettings` (Settings → Agent) with
Install/Remove/Refresh hooks.

**Scope:** the vendored Core is multi-agent (Codex/Cursor/Gemini/Kimi/OpenCode/Warp types + a hook
CLI advertising ~10 tools), but NotchNerd wires **only the Claude Code path** — it filters/persists
`tool == .claudeCode`, `AgentView` is Claude-only, and terminal jump covers only Ghostty +
Terminal.app. The rest is dormant surface area (broadening it is To-do — see Part II → Roadmap & TODO,
and the porting recipes there).

**Notification mode + sounds (batch-1 port; see Part II → Changelog).** Beyond the persistent `AgentClosedIndicator`,
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

### Onboarding & first-run

`AppDelegate` shows a 400×600 `OnboardingView` window (`showOnboardingWindow`) when
`coordinator.firstLaunch` (`@AppStorage`). Step chain:
`welcome → camera → calendar → reminders → accessibility → music → automationInfo → agentMonitor →
finished`. `firstLaunch` flips false on entering `.finished` (so every path that completes is covered,
and a quit before then re-surfaces the wizard). The returning-user now-playing re-prompt
(`isNowPlayingDeprecated`) reuses `.musicPermission` and branches music→`.finished` directly — it reads
`firstLaunch` *before* any flip, so it skips the new steps.

- **`automationInfo`** (`AutomationInfoView`) — explains the just-in-time macOS Automation (Apple
  Events) prompt (music control + terminal jump). There's no up-front grant API, so it's a heads-up
  card + an in-app "Open Automation Settings" deep-link (runs in-app — the app sends the Apple Events).
- **`agentMonitor`** (`AgentMonitorOnboardingView`) — the **single** opt-in consent surface for the
  agent. "Not now" writes **nothing** (agent stays off). "Turn on monitoring" flips
  `Defaults[.agentEnabled] = true` **only on a confirmed hook install** (roll-back-on-failure): it calls
  `AgentBridgeManager.installHooks()` (now `@discardableResult -> Bool`; `false` = the synchronous
  missing-helper failure), observes `hookInstallState` via `onChange` + a polling `.task` backstop, and
  only then sets `agentEnabled = true` + `start()` (install-first/start-after dodges the
  `refreshHookStatus()` clobber). `installHooks()` resets state to a transient `.unknown` first so a
  repeat-identical result is still an observable change (no stuck spinner).
- **Feature tour** (`FeatureTourView`, step `.featureTour`) — 7 educational cards with inline ✦ mock
  visuals (no live-notch coachmarks — the notch is click-through). Re-runnable from the menu-bar
  "Feature Tour" item and Settings → General → "Replay feature tour" (both post `.featureTourRequested`
  → `presentFeatureTour()`, which rebuilds the window fresh and is guarded so it can't tear down an
  in-progress wizard). Existing upgraders (who never see the wizard) get it auto-presented **once** via
  `Defaults[.hasSeenFeatureTour]`.

The onboarding `NSWindow` caches by step; `onFinish`/`onOpenSettings` nil `onboardingWindowController`
on close (and capture `window` **weakly**) so a re-present rebuilds and the old window + SwiftUI tree
deallocate. New `components/Onboarding/*.swift` are registered via
`tooling/scripts/add_onboarding_files.rb` (normal PBXGroup — they won't compile otherwise).

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
  `DEVELOPMENT_TEAM = ""`, empty provisioning profile, no notarization config). **Hardened runtime is
  OFF** (`ENABLE_HARDENED_RUNTIME = NO`). It was on, but its **Library Validation** refused to load the
  ad-hoc-signed `MediaRemoteAdapter.framework` ("different Team IDs") → every *downloaded* release
  crashed at launch with a DYLD "Library missing" error (the local Debug build had it off, so the bug
  only surfaced on releases — v0.1.0/v0.2.0). **Don't re-enable it** without a real Developer ID +
  notarization (or add `com.apple.security.cs.disable-library-validation` and sign nested frameworks
  with the same identity). Run `tooling/scripts/setup-dev-signing.sh` to create a stable self-signed
  "NotchNerd Dev" identity so TCC Automation/Accessibility grants survive rebuilds.
- **The agent is OFF by default** (`Defaults[.agentEnabled] = false`). Enable it in
  **Settings → Agent** (and Install hooks there). The Agent tab itself is visible by default
  (`agentPanelEnabled = true`) but shows nothing until monitoring is enabled.
- **App is non-sandboxed** (`com.apple.security.app-sandbox = false`) with apple-events automation +
  temporary exceptions for `com.spotify.client` / `com.apple.Music` — required for media control,
  but blocks Mac App Store distribution.
- **Sparkle 2.9.1 — auto-updates ENABLED.** NotchNerd ships its OWN EdDSA key (`SUPublicEDKey` in
  `Info.plist`; the private half is the `SPARKLE_PRIVATE_KEY` GitHub Actions secret + a Keychain backup)
  and `SUFeedURL` → `https://github.com/7amza-eth/NotchNerd/releases/latest/download/appcast.xml`. The
  **release workflow** (`.github/workflows/release.yml`) builds, EdDSA-signs the build, generates +
  signs the `appcast.xml`, and attaches it (with the zip + dmg) to a GitHub Release on each `v*` tag —
  so installed copies auto-update. Builds are still **ad-hoc signed and NOT notarized**, so a first
  download is Gatekeeper-blocked (testers clear quarantine once: `xattr -dr com.apple.quarantine …`);
  Sparkle's own updates aren't re-quarantined, so it's a one-time step. ⚠️ **Never re-add boring.notch's
  `SUPublicEDKey`** — only NotchNerd-signed updates verify against our key.

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
| `NotchNerd/Agent/TerminalAppJumpService.swift` | Terminal.app jump + `enum AgentTerminalJump` dispatcher (routes Ghostty / Terminal.app) |
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

The app is **feature-complete and publicly released** (latest **v0.2.1**) — all core implementation
phases are shipped. The **user-visible** rebrand to NotchNerd is done; the **structural** rename (SPM
module/products, the embedded hook-binary + socket/statusline paths, the XPC helper display name) is
deliberately deferred to Phase 6. Full phase history is in **Part II → Changelog**; the canonical list
of remaining work is **Part II → Roadmap & TODO**.

- **Done:** Phase 0 (sandbox-off baseline), Phase 1 (vendor engine as local SPM), Phase 2 (agent driver
  `AgentBridgeManager` — bridge + observer + reducer + hook install + approve/deny), Phase 3 (Agent tab
  UI), Phase 4 (Ghostty jump), Phase 5 (notepad — both surfaces), the rebrand identity work (bundle id
  `eth.7amza.notchnerd`, **Sparkle auto-updates enabled**, violet icon), Phase 5.5 (loose-thread audit),
  OI-feature-port batch 1 (notification mode + sounds, expanded panel, usage HUD, Ghostty hardening),
  Terminal.app jump / taller Agent tab / closed-notch status / visualizer presets, **HookHealthCheck**,
  and the **public-release line** — the GitHub Actions release workflow + Sparkle pipeline, the
  **v0.2.0** onboarding wizard + feature tour + Settings redesign, and **v0.2.1** (the hardened-runtime
  launch fix).
- **Remaining (see Part II → Roadmap & TODO for the authoritative list):** Phase 6 (socket/hook +
  statusline-cache namespacing off `eth.7amza.notchnerd`; the inherited pending-interaction overwrite
  patch; http-hook spike; residual structural rebrand), more terminals / more agents (engine already
  vendored — wiring jobs), and the optional Phase 7 Cowork read-only watcher (approve/deny stays
  CLI-only).

## Conventions / gotchas

- **Fork identity is half-renamed.** Code/types are `NotchNerd`; build output is still
  `build/boringNotch.build`; vendored-engine user strings still say "Open Island" (e.g.
  `SessionState`/`BridgeServer` emit *"Permission denied in Open Island."* while
  `AgentBridgeManager` sends *"Permission denied in NotchNerd."*). The socket path is intentionally
  still `OpenIsland/bridge.sock` until Phase 6.
- **Don't edit `Vendor/OpenIslandEngine/Sources/`.** Those 45 files are copied **verbatim** from
  open-vibe-island (GPL v3, commit `1e26dfc`, 2026-06-26) and kept pristine for clean re-pull
  (decision #6 — Part II → Decisions & rationale). Only `Package.swift` is locally authored. Re-pull
  steps are in `VENDORED-FROM.md`.
- **`Defaults.Keys` are split across two files** — most in `models/Constants.swift`, but
  `notepadVisible` / `notepadFloatStrategy` live in `Notepad/NotepadWindowController.swift`.
- **Settings tabs are enum-driven.** `SettingsTab` (in `SettingsView.swift`) is the single source for
  both the sidebar list and the detail `switch` — add a tab there, not in two places. The selected tab
  persists via `@AppStorage("settingsSelectedTab")`.
- **Version: local vs release.** `project.pbxproj` `MARKETING_VERSION` (currently `0.2.1`) /
  `CURRENT_PROJECT_VERSION` (`271`) govern **local dev builds only**; the release workflow overrides both
  from the git tag (`v0.2.1` → marketing `0.2.1`, build = `github.run_number`). The high local build
  number keeps dev builds correctly "up to date" against the low release run-numbers — it is **not** the
  release counter. The workflow forces `make_latest: true`.
- **`gh` defaults to `upstream` (boring.notch), not the fork.** Remotes: `origin` = `7amza-eth/NotchNerd`,
  `upstream` = `TheBoredTeam/boring.notch`. Without a default set, `gh release` / `gh run` resolve against
  **upstream** and show boring.notch's `v2.7.x` releases + its Actions — *not* the fork's. Fix:
  `gh repo set-default 7amza-eth/NotchNerd` (set) or always pass `--repo 7amza-eth/NotchNerd`. The fork's
  only releases are NotchNerd's `0.x` (`v0.1.0`, `v0.2.0`, …); the `v2.x` tags/releases are upstream's and
  unrelated. The fork's `.github/workflows/` is just `release.yml` (the inherited crowdin/pages/build
  workflows were already removed; old failed runs are stale history).
- **`AppDelegate`, not the App body, owns lifecycle.** Don't look for window/agent/notepad wiring
  in the SwiftUI scene.
- **Two notch window classes; only `NotchNerdSkyLightWindow` is live.** Editing `NotchNerdWindow.swift`
  has no runtime effect.
- **Notepad focus is a fragile AppKit trick** — `.nonactivatingPanel` + `canBecomeKey`, plus the
  `NotepadNotchFocus.allowsNotchKey` gate for the in-notch tab. Never call
  `setActivationPolicy(.regular)` / `NSApp.activate` for the notepad or it steals the frontmost app.
- **Notch close paths all check `preventNotchClose`** (hover-out, sharingDidFinish, battery popover,
  drop debounce, swipe-up). Swipe-up is the explicit override that also clears the pin.
- **The notch is dormant during first-launch onboarding.** Both `handleHover` and `doOpen()`
  early-return while `coordinator.firstLaunch`, so the notch can't open — or get stuck open showing the
  blanked `NotchHomeView` — until onboarding completes. (The `doOpen()` guard is a NotchNerd fix; the
  inherited code guarded only hover, so a stray tap opened the notch and it then couldn't close.)
- **Agent-tab gesture fix:** the swipe-up-to-close gesture is gated **off** the Agent tab
  (`coordinator.currentView != .agent` in `ContentView`) so it doesn't hijack the Agent tab's own
  scrolling.
- **Pre-rename paths:** some older notes (now folded into this doc's Part II) and git history cite
  pre-rename `boringNotch/*` paths — map them 1:1 onto `NotchNerd/*`. There is **no boring.notch clone
  on disk**; only `sources/open-vibe-island/` exists.
- **Attribution (resolved):** `THIRD_PARTY_LICENSES` credits both boring.notch (TheBoredTeam) and
  Open Island / open-vibe-island (Octane0411, commit `1e26dfc`); provenance + the NotchNerd patch-set
  are in `VENDORED-FROM.md`. (Open item: that file lists a few unused deps and omits some actually-linked
  SPM deps — reconcile with `Package.resolved` before a public binary release.)
- **When listing the tree, exclude** `build/`, `Vendor/OpenIslandEngine/.build`, and
  `Vendor/OpenIslandEngine/build` (large generated artifacts).

## References

> Roadmap, decision log, consolidated TODO, and deferred-work implementation notes now live in
> **Part II of this doc** (below) — they are no longer separate files.

| Doc | Why read it |
|---|---|
| [`Vendor/OpenIslandEngine/VENDORED-FROM.md`](./Vendor/OpenIslandEngine/VENDORED-FROM.md) | GPL provenance for the vendored engine — upstream commit `1e26dfc`, copied 2026-06-26, "kept pristine," and the rsync re-pull procedure. |
| [`sources/_hooks_research.md`](./sources/_hooks_research.md) | Claude Code hook-integration contract — event schema (9 classic → ~30 current), `PermissionRequest` vs `PreToolUse` vs `Notification`, the `defaultMode:"auto"` self-approve gotcha, transcript `.jsonl` structure. **Point-in-time snapshot** pinned to Claude Code v2.1.186 — verify against the current CLI before relying on schema detail. |
| [`LICENSE`](./LICENSE) | GNU GPL v3 full text — preserve verbatim. |
| [`THIRD_PARTY_LICENSES`](./THIRD_PARTY_LICENSES) | Third-party credits (note: no `.md` extension; missing Open Island attribution). |

## Credits & license

NotchNerd is **GPL v3**. It is a fork of **[boring.notch](https://github.com/TheBoredTeam/boring.notch)**
by **TheBoredTeam** (GPL v3) and vendors a slice of **[Open Island / open-vibe-island](https://github.com/Octane0411/open-vibe-island)**
by **Octane0411** (GPL v3). Both upstreams being GPL v3 is exactly why the merged work stays GPL v3
and runs non-sandboxed. Also bundled: MediaRemoteAdapter (BSD-3), NotchDrop (MIT), Calendr /
DynamicNotchKit (MIT), Parrot (MPL-2.0) — see `THIRD_PARTY_LICENSES`.

---

# Part II — Roadmap, decisions & deferred-work reference

> Part I (above) is the architecture/reference. Part II is the merged roadmap + decision log +
> consolidated TODO + deferred-implementation reference (folded in from the former
> `NotchNerd-PLAN.md` and `tooling/docs/deferred-work-notes.md`). Dated narrative was dropped — git
> history holds it; this keeps only the load-bearing **what + why** and the still-pending work.

## Decisions & rationale

### Direction A — boring.notch is the host

A formal review (independent advocates → adversarial critics → a sandbox/build feasibility deep-dive
→ a deciding judge) chose **Direction A: port Open Island's engine *into* boring.notch** (score 85)
over porting music into Open Island (B, 46) or a ground-up rebuild (C, 38). **Why:** it leaves the
beloved music notch byte-for-byte untouched; the engine (`OpenIslandCore`) is genuinely
clean/portable; notepad + sandbox + transport are small surgical changes. **Critical reframe:**
Direction A does **not** mean porting Open Island's `AppModel`/overlay/discovery coordinators (that
glue is Open Island's UI nervous system and would be a from-scratch rebuild). Instead **vendor only
the clean headless Core + the hook CLI and write a small fresh boring.notch-native driver on top** —
`BridgeServer` already exposes a UI-free `public init(socketURL:)` / `start()` that runs headless
in-process.

The one real tension that drove everything: the agent features (writing `~/.claude/settings.json`,
running `ps`/`lsof`/`osascript`/`open`, reading `~/.claude/projects`, AppleScript-controlling
terminals) **require an unsandboxed app**; boring.notch shipped sandboxed.

### The four engineering decisions

1. **Build system — vendor Core as a local SPM package.** Copy `Sources/OpenIslandCore` +
   `OpenIslandHooksCLI.swift` into `Vendor/OpenIslandEngine/`; hand-write a slim `Package.swift` (2
   products, zero deps). **Toolchain trap:** upstream manifest is `swift-tools-version:6.2`, which the
   host's pinned Xcode 16.4 (Swift 6.0) refuses to open → set the vendored manifest to
   **`swift-tools-version:6.0` + `.swiftLanguageMode(.v6)`** (Core uses no 6.2-only syntax). Three
   coexisting Swift modes (app 5.0 / hooks tool 6.0 / Core 6 library) is supported. **Do not** raise
   the app to `SWIFT_STRICT_CONCURRENCY=complete`. Embed the hook CLI via a Copy-Files phase →
   `Contents/Helpers`.
2. **Sandbox — drop it in-place.** Flip `com.apple.security.app-sandbox` → `false` (entitlements-only;
   keep automation + network.client). *(Historical note: hardened runtime was kept on here, but has
   since been disabled — `ENABLE_HARDENED_RUNTIME = NO` — because it crashed ad-hoc release launches;
   see the Dev-signing gotcha.)* Remove now-dead Sparkle sandbox
   XPC shims and **re-qualify the full Sparkle download→install→relaunch cycle** (the EdDSA key is
   load-bearing). **Don't** route privileged ops through the XPC helper to stay sandboxed — a
   sandboxed app can't host the bridge socket, write `~/.claude`, or spawn `ps`/`osascript`.
   Prerequisite: a **stable "NotchNerd Dev" signing identity** so TCC grants survive rebuilds.
3. **Hook transport — proven socket+CLI first, modern http later.** Ship the battle-tested
   Unix-socket + embedded-CLI + 24h-block design first (fail-open: if the app is down Claude proceeds
   unchanged). The modern **`http` hook → in-app `127.0.0.1` listener** (no binary to ship/sign) is
   the better long-term architecture *if it validates* — gate it behind a spike confirming Claude Code
   holds a blocking HTTP response for the full interactive `PermissionRequest` timeout + the
   `allowedHttpHookUrls` allowlist behavior. Install both `PreToolUse` (works headless, gates before
   the prompt) and `PermissionRequest` (interactive allow/deny). ⚠️ `defaultMode:"auto"` makes many
   calls self-approve and never raise `PermissionRequest`, so `PreToolUse` is the steadier signal.
4. **Notepad — an independent key-capable panel, NOT a notch tab.** A `NotchViews` tab only renders
   while the notch is *open* and is mutually exclusive with home/shelf, so it can't "stay visible
   while you use the notch." Build a `NotepadPanel`: a `.nonactivatingPanel` overriding
   **`canBecomeKey = true`** (the notch panels hard-code `canBecomeKey=false` for click-through). That
   combo takes **text focus** for a `TextEditor` **without** flipping the `.accessory` app to
   `.regular` or stealing the foreground app — the single hardest unproven problem. Own it via a
   `NotepadWindowController` singleton; gate visibility on its own Defaults key + MenuBarExtra +
   hotkey, never on `notchState`. For float-over-fullscreen, insert into the notch CGS space (the
   key-focus-inside-CGS-space spike was load-bearing — validated GO on-device).

### Locked decisions (2026-06-25)

1. **Terminal jump scope → Ghostty only** (initial). Smallest robust surface; no Warp SQLite
   fragility. *(Terminal.app has since been added; see Changelog / TODO.)*
2. **Notepad richness → multiple notes / tabs.** Notes list + per-note persistence.
3. **Notepad float → above fullscreen too.** Joins the CGS space (key-focus-in-CGS-space spike was
   load-bearing — validated GO).
4. **Usage HUD → yes, wrapper mode.** Preserve the user's existing custom statusline.
5. **Transport → socket+CLI first, spike http later.** Not gambling the flagship feature.
6. **Vendoring → Core whole, now a documented patch-set** (was "verbatim, only `Package.swift`
   authored"). We've started patching the engine (`QuestionOption.preview`; the Phase-6
   pending-interaction fix will too), so the model is **a clean `Sources/` tree + a re-appliable,
   documented patch series in `VENDORED-FROM.md`** — re-pull becomes a patch-rebase, not a verbatim
   rsync. The vendor-merge audit says **keep the SPM boundary** (load-bearing: the hook-CLI is a
   separate Mach-O that must share Core, and the Swift-6-vs-Swift-5 language-mode split must stay
   isolated — see decision #1) while unifying *identity* in tiers: rename the products/module off
   "OpenIsland" via a `path: "Sources/OpenIslandCore"` override (keeps the re-pull dir; touches
   `Package.swift` + 1 pbxproj ref + ~10 `import` sites, not the 45 vendored files), then namespace the
   socket / hook-binary / statusline paths (decision #8). GPL: a rename strips nothing (vendored files
   have no per-file headers; attribution lives in LICENSE / THIRD_PARTY_LICENSES / README / VENDORED-FROM).
7. **XPC helper → keep it as-is** (brightness/AX only).
8. **Namespace the bridge socket + hooks identity (load-bearing for Phase 6).** NotchNerd must NOT
   use Open Island's default shared socket (`~/Library/Application Support/OpenIsland/bridge.sock`) —
   `BridgeServer.start()` deletes any existing socket before binding, so it would **clobber a running
   Open Island and steal its hook connections**. Use a NotchNerd-specific socket path, pass it as
   `BridgeServer(socketURL:)`, bake `OPEN_ISLAND_SOCKET_PATH=<that path>` into the installed hook
   command, and give the managed-hooks group + `ManagedHooksBinary` copy location a NotchNerd identity
   so both apps coexist in one `~/.claude/settings.json`. **Still deferred** — the socket is
   deliberately the shared OpenIsland path on purpose until Phase 6.

### Why approve/deny is CLI-only (the one hard limit)

NotchNerd's signature approve/deny works by holding the hook *subprocess* blocked and writing a
directive to its stdout. Desktop/Cowork permission gates run in the cloud (chat) or the desktop app's
host loop + React UI (Cowork) — **there is no host-side hook process to block**. So **live status +
jump are the realistic desktop ceiling; approve/deny stays a Claude-Code-CLI exclusive.** Dropped from
scope entirely: chat-app AX automation and any MCP-based monitor (MCP only ever sees calls to its
*own* tools, never the session or the permission prompt).

## Changelog

> Dev-facing technical phase history (the load-bearing what + why per phase). The **user-facing**
> changelog is **GitHub Releases** — curated per `v*` tag — *not* a `CHANGELOG.md` file.

Condensed per-phase summary of what shipped. (Build-verified `BUILD SUCCEEDED`, committed, pushed at
each phase; git history holds the dated detail.)

- **Phase 0 — Sandbox drop.** Flipped `app-sandbox=false`, kept hardened runtime; stood up stable dev
  signing; confirmed MediaRemoteAdapter keeps its entitlement after re-sign (music survives); full
  regression baseline (now-playing, Sparkle, camera, calendar, CGS-notch-over-fullscreen).
- **Phase 1 — Vendor engine.** `Vendor/OpenIslandEngine/` (Core whole + hook CLI), slim
  `Package.swift` (tools 6.0, Swift-6 mode); linked `OpenIslandCore` into the app via local SPM;
  embedded the hook CLI into `Contents/Helpers`. Headless round-trip smoke test passed.
- **Phase 2 — Agent driver.** `AgentBridgeManager` (headless `BridgeServer` + observer + `SessionState`
  reducer, hook install, approve/deny round-trip, transcript + process-liveness discovery), wired in
  `AppDelegate`, gated by `agentEnabled` (default off).
- **Phase 3 — Agent tab.** In-notch Agent tab + session panel (Allow/Deny + question cards), settings
  pane, persistent closed-notch attention indicator (dedicated `@Published`, not the auto-expiring
  sneak-peek).
- **Phase 4 — Ghostty jump.** Ported just the Ghostty path of `TerminalJumpService` (AppleScript
  window-ID match) + TCC consent flow. Dropped Warp/iTerm/Terminal/tmux from initial scope.
- **Phase 5 — Notepad.** Always-open multi-note notepad — key-capable `.nonactivatingPanel` in the CGS
  space (focus GO validated on-device), MenuBarExtra/hotkey toggle, file-backed autosave, in-notch
  Notes tab.
- **Rebrand.** App bundle id `eth.7amza.notchnerd`, XPC helper `eth.7amza.notchnerd.XPCHelper`,
  display name NotchNerd, Sparkle disabled (no auto-update into boring.notch's appcast), violet icon +
  accent. Deconflicts from the user's daily boring.notch. (Residual brand strings + Xcode
  target/scheme names deferred.)
- **Phase 5.5 — Loose-thread audit.** 6 parallel finders → adversarial verification (13 raw findings →
  6 distinct bugs fixed, 5 rejected as false positives). Fixed: **wrong-process Accessibility checks**
  (the `c53ccfe` class — launch gate, Settings HUD read/monitor, onboarding all routed AX through the
  XPC helper's never-granted bundle id → all moved in-app via `MediaKeyInterceptor`; all XPC
  Accessibility calls now gone from app code, the helper still vends brightness per decision #7);
  **residual brand leak** (vendored reducer's `"Permission denied in Open Island."` rewritten at the
  `AgentBridgeManager.republish` projection boundary, keeping `Vendor/` pristine); **half-renamed icon
  id** (`TipStore` now uses `bundleIdentifier`). Verified-and-deferred: the inherited
  pending-interaction overwrite (structurally needs a `Vendor/` patch → Phase 6); reconnect storms
  confirmed already correctly fixed.
- **OI feature-port batch 1.** Four high-value OI features + Ghostty hardening (engine already carried
  the data/logic; work was NotchNerd-native SwiftUI + driver wiring): (1) **in-notch notification
  mode** (auto-pop on permission/question/completion; never hijacks an open notch; frontmost-suppress;
  completion auto-collapse 10s); (2) **notification sounds**; (3) **expanded session panel** (overview
  counts, pulsing per-phase status dots, age badges, spotlight lines, expandable subagent + task/todo
  rows); (4) **usage HUD** (5h/7d quota chips via `installAsWrapper()` statusline shim — the
  `rate_limits.{five_hour,seven_day}.{used_percentage,resets_at}` payload was re-verified against
  Claude Code **2.1.195**, Pro/Max-only, post-first-response); (5) **Ghostty hardening**
  (`jumpResolving`). New files added to the non-synchronized app target via
  `tooling/scripts/add_agent_files.rb`.
- **This session.** **Terminal.app jump** (`TerminalAppJumpService` + `AgentTerminalJump` dispatcher,
  routed from `AgentBridgeManager`); **taller Agent tab** (`agentNotchSize` 640×320 vs `openNotchSize`
  640×190; window created at the larger top-anchored size so the music notch is unchanged);
  **closed-notch Claude status** (`workingCount` "N working" pulsing + `liveSessionCount` "N active";
  an active session takes the music visualizer slot, standalone pill only when no music plays);
  **music-visualizer presets** (real Equalizer/Spectrum/Sound Bars Lottie + restored "Visualizer 4",
  version-seeded via `visualizerPresetVersion` / `CustomVisualizer.presetVersion` deduped by URL, +
  Lottie `sizeThatFits`/`scaleAspectFit` sizing fix); **Agent-tab gesture fix** (swipe-up-to-close
  gated off the Agent tab).
- **Agent UX overhaul + rebrand start (latest session).** Major rework of the Claude integration plus
  the start of NotchNerd's own identity:
  - **Liveness / session accuracy** — `AgentBridgeManager.aliveClaudeSessionIDs` matches live `claude`
    processes by **terminal (TTY)**, newest-per-terminal (handles `/clear`), replacing the sessionID-only
    match that force-ended every session ~6s after start; cwd-matching removed (it rescued dead sessions
    via sibling terminals in the same repo); per-event keep-alive restored; the published list + counts
    filter on `isVisibleInIsland`, discovery tightened (15min/8 files), persistence filters to visible.
    So the tab/notch show only sessions live in a terminal — phantom / `/clear`'d / historical no longer
    linger.
  - **Real-time "working" signal** — `workingCount` dropped its 60s recency window → `phase == .running
    && isProcessAlive` (so *thinking* reads as working), now reliable because liveness reaches
    `.completed` on Stop and ends dead processes. (http-transport audit: http is **not** needed for the
    signal — all turn/tool-boundary hooks already flow; http stays a deferred transport cleanup, verified
    viable.)
  - **Closed-notch indicator** — fixed the notch-occlusion layout (pill flanks the hardware notch);
    **music + Claude coexist** (needs-you = orange sparkle, working = purple, in the visualizer slot —
    music never hidden); standalone working/active pill is compact (sparkle + dot + count).
  - **Agent tab** — rows are a **recap, not a transcript**: goal (initial prompt) → outcome (`Claude: …`)
    / current activity, **identity chips** (branch · terminal · model · mode), a `k/n` task badge,
    attention-first sort, speaker-labeled lines.
  - **Question card** — full `AskUserQuestion`: multiple questions, **multi-select** (toggle + Submit, no
    auto-submit), **ASCII/code option previews**, freeform "Other" (notch becomes key via the Notes-tab
    `makeKey` trick to type). Needed a small **documented Vendor patch** — `QuestionOption.preview`
    (recorded in `VENDORED-FROM.md`, marked `// NotchNerd patch`).
  - **Permission card** — renders Claude's `suggestedUpdates` as one-tap "always allow X" / mode options
    (allow + persist) alongside Allow-once / Deny.
  - **HookHealthCheck wired** — Settings → Agent runs the (previously dormant) engine diagnostic on
    launch/refresh/install and offers **Repair hooks**.
  - **Rebrand (user-visible)** — first-run welcome screen uses NotchNerd's own app icon + drops the
    "TheBoringTeam" wordmark; About tagline, "Enable webcam mirror", hook-error string, and release
    codename de-branded; README refreshed (features + first-run/permissions + tester `xattr` note). Dead
    `runningCount` removed. Remaining rebrand is structural (module/socket/binary naming) — see Phase 6.
  - **Asymmetric closed-notch + pre-public prep** — the "needs you" pill expands only on the text side
    (the notch shifts by `closedNotchHOffset` so the cutout stays bridged; the sparkle wing stays small),
    and the music+Claude combo surfaces "N needs you" the same way with matched padding
    (`musicAttentionSlotWidth` derives from `agentAttentionFlankWidth`). Pre-public cleanup: removed the
    inherited `FUNDING.yml` (routed to upstream), the dead boring.notch `appcast.xml` / issue & PR
    templates / `crowdin.yml`, and de-branded the DMG packaging defaults; `THIRD_PARTY_LICENSES` now
    lists the linked SPM deps.
  - **Public release + auto-update pipeline.** Repo flipped **public**; added the GitHub Actions
    **release workflow** (`.github/workflows/release.yml`) — on a `v*` tag it builds, packages zip + dmg,
    EdDSA-signs + generates a Sparkle appcast, and publishes a GitHub Release. **Sparkle auto-updates
    enabled** with NotchNerd's own key (first release: `v0.1.0`). Distribution is still ad-hoc / **not
    notarized**, so testers clear quarantine once (README "Install a prebuilt build" has the steps);
    notarization is a possible future step (deliberately not documented here).
- **Onboarding wizard + feature tour + README state-doc (2026-06-28).** Extended the inherited
  first-run wizard and added a re-runnable feature tour (full reference in Part I → *Onboarding &
  first-run*). Welcome screen got a real app description; new **Automation** explainer
  (`AutomationInfoView`); new **Agent** consent step (`AgentMonitorOnboardingView`) — the single opt-in
  enable surface, **roll-back-on-failure** (`agentEnabled` flips true only on a *confirmed* install;
  "Not now" writes nothing), backed by a hardened `installHooks()` (`@discardableResult -> Bool` +
  transient-state reset) and an `onChange`+poll state machine. New **7-card tour** (`FeatureTourView`)
  with inline ✦ mocks, re-runnable from the menu bar + Settings, **auto-shown once** to upgraders via
  `hasSeenFeatureTour`. Fixed the **stuck-open notch** during onboarding (`doOpen()` now shares the
  `firstLaunch` guard hover already had — inherited bug). Adversarial review caught + fixed a
  **retain cycle** in the onboarding-window closures (per-replay `NSWindow` leak) and a window-reuse
  latent bug. README gained a **"What the notch shows you"** state-reading guide (ASCII diagrams + ✦
  reference). New files registered via `tooling/scripts/add_onboarding_files.rb`. Build-verified;
  live-walked on-device.
- **Settings IA redesign + version fix (2026-06-28).** Three-phase refactor of the Settings UI (driven
  by a multi-agent review → adversarial critique). **P1:** dropped 4 zero-consumer Defaults keys + dead
  decls; fixed the Agent Notifications/Sound/Usage sections that trapped their own masters inside
  `.disabled(!master)` (Usage shipped permanently un-enableable). **P2:** replaced the flat 11-tab
  sidebar with a single `SettingsTab` enum driving both sidebar + detail, grouped (General / Notch
  features / Advanced / About) with `@AppStorage` tab persistence (an accent change no longer resets to
  General); moved theming → Appearance and music visuals → Media; added **Notepad** + **Webcam** tabs;
  slimmed Advanced + a Reset-to-defaults button; fixed the gesture-enable inversion, a force-unwrap
  crash in the visualizer add-sheet, the `vizualizers`/`unkown` typos; applied disable-in-place child
  gating + a sentence-case sweep; removed ~215 lines of commented Downloads/Extensions + dead helpers;
  gave `toggleNotepad` a default (⌘⇧N) and dropped 4 handler-less shortcut names. **P3:** an "Include
  reminders" master (`showReminders`) wired at the `CalendarView` display layer. Also fixed the
  **local-build version** (`MARKETING_VERSION` 2.7.3 → 0.1.0 — boring.notch's leftover made *Check for
  Updates* show the wrong version; releases set it from the git tag, so unaffected). Deferred as
  low-value/risky: the calendar shared-store deselect-all snap-back, `musicControlSlotLimit` vs
  `fixedSlotCount`, and the `sliderColor`/`agentSuppressFrontmost` symbol-vs-string mismatches.
- **v0.2.x public release + the hardened-runtime launch fix (2026-06-28).** Tagged **v0.2.0** (first
  release built by the NotchNerd `release.yml` — onboarding + the Settings redesign) and forced
  `make_latest: true` so the fork's `0.x` releases win "Latest". Then **v0.2.1** fixes a crash that hit
  *every downloaded release* (incl. v0.1.0): the Release build's **hardened runtime** rejected the
  ad-hoc-signed `MediaRemoteAdapter.framework` via Library Validation → DYLD "Library missing" at
  launch. Disabled hardened runtime (`ENABLE_HARDENED_RUNTIME = NO`); verified a Release build signs
  `flags=0x2` and the dmg launches. Also: `gh` was defaulting to `upstream` (boring.notch) — the
  "inherited releases" scare was a mirage (`gh repo set-default` fixed it); release notes are now
  hand-curated per tag (the workflow's auto-notes are thin since commits skip PRs).

## Roadmap & TODO

The single source of truth for remaining work. Items reference the deferred-work and porting-recipe
subsections below where an implementer needs the concrete recipe.

### v0.3 — "Agent tab, grown up" (ACTIVE — locked 2026-06-30)

Multi-agent-researched + adversarially-verified overhaul of the Agent tab (plan-mode card, richer
recap/expand, subagent visibility). **All app-layer — zero Vendor patches.** Key research facts,
verified against the Claude Code **v2.1.198 binary** on this machine (not guessed):

- **The real ExitPlanMode plan-approval menu** (labels + values from the CLI bundle; the menu is
  *conditional on session state*): `"Yes, and use auto mode"` (`yes-resume-auto-mode`, shown instead
  of auto-accept when the session was in auto mode) / `"Yes, auto-accept edits"`
  (`yes-accept-edits-keep-context`) / `"Yes, manually approve edits"` (`yes-default-keep-context`) /
  conditional `"Yes, and publish plan as artifact"` / conditional `"No, refine with Ultraplan on
  Claude Code on the web"` (`ultraplan`) / `"No, keep planning"` — an **input** option with
  placeholder *"Tell Claude what to change"*.
- **`updatedPermissions` from a PermissionRequest hook IS honored** — the CLI's hook-allow path
  applies it via `handleHookAllow(...)` → `setToolPermissionContext`. So NotchNerd's
  `resolve(.allowWithUpdates([.setMode(.session, <mode>)]))` round-trip works; mode buttons are real.
- **Ultraplan cannot be triggered from a hook directive** (it's a CLI-side cloud-session flow) —
  the card represents it as "continue in terminal" (jump), never fakes it.
- **Do NOT use `ClaudePermissionUpdate.setMode(...).displayLabel`** for button copy — its mapping is
  inverted vs. the real CLI menu. Hardcode labels.
- The full last assistant message is **already un-truncated** in
  `claudeMetadata.lastAssistantMessage` (raw `last_assistant_message` hook field; the 140-char cap is
  view-layer `condensedForRecap`) — P6a renders it with **zero IO**; the transcript reader is only
  needed for plan text, activity timeline, edited files, stats, and stale-session fallback.

**Phase order** (each independently shippable + build-verified):
**P1** plan-mode review card — plan text via a small tail-read `PlanTextLoader` (last `ExitPlanMode`
`tool_use.input.plan`, matched by `toolUseID`), CLI-mirrored buttons (order + prominence match the
CLI; single-shot `resolving` guard), "keep planning" feedback field (notch `makeKey` trick) sending
`deny(message: feedback)` with the projected summary rewritten at the `debranded()` boundary so the
row doesn't flash "Permission denied" →
**P2** subagent chip — "N researching" on the *activity line* (not the crowded header), counting
`activeSubagents` without a `summary`; no auto-expand/soft-pin; closed-notch unchanged →
**P4** manager-owned expansion — `@Published expandedSessionIDs` in `AgentBridgeManager` (fixes the
@State-teardown expansion-loss bug), every row expandable, pruned in `republish()` →
**P6a** full last message + copy button ("Last message"/"Details", NOT "recap" — `/recap` is
API-synthesized and unreproducible) →
**P3** `AgentActivity` vocabulary — per-activity icon/tint descriptor (planReview/researching/
failed/compacting differentiation; status dot keeps phase color) →
**P5/P6b** `ClaudeTranscriptReader` — off-MainActor streaming read (≤12 MB forward, else 64 KB tail),
mtime-cached, never from a SwiftUI body; timeline/files/stats (validate jsonl field shapes first) →
**P7** `.failed` (isInterrupt/StopFailure) + `.compacting` (PreCompact, ~12s TTL) + startup-source
chip → **P8** polish (stop button, copy-summary, markdown, smart-expand).

**QA/pre-work:** audit our bridge use vs upstream PR **#503** (subagent permission requests dropped
by a bridge filter) before P2; retest upstream issue **#559** (decisions ignored/stuck) during P1 QA.
**Skip the upstream re-pull** at v1.1.4 (delta is ~90% Codex/Cursor-only; a re-pull clobbers the
`QuestionOption.preview` patch) — re-evaluate at upstream's next minor.

### v0.4 — "Close the lid" keep-awake (locked 2026-06-30, signing-gated)

Lidless-style (github.com/nghialuong/Lidless, MIT — add to `THIRD_PARTY_LICENSES` when built)
keep-awake via the **`SleepDisabled` flag in `IOPMrootDomain`** — the only mechanism that survives
lid-close on Apple Silicon (`caffeinate`/IOPMAssertion do not). Needs a **root helper**; a 90s
heartbeat watchdog restores sleep if the app dies. ⚠️ `SleepDisabled` is **undocumented on macOS
26.4** — treat as volatile: re-assert/clear at every boot, assume no persistence. Differentiator:
**nobody in the Claude-companion space ships agent-aware keep-awake** (field is saturated on usage
tracking + phone remotes instead; Anthropic's official Remote Control subsumes the remote niche —
don't build remote approve/deny).

- **Modes:** **Manual** (menu-bar toggle + hotkey, auto-off timer 15m–4h with live countdown, NO
  charging requirement — explicit user act); **While-Claude-works** (`workingCount > 0` + grace
  period, default 5 min, + `keepAwakeAgentMaxHours` runaway cap, default 8h); **Remote-ready**
  (`liveSessionCount > 0` — keeps the Mac reachable for Claude Code's phone remote control, e.g.
  backpack + hotspot; once asleep there is NO remote-wake path on a hotspot — no Bonjour Sleep
  Proxy — so "don't sleep while reachable matters" is the design, not "wake").
- **Safety rails** (agent modes): only-while-charging default ON, low-battery cutoff 20%, thermal
  pause (`ProcessInfo.thermalState`), watchdog invariant, safety releases announced via notch HUD +
  sound. `applicationWillTerminate` restores sleep.
- **Lid-closed attention alerts** *(revised per the 2026-06-30 sentiment/verification memo)*:
  phone push is the primary channel, stacked: (1) **first-party Remote Control push** ("Push when
  actions required", CLI ≥ 2.1.110) — document/integrate, don't rebuild; (2) **ntfy topic URL**
  (no-account, high-entropy topic generated in-app; add a "send test push — did it sound?" setup
  step, open iOS silent-notification bug ntfy#1562); (3) a **generic webhook field** (covers
  Pushover/Telegram/Slack). **iMessage-to-self is CUT** (self-sends produce no banner/sound, and
  per-cdhash Automation TCC would drop every rebuild). Local escalating sounds are **secondary,
  off-by-default** (clamshell audio confirmed working while awake, but lid+backpack muffles it —
  same-room channel only; play via AVAudioPlayer to the default output, NOT NSSound's alert
  device). Keep the Adrafinil-style **armed chime on lid close**. Lid detection: subscribe to
  `kIOPMMessageClamshellStateChange` (public IOPM.h) in-app — not the XPC helper, no root/TCC.
- **Adds from the sentiment memo:** **display-off while held awake** (raw `disablesleep` leaves the
  panel lit under the closed lid — Modafinil's entire raison d'être); **`CLAUDE_CLIENT_PRESENCE_FILE`
  integration** (CLI ≥ 2.1.181 — write/remove the presence marker from lid state so first-party RC
  pushes fire when the lid is shut; observe-only); **battery %/temp in the usage HUD** during
  held-awake runs; **coexistence with Claude Code's own `caffeinate -i`** (it already prevents
  lid-open idle sleep during turns — NotchNerd's added value is *only* the lid-closed case; detect
  it so state never looks contradictory); QA gate: lid closed + SleepDisabled + looping audio 5 min
  on target hardware.
- **Remote-ready mode CONFIRMED as ship-shape** — Remote Control is server-mediated outbound-HTTPS
  polling; a sleeping Mac is unreachable, hotspots have no Bonjour Sleep Proxy, APNs can't wake a
  Mac, and the documented reconnect-after-sleep is *empirically flaky* (anthropics/claude-code
  #34255 #34531 #69543) — holding awake avoids the buggiest path entirely. **Do not assume
  server-side message queueing** (unverified) — Remote-ready UI copy should treat
  delivery-while-asleep as failure. **Scheduled-wake** (sleep + periodic root RTC DarkWakes,
  ~4–6× better battery) is DEFERRED behind a spike: unknowns are DarkWake duration stretching and
  whether the RC session survives repeated sleep/wake.
- **Defaults keys:** `keepAwakeEnabled` (off, consent-gated helper install), `keepAwakeAgentMode`,
  `keepAwakeAgentGraceMinutes` (5), `keepAwakeAgentMaxHours` (8), `keepAwakeOnlyOnPower` (on),
  `keepAwakeLowBatteryCutoff` (20), `keepAwakeAutoOffMinutes` (60). Settings → Keep Awake tab
  mirroring the `AgentSettings` install/status pattern.
- **⚠️ SIGNING GATE (must resolve before building):** `SMAppService.daemon` under ad-hoc signing is
  a **confirmed non-starter** (macOS 26 SDK header: "Apps that contain LaunchDaemons must be
  notarized"; Lidless itself ships Developer ID + notarized). The classic
  `/Library/LaunchDaemons` fallback (one admin-prompt install) is *maybe* viable but **Background
  Task Management** (Sonoma 14.6.1+) gates daemons by developer signature (it broke Nix's daemons
  on Tahoe — "unidentified developer", disabled until manually toggled in Login Items). **Run the
  ~30-min user-assisted spike first** (ad-hoc helper → one-prompt install → `launchctl bootstrap
  system` → reboot → `sudo sfltool dumpbtm`; re-check after a re-signed binary swap — cdhash churn
  may reset BTM trust). Branch: spike passes → classic-daemon path; fails → **Developer ID +
  notarization** becomes the keep-awake prerequisite (one $99 gate that also retires quarantine
  friction, per-build TCC churn, and unblocks the Watch relay); either way a zero-privilege
  monitor+nag v1 can ship. Disclose the root-helper posture change in README/onboarding.

### Phase 6 — Modernize & harden

- **Socket / hooks / statusline-cache namespacing off `eth.7amza.notchnerd`** (locked decision #8).
  The bridge socket is still the shared `~/Library/Application Support/OpenIsland/bridge.sock`, the
  managed-hooks group/binary copy location reuses OI's identity, and the usage HUD reuses OI's
  `/tmp/open-island-rl.json` statusline cache + script name. Namespace all of them so NotchNerd and a
  running Open Island can coexist. ⚠️ **`sun_path` length trap** (see Reference: porting recipes) — a
  long namespaced socket path under `~/Library/Application Support` can trip `socketPathTooLong`; the
  legacy `/tmp` path stayed short for exactly this reason.
- **Fix the inherited "pending-interaction overwrite" bug** — structurally needs a small documented
  `Vendor/` patch (recipe in *Reference: deferred-work → §1*). Corroborated independently by
  `WatchNotificationRelay.swift` (same same-session fan-out problem:
  `actionableStateResolved` must clear **all** pending requests for a session). (Also note the
  harmless duplicate condition `a != nil || a != nil` in `BridgeServer.hasSession(id:)` ~L2569.)
- **http hook transport spike — VERIFIED VIABLE, DEFERRED.** The docs confirm `http` hooks block
  synchronously with a raisable per-hook `timeout` (so they *could* carry approve/deny). But the audit
  concluded http is **not needed for the activity signal**: all turn/tool-boundary hooks already flow
  over the socket, and `workingCount`'s recency window was **dropped** in favour of `phase == .running`
  (latest session). http remains an optional transport cleanup (no embedded binary to ship/sign), not a
  signal fix. The `workingCount` recency heuristic + liveness-tick republish concern in §2 is resolved.
- **HookHealthCheck — DONE.** Wired into Settings → Agent (diagnose on launch/refresh/install + a
  Repair-hooks action reusing the installer's `settings.json` backup). Remaining: exercise against more
  live hook-schema drift (`StopFailure` is already handled).
- **Finish the rebrand.** **User-visible + pre-public surfaces DONE** (welcome-screen icon/wordmark,
  About tagline, "webcam mirror", hook-error string, release codename, README; DMG volume name
  de-branded; the dead boring.notch `updater/appcast.xml` + `.github/FUNDING.yml` + inherited issue/PR
  templates + `crowdin.yml` removed; `THIRD_PARTY_LICENSES` credits Open Island and now lists the linked
  SPM deps). **Remaining is structural** (not user-visible app identity): the SPM module/products
  (`OpenIslandCore`/`OpenIslandHooks`), the embedded hook-binary name + socket/statusline paths (folds
  into the namespacing item above), and the `BoringNotchXPCHelper` display name. The vendor-merge audit
  recommends **keeping the SPM boundary** (load-bearing: the separate hook-CLI Mach-O must share Core,
  and the Swift-6/Swift-5 language-mode split must stay isolated) while rebranding its identity in tiers
  (rename products via a `path:` override that preserves the re-pull dir; namespace runtime paths).

### More terminals (remainder of OI review item #5)

Engine support is vendored; these are wiring jobs. Recipe in *Reference: porting recipes → ADD-A-TERMINAL*.

- **Small** (AppleScript or native CLI): iTerm2, tmux, WezTerm, Kaku, Zellij. *(Ghostty + Terminal.app
  already shipped.)*
- **Small-medium**: cmux (Unix-socket JSON-RPC), VS Code / JetBrains workspace-activation jumps
  (trivial), Codex.app (`codex://` URL).
- **Medium-large**: **Warp** — the hard one: needs hybrid Accessibility-menu-click ("Tab > Switch to
  Next Tab") + read-only `warp.sqlite` (private schema, AX with no programmatic prompt, `KeystrokeInjector`
  AX + Automation TCC).

### More agents (remainder of OI review item #6)

All hook payload models + installers are vendored in `OpenIslandCore`; `ActiveAgentProcessDiscovery`
already detects 5 of them. There is **no agent protocol** — see *Reference: porting recipes →
more-agents reality*: two parallel hardcoded enums + ~6 hardcoded switch sites.

- **Small** (Claude forks — almost no code; reuse `ClaudeHookPayload`, differ by config dir +
  `--source`; Kimi installs TOML): Qoder, Qwen, Factory, CodeBuddy, Kimi. Most savings are install/UI,
  not the hot path.
- **Small** (own hook payload + installer, already vendored): OpenCode, Gemini, Cursor.
- **Medium**: **Codex** — the outlier: a second JSON-RPC app-server integration (~3000 lines, watches
  rollout JSONL), not just a hook source.

### Music / visualizer

- **dotLottie (`.lottie`) support in `LottieView`** *(small-medium, user-requested)*. The current
  loader (`LottieAnimation.loadedFrom(url:)`) only handles `.json`; the best purpose-built equalizer
  visualizers (e.g. a Spotify-style 5-bar now-playing indicator) ship as **dotLottie**, so supporting
  the container unlocks better/more presets. Touches `components/LottieView.swift` (add a `.lottie`
  branch via `DotLottieFile.loadedFrom(url:)` alongside the existing JSON path + the `sizeThatFits` /
  `scaleAspectFit` sizing fix) and the seed path (`visualizerPresetVersion` / `CustomVisualizer.presetVersion`).
- *Follow-on (small):* once dotLottie lands, curate/seed more built-in presets beyond the current
  Equalizer / Spectrum / Sound Bars / "Visualizer 4" set.

### Phase 7 — Cowork (beta), optional

Read-only live-status watcher for Claude **Cowork / "local agent mode"** (its agent runs on-device in
an Apple-VZ + gVisor Linux microVM). **Live status + activate-app jump only — no approve/deny, no
per-session jump** (the gate runs in the desktop app's host loop; there is no host-side hook process
to block). Reuse the Phase-2 `ClaudeTranscriptDiscovery` design as a **second watcher root**, behind a
Defaults flag with a schema-version/format-drift guard. File formats + foreclosed approaches in
*Reference: deferred-work → §3*. **Read only session metadata/transcripts — never the
`.audit-key`/token/MCP-secret files in those dirs.**

### Net-new (not in Open Island — decide separately)

Real macOS Notification Center banners (OI uses only the in-notch pop + sound), a session
interrupt/stop button, a transcript viewer, copy-summary, IDE terminal-focus extensions
(`~/.claude/ide/*.lock` → jump to an IDE's embedded terminal), and the Watch/iPhone relay (engine is
in Core, UI is not).

### Dev workflow & on-device QA

- **On-device QA of the recent agent/notch UI** *(ongoing — the gap a build can't close).* Everything
  in the changelog is **build-verified only** unless noted; the assistant shell can't render the notch
  or run live Claude Code. Specifically wants a real-machine pass: the in-notch **notification pop +
  sound** on a live permission/question; the **usage HUD** chips (needs a Pro/Max plan, post-first-
  response); the **closed-notch "N working" / "N active"** status (incl. that an active session swaps
  the music visualizer for the ✦ without the music notch vanishing); the **taller Agent tab**
  (640×320) and that the **music notch is unchanged**; the **music-visualizer presets** looking right
  in the tiny slot; approve/deny round-trip; TCC consent (Accessibility in-app, Automation for the
  Ghostty/Terminal jump). (`workingCount` is now event-driven — `phase == .running &&
  isProcessAlive`, no recency window; the old "60s-recency heuristic" note is obsolete.)
- **Build-output location cleanup** *(trivial, deferred).* CLI builds use `-derivedDataPath build`
  (project-local `build/Build/Products/Debug/NotchNerd.app`), which is a **different** binary from
  Xcode's default DerivedData output — so launching the wrong one runs stale code, and TCC grants are
  per-binary. Decide whether to keep `-derivedDataPath build` (project-local, gitignored — current
  CLAUDE.md/spec.md form) or drop it so CLI + Xcode builds share one location. CLI builds are ad-hoc
  signed regardless (cdhash churn resets TCC each build unless the "NotchNerd Dev" identity is used).

## Reference: deferred-work implementation notes

> Implementation-load-bearing detail for work that is **planned but not yet built** (folded in from
> the former `tooling/docs/deferred-work-notes.md`, itself extracted from removed spike/research
> docs). Only the concrete file formats / fix recipes an implementer would otherwise re-derive.

### §1 — Phase 6: fix the inherited "pending-interaction overwrite" bug

**Status:** still present; lives in the **frozen** vendored engine + the resolve-command protocol, so
it is *not* fixable from the driver alone — needs a small documented `Vendor/` patch.

**Diagnosis.** `BridgeServer.pendingClaudeInteractions` is keyed by `sessionID` **only**
(`BridgeServer.swift:731,757`), and `bindListener`-side resolution removes by `sessionID`
(`:1806,2406,2473`). The `PendingClaudeInteraction` struct already carries a `toolUseID` field but it
is unused as a key. So two *simultaneous* `PermissionRequest`s in the **same** session (parallel tool
batches) overwrite each other → the first blocked hook never gets its directive and hangs to timeout.
Subagent hooks are already suppressed, so this is specifically the same-session concurrency case.

**Fix recipe (patches the pristine vendored engine — document the patch in `VENDORED-FROM.md`):**
1. Key `pendingClaudeInteractions` by a composite **`sessionID + toolUseID`** (the hook payload
   carries `toolUseID`, surfaced via `claudeToolUseID(for:)`). Apply the same to `pendingApprovals`
   and `pendingClaudeToolContexts` (`permissionCorrelationKey`).
2. Extend `BridgeCommand.resolvePermission` (and `AgentBridgeManager.resolve` / the engine's
   `resolvePendingClaudeInteraction`) to carry the `toolUseID` so the UI resolves the **exact**
   request, not "whichever is pending for this session."
3. `AgentSession.permissionRequest` must expose the `toolUseID` to the card so the Allow/Deny
   round-trip can pass it back.

**Repro to confirm impact before patching:** in `default`/`plan` mode, get a single Claude session to
raise two concurrent `PermissionRequest`s (parallel tool batch). If the current CLI can't do that, the
fix is pre-emptive hardening; if it can, it's load-bearing.

### §2 — Phase 6: http hook transport + a real-time "Claude is working" signal

**Status (updated):** the "working" signal is now event-driven, **not** a heuristic — `workingCount`
was changed to `phase == .running && isProcessAlive` (the 60s recency window + the reason for the
liveness-tick republish are gone), reliable because the TTY-based liveness rework ends dead/superseded
sessions. So this §2 below is **historical**: http transport is **verified viable but not needed for
the signal** and remains a deferred optional transport cleanup, not a correctness fix.

**The transport.** Replace/augment the embedded Unix-socket + `OpenIslandHooks` CLI with the modern
**`http` hook → in-app `127.0.0.1` listener** (no binary to ship/sign). Gate adoption behind a spike
confirming Claude Code holds a *blocking* HTTP response for the full interactive `PermissionRequest`
timeout, plus the `allowedHttpHookUrls` allowlist behavior. Keep socket+CLI as default until that
validates.

**The real-time activity signal** (the closed-notch "Claude working" indicator):
- **Why it's a heuristic today.** Classic hooks fire at **turn boundaries** only (`UserPromptSubmit`/
  `PreToolUse` → `.running`; `Stop` → `.completed`). There is no "generating *right now*" event, and a
  missed `Stop` leaves a session stuck `.running`. So NotchNerd infers "working" with
  `AgentBridgeManager.workingCount` = `phase == .running && isProcessAlive && now − updatedAt < 60s`
  (recency guard filters stuck/idle sessions). The 3s liveness backstop republishes while any session
  is `.running` so the time-based count updates. Consumed by the closed-notch visualizer-slot indicator
  and the standalone "N working" pill.
- **Failure modes the heuristic can't fix:** a stuck `.running` session still reads as working for
  ~60s; a long *silent* op (>60s, no tool events) falsely reads as not-working.
- **What http / newer hooks would give.** A persistent in-app connection (or newer hook events —
  `Notification`, `SubagentStart/Stop`, the `Stop`/`StopFailure` split) can deliver a precise
  start/stop-generating signal: no recency window, no stuck-session false positives, instant off on
  turn end. **When building this, replace `workingCount`'s recency heuristic with the real signal and
  drop the liveness-tick republish hack.** Audit the current hook schema for a finer-grained
  activity/heartbeat event before assuming http is required.

### §3 — Phase 7: Cowork ("local agent mode") read-only watcher

**Status:** optional beta, unbuilt. Read-only **live status + activate-app jump only** — no
approve/deny. Reuse the Phase-2 `ClaudeTranscriptDiscovery` design as a *second watcher root*. **Read
only metadata/transcripts — never the `.audit-key` / token / MCP-secret files in those dirs.**

**Session root layout:**
```
~/Library/Application Support/Claude/local-agent-mode-sessions/<accountId>/<orgId>/
  ├─ local_<uuid>.json        # session metadata
  └─ local_<uuid>/audit.jsonl # append-only, HMAC-signed transcript
```

**`local_<uuid>.json` keys (verified superset):** `sessionId`, `processName`, `cliSessionId`, `cwd`,
`userSelectedFolders`, `createdAt`, `lastActivityAt`, `model`, `permissionMode`, `isArchived`,
`title`, `vmProcessName`, `hostLoopMode`, `webFetchAllowedUrls`, `initialMessage`, `slashCommands`,
`enabledMcpTools`, `remoteMcpServersConfig`, `fsDetectedFiles`, `egressAllowedDomains`,
`orgCliExecPolicies`, `memoryEnabled`, `skillsEnabled`, `pluginsEnabled`, `spaceId`, `spaceIdSetBy`,
`systemPrompt`, `accountName`, `emailAddress`. Use a subset (title/model/permissionMode/cwd/
lastActivityAt/spaceId) for the chip; keep a **schema-version/format-drift guard**.

**`audit.jsonl` format:** append-only stream-json. Record types `{user, assistant, system, result,
rate_limit_event}`; per-record keys `type`, `uuid`, `session_id`, `parent_tool_use_id`,
`client_platform`, `message`, `_audit_timestamp`, `_audit_hmac`. **Turn completion = a `result`
record.** A **pending tool-permission can be *inferred*** (not resolved) in non-bypass modes by a
`tool_use` event with no following matching `result` — the only read-only "waiting" signal for Cowork.

**VM liveness:** prefer **FSEvents/mtime** of the VM bundle over `ps`
(`vm_bundles/claudevm.bundle/`: `rootfs.img`, `sessiondata.img`; NAT `vmIP=172.16.10.3` host/guest). A
guest hook can't reach a host listener (must cross the NAT) — which is *why* the embedded Cowork
Claude-Code path can't be hooked.

**Jump ceiling:** activate bundle id **`com.anthropic.claudefordesktop`** (single shared window). A
per-session `claude://` deep-link is undocumented (would need a reverse-engineering spike first).

**Foreclosed approaches (negative evidence — don't re-investigate):**
- **Chat content is not locally readable.** The chat app's IndexedDB
  (`https_claude.ai_0.indexeddb.leveldb`) has no plaintext role/human/assistant markers; Local Storage
  leveldb holds only `claudeai.*` telemetry and is locked while the app runs.
- **`mcp.log` can't signal a pending prompt.** It logs MCP tool calls only *after* user approval (a
  Decline produces no traffic) — it reflects resolved approvals, never the pending prompt. So
  MCP-as-monitor / `mcp.log` tailing cannot deliver approve/deny, even for the chat app.

## Reference: porting recipes (terminals & agents)

> Distilled from the dual-codebase map. Backs the **More terminals / More agents** TODO items above.

**ADD-A-TERMINAL recipe.** (1) Add a `TerminalAppDescriptor` to the jump dispatch (bundleID +
aliases) — in NotchNerd that's the `AgentTerminalJump` dispatcher + a per-terminal service like
`TerminalAppJumpService`; (2) write a per-app focus routine; (3) teach
`ActiveAgentProcessDiscovery.recognizedTerminalApp` the alias so discovery labels it; (4) optional
precision via a target-resolver / attachment-probe.

**Per-terminal jump strategy map:**
- **AppleScript:** iTerm2, Terminal.app, Ghostty.
- **Native CLI:** WezTerm, Kaku, Zellij, tmux, VS Code, JetBrains.
- **Unix-socket JSON-RPC:** cmux (`surface.focus`).
- **URL scheme:** Codex.app (`codex://`).
- **Hybrid (the hard one):** Warp — Accessibility-menu-click ("Tab > Switch to Next Tab") + read-only
  `warp.sqlite` (private SQLite schema + AX with no programmatic prompt).

**More-agents reality.** There is **no agent protocol** — two parallel hardcoded enums (`AgentTool`,
~10 agents; `AgentIdentifier`) + ~6 hardcoded switch sites. Claude forks (Qoder/Qwen/Factory/
CodeBuddy/Kimi) carry almost no code — they reuse `ClaudeHookPayload` and differ only by config dir +
`--source` (Kimi installs TOML) — so most fork savings are install/UI, not the hot path. **Codex is
the outlier:** a second JSON-RPC app-server integration (~3000 lines, watches rollout JSONL).

**Phase-6 socket-namespacing gotcha.** `sockaddr_un.sun_path` is ~104 bytes, so a long namespaced
path under `~/Library/Application Support` can trip `socketPathTooLong` (the legacy `/tmp` path stayed
short for exactly this reason) — check this when namespacing the socket off `eth.7amza.notchnerd`.

**Inherited-bug corroboration.** `WatchNotificationRelay.swift` documents the same same-session
pending-interaction fan-out problem (`actionableStateResolved` must clear **all** pending requests for
a session) — independent confirmation of *Reference: deferred-work → §1*. Separately,
`BridgeServer.hasSession(id:)` (~L2569) has a harmless duplicate condition `a != nil || a != nil`.

