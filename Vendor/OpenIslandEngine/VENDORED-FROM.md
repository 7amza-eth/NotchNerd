# Vendored from Open Island

`Sources/OpenIslandCore` and `Sources/OpenIslandHooks` are copied **verbatim** from
[open-vibe-island](https://github.com/Octane0411/open-vibe-island) (GPL v3, same license as this repo).

- **Upstream commit:** `1e26dfc` ("Merge pull request #523 from SSakutaro/docs/homebrew-install")
- **Copied:** 2026-06-26
- **Copied dirs:** `Sources/OpenIslandCore` (45 files, whole — incl. inert Codex/Cursor/Gemini/OpenCode types), `Sources/OpenIslandHooks/OpenIslandHooksCLI.swift`
- **Local changes:** kept as close to pristine as possible (per plan locked-decision #6); the only edits are the hand-written `Package.swift` and the small documented patches below.

## NotchNerd patches (re-apply after a re-pull)

- **`QuestionOption.preview`** — `Sources/OpenIslandCore/AgentSession.swift`: added `public var preview: String?` to `QuestionOption` (+ init param). `Sources/OpenIslandCore/ClaudeHooks.swift`: in the `questionPrompt` parser, populate it from `optionObject["preview"]?.stringValue`. **Why:** AskUserQuestion options can carry an ASCII/code `preview`; upstream drops it, so the Agent tab's question card couldn't show it. Backward-compatible (Optional → `decodeIfPresent`). Marked inline with `// NotchNerd patch`.
- **`PermissionRequest.planText`** — `Sources/OpenIslandCore/AgentSession.swift`: added `public var planText: String?` to `PermissionRequest` (+ init param, default nil). `Sources/OpenIslandCore/BridgeServer.swift`: in `handleClaudeHook`'s `.permissionRequest` branch, populate it from `payload.toolInput["plan"]` when `toolName == "ExitPlanMode"`. **Why:** the plan-review card must show the plan being approved, and the transcript is **not flushed while the PermissionRequest hook blocks** (verified live 2026-06-30 — the session's `.jsonl` doesn't exist yet at prompt time), so the blocked hook payload is the only live source. Backward-compatible (Optional). Marked inline with `// NotchNerd patch`.

## Re-pulling upstream
```sh
# from the OVI reference clone (sources/open-vibe-island), or a fresh clone:
git -C sources/open-vibe-island fetch origin && git -C sources/open-vibe-island checkout origin/main
rsync -a --delete sources/open-vibe-island/Sources/OpenIslandCore/  Vendor/OpenIslandEngine/Sources/OpenIslandCore/
cp sources/open-vibe-island/Sources/OpenIslandHooks/OpenIslandHooksCLI.swift Vendor/OpenIslandEngine/Sources/OpenIslandHooks/
cd Vendor/OpenIslandEngine && swift build   # verify it still compiles under tools 6.0
```
Then re-apply any NotchNerd-specific patches (e.g. socket namespacing, the parallel-permission
`sessionID+toolUseID` fix) — track those as a separate, documented patch set so re-pull stays clean.
