## Install (testers)

This build is **not notarized** (no Apple Developer ID secrets were configured for the release), so macOS Gatekeeper blocks it on first download. **The `.zip` is the smoothest path:**

1. Download **`NotchNerd.zip`** below and double-click to unzip.
2. Drag **`NotchNerd.app`** into your **/Applications** folder.
3. Open **Terminal** and run:
   ```
   xattr -dr com.apple.quarantine /Applications/NotchNerd.app
   ```
4. Launch it. NotchNerd is a **menu-bar app — no Dock icon**; look at your menu bar / the notch.
5. Grant **Accessibility** + **Automation** when prompted (System Settings → Privacy & Security).

> Prefer the `.dmg`? A downloaded DMG double-clicks to **nothing** until you clear its quarantine. In Terminal:
> ```
> xattr -dr com.apple.quarantine ~/Downloads/NotchNerd.dmg && open ~/Downloads/NotchNerd.dmg
> ```
> …then drag the app to /Applications and run step 3.

> [!NOTE]
> To ship a build that opens without these steps, configure the Developer ID + notarization secrets documented in [`RELEASING.md`](https://github.com/7amza-eth/NotchNerd/blob/main/RELEASING.md). With those set, releases are signed, notarized, and stapled automatically.

The Claude Code agent monitor is **off by default** — enable it in **Settings → Agent**. Once installed, future versions update automatically.
