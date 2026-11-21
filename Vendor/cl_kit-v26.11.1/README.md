# cl_kit

> [!CAUTION]
> ## Not yet stable
>
> **cl_kit is young and still changing. Its types and functions are not final, and any release may change them.**
>
> Version numbers are dates (YY.M.R), not semantic versions. Read the [CHANGELOG](CHANGELOG.md) before moving an app to a
> newer tag.

The Swift modules shared by [cl_audit](https://github.com/n-uf/cl_audit) and [cl_quick](https://github.com/n-uf/cl_quick):
the rules for reading Claude Code's accounts and usage, the one way to run a program, and one folder's Claude Code
sign-in. Source only: each app copies a tagged release into its own repository, builds it in with `swiftc` and ships it in
its own release. Nothing here is a product of its own, and no prebuilt binaries are published.

| Folder | Module | What it holds | Imports |
| --- | --- | --- | --- |
| [`Core/`](Core/README.md) | ProfileCore | the account, usage and reading rules: ids, standby accounts, limits, headlines, what to show, times, parsing, the reader's state machine | Foundation |
| [`Run/`](Run/README.md) | Runs | the one runner (timeout, SIGTERM, a grace, SIGKILL; output read while it runs), a program kept running, the cleaned environment of a `claude` run, the process table | Foundation |
| [`Auth/`](Auth/README.md) | ClaudeAuth | one folder's Claude Code sign-in: which account, verified or guessed; the watch; renew and sign-out; ClaudeSignIn, the sign-in in a Terminal window followed to its outcome | Foundation, CryptoKit, ProfileCore, Runs |

The layers are ProfileCore → Runs → ClaudeAuth: ProfileCore never imports the others, Runs imports nothing of ours, and
ClaudeAuth sits on both. Every module is Foundation only (no AppKit or SwiftUI), carries no app's paths, words or global
state, and never logs. The suites' lints hold that.

## The Keychain is optional

`Auth/Keychain.swift` is the only file that reads the Keychain (read only, through `/usr/bin/security`). ClaudeAuth reaches
a stored sign-in only through `StoredSignInReader`, so an app that never reads the Keychain builds ClaudeAuth without that
file: cl_audit builds it in, cl_quick leaves it out. The `nokeychain` suite builds ClaudeAuth without it and checks that the
libraries name no Security API and no `security` tool.

## Build

macOS 13 or later on Apple silicon, Xcode's Swift toolchain (Swift 5 language mode). No SwiftPM or Xcode project: the
modules are static libraries built with `swiftc`, as both apps build them.

```bash
scripts/build.sh                 # build/libProfileCore.a, libRuns.a, libClaudeAuth.a and their .swiftmodule
scripts/build.sh --no-keychain   # the same without Auth/Keychain.swift
```

An app's own build sources `scripts/modules.sh` from its vendored copy and calls `kit_build OUT keychain|no-keychain [flags]`
and `kit_link OUT` (see the file's header).

## Checks

```bash
Checks/run.sh            # all suites: core, runs, auth, claudesignin, nokeychain
Checks/run.sh auth       # one suite
```

Each suite is compiled against its module only and runs with `HOME` at its own throwaway `Checks/.work/<suite>/home`. Nothing
reads the real Keychain, Terminal's preferences or Claude Code's folders: the suites use fakes and stand-ins (a stand-in
`claude auth login`, a stand-in Terminal) and sample addresses (`example.com`). CI (`.github/workflows/checks.yml`) builds
and runs every suite on each pull request and push to main.

## Use it in an app

Each app copies one tag into its repository and moves to a newer tag when it's ready:

```bash
scripts/vendor.sh v26.11.1   # in the app: copies the tag into Vendor/cl_kit-v26.11.1/ and points the build at it
```

- The copy is never edited in the app. A change is a pull request here, then a new tag, then `vendor.sh <new tag>` in each
  app that wants it.
- The app's CI runs this repository's suites on its vendored copy (`Vendor/cl_kit-<tag>/Checks/run.sh`), so what ships is
  what was checked.
- The app's release ships the modules inside it; cl_kit has no releases of its own beyond its tags.

## Versions and release

Calendar versions `YY.M.R`, tagged `vYY.M.R` (`R` restarts each month). A release is a pull request that sets `VERSION` and
adds a CHANGELOG entry; once it is merged with CI green, main is tagged `v<VERSION>`. Tags are never moved or reused.

## Licence

[PolyForm Perimeter 1.0.1](LICENSE), as cl_audit and cl_quick.
