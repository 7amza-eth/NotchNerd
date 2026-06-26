# NotchNerd — Integration Plan

*Merging **boring.notch** (music notch) with **Open Island** (Claude Code session monitor), plus an always-open notepad. Generated 2026-06-25 from a deep two-codebase map + an adversarial direction review.*

---

## 1. What the two apps actually are

| | **boring.notch** (host) | **Open Island** / open-vibe-island (source) |
|---|---|---|
| Purpose | Music notch + shelf + calendar + HUD | Monitors AI coding agents (Claude Code, Codex, …) |
| Build | **Xcode project** (`.xcodeproj`, objectVersion 70), Swift 5.0 | **SwiftPM** package, Swift 6.2, 4 targets |
| Sandbox | **App-Sandboxed**, hardened runtime, Apple-Development signing, **not** notarized (Homebrew quarantine-strip) | **Unsandboxed** hardened runtime, Developer-ID + notarized |
| Music | private **MediaRemote** framework via bundled adapter + perl subprocess (fragile, OS-sensitive) | n/a |
| Notch window | private **CGSSpace/SkyLight** APIs (floats over fullscreen) | own NSPanel overlay |
| Agent engine | n/a | `OpenIslandCore` — **pure Foundation, zero external deps**: hooks → Unix-socket `BridgeServer` → `SessionState` reducer → `@Observable` UI |
| License | **GPL v3** | **GPL v3** |

**Compatibility wins:** both macOS 14+, both SwiftUI+AppKit, both Sparkle, both GPL v3 (a merged/derived work is fine, and code copies freely between them).

**The one real tension:** the agent features (writing `~/.claude/settings.json`, running `ps`/`lsof`/`osascript`/`open`, reading `~/.claude/projects`, AppleScript-controlling terminals) **require an unsandboxed app**. boring.notch ships sandboxed. This single fact drives the whole decision.

---

## 2. The decision: **Direction A — boring.notch is the host**

A formal review pitted three directions against each other (independent advocates → adversarial critics → a sandbox/build feasibility deep-dive → a deciding judge):

| Direction | Score | Critic verdict | Adjusted effort | Why it ranks here |
|---|---|---|---|---|
| **A — Port Open Island's engine *into* boring.notch** | **85** | viable-with-caveats | **16–28 wk** | **Leaves the beloved music notch byte-for-byte untouched.** The engine (`OpenIslandCore`) is genuinely clean/portable. Notepad + sandbox + transport are small surgical changes. |
| B — Port boring.notch's music *into* Open Island | 46 | viable-with-caveats | 15–30 wk | Puts the **fragile music subsystem at most risk** (re-embed/re-sign MediaRemoteAdapter into a foreign project) and demotes the app you actually use; needs a ~70% UI re-port to not regress. |
| C — Ground-up "NotchNerd" | 38 | risky | 20–34 wk | Most expensive **and** highest regression risk to your #1 feature, for benefits Option A already gets for near-free. |

> **Critical reframe (from the critics):** Direction A does **not** mean "port Open Island's `AppModel`." That glue (`applyTrackedEvent`, the overlay/discovery/monitoring coordinators) *is* Open Island's UI nervous system and would be a from-scratch rebuild against a UI that doesn't exist in boring.notch. **Instead: vendor only the clean headless core + the hook CLI, and write a small fresh boring.notch-native driver on top.** `BridgeServer` already has a UI-free `public init(socketURL:)` / `start()` — it runs headless in-process.

---

## 3. The four key engineering decisions

### 3a. Build system — vendor Core as a local SPM package
- Copy `Sources/OpenIslandCore` + `Sources/OpenIslandHooks/OpenIslandHooksCLI.swift` into `Vendor/OpenIslandEngine/` (verified: Core is **pure Foundation, zero external deps**).
- Hand-write a slim `Package.swift` there: **2 products** (`.library("OpenIslandCore")`, `.executable("OpenIslandHooks")`), no deps, no App target, no tests.
- **Toolchain trap (critics caught this):** the upstream manifest is `swift-tools-version:6.2`, which boring.notch's pinned **Xcode 16.4 (Swift 6.0) CI will refuse to open.** Fix: set the vendored manifest to **`swift-tools-version:6.0` + `.swiftLanguageMode(.v6)`** — safe because Core uses no 6.2-only syntax. This avoids force-migrating the whole host to Xcode 26 (which would re-resolve all 11 pinned deps incl. Sparkle and re-qualify the private CGS/MediaRemote code).
- Add via `XCLocalSwiftPackageReference` (legal at objectVersion 70) through the **Xcode UI** (not hand-edited pbxproj).
- **Embed the hook CLI** as a native command-line-tool target (Swift 6.0, per-target override is fine) + a Copy Files phase → `Contents/Helpers` with CodeSignOnCopy (clone the existing "Embed XPC Services" phase). Set `ENABLE_USER_SCRIPT_SANDBOXING=NO` if a run-script fallback is used.
- Three coexisting Swift modes (app 5.0 / hooks tool 6.0 / Core 6 library) is fully supported. **Do not** raise the app to `SWIFT_STRICT_CONCURRENCY=complete`.

### 3b. Sandbox — drop it in-place
- Flip `com.apple.security.app-sandbox` → `false` in `boringNotch.entitlements` (it's entitlements-only; no build-setting). **Keep hardened runtime ON.** Keep `automation.apple-events` + `network.client`.
- Remove now-dead Sparkle sandbox shims (`-spks`/`-spki` mach-lookups; `SUEnableDownloaderService`/`InstallerLauncherService`) and **re-qualify the full Sparkle download→install→relaunch cycle** (the EdDSA key is load-bearing).
- Result = byte-for-byte **Open Island's proven posture** (hardened + unsandboxed + automation).
- **Do not** route through the XPC helper to stay sandboxed (a sandboxed app can't host the bridge socket, write `~/.claude`, or spawn `ps`/`osascript`). Keep the existing `BoringNotchXPCHelper` as-is for brightness/AX.
- **Prerequisite:** introduce a **stable local "NotchNerd Dev" signing identity** (mirror Open Island's `setup-dev-signing.sh`) so Automation/Accessibility TCC grants survive rebuilds instead of resetting on every cdhash change.

### 3c. Hook transport — proven socket+CLI first, modern http later
- **Ship Open Island's proven Unix-socket + embedded-CLI + 24h-block design first** — it's battle-tested, fail-open (if the app is down, Claude proceeds unchanged), and the permission round-trip is the flagship feature.
- The modern **`http` hook → in-app `127.0.0.1` listener** (no binary to ship/sign) is the better long-term architecture **if it validates** — but gate it behind a 1-day spike confirming v2.1.186 holds a blocking HTTP response for the full interactive `PermissionRequest` timeout, and the `allowedHttpHookUrls` allowlist behavior.
- Install **both** `PreToolUse` (works headless, gates before the prompt) and `PermissionRequest` (interactive allow/deny).
- ⚠️ Your `settings.json` has `defaultMode:"auto"` → many calls self-approve and never raise a `PermissionRequest`, so **`PreToolUse` is the more reliably-firing signal**; the approve/deny showcase is partly dependent on permission mode.

### 3d. Notepad — an independent key-capable panel, NOT a notch tab
- A `NotchViews` tab only renders when the notch is *open* and is mutually exclusive with home/shelf → it **cannot** "stay visible while you use the main notch." So the notepad is its **own window**.
- Build a `NotepadPanel` subclass: `.nonactivatingPanel` that overrides **`canBecomeKey = true`** (the existing notch panels hard-code `canBecomeKey=false` for click-through). This `.nonactivatingPanel + canBecomeKey` combo is the proven way to take **text focus** for a `TextEditor` **without** flipping the `.accessory` app to `.regular` or stealing the user's foreground app — this solves Option A's single hardest unproven problem.
- Own it via a `NotepadWindowController` singleton (model on `SettingsWindowController`), created in `applicationDidFinishLaunching`, positioned/reflowed on the existing screen-change paths. Visibility gated by its own `Defaults` key + a MenuBarExtra item + a global hotkey — **never** bound to `BoringViewModel.notchState`.
- Persist text to a file in Application Support (reachable now that we're unsandboxed), autosave on change.
- For float-over-fullscreen: optionally insert into `NotchSpaceManager.shared.notchSpace` (max-level CGS space) — **but validate key-focus inside that space as an isolated spike first**; fall back to a plain high-level floating panel (`level .mainMenu+2`) if focus breaks.

---

## 4. Phased roadmap (~16–26 person-weeks)

- **Phase 0 — De-risk preservation.** Flip sandbox off; stand up stable dev signing; confirm MediaRemoteAdapter keeps its entitlement after re-sign; full regression: now-playing, Sparkle, camera, calendar, CGS-notch-over-fullscreen.
- **Phase 1 — Vendor engine & clean mixed build.** Vendor Core+Hooks; slim Package.swift (tools 6.0); add local package + hooks tool target + Copy-to-Helpers; clean signed archive on Xcode 16.4.
- **Phase 2 — Native agent driver.** Write `@MainActor AgentBridgeManager` (starts `BridgeServer` headless, observes events, drives `SessionState.apply`); install hooks pointed at `Contents/Helpers/OpenIslandHooks`; port `ActiveAgentProcessDiscovery` (liveness) + `ClaudeTranscriptDiscovery` (restore); wire approve/deny.
- **Phase 3 — Notch agent UI.** Add the Agent tab (documented 9-step recipe); add a **persistent** closed-notch indicator (dedicated `@Published`, not the auto-expiring sneak-peek); rebuild Allow/Deny + question + session-list cards against boring.notch's notch (do **not** port `IslandPanelView`).
- **Phase 4 — Terminal jump-back (Ghostty-only).** Port just the Ghostty path from `TerminalJumpService` (`jumpToGhosttyTerminal` / `ghosttyJumpScript`, AppleScript window-ID match) + the `GHOSTTY_RESOURCES_DIR` hook-time enrichment. **Drop** Warp/iTerm/Terminal/VS Code/JetBrains/tmux paths from initial scope (big simplification — no fragile Warp SQLite). Build a TCC consent/onboarding flow for Automation.
- **Phase 5 — Always-open notepad (multi-note, over-fullscreen).** Key-capable `.nonactivatingPanel` + `NotepadWindowController` with a **notes list / tabs** UI and per-note file persistence; Defaults-gated + MenuBarExtra/hotkey toggle; multi-display. **Over-fullscreen float is in scope** → insert the panel into the notch CGS space; the **key-focus-inside-CGS-space spike is now load-bearing** (must validate that a text panel takes focus in the max-level space without stealing foreground; fallback = high-level floating panel in normal spaces if it breaks). *Validate text focus in isolation first.*
- **Phase 6 — Modernize & harden.** Install the **Claude usage HUD via wrapper-mode statusline** (preserve your existing `bash ~/.claude/statusline-command.sh`); spike http transport (adopt only if 24h hold validates); HookHealthCheck auto-repair + settings.json backup; fix inherited Open Island bugs (parallel-subagent pending-interaction overwrite; reconnect storms); test against live Claude Code + handle hook-schema drift (9→~30 events).

---

## 5. Key risks to manage
1. **MediaRemoteAdapter entitlement survival** after sandbox-off re-sign — silent failure mode on your #1 feature; gate it day one (lower risk than B/C: same project/identity, only the plist changes).
2. **TCC grant churn** on dev rebuilds — stable signing identity is a hard Phase-0 prerequisite.
3. **Notepad key-focus** in an `.accessory` app — validate in isolation before CGS-space integration.
4. **http-hook 24h hold** unvalidated — default to socket+CLI; spike before adopting.
5. **Sparkle re-qualification** after removing sandbox XPC shims — EdDSA key is unforgiving.
6. **Hook-schema drift** is a standing tax (9→~30 events; `StopFailure` split from `Stop`).
7. **`defaultMode:"auto"`** can leave the approve/deny showcase dormant — `PreToolUse` gating is the steadier signal.
8. **Inherited Open Island bugs** — port the fixes, don't inherit them.

---

## 6. Locked decisions (2026-06-25)
1. **Terminal jump scope → Ghostty only.** Smallest, robust surface; no Warp SQLite fragility.
2. **Notepad richness → multiple notes / tabs.** Notes list + per-note persistence.
3. **Notepad float → above fullscreen too.** Joins the CGS space → the key-focus-in-CGS-space spike is load-bearing in Phase 5.
4. **Usage HUD → yes, wrapper mode.** Preserve the existing custom statusline.
5. **Transport → socket+CLI first, spike http later.** *(My call; not gambling the flagship feature.)*
6. **Vendoring → Core whole** (clean upstream re-pull). *(My call.)*
7. **XPC helper → keep `BoringNotchXPCHelper` as-is.** *(My call.)*
8. **Namespace the bridge socket + hooks identity (NEW — from the Phase-2 spike).** NotchNerd must NOT use Open Island's default shared socket (`~/Library/Application Support/OpenIsland/bridge.sock`) — `BridgeServer.start()` deletes any existing socket before binding, so it would clobber a running Open Island and steal its hook connections. Use a NotchNerd-specific socket path, pass it as `BridgeServer(socketURL:)`, bake `OPEN_ISLAND_SOCKET_PATH=<that path>` into the installed hook command, and give the managed-hooks group + `ManagedHooksBinary` copy location a NotchNerd identity so the two apps coexist in the same `~/.claude/settings.json`. *(My call; finalize before wiring the notch UI.)*

## 7. Spike outcomes (2026-06-25)

### Phase-2 driver design — ✅ done (`spikes/phase2-driver/`)
- `DESIGN.md` — full `AgentBridgeManager` design (boring.notch-native `@MainActor ObservableObject` singleton), with the **exact** OpenIslandCore public surface it consumes verified `file:line`, the event→UI / hook-install / approve-deny flows, startup discovery + liveness, fail-open, instantiation points, and the Agent-tab/closed-notch binding.
- `AgentBridgeManager.swift` — compile-intent-correct skeleton.
- `OPEN-QUESTIONS.md` — risks + a **cheapest-disproof-first validation order** for Phase 2: (1) vendor + compile, (2) headless bridge smoke (no UI), (3) hook install on a throwaway `CLAUDE_CONFIG_DIR`, (4) live `PermissionRequest` approve/deny in **`default`** mode (not `auto`), (5) liveness + crash recovery, (6) coexistence with real Open Island (locks the socket namespacing), (7) notch UI bind.
- **Confirmed mechanics:** `LocalBridgeClient.connect()` does NOT auto-register → must `send(.registerClient(role:.observer))`; the installer **copies** the embedded `Contents/Helpers/OpenIslandHooks` to `~/Library/Application Support/OpenIsland/bin/` and points `settings.json` at the copy; `ActiveAgentProcessDiscovery` lives in the App target (not Core) and must be vendored/adapted; the installed event set already covers the v2.1.186 `StopFailure`/`PostToolUseFailure`/`PermissionDenied` splits.
- **Bugs to FIX (not inherit):** pending-interaction map keyed by `sessionID` only (parallel same-session permissions overwrite — key by `sessionID+toolUseID`); reconnect storms (one long-lived backoff task + `connectionGeneration` guard).

### Notepad focus-spike — ✅ done (`spikes/notepad-focus/`)
- `DESIGN.md` + production-intent code (`NotepadPanel.swift`, `NotepadWindowController.swift`, `NotesStore.swift` multi-note split body/index + debounced autosave, `NotepadView.swift`).
- **Runnable harness** (`harness/main.swift` + `README.md`) — a single-file AppKit program (no Xcode needed): `cd spikes/notepad-focus/harness && swiftc -O main.swift -o harness && ./harness` (append `B` for CGS-space mode). It builds clean (`swiftc` exit 0) and replicates the real `CGSSpace.swift` `@_silgen_name` symbols 1:1, with a live status line (frontmost app / `ourApp.isActive` / `notepad.isKey`) and a PASS/FAIL → GO/NO-GO checklist.
- **Key rule confirmed:** the controller must NEVER call `NSApp.activate`/`.regular` (unlike `SettingsWindowController`); `.nonactivatingPanel` + `canBecomeKey=true` is the focus mechanism.
- **Prediction: GO at ~65–70%.** Not stealing foreground is low-risk (AppKit activation severance is independent of CGS reparenting). The one real risk is the macOS "key window must be in the active space" rule biting the reparented window (no caret / dropped keys) in CGS mode — exactly why the harness exists. Fallback (plain high-level floating panel, normal spaces) is a one-line `Defaults` switch. **You run the harness to get the verdict.**
