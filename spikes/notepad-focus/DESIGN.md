# NotchNerd Notepad — Design + Focus-Risk Spike

*Spike for PLAN §3d + Phase 5 + Risk #3. Goal: an always-open, multi-note
notepad that stays usable while the main notch is in use and floats above other
apps' fullscreen — and a runnable harness validating the single riskiest
unknown: **can a key-capable text panel take keyboard focus inside boring.notch's
max-level CGS Space without stealing foreground activation from an `.accessory`
app?***

Files in this spike:

| File | Role |
|---|---|
| `DESIGN.md` | this document |
| `NotepadPanel.swift` | production-intent `NSPanel` subclass |
| `NotepadWindowController.swift` | production-intent singleton lifecycle/CGS/fallback |
| `NotesStore.swift` | production-intent multi-note model + autosave |
| `NotepadView.swift` | production-intent SwiftUI content (tabs + TextEditor) |
| `harness/main.swift` | **runnable** `swiftc` validation harness (Mode A / Mode B) |
| `harness/README.md` | build/run + PASS/FAIL → GO/NO-GO checklist |

---

## 1. Why it is its own window (not a notch tab)

A `NotchViews` tab only renders when the notch is **open**, and is mutually
exclusive with home/shelf. So a tab "cannot stay visible while you use the main
notch" and cannot be open simultaneously with music/shelf. The notepad is
therefore its **own** window, completely decoupled from `BoringViewModel.notchState`.
Its visibility is gated only by:

- `Defaults[.notepadVisible]` (persisted; restored on launch),
- a `MenuBarExtra` item ("Notepad"), and
- a `KeyboardShortcuts` global hotkey (`.toggleNotepad`).

---

## 2. NotepadPanel configuration

`NotepadPanel: NSPanel` (see `NotepadPanel.swift`). The configuration that
matters:

| Property | Value | Why |
|---|---|---|
| styleMask | includes **`.nonactivatingPanel`** + `.titled .closable .resizable .fullSizeContentView` | non-activating = clicking it does **not** activate our app; titled/closable give draggable chrome |
| `canBecomeKey` | **`true`** (override) | the editor must be able to receive keystrokes |
| `canBecomeMain` | `false` | stay a panel; never pull main-window/document semantics into an `.accessory` app |
| `becomesKeyOnlyIfNeeded` | `false` | become key on click into the editor |
| `hidesOnDeactivate` | `false` | stay visible when other apps are frontmost |
| `level` | `.mainMenu + 2` | fallback float level (CGS absolute level dominates when joined) |
| `collectionBehavior` | `.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle` | appear on every space incl. fullscreen (fallback behavior) |
| `isMovableByWindowBackground` | `true` | drag from anywhere |

**This is the inversion of the notch panels.** `BoringNotchWindow` and
`BoringNotchSkyLightWindow` hard-code `canBecomeKey=false`/`canBecomeMain=false`
for click-through passivity. The notepad is the **one** window that flips
`canBecomeKey=true`. We do **not** reuse those panel classes.

---

## 3. NotepadWindowController lifecycle

Singleton `NSWindowController` (modeled on `SettingsWindowController`), created
in `applicationDidFinishLaunching`. Public surface: `show()`, `hide()`,
`toggle()`, `restoreIfNeeded()`.

**The one rule that makes the whole thing work:** unlike `SettingsWindowController`
— which intentionally calls `NSApp.setActivationPolicy(.regular)` and
`NSApp.activate(ignoringOtherApps:)` in `showWindow()` / `windowDidBecomeKey` —
the notepad controller **NEVER** changes activation policy and **NEVER** calls
`NSApp.activate`. Showing it is `orderFrontRegardless()` + `makeKey()` only. The
`.nonactivatingPanel` + `canBecomeKey=true` combo lets `makeKey()` route
keystrokes to the panel **without** activating the app, so the user's frontmost
app keeps the menu bar and Dock focus.

Lifecycle wiring in `AppDelegate.applicationDidFinishLaunching`:

```swift
NotepadWindowController.shared.restoreIfNeeded()   // reopen if was visible
// MenuBarExtra "Notepad" button → NotepadWindowController.shared.toggle()
// KeyboardShortcuts.Name.toggleNotepad already registered in the controller
```

`applicationWillTerminate` → `NotesStore.shared.flush()` to drain pending
autosaves.

Close button (red dot) is intercepted via `windowShouldClose` → `hide()` and
returns `false` (hide, not destroy; notes persist; panel reused).

Positioning: top-center under the menu bar/notch on the preferred screen
(reuses `BoringViewCoordinator.selectedScreenUUID` + `NSScreen.screen(withUUID:)`),
re-applied on `didChangeScreenParametersNotification` — consistent with
`AppDelegate.positionWindow` / `adjustWindowPosition` conventions. Multi-display:
follows the same preferred-screen selection the notch uses; one panel, moved to
the active screen (not one-per-display — a notepad is a single document surface).

---

## 4. Multi-note model + on-disk format + autosave

`NotesStore` (see `NotesStore.swift`) — `@MainActor ObservableObject`, pure
Foundation/Combine, host-decoupled and unit-testable.

**Model.** `Note { id: UUID, explicitTitle: String?, createdAt, modifiedAt,
body: String }`. `displayTitle` = `explicitTitle` else first non-empty body line
(else "Untitled") — drives tab/list labels.

**On-disk layout** (reachable once unsandboxed, PLAN §3b):

```
~/Library/Application Support/NotchNerd/Notepad/
  ├── index.json        ← ordered [Note metadata] + selectedID   (order source of truth)
  └── notes/
      ├── <uuid>.md      ← one plain-text/markdown body per note
      └── <uuid>.md
```

Body and metadata are **split on purpose**: each body is a plain `.md` the user
could open in any editor; `index.json` owns order, titles, timestamps and the
selected note. `Note.CodingKeys` excludes `body` so it never lands in
`index.json`.

**Autosave.** Debounced (0.6 s) per the mutation:
- editing a body → debounced **per-note body write** (`<uuid>.md`) + debounced
  index write (title/timestamp may have changed);
- new/delete/rename/reorder/select → debounced index write.

`flush()` (called on quit) cancels timers and writes everything synchronously.
Deleting the last note immediately creates a fresh empty one — the notepad is
never empty.

**UI** (`NotepadView.swift`): a horizontal scrollable tab strip (select / close
/ `+` new) above a `TextEditor` bound to the selected note's body via a custom
`Binding` that funnels every edit through `store.updateBody`. `@FocusState`
focuses the editor on appear and on selection change so the
`.nonactivatingPanel+canBecomeKey` focus actually lands in the text.

---

## 5. CGS-space integration (the GO path)

For float-over-fullscreen, insert the panel into the **same** max-level space the
notch already floats in:

```swift
NotchSpaceManager.shared.notchSpace.windows.insert(notepadPanel)
```

`NotchSpaceManager.shared.notchSpace` is a `CGSSpace(level: 2147483647)`
(`Int32.max`). `CGSSpace.windows.didSet` calls the private
`CGSAddWindowsToSpaces(_CGSDefaultConnection(), [windowNumber], [spaceID])`. The
space was created with `CGSSpaceCreate(..., flag=0x1, ...)`,
`CGSSpaceSetAbsoluteLevel(..., 2147483647)`, `CGSShowSpaces`. Because the space's
**absolute** level is above the menu bar / Dock / fullscreen windows, any window
parented into it draws over a native-fullscreen app's space — which is exactly
why boring.notch's notch survives over fullscreen.

The controller chooses GO vs fallback via `Defaults[.notepadFloatStrategy]`
(`.cgsSpace` | `.floating`), so we can ship the fallback **without code changes**
if the spike says NO-GO. `hide()` removes the panel from the space so a hidden
panel isn't pinned in it.

---

## 6. Focus-risk analysis

### 6.1 Why `.nonactivatingPanel` + `canBecomeKey=true` *should* work

Two macOS concepts are independent:

- **App activation** — which *application* is frontmost (owns the menu bar, lit
  Dock dot). Controlled by `NSApp.activate` / `setActivationPolicy` / clicking a
  normal window.
- **Key window** — which *window* receives keyboard events, scoped per app and
  routed by the window server.

A normal window click does both (activates the app *and* makes the window key).
`.nonactivatingPanel` **severs** the first: clicking the panel makes it the key
window (so the `NSTextView`/`TextEditor` receives keystrokes) **without**
activating our app. Our app stays `.accessory` (no Dock icon, no menu bar), and
the user's frontmost app keeps activation — its menu bar and Dock focus are
untouched. The notch panels never exercise this because they force
`canBecomeKey=false`; the notepad is the deliberate exception.

This combo is the conventional way HUD/palette utilities (Spotlight-like
overlays, floating inspectors) take text input from a background/agent app, so on
**normal spaces** it is low-risk and well-understood.

### 6.2 What could break it *inside the CGS space*

The unknown is **stacking the CGS reparenting on top of the focus trick**.
`CGSAddWindowsToSpaces` moves the window into a private window-server space at
absolute level `Int32.max`. Plausible failure modes:

1. **Key-window-must-be-in-active-space rule.** The window server may only grant
   key status to a window in the *currently active* space. The notch space is
   *shown above* (`CGSShowSpaces`) but is **not** the user's active space. If
   that rule applies, clicking the panel may fail to make it key → caret never
   appears, keystrokes go nowhere. (This is the most likely failure.)
2. **Hit-testing / event routing.** Even if key is granted, mouse-down and
   keyboard events must route correctly through the reparented window; the caret
   must draw/blink in a foreign space.
3. **Activation leak.** Some interaction with the private space could nudge the
   app toward activation (menu-bar flicker / `NSApp.isActive` flipping true),
   defeating the "don't steal foreground" requirement.
4. **Fullscreen interaction.** Over another app's *native* fullscreen space the
   above must still hold — fullscreen spaces are themselves separate spaces.

The notch never hits any of these because it never wants key focus. Hence the
load-bearing spike.

---

## 7. GO / NO-GO criteria

Run `harness/` and compare **Mode A (floating)** vs **Mode B (CGS space)**.

**GO — ship `.notepadFloatStrategy = .cgsSpace`** iff, in **Mode B**:
1. you can click into the editor and type; caret blinks; characters appear;
2. `notepad.isKey` shows `YES` while typing;
3. `Frontmost` stays your other app (Safari/Notes), not the harness;
4. `ourApp.isActive` stays `no` (never the red `YES`); menu bar/Dock unchanged;
5. the panel floats above a native-fullscreen app.

**NO-GO — ship the fallback `.notepadFloatStrategy = .floating`** if, in
**Mode B**, any of: cannot type / no caret (criterion 1–2 fail), or `Frontmost`
flips to the harness / `ourApp.isActive` turns red `YES` (3–4 fail), or it fails
to float over fullscreen (5 fail).

Because the strategy is a `Defaults` switch, NO-GO is a one-line ship decision,
not a rewrite.

---

## 8. Documented fallback

If NO-GO, leave the panel **out** of the CGS space and rely on:

- `level = .mainMenu + 2` (above menu bar/Dock), and
- `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`.

Text focus is well-understood here (normal spaces), so criteria 1–4 are safe.
The **trade-off**: a high-level floating panel may not float above *another app's
native fullscreen space* as reliably as the max-level CGS space does
(`.canJoinAllSpaces` shows it on most spaces incl. many fullscreen cases, but the
CGS absolute-level approach is the bulletproof one boring.notch uses). If
Mode A passes 1–4 but fails 5, that lost over-fullscreen capability is the
accepted cost of guaranteed focus — and is exactly what the harness lets you
observe before committing.

---

## 9. Validation status of the harness

- `swiftc -O harness/main.swift -o harness` → **exit 0** (Command Line Tools,
  Swift 6.2.1, no Xcode).
- Launches without crashing in **both** modes (clean SIGALRM on timeout, no
  abort/segv).
- **Mode B at runtime actually creates the max-level CGS space** and inserts the
  panel via the replicated `@_silgen_name` symbols — confirming the private-API
  path links and runs.
- The remaining checks (does focus land? does activation leak?) are inherently
  visual/behavioral and are what **you** verify via `harness/README.md`'s
  checklist. The toolchain confirms it builds and runs; your eyes confirm the
  focus model.
