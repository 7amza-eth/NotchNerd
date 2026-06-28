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
  prompt), a one-line recap of the latest outcome (`Claude: …`) or current activity, plus identity
  chips: **branch · terminal · model · permission-mode**, and a `k/n` task-progress badge. Sessions
  that need you are pinned to the top.
- **Only what's actually running** — the list tracks the sessions live in your terminals (matched by
  TTY), so `/clear`'d, finished, and closed-tab sessions drop automatically instead of piling up.
- **Permission prompts in the notch** — Allow once / Deny, plus Claude's structured one-tap options
  ("always allow Bash here", mode changes) when offered.
- **Question prompts in the notch** — answer Claude's `AskUserQuestion` with full support for
  **multiple questions, multi-select, freeform answers, and ASCII/code option previews**.
- **Closed-notch status** — a compact indicator shows when Claude is **working** (mid-turn) vs
  **active** (open but idle) vs **needs you**, coexisting with the music notch (it rides the
  visualizer slot when music is playing).
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

NotchNerd is a menu-bar app — look for its icon in the menu bar, not the Dock. To use everything,
grant these in **System Settings → Privacy & Security**:

- **Accessibility** — for the media-key and gesture handling.
- **Automation** — to control your music app and to jump into Ghostty / Terminal.app.

Both are requested only when needed, and the app runs unsandboxed.

## The agent monitor is off by default

The Claude Code monitor does nothing until you turn it on. Open **Settings → Agent**, enable
monitoring, and install the Claude Code hooks from there. Until then the bridge never starts, and no
changes are made to your `~/.claude/settings.json`. The Agent tab is visible by default but simply
shows "no active sessions" while monitoring is off.

## Documentation

- [`spec.md`](./spec.md) — the single canonical doc: architecture, data flow, key files, and gotchas
  (Part I) + roadmap, decision log, TODO, and deferred-work reference (Part II).

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
