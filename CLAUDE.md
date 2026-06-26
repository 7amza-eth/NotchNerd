# CLAUDE.md — NotchNerd

NotchNerd is a macOS menu-bar SwiftUI app: a fork of **boring.notch** (the whole notch shell — music,
shelf, calendar, HUD, webcam) that adds a **Claude Code agent monitor** (a vendored slice of the
**Open Island** engine) and an **always-open notepad**. Both upstreams are GPL v3; so is this.

## Read first

**[`spec.md`](./spec.md)** is the canonical hydration doc — overview, annotated repo tree, stack,
architecture (agent pipeline + notepad + notch/CGS-space), build, key files, and gotchas. Read it
before doing anything non-trivial. **[`NotchNerd-PLAN.md`](./NotchNerd-PLAN.md)** is the roadmap +
decision log (phases, locked decisions). `spec.md`'s "References" section links the rest.

## Build & run

```sh
xcodebuild -project NotchNerd.xcodeproj -scheme NotchNerd -configuration Debug build
```

- **Full Xcode required** (not just Command Line Tools) — a run-script phase shells out to `swift build`.
- No shared scheme is committed; `-scheme NotchNerd` relies on the auto-generated one (or use `-target NotchNerd`). Build with `-scheme` (not `-target`) so SPM packages resolve.
- The app is **unsandboxed**, ad-hoc signed. **Ad-hoc signing changes the cdhash every build → macOS drops Accessibility/Automation TCC grants.** Run `zsh tooling/scripts/setup-dev-signing.sh` + set the target to Manual signing with "NotchNerd Dev" before iterating, or you'll re-grant permissions every build.

## Conventions / load-bearing rules

- **Do NOT edit `Vendor/OpenIslandEngine/Sources/`.** Those files are copied **verbatim** from Open Island (GPL v3, commit `1e26dfc`) and kept pristine for clean re-pull (`Vendor/OpenIslandEngine/VENDORED-FROM.md`). Only `Package.swift` is locally authored. If you must change engine behavior, do it as a small, documented patch and note it.
- **`AppDelegate` (in `NotchNerd/NotchNerdApp.swift`), not the SwiftUI `App` body, owns all lifecycle** — window creation, agent start, notepad restore. The `App` scene is just a `MenuBarExtra`.
- **Adding files/targets/refs to the Xcode project: use the `xcodeproj` Ruby gem**, not hand-edited `project.pbxproj` (objectVersion 70). The helper folder is a `PBXFileSystemSynchronizedRootGroup`; the app folder is a normal `PBXGroup`.
- **Two notch window classes; only `NotchNerdSkyLightWindow` is instantiated** at runtime. `NotchNerdWindow.swift` is dead. Notch panels are non-key (click-through) **except** while the Notes tab is active (`NotepadNotchFocus.allowsNotchKey`).
- **Privileged ops must target the process that performs them.** The app is unsandboxed, so do Accessibility/AX checks **in-app** (the CGEventTap runs in the app), not via the XPC helper. (This was a real bug — see commit `c53ccfe`.)
- **`Defaults.Keys` are split** across `NotchNerd/models/Constants.swift` and `NotchNerd/Notepad/NotepadWindowController.swift`.
- **`spikes/` are unwired prototypes** — real code is `NotchNerd/Agent/` and `NotchNerd/Notepad/`. Editing spikes does nothing.
- **The agent monitor is OFF by default** (`Defaults[.agentEnabled]`), behind Settings → Agent. It only OBSERVES Claude Code via hooks — it never calls the Anthropic API and stores no credentials.
- **Preserve GPL attribution** (boring.notch / TheBoredTeam, Open Island / Octane0411) in `LICENSE`, `THIRD_PARTY_LICENSES`, source headers.
- Some docs (`NotchNerd-PLAN.md` §3–9, the spike `DESIGN.md`s, `sources/_map_digest.md`) cite **pre-rename `boringNotch/*` paths** — map them 1:1 onto `NotchNerd/*`.

## Commit conventions

Branch is `main` (personal fork, `upstream` = boring.notch). Commit messages end with the
`Co-Authored-By` / `Claude-Session` trailers per the harness config.
