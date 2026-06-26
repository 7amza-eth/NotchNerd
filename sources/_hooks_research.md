Compiled. Here is the brief.

---

# Claude Code Hooks & Integration Surface — 2025-2026 Brief (for an Open-Island-style monitor)

Validated against the **official Anthropic docs** (`code.claude.com/docs/en/...`, the current canonical host; `docs.claude.com`/`docs.anthropic.com` redirect here) **and** the live install on this machine (**Claude Code v2.1.186**, `~/.claude/`).

## TL;DR — what a port must know

1. **The hook surface has exploded.** The classic Open-Island integration was built against ~9 events (`PreToolUse, PostToolUse, Notification, UserPromptSubmit, Stop, SubagentStop, PreCompact, SessionStart, SessionEnd`). The **current** docs list **~30 events**. The 9 classic events still exist and are unchanged in shape, so old integrations keep working, but you're now leaving a lot of signal on the table.
2. **"Waiting for user permission" is signaled two ways:** (a) the **`Notification`** event with **`matcher: "permission_prompt"`** (passive, can't approve), and (b) the newer **`PermissionRequest`** event that fires when the dialog appears and **can programmatically allow/deny** via `hookSpecificOutput.decision.behavior`. "Claude is done / idle, waiting for your next prompt" is `Notification` with **`matcher: "idle_prompt"`** (or the `Stop` event).
3. **Field-casing gotcha:** hook **stdin** uses `snake_case` (`session_id`, `transcript_path`, `hook_event_name`, `tool_name`). The **transcript `.jsonl`** uses `camelCase` (`sessionId`, `parentUuid`, `gitBranch`). Don't assume they match.
4. **Encoded-cwd gotcha:** both `/` **and `.`** become `-`. `cwd=/Users/hamza/Developer/NotchNerd/sources/boring.notch` → dir `-Users-hamza-Developer-NotchNerd-sources-boring-notch` (verified on disk).

---

## 1. Live environment on this machine (v2.1.186)

`~/.claude/settings.json` (relevant excerpt — note this user already runs a command statusline and notification flags):
```json
{
  "permissions": { "defaultMode": "auto" },
  "statusLine": { "type": "command", "command": "bash ~/.claude/statusline-command.sh" },
  "inputNeededNotifEnabled": true,
  "agentPushNotifEnabled": true
}
```
- `~/.claude/settings.local.json` exists but is **empty**.
- No `hooks` block is currently configured (a port would add one here or in project `.claude/settings.json`).
- `~/.claude/projects/<encoded-cwd>/<session-uuid>.jsonl` confirmed present; transcripts also appear at `~/.claude/projects/<encoded-cwd>.jsonl` (flat) and under a nested `<encoded-cwd>/<session-uuid>/` directory layout in newer versions — **handle both**.
- Other dirs relevant to a monitor: `~/.claude/history.jsonl`, `~/.claude/statusline-command.sh`, `~/.claude/sessions/`, `~/.claude/session-env/`, `~/.claude/plugins/`, `~/.claude/tasks/`.

---

## 2. Full hook event table (current docs)

`Block?` = whether `exit 2` / a `decision`/`permissionDecision` can veto the action.

| Event | Fires when | Matcher filters on | Block? |
|---|---|---|---|
| `SessionStart` | Session begins or resumes | `startup`,`resume`,`clear`,`compact` | No |
| `Setup` | `--init-only` / `--init` / `--maintenance` (`-p` mode) | `init`,`maintenance` | No |
| `UserPromptSubmit` | User submits a prompt, before processing | (none) | **Yes** |
| `UserPromptExpansion` | A typed command/skill expands into a prompt | command/skill name | **Yes** |
| `PreToolUse` | Before a tool call executes | tool name | **Yes** |
| `PermissionRequest` | A permission dialog is about to appear | tool name | **Yes** |
| `PermissionDenied` | Tool denied by the auto-mode classifier | tool name | No (`retry:true`) |
| `PostToolUse` | After a tool call **succeeds** | tool name | Yes (loop only) |
| `PostToolUseFailure` | After a tool call **fails** | tool name | No |
| `PostToolBatch` | After a batch of parallel tool calls resolves | (none) | **Yes** |
| `Notification` | Claude Code emits a notification | `permission_prompt`,`idle_prompt`,`auth_success`,`elicitation_dialog`,`elicitation_complete`,`elicitation_response` | No |
| `MessageDisplay` | Assistant message text is displayed | (none) | No |
| `SubagentStart` | A subagent (Task) is spawned | agent type | No |
| `SubagentStop` | A subagent finishes | agent type | **Yes** |
| `TaskCreated` | Task created via `TaskCreate` | (none) | **Yes** |
| `TaskCompleted` | Task marked completed | (none) | **Yes** |
| `Stop` | Main agent finishes responding (not on user interrupt) | (none) | **Yes** |
| `StopFailure` | Turn ends due to an API error | `rate_limit`,`overloaded`,`authentication_failed`,`billing_error`,`invalid_request`,`model_not_found`,`server_error`,`max_output_tokens`,`unknown`, … | No |
| `TeammateIdle` | An agent-team teammate is about to go idle | (none) | **Yes** |
| `InstructionsLoaded` | `CLAUDE.md` / `.claude/rules/*.md` loaded | `session_start`,`nested_traversal`,`path_glob_match`,`include`,`compact` | No |
| `ConfigChange` | A settings/skills file changes mid-session | `user_settings`,`project_settings`,`local_settings`,`policy_settings`,`skills` | **Yes** |
| `CwdChanged` | Working dir changes (e.g. `cd`) | (none) | No |
| `FileChanged` | A watched file changes on disk | literal filenames (`.env\|.envrc`) | No |
| `WorktreeCreate` | A worktree is being created | (none) | **Yes** |
| `WorktreeRemove` | A worktree is being removed | (none) | No |
| `PreCompact` | Before context compaction | `manual`,`auto` | **Yes** |
| `PostCompact` | After compaction completes | `manual`,`auto` | No |
| `Elicitation` | MCP server requests user input mid-tool-call | MCP server name | **Yes** |
| `ElicitationResult` | User responds to an MCP elicitation | MCP server name | **Yes** |
| `SessionEnd` | Session terminates | `clear`,`resume`,`logout`,`prompt_input_exit`,`bypass_permissions_disabled`,`other` | No |

> The classic 9-event Open-Island set is everything not introduced in 2025-2026 (see §9). Everything else is new.

---

## 3. Hook stdin JSON

### Common fields (every event)
```json
{
  "session_id": "abc123",
  "transcript_path": "/Users/.../.claude/projects/<enc-cwd>/<uuid>.jsonl",
  "cwd": "/Users/hamza/my-project",
  "permission_mode": "default",        // default|plan|acceptEdits|auto|dontAsk|bypassPermissions
  "hook_event_name": "PreToolUse",
  "effort": { "level": "medium" },     // low|medium|high|xhigh|max (tool events, Stop, SubagentStop)
  "agent_id": "subagent-xyz",          // only inside a subagent
  "agent_type": "Explore"              // only with --agent / inside subagent
}
```

### Key event-specific shapes
```json
// PreToolUse
{ "hook_event_name":"PreToolUse", "tool_name":"Bash", "tool_input":{ "command":"npm test" } }

// PostToolUse
{ "hook_event_name":"PostToolUse", "tool_name":"Bash",
  "tool_input":{ "command":"npm test" },
  "tool_response":{ "stdout":"PASS", "exit_code":0 } }

// UserPromptSubmit
{ "hook_event_name":"UserPromptSubmit", "prompt":"Build a React component" }

// SessionStart  (source = startup|resume|clear|compact)
{ "hook_event_name":"SessionStart", "source":"startup",
  "model":"claude-sonnet-4-6", "session_title":"my-session" }

// SessionEnd
{ "hook_event_name":"SessionEnd", "reason":"prompt_input_exit" }

// Notification  (this is the "needs attention" signal)
{ "hook_event_name":"Notification", "type":"permission_prompt", "message":"Permission required" }

// PermissionRequest
{ "hook_event_name":"PermissionRequest", "tool_name":"Bash",
  "tool_input":{ "command":"rm -rf /tmp" } }

// Stop  (also receives stop_hook_active=true when re-fired after a block)
{ "hook_event_name":"Stop", "permission_mode":"default", "effort":{"level":"medium"} }

// SubagentStop / SubagentStart
{ "hook_event_name":"SubagentStop", "agent_type":"Explore", "agent_id":"subagent-xyz" }

// PreCompact
{ "hook_event_name":"PreCompact", "trigger":"manual" }
```

---

## 4. Hook output / decision-control schemas

### Universal output (exit 0 + JSON on stdout)
```json
{
  "continue": true,            // false = Claude stops processing entirely
  "stopReason": "…",           // shown to user when continue:false
  "suppressOutput": false,     // hide stdout from transcript
  "systemMessage": "…",        // warning shown to user
  "terminalSequence": "\u001b]2;Claude Code\u0007"  // OSC/BEL escape (desktop notifs etc.)
}
```

### PreToolUse — programmatic approve/deny
```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",          // allow | deny | ask | defer
    "permissionDecisionReason": "Destructive command blocked by hook",
    "updatedInput": { "command": "npm run lint" },  // optional: rewrite args
    "additionalContext": "Used safer alternative"
  }
}
```
- `allow` skips the interactive prompt but **does not override deny/ask permission rules** (incl. managed/enterprise deny lists). Hooks can tighten, never loosen.
- A hook returning `deny` blocks even under `bypassPermissions` / `--dangerously-skip-permissions` (PreToolUse fires *before* the permission-mode check).
- `defer` is `-p`/headless-only (preserves the call for an Agent SDK wrapper to resume).
- When multiple hooks disagree, **most restrictive wins**: `deny` > `defer` > `ask` > `allow`.

### PermissionRequest — answer the dialog on the user's behalf
```json
{
  "hookSpecificOutput": {
    "hookEventName": "PermissionRequest",
    "decision": {
      "behavior": "allow",                 // allow | deny
      "updatedInput": { "command": "npm run lint" },
      "updatedPermissions": [
        { "type": "setMode", "mode": "acceptEdits", "destination": "session" }
      ]
    }
  }
}
```
> Important: **`PermissionRequest` hooks do NOT fire in non-interactive (`-p`) mode** — use `PreToolUse` there.

### PostToolUse / Stop / SubagentStop
```json
// PostToolUse: decision is top-level
{ "decision": "block", "reason": "Tests are failing",
  "hookSpecificOutput": { "hookEventName":"PostToolUse",
    "updatedToolOutput":"3 passed, 5 failed", "additionalContext":"Halting" } }

// Stop / SubagentStop: non-blocking context injection
{ "hookSpecificOutput": { "hookEventName":"Stop",
    "additionalContext":"Remember to push changes" } }
```

### UserPromptSubmit
```json
{ "decision": "block", "reason": "…", "additionalContext": "injected into context" }
```

### Exit-code semantics
| Code | Meaning |
|---|---|
| `0` | Success; parse stdout JSON. For `UserPromptSubmit`/`UserPromptExpansion`/`SessionStart`, stdout is added to Claude's context. |
| `2` | **Blocking** error; JSON ignored, **stderr** is the feedback channel (effect is event-specific — see Block? column). |
| other | Non-blocking; stderr shown as `<hook> hook error`, execution continues. |

`Stop` block-loop cap: Claude overrides a `Stop` hook after **8** consecutive blocks; check `stop_hook_active` and bail, or raise via env `CLAUDE_CODE_STOP_HOOK_BLOCK_CAP`.

---

## 5. settings.json hooks schema + handler types + precedence

### Shape (`hooks` → eventName → array of matcher-groups → `hooks` array → handlers)
```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Edit|Write",        // omit or "" = fire on every occurrence; "|" alternation, regex ok; "," == "|" on v2.1.191+
        "hooks": [
          {
            "type": "command",          // command | http | mcp_tool | prompt | agent
            "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/protect.sh",
            "if": "Bash(git *)",        // v2.1.85+, tool events only; permission-rule syntax
            "timeout": 30,              // seconds
            "async": false
          }
        ]
      }
    ]
  }
}
```

### Handler types
- `command` (default, stdin/stdout/exit-code; default timeout 10 min, 30 s for `UserPromptSubmit`, 10 s for `MessageDisplay`).
- `http` — POSTs the same JSON to a URL; reply body uses the same output schema; `headers` support `$VAR` interpolation limited to an `allowedEnvVars` allowlist. **Relevant for an Open-Island daemon**: point a single HTTP hook at a localhost listener instead of spawning per-event scripts.
- `mcp_tool` — call a tool on a connected MCP server.
- `prompt` — single-turn Haiku (default) yes/no decision; returns `{"ok":bool,"reason":"…"}`.
- `agent` — experimental multi-turn subagent verification.

### Precedence (highest → lowest)
1. **Managed/enterprise policy** — `/Library/Application Support/ClaudeCode/managed-settings.json` (macOS), `/etc/claude-code/` (Linux), `C:\Program Files\ClaudeCode\` (Win). Cannot be overridden.
2. **Command-line args** (session overrides)
3. **Local** — project `.claude/settings.local.json` (gitignored)
4. **Project** — `.claude/settings.json` (committed)
5. **User** — `~/.claude/settings.json`

Plus: plugin `hooks/hooks.json`, and skill/agent frontmatter. Scalar keys override by precedence; **arrays merge** (`permissions`, `allowedHttpHookUrls`) and hooks from **all** scopes accumulate. Files are **hot-reloaded** (`hooks`/`permissions` apply without restart). `"disableAllHooks": true` kills all hooks. `/hooks` opens a read-only browser.

---

## 6. Transcript `.jsonl` structure (verified on disk, v2.1.186)

Location: `~/.claude/projects/<encoded-cwd>/<session-uuid>.jsonl` (one JSON object per line; append-only). **Encoded-cwd = replace every `/` and `.` with `-`** (e.g. `…/sources/boring.notch` → `-Users-hamza-Developer-NotchNerd-sources-boring-notch`).

Observed `type` values: `user`, `assistant`, `system`, plus harness/control records `mode`, `permission-mode`, `bridge-session`, `attachment`, `ai-title`, `last-prompt`, `file-history-snapshot`. A robust parser must **skip unknown types**.

`assistant` record (top-level fields are **camelCase**):
```json
{
  "parentUuid": "1a74…", "isSidechain": false,
  "message": {
    "model": "claude-opus-4-8", "id": "msg_…", "type": "message", "role": "assistant",
    "content": [ /* text + tool_use blocks */ ],
    "stop_reason": "tool_use", "stop_sequence": null,
    "usage": { "input_tokens": 3316, "cache_creation_input_tokens": 20842,
               "cache_read_input_tokens": 0, "output_tokens": 960, "service_tier": "standard" }
  },
  "requestId": "req_…", "type": "assistant", "uuid": "93cc…",
  "timestamp": "2026-06-25T22:45:18.218Z", "userType": "external", "entrypoint": "cli",
  "cwd": "/Users/hamza/Developer/NotchNerd", "sessionId": "27d9…",
  "version": "2.1.186", "gitBranch": "HEAD"
}
```
`user` record adds `promptId`, `gitBranch`, `isMeta`; `message.role:"user"`. A `system` record example carries useful turn metadata:
```json
{ "type":"system", "subtype":"turn_duration", "durationMs":329157,
  "messageCount":71, "pendingWorkflowCount":1, "timestamp":"…", "sessionId":"…" }
```
Other `system.subtype`s carry hook/compaction/notice info. Records are linked via `uuid`/`parentUuid` (a DAG, not a flat list — sidechains/subagents branch off). **The transcript is the single most reliable cross-version data source** since stdin field availability shifts per release.

---

## 7. Statusline mechanism

Config (already used on this machine):
```json
{ "statusLine": { "type": "command", "command": "bash ~/.claude/statusline-command.sh" } }
```
The command receives **JSON on stdin** (NOT the same casing as hooks — top-level `session_id`/`transcript_path` are snake_case but the data objects are nested) and **prints a line to stdout**; ANSI colors allowed; stdout is captured (so `tput`/width detection fails — read `COLUMNS`/`LINES` env, v2.1.153+). Full stdin schema:
```json
{
  "cwd": "/current/working/directory",
  "session_id": "abc123...",
  "session_name": "my-session",
  "transcript_path": "/path/to/transcript.jsonl",
  "model": { "id": "claude-opus-4-8", "display_name": "Opus" },
  "workspace": {
    "current_dir": "…", "project_dir": "…", "added_dirs": [],
    "git_worktree": "feature-xyz",
    "repo": { "host": "github.com", "owner": "anthropics", "name": "claude-code" }
  },
  "version": "2.1.90",
  "output_style": { "name": "default" },
  "cost": { "total_cost_usd": 0.01234, "total_duration_ms": 45000,
            "total_api_duration_ms": 2300, "total_lines_added": 156, "total_lines_removed": 23 },
  "context_window": {
    "total_input_tokens": 15500, "total_output_tokens": 1200,
    "context_window_size": 200000,        // 200000 default, 1000000 for extended-context models
    "used_percentage": 8, "remaining_percentage": 92,
    "current_usage": { "input_tokens": 8500, "output_tokens": 1200,
                       "cache_creation_input_tokens": 5000, "cache_read_input_tokens": 2000 }
  },
  "exceeds_200k_tokens": false,
  "effort": { "level": "high" },
  "thinking": { "enabled": true },
  "rate_limits": {
    "five_hour": { "used_percentage": 23.5, "resets_at": 1738425600 },
    "seven_day": { "used_percentage": 41.2, "resets_at": 1738857600 }
  },
  "vim": { "mode": "NORMAL" },
  "agent": { "name": "security-reviewer" },
  "pr": { /* … */ }
}
```
For an Open-Island monitor this is the cleanest **pre-computed** source of model name, `context_window.used_percentage`, cost, and rate-limit consumption — no transcript math required. Note: `context_window.total_*` became *current-window* (not cumulative) in **v2.1.132**, and the convenience flags `inputNeededNotifEnabled`/`agentPushNotifEnabled` in this user's settings already drive native input/idle notifications.

---

## 8. Answering the core question: how a hook signals "waiting for user permission"

Three distinct, current mechanisms — pick based on whether you only want to *observe* or also *act*:

| Goal | Mechanism | Notes |
|---|---|---|
| **Observe "needs approval"** (Open-Island light) | `Notification` hook, `matcher: "permission_prompt"`; stdin `{"type":"permission_prompt","message":"Permission required"}` | Passive only. Cannot approve/deny. Also `idle_prompt` = "done, waiting for your prompt"; `auth_success`, `elicitation_*`. |
| **Observe AND auto-answer the dialog** | `PermissionRequest` hook; return `hookSpecificOutput.decision.behavior: "allow"\|"deny"` | The intended modern auto-approve path (docs' "Auto-approve specific permission prompts" recipe). **Does not fire under `-p`.** |
| **Gate before the prompt even appears** | `PreToolUse` hook; return `permissionDecision: "allow"\|"deny"\|"ask"` | Works in headless; cannot override settings deny rules; `allow` just skips the interactive prompt. |

So: **the permission prompt is its own event now (`PermissionRequest`)**, distinct from the generic `Notification`. A classic Open-Island port that only watched `Notification` will still get the "needs attention" beat, but to *resolve* it programmatically you want `PermissionRequest` (interactive) or `PreToolUse` (headless). `PermissionDenied` (auto-mode classifier rejected a call; supports `{"retry":true}`) is also new and worth surfacing as a "blocked" state.

---

## 9. 2025-2026 changes a port must account for

- **Many new lifecycle events** beyond the classic 9: `Setup`, `UserPromptExpansion`, `PermissionRequest`, `PermissionDenied`, `PostToolUseFailure`, `PostToolBatch`, `MessageDisplay`, `SubagentStart`, `TaskCreated`, `TaskCompleted`, `StopFailure`, `TeammateIdle` (agent teams), `InstructionsLoaded`, `ConfigChange`, `CwdChanged`, `FileChanged`, `WorktreeCreate`/`WorktreeRemove`, `PostCompact`, `Elicitation`/`ElicitationResult`.
- **`StopFailure` split from `Stop`**: API-error turn-ends now fire `StopFailure` (output/exit ignored), not `Stop`. A monitor that treats `Stop` as "turn ended" will miss error terminations.
- **Subagent lifecycle is now bracketed**: `SubagentStart` + `SubagentStop` (previously only Stop-style). Plus agent-team `TeammateIdle`.
- **New hook handler types**: `http`, `mcp_tool`, `prompt`, `agent` (was command-only). An HTTP hook to a localhost daemon is the cleanest architecture for an external monitor app.
- **New stdin fields**: `permission_mode` (now includes `auto`, `dontAsk`), `effort.level`, `agent_id`, `agent_type`. New permission mode `auto` is in active use (this machine's `defaultMode:"auto"`).
- **`if` field** (v2.1.85+) for arg-level filtering; **`,` as matcher separator** (v2.1.191+).
- **Statusline `context_window.total_*` semantics changed** in v2.1.132 (current-window vs cumulative); extended-context models report `context_window_size: 1000000`.
- **Transcript path layout varies** (`<enc>/<uuid>.jsonl`, flat `<enc>.jsonl`, and nested `<enc>/<uuid>/` seen on this v2.1.186 box) — derive the path from `transcript_path` in hook/statusline stdin rather than reconstructing it.
- **No removals of the classic 9 events** — backward compatible. Risk is missed signal, not breakage.

---

## Sources
- [Hooks reference — code.claude.com/docs/en/hooks](https://code.claude.com/docs/en/hooks) (full event list, input/output JSON schemas, exit codes, decision control)
- [Automate actions with hooks (guide) — code.claude.com/docs/en/hooks-guide](https://code.claude.com/docs/en/hooks-guide) (settings.json config shape, matchers, Notification matchers, PermissionRequest auto-approve, handler types, `stop_hook_active`)
- [Settings — code.claude.com/docs/en/settings](https://code.claude.com/docs/en/settings) (precedence: managed > CLI > local > project > user; file locations; hot-reload)
- [Status line — code.claude.com/docs/en/statusline](https://code.claude.com/docs/en/statusline) (stdin JSON schema, context_window/cost/rate_limits fields)
- Live install inspected on this machine: `~/.claude/settings.json`, `~/.claude/statusline-command.sh`, `~/.claude/projects/-Users-hamza-Developer-NotchNerd/27d9c3c1-afaf-430e-9750-3db7c669561a.jsonl` (Claude Code **v2.1.186**)

Persisted full-doc captures (for re-reading): `/Users/hamza/.claude/projects/-Users-hamza-Developer-NotchNerd/27d9c3c1-afaf-430e-9750-3db7c669561a/tool-results/toolu_01CW8h28z5svJMmcYsG3GwYZ.txt` (hooks-guide) and `…/toolu_01LSs3v7tygJGcfihEEZ9kfB.txt` (statusline).
