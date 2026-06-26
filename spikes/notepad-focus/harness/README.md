# Notepad focus spike — runnable harness

Validates the single riskiest unknown for NotchNerd's always-open notepad:

> Can a key-capable text panel take **keyboard focus** while living in
> boring.notch's **max-level private CGS Space**, **without** stealing
> foreground activation from the user's frontmost app — given the app runs as
> `.accessory` (LSUIElement)?

This harness is a single AppKit file. It needs **only the Swift CLI toolchain**
(Swift 6.2.1 Command Line Tools). **No Xcode, no `.xcodeproj`, no SwiftPM
manifest.**

---

## Build & run

```sh
cd spikes/notepad-focus/harness
swiftc -O main.swift -o harness && ./harness
```

Optionally start straight in CGS-space mode (you can also toggle live with the
on-panel buttons):

```sh
./harness B      # start in Mode B (CGS space).  ./harness  = Mode A (floating)
```

> If `swiftc` complains it can't reach the WindowServer, run it from a normal
> **Terminal.app** window inside your logged-in graphical session (not over a
> bare SSH/tmux session with no Aqua session attached).

Quit: click the panel's red close button, or `Ctrl+C` in the terminal.

The harness was confirmed to **compile (`swiftc` exit 0)** and **launch without
crashing** in both modes; the CGS path actually creates a max-level space at
runtime. The remaining checks below require **your eyes** — they are about
focus/activation behavior the toolchain can't self-assert.

---

## What it does

- `NSApplication` with `setActivationPolicy(.accessory)` — no Dock icon, no menu
  bar, exactly like the shipping LSUIElement app.
- A `KeyPanel: NSPanel` whose style mask includes **`.nonactivatingPanel`** and
  which overrides **`canBecomeKey = true`** (the shipping notch panels hard-code
  `false`). It hosts a scrollable `NSTextView`.
- A live status line showing **which app macOS thinks is frontmost**, whether
  **our** app is active, and whether the notepad is the key window.
- **Mode A** — plain floating panel at `level .mainMenu+2`, `.canJoinAllSpaces`.
  This is the documented **fallback** design.
- **Mode B** — the panel is inserted into a self-created **max-level CGS Space**
  (`level 2147483647`) that replicates `boringNotch/private/CGSSpace.swift` +
  `NotchSpaceManager`. This is the **GO** design under test.

The CGS symbols (`_CGSDefaultConnection`, `CGSSpaceCreate`,
`CGSSpaceSetAbsoluteLevel`, `CGSAddWindowsToSpaces`,
`CGSRemoveWindowsFromSpaces`, `CGSShowSpaces`, `CGSHideSpaces`,
`CGSSpaceDestroy`) are copied 1:1 from the real `CGSSpace.swift`, so Mode B
exercises the exact code path the app would ship.

---

## PASS / FAIL checklist → GO / NO-GO

Do this for **Mode A first** (sanity), then **Mode B** (the real test).

1. Click **Safari** or **Notes** to make it the visibly-active foreground app
   (its menu bar shows, its Dock dot is lit).
2. **Without cmd-tabbing**, click into the notepad and type a few characters.
3. Read the in-panel status line and answer:

| # | Check | PASS looks like |
|---|-------|-----------------|
| 1 | Can you click in and type? Caret blinks, letters appear? | yes |
| 2 | `Frontmost:` after you type | still **Safari/Notes**, NOT "harness" |
| 3 | `ourApp.isActive:` while typing | stays **`no`** (red `YES` = activation leak = fail) |
| 4 | `notepad.isKey:` while typing | **`YES`** |
| 5 | Menu bar / Dock focus while typing | unchanged (other app stays lit) |
| 6 | Put another app in native fullscreen (green button). Notepad still visible above it? | **yes** in Mode B |

### Decision

- **GO — ship the CGS-space design** if, in **Mode B**, checks **1–5 PASS**
  (you can type, frontmost stays your other app, `isActive` stays `no`,
  notepad is key) **and** check **6 PASS** (floats over fullscreen).

- **NO-GO — ship the fallback** if, in **Mode B**, any of:
  - check 1 fails (cannot type / no caret / clicks ignored), **or**
  - check 2/3/5 fails (frontmost flips to the harness, `isActive` turns red
    `YES`, or the other app's menu bar/Dock focus is stolen), **or**
  - check 6 fails (panel vanishes or mis-renders over fullscreen).

  In that case use **Mode A** (plain high-level floating panel, NOT in the CGS
  space). If Mode A passes 1–5 but fails 6, that is the documented trade-off:
  fallback keeps focus but may not float over *another app's* native fullscreen
  space as reliably as the CGS space does.

Record which checks passed in each mode — that table is the spike's output.
