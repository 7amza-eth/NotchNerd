# Vendored from Open Island

`Sources/OpenIslandCore` and `Sources/OpenIslandHooks` are copied **verbatim** from
[open-vibe-island](https://github.com/Octane0411/open-vibe-island) (GPL v3, same license as this repo).

- **Upstream commit:** `1e26dfc` ("Merge pull request #523 from SSakutaro/docs/homebrew-install")
- **Copied:** 2026-06-26
- **Copied dirs:** `Sources/OpenIslandCore` (45 files, whole — incl. inert Codex/Cursor/Gemini/OpenCode types), `Sources/OpenIslandHooks/OpenIslandHooksCLI.swift`
- **Local changes:** none yet (kept pristine for clean upstream re-pull, per plan locked-decision #6). Only the `Package.swift` here is hand-written (tools 6.0 + Swift-6 mode + 2 products, vs upstream's 6.2 / 4-target manifest).

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
