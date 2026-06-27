# Deferred-work implementation notes

> **What this is.** Implementation-load-bearing *reference detail* for NotchNerd work that is
> **planned but not yet built** — extracted and consolidated from earlier spike/research docs that
> were otherwise superseded and removed (the Phase-2 driver spike, the notepad-focus spike, and the
> desktop-surfaces feasibility research). **Decisions and status live in [`NotchNerd-PLAN.md`](../../NotchNerd-PLAN.md)**
> (§12 inherited bugs, §13 the OI-feature-port To-do, Phase 6/7); this file holds only the concrete
> file formats / fix recipes an implementer would otherwise have to re-derive. Keep it pruned: when a
> section ships, fold the durable facts into `spec.md` and delete the section here.

---

## 1. Phase 6 — fix the inherited "pending-interaction overwrite" bug

**Status (PLAN §12):** still present; lives in the **frozen** vendored engine + the resolve command
protocol, so it is *not* fixable from the driver alone — it needs a small, documented `Vendor/` patch.

**Diagnosis.** `BridgeServer.pendingClaudeInteractions` is keyed by `sessionID` **only**
(`BridgeServer.swift:731,757`), and `bindListener`-side resolution removes by `sessionID`
(`:1806,2406,2473`). The `PendingClaudeInteraction` struct already carries a `toolUseID` field but it
is unused as a key. So two *simultaneous* `PermissionRequest`s in the **same** session (parallel tool
batches) overwrite each other → the first blocked hook never gets its directive and hangs to timeout.
Subagent hooks are already suppressed, so this is specifically the same-session concurrency case.

**Fix recipe (requires patching the pristine vendored engine — document the patch in `VENDORED-FROM.md`):**
1. Key `pendingClaudeInteractions` by a composite **`sessionID + toolUseID`** (the hook payload already
   carries `toolUseID`, surfaced via `claudeToolUseID(for:)` in `BridgeServer`). Apply the same to
   `pendingApprovals` and `pendingClaudeToolContexts` (`permissionCorrelationKey`).
2. Extend `BridgeCommand.resolvePermission` (and `AgentBridgeManager.resolve` / the engine's
   `resolvePendingClaudeInteraction`) to carry the `toolUseID` so the UI resolves the **exact** request,
   not "whichever is pending for this session."
3. NotchNerd's `AgentSession.permissionRequest` would need to expose the `toolUseID` to the card so the
   Allow/Deny round-trip can pass it back.

**Repro to confirm impact before patching:** in `default`/`plan` permission mode, get a single Claude
session to raise two concurrent `PermissionRequest`s (parallel tool batch). If that can't happen in
the current CLI, the fix is pre-emptive hardening; if it can, it's load-bearing.

---

## 2. Phase 6 — http hook transport + a real-time "Claude is working" signal

**Status:** transport is the unbuilt Phase-6 spike (locked decision #5: ship socket+CLI first, spike
http later). The "working" signal below is a *current heuristic* that the http transport would make exact.

**The transport (decision #5 / PLAN §4 Phase 6):** replace (or augment) the embedded Unix-socket +
`OpenIslandHooks` CLI with the modern **`http` hook → in-app `127.0.0.1` listener** (no binary to
ship/sign). Gate adoption behind a spike that confirms Claude Code holds a *blocking* HTTP response
for the full interactive `PermissionRequest` timeout, and the `allowedHttpHookUrls` allowlist
behavior. Keep socket+CLI as the default until that validates.

**The real-time activity signal (concrete use case — the closed-notch "Claude working" indicator):**
- **Why it's only a heuristic today.** The classic hooks fire at **turn boundaries** only
  (`UserPromptSubmit`/`PreToolUse` → a session is `.running`; `Stop` → `.completed`). There is no
  "Claude is generating *right now*" event, and if a `Stop` hook doesn't fire the session lingers in
  `.running`. So NotchNerd infers "working" with `AgentBridgeManager.workingCount` =
  `phase == .running && isProcessAlive && now − updatedAt < 60s` (the recency guard filters
  stuck/idle sessions). The 3s liveness backstop republishes while any session is `.running` so the
  time-based count updates. Consumed by the closed-notch visualizer-slot ✦ and the standalone
  "N working" pill (`ContentView.MusicLiveActivity` + the closed-notch branch).
- **Its failure modes** (what the heuristic can't fix): a stuck `.running` session still reads as
  working for up to ~60s; a long *silent* operation (>60s with no tool events — a slow single tool or
  long text-only generation) falsely reads as not-working.
- **What the http transport / newer hooks would give.** A persistent in-app connection (or the newer
  Claude Code hook events — the set grew ~9 → ~30, e.g. `Notification`, `SubagentStart/Stop`, the
  `Stop`/`StopFailure` split) can deliver a precise start/stop-generating signal, so the indicator
  becomes exact: no recency window, no stuck-session false positives, instant off on turn end.
  **When building this, replace `workingCount`'s recency heuristic with the real signal and drop the
  liveness-tick republish hack.** Audit the current Claude Code hook schema for a finer-grained
  activity/heartbeat event before assuming http is required — a newer classic hook may suffice.

---

## 3. Phase 7 — Cowork ("local agent mode") read-only watcher

**Status (PLAN §11 / Phase 7):** optional beta, unbuilt. Read-only **live status + activate-app jump
only** — no approve/deny (the gate runs in the desktop app's host loop; there is no host-side hook
process to block). Reuse the Phase-2 `ClaudeTranscriptDiscovery` design as a *second watcher root*.
**Read only metadata/transcripts — never the `.audit-key` / token / MCP-secret files in those dirs.**

**Session root layout:**
```
~/Library/Application Support/Claude/local-agent-mode-sessions/<accountId>/<orgId>/
  ├─ local_<uuid>.json        # session metadata
  └─ local_<uuid>/audit.jsonl # append-only, HMAC-signed transcript
```

**`local_<uuid>.json` keys (verified superset):** `sessionId`, `processName`, `cliSessionId`, `cwd`,
`userSelectedFolders`, `createdAt`, `lastActivityAt`, `model`, `permissionMode`, `isArchived`, `title`,
`vmProcessName`, `hostLoopMode`, `webFetchAllowedUrls`, `initialMessage`, `slashCommands`,
`enabledMcpTools`, `remoteMcpServersConfig`, `fsDetectedFiles`, `egressAllowedDomains`,
`orgCliExecPolicies`, `memoryEnabled`, `skillsEnabled`, `pluginsEnabled`, `spaceId`, `spaceIdSetBy`,
`systemPrompt`, `accountName`, `emailAddress`. Use a subset (title/model/permissionMode/cwd/
lastActivityAt/spaceId) for the chip; keep a **schema-version/format-drift guard**.

**`audit.jsonl` format:** append-only stream-json. Record types `{user, assistant, system, result,
rate_limit_event}`; per-record keys `type`, `uuid`, `session_id`, `parent_tool_use_id`,
`client_platform`, `message`, `_audit_timestamp`, `_audit_hmac`. **Turn completion = a `result`
record.** A **pending tool-permission can be *inferred*** (not resolved) in non-bypass modes by a
`tool_use` event with no following matching `result` — the only read-only "waiting" signal for Cowork.

**VM liveness:** prefer **FSEvents/mtime** of the VM bundle over `ps` (`vm_bundles/claudevm.bundle/`:
`rootfs.img`, `sessiondata.img`; NAT `vmIP=172.16.10.3` host/guest). A guest hook can't reach a host
listener (must cross the NAT) — which is *why* the embedded Cowork Claude-Code path can't be hooked.

**Jump ceiling:** activate bundle id **`com.anthropic.claudefordesktop`** (single shared window). A
per-session `claude://` deep-link is undocumented and would need a reverse-engineering spike first.

**Foreclosed approaches (negative evidence — don't re-investigate):**
- **Chat content is not locally readable.** The chat app's IndexedDB (`https_claude.ai_0.indexeddb.leveldb`)
  has no plaintext role/human/assistant markers; Local Storage leveldb only holds `claudeai.*` telemetry
  and is locked while the app runs.
- **`mcp.log` can't signal a pending prompt.** It logs MCP tool calls only *after* user approval (a
  Decline produces no traffic) — it reflects resolved approvals, never the pending prompt. So
  MCP-as-monitor / `mcp.log` tailing cannot deliver approve/deny, even for the chat app.
