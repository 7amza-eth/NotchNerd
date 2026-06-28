# Releasing NotchNerd

Releases are built by [`.github/workflows/release.yml`](.github/workflows/release.yml), triggered by
pushing a version tag (`git tag v0.1.1 && git push origin v0.1.1`) or via **Actions → Release → Run
workflow**.

The workflow has **two signing modes**, chosen automatically by which secrets exist:

| Mode | When | Result for downloaders |
|------|------|------------------------|
| **Notarized** (recommended) | The Developer ID secrets below are configured | App + DMG are Developer-ID signed, notarized by Apple, and stapled. Users download, drag to /Applications, double-click. No Terminal, no `xattr`. Accessibility/Automation grants persist across Sparkle updates. |
| **Ad-hoc** (fallback) | Those secrets are absent | Unsigned/un-notarized, exactly as before. Gatekeeper blocks it; testers must clear quarantine manually. |

If you do nothing, releases keep working in ad-hoc mode. To get notarized releases, add the secrets below.

## One-time setup for notarized releases

You need a paid **Apple Developer Program** membership ($99/yr).

### 1. Create a "Developer ID Application" certificate

- Xcode → **Settings → Accounts → Manage Certificates → ＋ → Developer ID Application**, **or** create
  one at <https://developer.apple.com/account/resources/certificates>.
- In **Keychain Access**, find the cert (with its private key), right-click → **Export** → save as
  `cert.p12` and set an export password.
- Base64-encode it for the secret:
  ```sh
  base64 -i cert.p12 | pbcopy
  ```

### 2. Create an app-specific password for notarization

- Sign in at <https://appleid.apple.com> → **Sign-In and Security → App-Specific Passwords → ＋**.
- Copy the generated password (format `xxxx-xxxx-xxxx-xxxx`).

### 3. Find your Team ID

- <https://developer.apple.com/account> → **Membership details → Team ID** (10 characters), or run
  `xcrun notarytool ... ` errors will also print it.

### 4. Add the repository secrets

**Settings → Secrets and variables → Actions → New repository secret:**

| Secret | Value |
|--------|-------|
| `MACOS_CERTIFICATE` | The base64 string from step 1 |
| `MACOS_CERTIFICATE_PWD` | The `.p12` export password from step 1 |
| `KEYCHAIN_PASSWORD` | Any throwaway string (used only for the ephemeral CI keychain) |
| `APPLE_TEAM_ID` | Your 10-character Team ID |
| `NOTARY_APPLE_ID` | The Apple ID email of your developer account |
| `NOTARY_PASSWORD` | The app-specific password from step 2 |

(`SPARKLE_PRIVATE_KEY` is a separate, already-documented secret used to sign the auto-update appcast.)

### 5. Cut a release

```sh
git tag v0.1.1
git push origin v0.1.1
```

Watch the **Release** action. In notarized mode it will:

1. Import the cert into an ephemeral keychain.
2. Build Release with Developer ID signing, hardened runtime, and a secure timestamp.
3. Verify the signature and assert `get-task-allow` is absent (notarization would otherwise reject it).
4. Notarize and staple `NotchNerd.app`, then package the `.zip` (Sparkle) and a signed+notarized `.dmg`.
5. Publish the GitHub Release with install notes matching the mode that ran.

## Notes

- **Why hardened runtime is forced in the workflow:** the Xcode project only enables it on the main app
  target; the workflow passes `ENABLE_HARDENED_RUNTIME=YES` on the build command so it also covers the
  bundled XPC helper. Notarization requires it on every executable.
- **`get-task-allow`:** Xcode injects this debug entitlement when ad-hoc signing. Building with a real
  Developer ID identity drops it; the workflow also hard-fails if it ever sneaks back in.
- **Alternative notary auth:** instead of `NOTARY_APPLE_ID` + `NOTARY_PASSWORD`, you can use an App
  Store Connect API key by swapping the `notarytool submit` flags to
  `--key`, `--key-id`, and `--issuer`. (The current workflow uses the app-specific-password method.)
- **App-specific password belongs to the account that signs.** Whoever's Developer ID signs the build is
  the developer of record that Apple and users see.
