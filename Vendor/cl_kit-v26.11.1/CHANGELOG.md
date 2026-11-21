# Changelog

All notable changes to cl_kit are listed here, newest first. Calendar versions, `YY.M.R`, tagged `vYY.M.R` (see README ▸
Versions and release).

## 26.11.1

The first release: cl_audit's `Core/`, `Run/` and `Auth/` move here with their history, exactly as in cl_audit
26.11.79 (7444e6f), with the shared sign-in it took from cl_quick.

- **ProfileCore** (`Core/`), **Runs** (`Run/`) and **ClaudeAuth** (`Auth/`) as they were in cl_audit, including
  `Run/ProcessTable.swift`, `Auth/StoredSignIn.swift` and **ClaudeSignIn** (`Auth/ClaudeSignIn.swift`), the sign-in in a
  Terminal window shared by both apps.
- **The Keychain is optional.** ClaudeAuth reads a stored sign-in only through `StoredSignInReader`; `Auth/Keychain.swift`
  is the one file that reads the Keychain, and an app can build without it.
- **Build:** `scripts/build.sh` (`--no-keychain`) and `scripts/modules.sh`, the build recipe apps source from their vendored
  copy: static libraries in layers, Swift 5 language mode, macOS 13.
- **Checks:** the core, runs, auth and claudesignin suites from cl_audit, and a new `nokeychain` suite (ClaudeAuth builds
  without `Auth/Keychain.swift` and names no Security API), all through `Checks/run.sh`, on every pull request and push in CI.
