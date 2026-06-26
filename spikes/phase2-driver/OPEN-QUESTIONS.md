# Phase-2 Driver — Open Questions, Risks, Validation Order

*Companion to DESIGN.md / AgentBridgeManager.swift. Everything here is a real unknown found while reading the source — not hypotheticals.*

---

## A. Hard risks (could sink the feature)

1. **Single-socket contention with a *running* Open Island.** `BridgeServer.start()` binds the **shared** path `~/Library/Application Support/OpenIsland/bridge.sock` **and** the legacy `/tmp/open-island-<uid>.sock` (`BridgeServer.swift:101-111`), and `bindListener` first `removeItem`s any existing socket (`:117`). If the user *also* runs the real Open Island (or "Open Island Dev.app"), the two servers fight over the same path and steal each other's hook connections — and the hook CLI resolves the socket via the shared `currentURL()`, so it'll connect to whichever bound last. **Decide:** namespace NotchNerd's socket (set `OPEN_ISLAND_SOCKET_PATH` for our installed hooks + pass a custom `socketURL:` to `BridgeServer`), or detect/coexist. Leaning: ship a NotchNerd-specific socket + matching `--source`/env in the installed hook command so the two apps never collide.

2. **`defaultMode:"auto"` keeps the approve/deny showcase dormant.** This machine's `~/.claude/settings.json` is `auto` (`_hooks_research.md §1`), which self-approves most calls so `PermissionRequest` rarely fires, and `PermissionRequest` never fires under `-p` at all (`§8`). The flagship Allow/Deny round-trip may look "broken" simply because Claude isn't asking. **Validate** against a `default`/`plan` permission-mode session before judging the round-trip. Surface `PreToolUse` activity as the steady signal regardless.

3. **Unsandboxed posture is a hard prerequisite.** `ActiveAgentProcessDiscovery` shells out to `/bin/ps` + `/usr/sbin/lsof` (`ActiveAgentProcessDiscovery.swift:194,481`), `BridgeServer` hosts a Unix domain socket under Application Support, and the installer writes `~/.claude/settings.json`. None of this works while `com.apple.security.app-sandbox = true`. Phase 0 (sandbox-off + stable signing) must land first, or the entire driver no-ops silently.

4. **Toolchain mode mismatch.** Upstream `Package.swift` is `swift-tools-version:6.2`; boring.notch CI is pinned to Xcode 16.4 / Swift 6.0 (`NotchNerd-PLAN.md §3a`). The vendored manifest must be hand-written as `6.0 + .swiftLanguageMode(.v6)`. Core uses no 6.2-only syntax (verified: plain Foundation/Darwin/Dispatch), but `BridgeServer.swift` uses `@unchecked Sendable`, `AsyncThrowingStream`, typed `throws`-free async — confirm these compile clean under 6.0 strict-concurrency *as a library* without forcing the app to `SWIFT_STRICT_CONCURRENCY=complete`.

---

## B. Engine-behavior unknowns (verify by experiment)

5. **Does the app need to push `updateStateSnapshot` for correctness, or only as an optimization?** `BridgeServer.emit()` maintains its own `localState` (`:2564-2567`) and `ensureClaudeSessionExists` self-heals missing sessions, so hook-driven sessions converge without snapshots. But `requestQuestion` silently drops if `hasSession` is false (`:313-317`) and notification-phase logic reads `localState.session(id:)` (`:851`). We push snapshots anyway (driver `state.didSet`), but confirm there's no ordering hazard where a restored-but-not-yet-snapshotted session makes the server reject an early event.

6. **Claude liveness matching is weak.** `ActiveAgentProcessDiscovery.claudeSnapshot` derives `sessionID` from an open transcript path via `lsof` or from `--resume/--session-id` flags (`:289-293, :521`). A plain `claude` invocation with no resume flag and a not-yet-opened transcript yields **no sessionID**, so `markProcessLiveness` can't match it and may prematurely age it out after 2 polls. Since these are `isHookManaged`, they're primarily governed by hook lifecycle (`SessionState.swift:378-406`) — confirm the backstop doesn't fight the hooks and kill live sessions during quiet periods.

7. **Transcript-path layout drift.** `_hooks_research.md §9` notes v2.1.186 shows `<enc>/<uuid>.jsonl`, flat `<enc>.jsonl`, *and* nested `<enc>/<uuid>/` layouts. `ClaudeTranscriptDiscovery` enumerates recursively for `*.jsonl` excluding `/subagents/` (`:44-48`), so it should catch all three, but confirm it doesn't double-count a session that appears in two layouts.

8. **`pendingClaudeInteractions` keyed by sessionID only** (`BridgeServer.swift:731,757`) — the parallel-permission overwrite bug (DESIGN §10.1). Need a repro: can a single Claude session legitimately raise two simultaneous `PermissionRequest`s today? If not, the fix is pre-emptive hardening; if yes (parallel tool batches), it's load-bearing. Tied to the `PostToolBatch` event family in `_hooks_research.md §2`.

---

## C. Host-integration unknowns

9. **Where does the Agent panel get its width/height?** The map digest flags that open-notch geometry is computed in `BoringViewModel`/`sizing/`, and a wide agent transcript may overflow (`_map_digest.md` open questions). Card layout must fit `openNotchSize` (640×190) or trigger a sizing path not covered by the tab recipe.

10. **`ClaudeConfigDirectory` reads `UserDefaults.standard` key `"claude.configDirectory"`** (`ClaudeConfigDirectory.swift:7-12`), which is a *different* store from sindresorhus/Defaults. Our `Defaults[.agentClaudeConfigDir]` override is bridged by passing `claudeDirectory:` explicitly to the manager init (done in the skeleton), so the two never need to agree — but if any *other* vendored code calls `ClaudeConfigDirectory.resolved()` directly, it won't see our Defaults value. Audit for stray callers.

11. **Closed-notch indicator render branch.** STEP 9's caveat (`_map_digest.md:65`) says add a dedicated `@Published` rather than reuse the auto-expiring `expandingView`. We expose `attentionCount`, but the actual render branch in `ContentView.NotchLayout()` (`:287-301`) and its interaction with the existing music live-activity (mutual exclusion? stacking?) is unverified.

12. **MenuBarExtra / hotkey toggle for the panel** isn't in scope here but the `agentEnabled` master switch needs a settings UI; confirm the `SettingsView` string-tag wiring (sidebar + detail switch, two places — `_map_digest.md` Risks) is done or the pane silently falls through to General.

---

## D. Recommended validation order (cheapest disproof first)

1. **Vendor + compile (1 day).** Copy Core + `ActiveAgentProcessDiscovery`, hand-write the slim `Package.swift` (tools 6.0), get `import OpenIslandCore` resolving and `AgentBridgeManager.swift` compiling. Disproves the toolchain/Sendable risk (#4) before any runtime work.

2. **Headless bridge smoke, no UI (½ day).** Instantiate `AgentBridgeManager.shared`, `start()`, and from a terminal pipe a synthetic `SessionStart` + `PreToolUse` JSON into the embedded `OpenIslandHooks --source claude`. Assert `sessions`/`runningCount` update. Disproves the in-process server + observer + socket-resolution chain (#1, #5) without touching the notch.

3. **Hook install round-trip on a throwaway `CLAUDE_CONFIG_DIR` (½ day).** Point `Defaults[.agentClaudeConfigDir]` at a temp dir, `installHooks()`, diff the written `settings.json` against `ClaudeHookInstaller.eventSpecs`, confirm the backup file and the managed-copy at `~/Library/Application Support/OpenIsland/bin/`. Disproves install-path + backup safety (#10) with zero risk to the real `~/.claude`.

4. **Live `PermissionRequest` approve/deny (1 day).** Run real Claude Code in **`default` permission mode** (not `auto`!) against a project, trigger a Bash permission, approve from a minimal debug button bound to `resolve(...)`, confirm the blocked hook unblocks and Claude proceeds. This is the flagship — and #2 is why mode matters.

5. **Liveness + crash recovery (½ day).** Start a Claude session, `kill -9` the bridge mid-turn (or quit/relaunch the app), confirm restore-from-registry repopulates and the liveness backstop ages out the dead session within ~6 s. Disproves #6.

6. **Coexistence with real Open Island (½ day).** Run both apps; observe socket contention (#1). This決定s the socket-namespacing decision — do it before wiring the notch UI so the transport contract is final.

7. **Notch UI bind (Phase 3).** Only after 1-6 are green: Agent tab + persistent closed-notch indicator (#9, #11, #12).
