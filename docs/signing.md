# Signing and notarizing cl_audit

cl_audit is signed **ad hoc** today: a download needs **Open Anyway** once in System Settings ▸ Privacy & Security. The
release can sign it with a **Developer ID** and have Apple **notarize** it instead, so it opens like any other app. The
scripts are ready; what's missing is the certificate and the notary credentials, which only the account holder can make.
Nothing changes until they exist: with the two settings below unset, `build.sh` and `scripts/release.sh` run exactly as
before.

## The two settings

| Setting | What it is | Unset |
|---|---|---|
| `CL_SIGN_ID` | The Developer ID Application identity, as `security find-identity -v -p codesigning` lists it: its 40-character SHA-1 (best: after a renewal two certificates share one name), or its whole name `Developer ID Application: Your Name (TEAMID)`. Only an exact match on a Developer ID Application line counts | Ad hoc, as today |
| `CL_NOTARY_PROFILE` | The name of a notarytool keychain profile, for example `cl-notary` | No notarization |

`CL_NOTARY_PROFILE` needs `CL_SIGN_ID` (Apple notarizes Developer ID signatures only); a release with only the profile set
stops before its release commit. Both are environment variables on this Mac, never in the repository or in CI: releases
run here, and the certificate's private key and the notary password stay in this Mac's Keychain.

Before a release, check the set-up (signs nothing, changes nothing):

```bash
CL_SIGN_ID="Developer ID Application: Your Name (TEAMID)" CL_NOTARY_PROFILE=cl-notary scripts/release.sh --check-signing
```

It says whether the identity is in the Keychain and whether the profile answers (one call to Apple's notary service), and
lists what it would sign, in order. `./build.sh --check-signing` prints the same.

A release with both:

```bash
CL_SIGN_ID="Developer ID Application: Your Name (TEAMID)" CL_NOTARY_PROFILE=cl-notary scripts/release.sh --push
```

## What the scripts do with them

`build.sh` signs inside out, each piece before the bundle that seals it, never with `--deep`, with the identifiers the
build always used (`scripts/signing.sh` holds the order):

1. `Contents/Helpers/cl_audit-agent`, the agent's launcher (identifier `local.usage-n-uf-agent-launcher`)
2. `Contents/Library/LoginItems/cl_audit Agent.app`, the agent, with `Signing/cl_audit.entitlements`
3. `Contents/PlugIns/cl_audit Widget.appex`, the widget, with `Widget/widget.entitlements`
4. `Contents/PlugIns/Dock Tile.docktileplugin`, the Dock tile plug-in
5. `cl_audit.app`, with `Signing/cl_audit.entitlements`

With `CL_SIGN_ID` each is signed `--options runtime --timestamp` (the hardened runtime and a secure timestamp, which
notarization requires; the timestamp needs the network during the build). Without it, each is signed
`codesign --force --sign -` as before.

`scripts/release.sh --push`, before anything is pushed (a failure leaves the release commit and tag local, as today):

1. builds the app and checks its signature is the Developer ID's with the hardened runtime;
2. zips it and sends the zip to Apple: `xcrun notarytool submit … --keychain-profile "$CL_NOTARY_PROFILE" --wait`.
   Anything but **Accepted** stops the release, with the command that shows Apple's log;
3. staples the ticket into the app (`xcrun stapler staple`) and zips the stapled app again;
4. makes the disk image from the stapled app, signs it, notarizes it and staples it;
5. checks what a downloader's Mac will say: `spctl -a -vv -t exec` on the app, `spctl -a -vv -t open
   --context context:primary-signature` on the disk image, `xcrun stapler validate` on both, and (as today) the same
   code directory hash in the zip's and the image's app, and `codesign --verify --deep --strict` on the image's;
6. writes the release notes without the Open Anyway step, then pushes and publishes as today.

## Entitlements under the hardened runtime

The hardened runtime blocks a few things unless an entitlement allows them. What cl_audit does, checked one by one:

| What cl_audit does | Under the hardened runtime | Entitlement |
|---|---|---|
| Sends the profile's Claude window one "open location" Apple Event after a restore (`WindowLink`, `SwitchSidebar.swift`) | Blocked without the entitlement | `com.apple.security.automation.apple-events` in `Signing/cl_audit.entitlements`, for the app and the agent (the same program). macOS still asks the Automation question first (`NSAppleEventsUsageDescription`) |
| Runs `claude`, `git`, `codesign`, `iconutil`, `lsregister` and other tools | Allowed: they are separate programs with their own signatures | None |
| Reads Claude Code's Keychain item | Done by `/usr/bin/security find-generic-password` (cl_kit `Auth/Keychain.swift`), not in cl_audit's own process | None |
| The agent as a login item (`SMAppService`), notifications, the widget's reloads | Allowed | None |
| Loads code | Only Apple's frameworks; cl_kit's modules are linked in statically. No `dlopen`, no plug-ins loaded by cl_audit itself (the Dock loads the Dock tile plug-in) | None (library validation stays on) |
| JIT, unsigned memory, DYLD variables, debugging | Not used | None |

The widget keeps its own `Widget/widget.entitlements`: the App Sandbox (WidgetKit requires it) and one read-only
exception for `~/Library/Application Support/usage-n-uf/`. A `temporary-exception` entitlement is allowed for Developer
ID apps outside the Mac App Store and needs no provisioning profile; notarization accepts it.

**App groups:** none are used. The widget reads the agent's folder through its exception, and the apps share
preferences by their own bundle identifiers, so no team ID prefix is needed. If one is ever added: on macOS 15 and later
a Developer ID app's group must be named `TEAMID.something` (the `group.` form needs a provisioning profile), or macOS
asks the user each time.

**Bundle identifiers** stay as they are (`local.usage-n-uf` and its helpers). A Developer ID signature doesn't need them
registered with Apple.

## The Dock icon apps

A profile's Dock icon app is a copy of cl_audit.app made on the user's Mac, with its own name, icon and Info.plist, and
signed there ad hoc (`Installer.install`, `Config.swift`). That stays as it is: the copy is made locally, its download
mark is removed, so Gatekeeper never checks it, and an ad hoc copy has no hardened runtime and needs no entitlements.

## What users see once, when the signature changes

The first notarized release replaces an ad hoc signature (identified by its code hash) with a Developer ID one
(identified by its team). macOS treats it as a new identity once:

- **Automation:** "cl_audit wants to control Claude" comes again, the first time a restore sends its link; and "cl_audit
  wants to control Terminal", the first time a sign-in opens Terminal through `osascript` (cl_kit's `ClaudeSignIn`).
- **Background item:** macOS shows "Background Items Added" again for the agent (System Settings ▸ General ▸ Login
  Items & Extensions), now with the developer's name instead of "cl_audit". From then on, updates signed by the same
  team don't ask again.
- **Keychain:** no new question. Claude Code's item is read through `/usr/bin/security`, so the item's access list names
  Apple's tool, not cl_audit; the "Always Allow" given to it stays.
- **Widget:** placed widgets may need to be added again if macOS doesn't recognise the re-signed extension at once
  (`build.sh` registers it on install; a download registers it at first launch).
- The release that brings the change should say so in its notes.

## Updates

cl_audit has no update framework (no Sparkle, no appcast). Updates are a new download from GitHub Releases
(`releases/latest/download/cl_audit.zip` or `.dmg`) or a build from source, so nothing else needs signing. Should an
update framework be added, its own helpers would be signed in the same inside-out order, before the app.

## Steps only the account holder can do

Done once, on this Mac. None of them can be done by a script: they need the Apple Account, its password and two-factor
sign-in. Never paste a password into a chat or a file.

### 1. Join the Apple Developer Program

1. Open <https://developer.apple.com/programs/enroll/> in Safari and click **Start Your Enrollment**.
2. Sign in with the Apple Account that will own the certificate (two-factor authentication must be on).
3. Choose **Individual / Sole Proprietor** (or **Organization**, which needs a D-U-N-S number), confirm the details and pay
   the yearly fee (99 USD).
4. Wait for the confirmation email (from minutes to two days). Then
   <https://developer.apple.com/account> ▸ **Membership details** shows the **Team ID**: ten characters, needed below.

### 2. The Developer ID Application certificate (Xcode)

1. Open **Xcode** ▸ **Settings…** (⌘,) ▸ **Accounts**.
2. Click **+** at the bottom left ▸ **Apple ID** ▸ **Continue**, and sign in with the same Apple Account.
3. Select the account ▸ select the team on the right ▸ **Manage Certificates…**.
4. Click **+** at the bottom left ▸ **Developer ID Application**. Xcode makes the key in this Mac's login Keychain and the
   certificate with Apple. Click **Done**.
5. Optional but wise: in **Keychain Access** ▸ login ▸ **My Certificates**, right-click "Developer ID Application: …" ▸
   **Export…** and keep the `.p12` with a strong password somewhere safe (not in a repository). Without it, a new Mac means
   a new certificate.

Only the account holder can make a Developer ID certificate, and a team can have only a few. Don't revoke it: apps signed
with a revoked Developer ID stop opening.

### 3. The identity string

In Terminal:

```bash
security find-identity -v -p codesigning
```

On the line with `"Developer ID Application: Your Name (TEAMID)"`, the 40-character hash before the name is the best
value for `CL_SIGN_ID`: when the certificate is renewed, the old and the new one share the name, and the hash still
names one. The whole name in the quotes works too. The list shows names and hashes only, no key.

### 4. An app-specific password for notarytool

1. Open <https://account.apple.com> ▸ **Sign-In and Security** ▸ **App-Specific Passwords** ▸ **+**.
2. Name it `cl_audit notary` and click **Create**. Copy the password it shows (once only).

### 5. The notary profile in the Keychain

In Terminal (it asks for the app-specific password and stores it in the login Keychain; nothing goes into a file):

```bash
xcrun notarytool store-credentials cl-notary --apple-id "you@example.com" --team-id "TEAMID"
```

Use the Apple Account's address and the Team ID from step 1. `cl-notary` is then the value for `CL_NOTARY_PROFILE`.
Check it:

```bash
xcrun notarytool history --keychain-profile cl-notary
```

An empty list is fine ("No submission history"); an error means the profile or the password is wrong.

### 6. Check, then release

```bash
CL_SIGN_ID="Developer ID Application: Your Name (TEAMID)" CL_NOTARY_PROFILE=cl-notary scripts/release.sh --check-signing
```

Both lines should say found / answers. The first signing may ask once whether codesign may use the key: **Always
Allow**. Then release as usual with the two settings in front of `scripts/release.sh --push`. They hold no secret
themselves.

Prefer setting them on the release command, not exporting them from a shell profile: with `CL_SIGN_ID` exported, every
local `./build.sh` signs with the Developer ID too. It then needs the network (Apple's timestamp server) and installs a
hardened build, which for example keeps a restore from sending its link until the Automation question is answered
again.

After the first notarized release, update README ▸ Install and the site's download text: the Open Anyway step goes away.
