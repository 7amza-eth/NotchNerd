# Phase 0 — De-risk preservation (verification checklist)

**Goal:** prove that dropping the App Sandbox does **not** regress boring.notch's existing features — *before* any agent/notepad work. Run these on your Mac with full Xcode installed (the agent environment here only has Command Line Tools, so it could not build/run).

## What changed in the tree (already applied by Phase 0)
- `boringNotch/boringNotch.entitlements`: `com.apple.security.app-sandbox` → **`false`**; removed the now-dead Sparkle `-spks`/`-spki` `temporary-exception.mach-lookup.global-name` entries. (Kept hardened runtime, `automation.apple-events`, camera, calendars, network, Music/Spotify AppleEvents exception.)
- `boringNotch/Info.plist`: removed `SUEnableDownloaderService` + `SUEnableInstallerLauncherService` (sandbox-only Sparkle XPC shims). Kept `SUFeedURL` + `SUPublicEDKey`.
- `boringNotch.xcodeproj/project.pbxproj`: broadened `INFOPLIST_KEY_NSAppleEventsUsageDescription` to mention controlling terminals/IDEs.
- Branch: `notchnerd` (upstream `origin` renamed to `upstream`).

## Pre-req: stable dev signing (do this FIRST)
```sh
zsh notchnerd/scripts/setup-dev-signing.sh
```
Then in Xcode set target **boringNotch** → Signing & Capabilities → Signing Certificate = **"NotchNerd Dev"** (Manual). This keeps Automation/Accessibility grants stable across rebuilds.

## Build
```sh
xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration Debug build
```
- [ ] **Builds clean** with the sandbox off.
- [ ] `codesign -d --entitlements - --xml $(...)/boringNotch.app` shows `app-sandbox = false`, hardened runtime still on.

## Regression — the music player (HIGHEST priority; this is the feature we must not break)
The risk: `MediaRemoteAdapter.framework` is entitled to talk to the private MediaRemote framework; re-signing with the sandbox off must not strip that. Failure is **silent** (debug assertion only), so check explicitly.
- [ ] Play a track in **Apple Music** → now-playing title/artist/artwork appears in the notch, transport controls work.
- [ ] Repeat in **Spotify** (AppleScript controller) — first run will prompt for Automation consent; approve it.
- [ ] If you use a browser/"NowPlaying" source: confirm `mediaremote-adapter.pl` still streams (the notch updates on track change). If now-playing is blank, run the adapter `test` to see if MediaRemote is functional on your OS build.
- [ ] Media-key HUD replacement (if you use it) still works via the XPC helper.

## Regression — Sparkle auto-update (re-qualify after removing the XPC shims)
- [ ] App launches without Sparkle errors in Console.
- [ ] **Check for Updates…** reaches the appcast and shows update state.
- [ ] (When a real update exists) the full **download → install → relaunch** cycle completes. *The EdDSA `SUPublicEDKey` is load-bearing — if signature verification fails, auto-update is broken.*

## Regression — other boring.notch features
- [ ] **Camera "Mirror"** opens (camera permission prompt OK).
- [ ] **Calendar/Reminders** events show (calendar permission prompt OK).
- [ ] **File Shelf** + AirDrop drag/drop works.
- [ ] **HUD replacement** (volume/brightness) works (XPC helper + Accessibility).
- [ ] Notch **floats over a fullscreen app** (CGSSpace path intact).
- [ ] Multi-display: notch appears on the right screen(s).

## Confirm the unsandbox actually unlocked the agent prerequisites
These must now succeed from within the running app (they were blocked under the sandbox):
- [ ] App can **read** `~/.claude/settings.json` and `~/.claude/projects/`.
- [ ] App can **write** to `~/.claude/settings.json` (hook install target).
- [ ] App can spawn `/bin/ps`, `/usr/sbin/lsof`, `/usr/bin/osascript`, `/usr/bin/open`.
- [ ] App can bind a Unix domain socket under `~/Library/Application Support/`.

## Exit criteria
✅ Sandbox off, music + Sparkle + camera + calendar + shelf + HUD + over-fullscreen all green, stable dev signing in place, and the four agent-prereq operations succeed. **Only then proceed to Phase 1 (vendor the engine).**

> If MediaRemoteAdapter loses its entitlement after the unsandboxed re-sign (now-playing dies), STOP — that's the one true blocker for this direction; ping me and we'll route media through the existing non-sandboxed XPC helper instead.
