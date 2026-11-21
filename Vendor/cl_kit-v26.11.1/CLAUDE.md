cl_kit: the Swift modules shared by cl_audit and cl_quick (ProfileCore `Core/`, Runs `Run/`, ClaudeAuth `Auth/`). See README.md.

- Source only, built with `swiftc` (scripts/modules.sh); no SwiftPM, no Xcode project, no prebuilt binaries.
- Layers: ProfileCore never imports Runs or ClaudeAuth; Runs imports nothing of ours. Foundation only, no app's paths,
  words or global state, no logging. The suites' lints hold this; keep them passing, never weaken them.
- `Auth/Keychain.swift` is the only file that may name the Keychain, read only. cl_quick builds without it.
- Checks: `Checks/run.sh <suite>` for what you touched, under `~/.claude/bin/heavy.sh`. Suites use sample addresses
  (example.com), throwaway homes and stand-ins; never the real Keychain, Terminal preferences or Claude Code folders.
- Changes are pull requests with CI green and a review by another lane; merge with `--rebase`. A release is a PR that
  sets `VERSION` and adds a CHANGELOG entry, then main is tagged `v<VERSION>`. Tags are never moved or reused.
- Apps vendor a tag (`scripts/vendor.sh <tag>` in the app) and never edit their copy.
- Plain names: this is not a UI library.
