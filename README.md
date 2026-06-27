# NotchNerd

A macOS menu-bar app that turns the notch into a live workspace — music, a file shelf, calendar,
and system HUDs in the notch you already have, plus a **Claude Code agent monitor** and an
**always-open notepad** that floats over everything.

NotchNerd is a fork of [boring.notch](https://github.com/TheBoredTeam/boring.notch) by TheBoredTeam.
It keeps the whole boring.notch experience and adds two things on top: a notch surface that watches
your local Claude Code sessions, and a notepad that can take keyboard focus without stealing your
frontmost app.

## Features

Inherited from boring.notch:

- **Music notch** — now-playing with album art, a marquee, a live audio visualizer, scrubber,
  control slots, volume, favorites, and synced lyrics (Apple Music, Spotify, YouTube Music, and any
  Now Playing source).
- **File shelf** — drag files into the notch, then drag them out or AirDrop/share them.
- **Calendar** — your upcoming events in the open notch.
- **System HUDs** — replaces the stock macOS volume / brightness / backlight / mic and battery
  overlays with notch-native ones.
- **Webcam mirror** and closed-notch **live activities**.

New in NotchNerd:

- **Claude Code agent monitor** — an in-notch Agent tab that watches your local Claude Code
  sessions via Claude Code hooks: session status, permission prompts you can **Allow Once / Deny**
  right from the notch, agent questions you can answer, and a one-tap **jump into the Ghostty
  terminal** running the session. A closed-notch indicator lights up when a session needs your
  attention. It is **observe-only** — it never calls the Anthropic API and stores no credentials.
- **Always-open Notepad** — a floating, multi-note scratchpad (and an in-notch Notes tab) that
  takes keyboard focus **without** activating the app, so it never interrupts what you're doing.
  Notes autosave to disk and survive restarts.

## Requirements

- **macOS 14.0 (Sonoma) or later**
- **Full Xcode** (not just the Command Line Tools) to build from source — the build runs a Swift
  package build step for the embedded agent-hook CLI.

There is no prebuilt download, Homebrew cask, or auto-update feed for this fork yet — build it from
source.

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
- The app is **not sandboxed** (this is required for media control and the float-over-fullscreen
  notch), so it is not distributable via the Mac App Store.
- Signing is ad-hoc out of the box (no team / no notarization configured).

## The agent monitor is off by default

The Claude Code monitor does nothing until you turn it on. Open **Settings → Agent**, enable
monitoring, and install the Claude Code hooks from there. Until then the bridge never starts. The
Agent tab is visible by default but simply shows "no active sessions" while monitoring is off.

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
  for provenance).

Because both upstreams are GPL v3, the combined work is GPL v3.

Additional bundled components and their licenses are listed in
[`THIRD_PARTY_LICENSES`](./THIRD_PARTY_LICENSES): MediaRemoteAdapter (BSD-3), NotchDrop (MIT),
Calendr / DynamicNotchKit (MIT), Parrot (MPL-2.0), and others.

