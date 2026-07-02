# NotchNerd

A macOS menu-bar app that turns the notch into a live workspace — music, a file shelf, calendar,
and system HUDs in the notch you already have, plus a **Claude Code agent monitor** and an
**always-open notepad** that floats over everything.

NotchNerd is a fork of [boring.notch](https://github.com/TheBoredTeam/boring.notch) by TheBoredTeam,
extended with a vendored slice of [Open Island](https://github.com/Octane0411/open-vibe-island) by
Octane0411. It keeps the whole boring.notch experience and adds an opinionated set of features on
top: a notch surface that watches your local Claude Code sessions, and a notepad that can take
keyboard focus without stealing your frontmost app.

> Personal fork, early/alpha, no warranty. It's GPL v3 and open — use it, but expect rough edges.

## Features

**Inherited from boring.notch**

- **Music notch** — now-playing with album art, a marquee, scrubber, control slots, volume,
  favorites, and synced lyrics (Apple Music, Spotify, YouTube Music, and any Now Playing source),
  with selectable **music-visualizer presets** (Equalizer / Spectrum / Sound Bars + a classic
  "Visualizer 4").
- **File shelf** — drag files into the notch, then drag them out or AirDrop/share them.
- **Calendar** — your upcoming events in the open notch.
- **System HUDs** — replaces the stock macOS volume / brightness / backlight / mic and battery
  overlays with notch-native ones.
- **Webcam mirror** and closed-notch **live activities**.

**New in NotchNerd — the Claude Code agent monitor**

An in-notch **Agent tab** that watches your local Claude Code sessions through Claude Code hooks.
It is **observe-only** — it never calls the Anthropic API and stores no credentials.

- **Live session list as a recap, not a transcript** — each row shows the session's goal (its first
  prompt), a one-line recap of the latest outcome (`Claude: …`) or current activity **with a
  per-activity icon** (thinking · terminal · editing · searching), plus identity chips:
  **branch · terminal · model · permission-mode · Resumed/Cleared**, and a `k/n` task-progress
  badge. Sessions that need you are pinned to the top; interrupted turns show a red **stopped**
  badge instead of masquerading as done.
- **Click any session to expand it** — Claude's **full last message** (with a copy button), the
  live subagent/task checklists, **recent tool activity**, **files touched**, and a stats line:
  turns · output tokens · **current context size** (`ctx 341k`). Expansion survives the notch
  closing and reopening.
- **Only what's actually running** — the list tracks the sessions live in your terminals (matched by
  TTY), so `/clear`'d, finished, and closed-tab sessions drop automatically instead of piling up.
- **Plan-mode review in the notch** — when Claude presents a plan, the card shows the **plan text
  itself** and the same choices as the CLI ("use auto mode" / "auto-accept edits" / "manually
  approve edits"), plus **"keep planning" with feedback** — type what to change and Claude revises
  without leaving plan mode. (Ultraplan hands off to the terminal.)
- **Waiting-on-subagents at a glance** — a session blocked on research/workflow agents shows
  "N agents researching" instead of looking frozen.
- **Permission prompts in the notch** — Allow once / Deny, plus Claude's structured one-tap options
  ("always allow Bash here", mode changes) when offered.
- **Question prompts in the notch** — answer Claude's `AskUserQuestion` with full support for
  **multiple questions, multi-select, freeform answers, and ASCII/code option previews**.
- **Closed-notch status** — a compact indicator shows when Claude is **working** (mid-turn) vs
  **active** (open but idle) vs **needs you**, coexisting with the music notch (it rides the
  visualizer slot when music is playing). See [**What the notch shows you**](#what-the-notch-shows-you)
  below for how to read the sparkle colors at a glance.
- **Usage HUD** — optional 5h / 7d quota chips, read from Claude Code's local statusline (Pro/Max).
- **Notification mode** — optionally pop the notch (with an optional sound) when a session needs a
  permission/answer or finishes.
- **Terminal jump** — one tap to focus the **Ghostty** or **Terminal.app** session running an agent.
- **Hook self-check** — Settings → Agent diagnoses broken/stale hook installs and offers a one-tap
  repair.

**New in NotchNerd — the Notepad**

- **Always-open Notepad** — a floating, multi-note scratchpad (and an in-notch Notes tab) that takes
  keyboard focus **without** activating the app, so it never interrupts what you're doing. Notes
  autosave to disk and survive restarts.

**New in NotchNerd — getting set up**

- **First-run onboarding wizard** — walks you through permissions and your music source, with an opt-in
  step to enable the agent monitor (it installs the hooks for you), and ends with a short **feature
  tour** you can replay anytime (menu-bar **✦** → *Feature Tour*, or Settings → General).
- **A full Settings window** — menu-bar **✦** → *Settings* (or ⌘,): a grouped sidebar for every surface
  (Media, Calendar, Shelf, Notepad, Webcam, HUDs, Battery, Agent, Appearance, Shortcuts), plus
  reset-to-defaults.

## What the notch shows you

The closed notch is a single strip with three zones: a **left slot** (album art), the **hardware
notch** itself (the black cutout over the camera), and a **right slot** (visualizer / Claude status).
What lands in each zone depends on what's happening — here's how to read it. (All the Claude bits
below only ever appear once the monitor is on; it's off by default and observe-only.)

The one rule that explains most of it: **Claude never pushes your music off the notch.** When a
track is playing, Claude's status rides the right-hand visualizer slot instead of taking over —
album art and title never disappear. Only when there's *no* music does Claude get the whole strip.
(Transient system HUDs — battery, volume, brightness — are the one thing that can briefly take the
notch from music; Claude never does.)

### music only

A track is playing (or paused-but-not-idle) and Claude is quiet:

```
   [ ♫ album ]  ▓▓▓▓▓▓  ≋≋≋
        art      notch   spectrum
```

The right slot is your music-visualizer (spectrum bars, or your chosen preset).

### Claude working — no music

A session is mid-turn (Claude is "cooking"). The whole strip is Claude's:

```
   ✦  ▓▓▓▓▓▓  ●
  purple        blue dot
 (pulsing)
```

A **purple pulsing ✦** hugs the left edge of the notch; a **blue dot** sits on the right (with a
count if more than one session is running). "Working" means *actively mid-turn* — and it is **not**
time-gated, so a long, silent "thinking" stretch still counts as working (it won't flip off just
because Claude went quiet for a minute).

If sessions are live but idle between turns, the same indicator turns **green** instead — a calm
"active" presence rather than a pulsing "working" one:

```
   ✦  ▓▓▓▓▓▓  ●
  green         green dot
```

### Claude needs you — no music

A session is blocked on a permission prompt or a question:

```
   ✦  ▓▓▓▓▓▓  2 need you
 purple
(pulsing)
```

A **pulsing ✦** on the left, and **"N need you"** spelled out on the right (a single waiting session
reads "1 needs you"). This one is **persistent** — it never auto-expires; it stays until you answer
(and that session is pinned to the top of the Agent tab). Needs-you outranks working/active, so
you'll always see the words "need you" rather than a bare dot when something is waiting.

### music *and* Claude working

Music wins the notch; the working session rides the right slot, replacing the spectrum:

```
   [ ♫ album ]  ▓▓▓▓▓▓  ✦
        art      notch   purple
```

Album art and track stay put — only the visualizer slot changes to a **purple ✦**.

### music *and* Claude needs you

Same idea, but now the right slot carries the alert — in **orange**, to stand out from the purple
"working" sparkle, with the "need you" text inline:

```
   [ ♫ album ]  ▓▓▓▓▓▓  ✦ 2 need you
        art      notch   orange
```

Music keeps playing; the notch just grows on the right to fit the label. Claude never shoves your
music aside.

### the needs-you notification (optional)

If notifications are on, the moment a session needs a permission/answer the notch can **pop open
straight to the Agent tab** (with an optional sound). The guard rails:

- It pops **only from a closed notch** — it will *never* hijack a notch you already opened for music,
  the shelf, or the notepad. If the notch is already open, the live Agent tab just updates in place.
- It's **suppressed if the session's Ghostty window is already frontmost** (you're already looking
  at it). This is best-effort and **Ghostty-only** — a frontmost Terminal.app session is not
  suppressed — and it's a toggle (`agentSuppressWhenFrontmost`, on by default).
- **Permission and question pops stay until you answer them.** A "finished" pop auto-collapses after
  ~10 seconds.
- Auto-open and sound are independent toggles — you can have a quiet indicator only, a sound only, or
  the full pop.

### quick reference

| right slot / sparkle | meaning |
| --- | --- |
| spectrum bars (no ✦) | music playing, Claude quiet |
| **purple ✦** + blue dot | Claude **working** (mid-turn) |
| **green ✦** + green dot | session(s) live but **idle** ("active") |
| **purple ✦** + "N need you" | a session **needs you** (no music) |
| **purple ✦** in the music slot | Claude **working** while music plays |
| **orange ✦** + "need you" in the music slot | a session **needs you** while music plays |

Mnemonic: **pulsing = something's happening**, **green = calm/idle**, and the words **"need you"**
(orange when riding music) always mean *you're being asked something*.

### the open Agent tab

Tap the notch and switch to **Agent** for the full picture. Each session is a recap row — its goal,
a one-line recap of the latest outcome, and identity chips (**branch · terminal · model ·
permission-mode**) so same-repo sessions stay distinct, plus a `k/n` task badge. Sessions that need
you are **pinned to the top**. When Claude asks for something you answer it right there: a
**permission** prompt shows an orange Allow/Deny card (plus Claude's structured one-tap options, like
"always allow Bash here", when offered); a **question** shows a yellow card that handles multiple
questions, multi-select, freeform answers, and ASCII/code previews. The arrow button **jumps to the
session's terminal** (Ghostty / Terminal.app) — that one needs the Automation permission.

## Requirements

- **macOS 14.0 (Sonoma) or later**
- **Full Xcode** (not just the Command Line Tools) to build from source — the build runs a Swift
  package build step for the embedded agent-hook CLI.

## Build from source

```sh
git clone git@github.com:7amza-eth/NotchNerd.git
cd NotchNerd

# (optional but recommended) create a stable self-signed dev identity so macOS
# Automation/Accessibility permission grants survive rebuilds:
zsh tooling/scripts/setup-dev-signing.sh

# build
xcodebuild -project NotchNerd.xcodeproj -scheme NotchNerd -configuration Debug -derivedDataPath build build
```

Swap `-configuration Release` for a release build. You can also just open `NotchNerd.xcodeproj` in
Xcode and run the `NotchNerd` scheme.

Notes:

- The build embeds an agent-hook helper CLI by running `swift build` as part of the app build, so a
  working Swift toolchain (i.e. full Xcode) is required.
- The app is **not sandboxed** (required for media control and the float-over-fullscreen notch), so
  it is not distributable via the Mac App Store.
- Signing is **ad-hoc** out of the box. Releases can be Developer-ID signed + notarized by configuring
  the secrets in [`RELEASING.md`](RELEASING.md) — the release workflow does it automatically when they exist.

## Install a prebuilt build

Prebuilt downloads are attached to each [GitHub Release](https://github.com/7amza-eth/NotchNerd/releases).

**If the release is notarized** (the install notes on the release will say so):

1. Download **`NotchNerd.dmg`**, open it, and drag **`NotchNerd.app`** into `/Applications`.
2. Launch it — no Terminal step needed.

**If the release is an ad-hoc build** (not notarized), macOS Gatekeeper blocks it on first download —
**the `.zip` is the smoothest path** (a downloaded `.dmg` silently does nothing on double-click until
its quarantine is cleared):

1. Download **`NotchNerd.zip`** from the latest release and double-click to unzip.
2. Drag **`NotchNerd.app`** into `/Applications`.
3. Clear the quarantine flag and launch:

   ```sh
   xattr -dr com.apple.quarantine /Applications/NotchNerd.app
   open /Applications/NotchNerd.app
   ```

   Prefer the `.dmg`? Clear *its* quarantine first, then it mounts:

   ```sh
   xattr -dr com.apple.quarantine ~/Downloads/NotchNerd.dmg && open ~/Downloads/NotchNerd.dmg
   ```

After the first install, **updates are automatic** (Sparkle, EdDSA-signed) — no re-downloading or
re-`xattr`. (Auto-updates verify a signature rather than Gatekeeper.)

## First run & permissions

NotchNerd is a menu-bar app — look for its **✦ icon in the menu bar**, not the Dock. On first launch a
short **onboarding wizard** walks you through setup: a welcome screen, one card per permission, a quick
music-source pick, a heads-up about the **Automation** prompt, and an opt-in step to turn on the Claude
Code agent monitor (which installs its hooks for you). Every step is skippable, and it ends by offering
the feature tour.

The permissions, all requested only when needed (the app is unsandboxed):

- **Accessibility** — to replace the system HUDs and for media-key / gesture handling.
- **Automation** — to control your music app and jump into Ghostty / Terminal.app (asked the first time
  it's needed, not up front).
- **Camera / Calendar / Reminders** — for the webcam mirror and the calendar widget (optional).

Re-grant or revoke any of these later in **System Settings → Privacy & Security**.

## Settings & the menu-bar icon

Click the menu-bar **✦** for the quick menu: open **Settings** (⌘,), pop out the **Notepad**, replay the
**Feature Tour**, **Check for Updates**, or restart / quit.

**Settings** is a normal window with a grouped sidebar:

- **General / Appearance** — displays, notch sizing, gestures, the menu-bar icon, accent color, the
  notch tab strip, and *Replay feature tour…*.
- **Notch features** — Media, Calendar, Shelf, Notepad, Webcam, HUDs, Battery, and **Agent** (enable
  monitoring, install / repair hooks, notifications, sounds, the usage HUD).
- **Advanced + About** — Shortcuts (hotkeys), window behavior, and **Reset all settings to defaults**
  (which leaves your notes and shelf files untouched).

Hidden the menu-bar icon? Turn on **Appearance → "Show settings icon in notch"** to open Settings from a
gear inside the open notch instead.

## The agent monitor is off by default

The Claude Code monitor does nothing until you turn it on. Open **Settings → Agent**, enable
monitoring, and install the Claude Code hooks from there. Your existing `~/.claude/settings.json` is
backed up first and the install is fully reversible — **Remove hooks** in the same pane restores it.
Until then the bridge never starts, and no changes are made to your settings. The Agent tab is
visible by default but simply shows "no active sessions" while monitoring is off. The onboarding wizard
offers this same one-tap enable + hook install as an opt-in step, so if you turned it on there, it's
already running.

## Documentation

- [`spec.md`](./spec.md) — the single canonical doc: architecture, data flow, key files, and gotchas
  (Part I) + roadmap, decision log, TODO, and deferred-work reference (Part II).
- **[Releases](https://github.com/7amza-eth/NotchNerd/releases)** — the changelog: what's new in each
  version, with prebuilt builds attached.

## Credits & license

NotchNerd is licensed under the **GNU General Public License v3** (see [`LICENSE`](./LICENSE)).

It stands on two GPL v3 projects:

- **[boring.notch](https://github.com/TheBoredTeam/boring.notch)** by **TheBoredTeam** — the notch
  shell (music, shelf, calendar, HUD, webcam) that NotchNerd is forked from.
- **[Open Island / open-vibe-island](https://github.com/Octane0411/open-vibe-island)** by
  **Octane0411** — the agent-monitoring engine (`OpenIslandCore` + the hook CLI), vendored under
  `Vendor/OpenIslandEngine/` (see [`Vendor/OpenIslandEngine/VENDORED-FROM.md`](./Vendor/OpenIslandEngine/VENDORED-FROM.md)
  for provenance and the NotchNerd patches applied to it).

Because both upstreams are GPL v3, the combined work is GPL v3.

Additional bundled components and their licenses are listed in
[`THIRD_PARTY_LICENSES`](./THIRD_PARTY_LICENSES).
