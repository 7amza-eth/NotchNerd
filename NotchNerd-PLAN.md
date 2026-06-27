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

- **Phase 0 — De-risk preservation.** Flip sandbox off; stand up stable dev signing; confirm MediaRemoteAdapter keeps its entitlement after re-sign; full regression: now-playing, Sparkle, camera, calendar, CGS-notch-over-fullscreen. *Also assert managed hooks fire for a native-installer `claude` (`~/.local/bin/claude`) and an IDE-launched `claude` — proves "Claude Code via the desktop app" is already covered (same `~/.claude` hooks).*
- **Phase 1 — Vendor engine & clean mixed build.** Vendor Core+Hooks; slim Package.swift (tools 6.0); add local package + hooks tool target + Copy-to-Helpers; clean signed archive on Xcode 16.4.
- **Phase 2 — Native agent driver.** Write `@MainActor AgentBridgeManager` (starts `BridgeServer` headless, observes events, drives `SessionState.apply`); install hooks pointed at `Contents/Helpers/OpenIslandHooks`; port `ActiveAgentProcessDiscovery` (liveness) + `ClaudeTranscriptDiscovery` (restore); wire approve/deny.
- **Phase 3 — Notch agent UI.** Add the Agent tab (documented 9-step recipe); add a **persistent** closed-notch indicator (dedicated `@Published`, not the auto-expiring sneak-peek); rebuild Allow/Deny + question + session-list cards against boring.notch's notch (do **not** port `IslandPanelView`).
- **Phase 4 — Terminal jump-back (Ghostty-only).** Port just the Ghostty path from `TerminalJumpService` (`jumpToGhosttyTerminal` / `ghosttyJumpScript`, AppleScript window-ID match) + the `GHOSTTY_RESOURCES_DIR` hook-time enrichment. **Drop** Warp/iTerm/Terminal/VS Code/JetBrains/tmux paths from initial scope (big simplification — no fragile Warp SQLite). Build a TCC consent/onboarding flow for Automation. *Optionally read `~/.claude/ide/*.lock` (`workspaceFolders`/`ideName`) so an IDE-launched session jumps to the IDE's embedded terminal.*
- **Phase 5 — Always-open notepad (multi-note, over-fullscreen).** Key-capable `.nonactivatingPanel` + `NotepadWindowController` with a **notes list / tabs** UI and per-note file persistence; Defaults-gated + MenuBarExtra/hotkey toggle; multi-display. **Over-fullscreen float is in scope** → insert the panel into the notch CGS space; the **key-focus-inside-CGS-space spike is now load-bearing** (must validate that a text panel takes focus in the max-level space without stealing foreground; fallback = high-level floating panel in normal spaces if it breaks). *Validate text focus in isolation first.*
- **Phase 5.5 — Loose-thread audit & fixes (interim).** Hunt for and fix regressions introduced by the sandbox-drop, the rename, and the engine vendoring — the class exemplified by the **HUD/Accessibility bug** (a privileged op routed through the XPC helper / wrong process under the now-unsandboxed app). Sweep: all permission/TCC flows (does the grant target the process that does the privileged op?), remaining XPC-helper indirection that should now be in-app, renamed `Defaults` keys that silently drop stored settings, hardcoded old identity/paths/resources, user-facing residual "Open Island"/old-brand strings, and whether the inherited Open Island bugs (pending-interaction overwrite, reconnect storms) were actually fixed in the driver. Method: parallel finders → **adversarial verification** (fix real bugs, not false positives) → fix the confirmed ones, build-verified.
- **Phase 6 — Modernize & harden.** Install the **Claude usage HUD via wrapper-mode statusline** (preserve your existing `bash ~/.claude/statusline-command.sh`); spike http transport (adopt only if 24h hold validates); HookHealthCheck auto-repair + settings.json backup; fix inherited Open Island bugs (parallel-subagent pending-interaction overwrite; reconnect storms); test against live Claude Code + handle hook-schema drift (9→~30 events).
- **Phase 7 — Cowork (beta), optional.** Read-only live-status watcher for Claude **Cowork / "local agent mode"** (its agent runs on-device in an Apple-VZ + gVisor Linux microVM). Reuse the Phase-2 `ClaudeTranscriptDiscovery` design as a **second watcher root**: `~/Library/Application Support/Claude/local-agent-mode-sessions/<acct>/<org>/` — parse `local_<uuid>.json` (title/model/permissionMode/cwd/lastActivityAt/spaceId) for a session chip and tail the HMAC-signed `audit.jsonl` (stream-json — **read-only, never write**) for turn activity. Surface a "Cowork (beta)" session chip + activate-app jump, behind a Defaults flag with a schema-version/format-drift guard. **No approve/deny, no per-session jump** (the gate runs in the desktop app's host loop; one shared window). Read only session metadata/transcripts — never the `.audit-key`/token/MCP-secret files in those dirs.

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

> **Note (2026-06-27):** the `spikes/` prototype directories referenced below were **removed** once
> both spikes were validated and shipped (Phase 2 / Phase 5). They're recoverable in git history;
> the only still-relevant deferred detail (the Phase-6 pending-interaction fix recipe) was preserved
> in [`tooling/docs/deferred-work-notes.md`](./tooling/docs/deferred-work-notes.md). The `spikes/…`
> paths in this dated section are kept as a historical record.

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
- **VERDICT: GO — validated on-device (2026-06-26).** In Mode B (max-level CGS space) the key-capable `.nonactivatingPanel` took text focus (caret blinked, keys landed) while the user's other app stayed frontmost (`ourApp.isActive` stayed `no` — no activation leak), AND it floated above a native-fullscreen app. **Phase 5 ships the CGS-space float; the plain-floating fallback is not needed.**

## 8. Claude Desktop surfaces — feasibility outcome (2026-06-25)

Reviewed whether NotchNerd's monitoring can extend to the Claude **Desktop app** (chat / Cowork / Claude-Code-in-desktop). Grounded in inspection of this machine (`/Applications/Claude.app` v1.15962.0; native `~/.local/bin/claude`; 12+ Cowork sessions Feb–Jun 2026).

| Surface | Monitorable | Achievable features | Effort | Verdict |
|---|---|---|---|---|
| **Claude Code via desktop** (native installer + IDE-launched) | Full | status + **approve/deny** + jump | ~0 wk | **Already covered** — same `~/.claude` hooks. Verify in Phase 0. |
| **Claude Cowork** (local agent mode) | Partial | **live status** + activate-app jump | 2–4 wk | **Yes → new Phase 7 (beta)**. |
| **Claude Desktop chat app** | Partial | jump-to-window only | — | **Skip** beyond a free activate-window button. |
| **MCP-as-monitor** | No | none | — | **Drop** — protocol can't see the session or the prompt. |

**Why approve/deny is CLI-only (the one hard limit):** NotchNerd's signature approve/deny works by holding the hook *subprocess* blocked and writing a directive to its stdout. Desktop/Cowork permission gates run in the cloud (chat) or the desktop app's host-loop + React UI (Cowork) — **there is no host-side hook process to block**. The only way to resolve a desktop prompt is brittle Accessibility clicking (not recommended). So **live status + jump are the realistic desktop ceiling; approve/deny stays a Claude-Code-CLI exclusive.**

**Dropped from scope:** chat-app heuristic status / AX automation, and any MCP-based monitor (it only ever sees calls to its *own* tools, never the session or the permission prompt). The embedded Cowork Claude-Code path can't be hooked either (its `CLAUDE_CONFIG_DIR` is redirected to a per-session isolated `.claude` with `hooks:null`, and tools run inside the VM) — it routes to the Phase-7 read-only watcher instead.

## 9. Rebrand / identity (2026-06-26) — deconflict from the user's daily boring.notch

To stop NotchNerd colliding with the user's installed boring.notch (shared prefs/TCC/auto-update), the app was given a distinct identity:
- **Name:** NotchNerd. **App bundle id:** `eth.7amza.notchnerd`. **XPC helper bundle id:** `eth.7amza.notchnerd.XPCHelper` (+ the hardcoded `serviceName` in `XPCHelperClient.swift` and the protocol doc comment updated to match).
- **Sparkle disabled:** removed `SUFeedURL`/`SUPublicEDKey`, set `SUEnableAutomaticChecks=false` — so it can NEVER auto-update into boring.notch's appcast. (Re-add our own appcast later if we ship updates.)
- **Display name** `TheBoringNotch` → `NotchNerd`; high-visibility labels fixed (menu "Restart NotchNerd", "NotchNerd Settings" window title, onboarding "NotchNerd" heading).
- **Icon + accent:** new app icon (violet "notched screen wearing nerd glasses" on a dark squircle) generated into `AppIcon.appiconset`; accent color → violet (`#7C5CFF`, sRGB 0.486/0.361/1.0).
- **Deferred (the "full branding" pass):** descriptive onboarding copy + the ~34 `Localizable.xcstrings` brand strings + internal symbol names (`BoringNotch*` types — harmless, left as-is). Build target/scheme names also left as `boringNotch` (renaming the Xcode target is risky and invisible to users).
- **Note for Phase 2:** the bridge socket + managed-hooks identity must key off this new bundle id (locked decision #8).

## 10. Implementation progress (2026-06-26, on Xcode 26.6)

- ✅ **Fork set up** — repo root, branch `main`, `origin` = github.com/7amza-eth/NotchNerd, `upstream` = boring.notch (full history). Inherited boring.notch CI removed.
- ✅ **Phase 0 — sandbox dropped & verified.** Builds unsandboxed (0 errors); `app-sandbox=false` in the signed binary; MediaRemoteAdapter `test` passes after re-sign (music survives); app launches clean. *(Visual UI confirmation pending — assistant shell lacks Screen Recording.)*
- ✅ **Rebrand** — `eth.7amza.notchnerd`, name NotchNerd, Sparkle off, violet icon + accent. Distinct from boring.notch.
- ✅ **Notepad focus-spike — GO** (validated on-device). Phase 5 ships the CGS-space float.
- ✅ **Phase 1 (step 1) — engine vendored & compiles.** `Vendor/OpenIslandEngine/` (Core whole + hook CLI), slim `Package.swift` (tools 6.0); `swift build` ✅; hook CLI fail-opens ✅.
- ⏭️ **Phase 1 (step 2) — xcodeproj integration** (next): add the local package via `XCLocalSwiftPackageReference`, link `OpenIslandCore` into the app, add a native command-line-tool target compiling `OpenIslandHooksCLI` + a Copy-Files phase embedding it into `Contents/Helpers` (clone the Embed-XPC-Services phase). Spike advises the Xcode UI for this.
- ⏭️ **Phase 2** — `AgentBridgeManager` driver (design ready in `spikes/phase2-driver/`), namespaced socket per decision #8.

## 11. BUILD STATUS — feature-complete (2026-06-26, Xcode 26.6)

All phases implemented, build-verified (`xcodebuild ... BUILD SUCCEEDED`, 0 errors), committed, pushed.

- ✅ **Phase 0** sandbox dropped; music/MediaRemote verified intact after re-sign.
- ✅ **Phase 1** vendored `OpenIslandCore` + hook CLI; linked into the app via local SPM package; hook CLI embedded in `Contents/Helpers`. Headless engine round-trip smoke test PASSED.
- ✅ **Phase 2** `AgentBridgeManager` driver (headless `BridgeServer` + observer + `SessionState`, hook install, approve/deny round-trip, transcript + process-liveness discovery), wired in AppDelegate (gated by `agentEnabled`, default off).
- ✅ **Phase 3** Agent tab + session panel (Allow/Deny + question cards), settings pane, persistent closed-notch attention indicator.
- ✅ **Phase 5** always-open multi-note notepad — key-capable `.nonactivatingPanel` in the CGS space (focus GO validated on-device), MenuBarExtra toggle, file-backed autosave.
- ✅ **Phase 4** Ghostty terminal jump-back.
- ✅ **Comprehensive rename → NotchNerd**: product `NotchNerd.app`, targets, `NotchNerd.xcodeproj`, source folders, every file name, all code symbols, UI copy + localization, display name, icon, and `Defaults` keys. Upstream attribution (boring.notch links, TheBoredTeam credit + logo) preserved per GPL.

**The agent feature ships OFF by default** — enable in Settings → Agent, then Install hooks.

**Remaining (not blockers):** runtime/visual QA on a real machine (notch draws, now-playing renders, agent approve/deny end-to-end against live Claude Code, notepad focus in daily use, TCC consent flows); the optional Phase 6 (http-hook spike, usage-HUD wrapper statusline) and Phase 7 (Cowork beta watcher).

## 12. Phase 5.5 — Loose-thread audit & fixes (2026-06-27) ✅

Method as planned: 6 parallel finders (one per §5 sweep dimension) → adversarial verification of every finding → fix the confirmed ones, build-verified. 13 raw findings → **8 confirmed (6 distinct bugs after dedup), 5 rejected** as false positives (GPL-attribution GitHub links; the already-correct reconnect-storm guard; intentional optimistic-UI behavior).

**Fixed (all fork-introduced regressions; `BUILD SUCCEEDED`, 0 errors/warnings):**
1. **Wrong-process Accessibility checks — the c53ccfe class, three more sites.** c53ccfe fixed only the HUD toggle's publisher path + Request button; the audit found the launch gate, the Settings HUD read/monitor, and onboarding still routed AX through the XPC helper (a different bundle id that is never granted), so the HUD silently self-disabled each launch / the toggle stayed stuck-disabled / onboarding authorized the wrong binary. Now all in-app:
   - `NotchNerdViewCoordinator.swift` launch gate → `MediaKeyInterceptor.isAccessibilityTrusted`.
   - `OnboardingView.swift` → `MediaKeyInterceptor.ensureAccessibilityAuthorization`.
   - `SettingsView.swift` HUD page read + monitor → new in-app `MediaKeyInterceptor.start/stopAccessibilityMonitoring` (polls the app's own trust, posts the same `.accessibilityAuthorizationChanged`); terminate-time stop in `AppDelegate` repointed. Removed a dead wrong-process AX call in the Battery view. **All XPC Accessibility calls are now gone from app code** (the helper still vends brightness — intentional, decision #7).
2. **Residual brand leak.** The vendored reducer hardcodes `"Permission denied in Open Island."` (ignores our directive message). Kept `Vendor/` pristine; rewrote the brand at the projection boundary (`AgentBridgeManager.republish` → `debranded`).
3. **Half-renamed icon id.** `TipStore` looked up `AppIcon(for: "theboringteam.NotchNerd")` (not the real id `eth.7amza.notchnerd`) → generic blank icon; now `AppIcon(for: bundleIdentifier)`. (Latent — TipsView is currently unwired.)

**Verified-and-deferred (not a fork regression):**
- **Inherited bug (a) — pending-interaction overwrite.** Confirmed still present: `BridgeServer.pendingClaudeInteractions` is keyed by `sessionID` only (the `PendingClaudeInteraction.toolUseID` field exists but is unused as a key), and `BridgeCommand.resolvePermission` carries only `sessionID` — so parallel same-session permission prompts overwrite, and the bug is **structurally unfixable from the driver** without patching the frozen `Vendor/` engine + command protocol. Stays in **Phase 6** ("fix inherited Open Island bugs"), as already planned.
- **Inherited bug (b) — reconnect storms:** verified **correctly fixed** in the driver (single `reconnectTask` guard + `connectionGeneration`).

## 13. Open Island feature port — batch 1 (2026-06-27) ✅

After an exhaustive feature review of Open Island (`OpenIslandApp` vs the vendored `OpenIslandCore` — see method below), four high-value features + a Ghostty hardening pass were ported into the agent monitor. All build-verified (`BUILD SUCCEEDED`), then adversarially reviewed (4 reviewers → verify; 4 findings fixed). **The vendored engine already carried all the data/logic; the work was NotchNerd-native SwiftUI + driver wiring on top.** New files live in `NotchNerd/Agent/`; added to the (non-synchronized) app target via `tooling/scripts/add_agent_files.rb`.

**Shipped:**
1. **In-notch notification mode** — agent events auto-pop the notch to the Agent tab. Pipeline: `AgentEvent → AgentBridgeManager.emitNotification → notificationPublisher → NotchNerdViewCoordinator.presentAgentNotification → (NotificationCenter) → ContentView opens the notch`. Permission/question pops persist until resolved; completion notices auto-collapse after 10s (deferred while hovered). **Deliberately never hijacks an already-open notch** (opens only from `notchState == .closed`) and suppresses when the session's terminal is frontmost. Off-switch + sub-toggles in Settings → Agent → Notifications. Keys: `agentNotificationsEnabled` / `agentAutoOpenNotch` / `agentNotifyOnCompletion` / `agentSuppressWhenFrontmost`.
2. **Notification sounds** — `AgentNotificationSound` plays a `/System/Library/Sounds` system sound at the notification moment (single trigger in `presentAgentNotification`, no double-ring). Picker + mute in Settings. Keys: `agentSoundEnabled` / `agentSoundName` (default "Submarine") / `agentSoundMuted`.
3. **Expanded session panel** — richer Agent tab: an overview counts row (total/waiting/running/done/idle), pulsing per-phase status dots, age badges, the spotlight activity/prompt lines, and **expandable rows showing live subagents + task/todo checklists** (from `ClaudeSessionMetadata.activeSubagents`/`activeTasks`). `AgentSessionPresentation.swift` is a near-verbatim copy of OI's `AgentSession+Presentation.swift` (GPL, pure Core deps).
4. **Usage HUD** — `AgentUsageManager` installs the vendored statusline shim via `installAsWrapper()` (preserving any existing statusline), polls `ClaudeUsageLoader` (`/tmp/open-island-rl.json`), and renders 5h/7d quota chips in the Agent tab header. Verified: Claude Code 2.1.195's statusline payload carries `rate_limits.{five_hour,seven_day}.{used_percentage,resets_at}` (Pro/Max only, post-first-response). Off by default. Key: `agentUsageEnabled`. **Namespacing of the cache path/script is deferred** (reuses OI's, same posture as the bridge socket).
5. **Ghostty jump hardening (only)** — `jumpResolving`: already-focused short-circuit (no flicker), pre-jump live re-resolution recovering a stale/nil `terminalSessionID` from cwd→title, cwd path normalization, and a bounded/concurrently-drained `osascript` runner. No new terminals.

**To-do (remainder of the OI review, deferred):**
- **More terminals (rest of review item #5):** Terminal.app, iTerm2, tmux are *small* ports of OI's `TerminalJumpService` paths; WezTerm/Kaku/Zellij/cmux small-medium; **Warp** medium-large (needs `KeystrokeInjector` AX + Automation TCC). VS Code / JetBrains workspace-activation jumps are trivial. *Not started.*
- **More agents (review item #6):** Codex, OpenCode, Gemini, Kimi, Cursor, and the Claude-forks (Qoder/Qwen/Factory/CodeBuddy) — all hook payload models + installers are already vendored in `OpenIslandCore`; each is a *small* wiring + install-toggle job. `ActiveAgentProcessDiscovery` already detects 5 of them. Codex's live app-server path is medium. *Not started.*
- **Phase 6 carryovers (unchanged):** socket + statusline-cache namespacing off `eth.7amza.notchnerd` (locked decision #8); the inherited pending-interaction overwrite (§12 — needs a Vendor patch); the http-hook transport spike; HookHealthCheck auto-repair UI.
- **Not present in Open Island (net-new, decide separately):** real macOS Notification Center banners (OI uses only the in-notch pop + sound), a session interrupt/stop button, a transcript viewer, copy-summary, IDE terminal-focus extensions, and the Watch/iPhone relay (engine is in Core, UI is not).

**Method note:** the OI feature review fanned out 4 read-only explorers over `sources/open-vibe-island/` mapping every feature to *Core (already linked, needs wiring)* vs *App (needs reimplementation)* vs *net-new*. The port itself was driven by a 5-agent file-grounded implementation blueprint. Both are archived in the session transcript.
