# ClaudeAuth

The Claude Code sign-in of a profile's ONE folder, in one Swift module. It answers one question: which account is this
folder signed in to, and is that verified or guessed. Around it: the folder's Keychain item (its name, and reading it),
the watch for a changed sign-in, and Claude Code's own sign-in, renew and sign-out on the folder.

It sits beside ProfileCore (`Core/`), above it: it imports ProfileCore (`Login`, `AccountID`, `AccountIdentity`), and
ProfileCore never imports it (ProfileCore stays Foundation-only, with no Keychain and no processes). cl_audit builds it
as a static library after ProfileCore (`build.sh`, `Checks/run.sh`); the app links it, the widget doesn't. Later it
moves to its own repository with ProfileCore and cl_quick compiles it from source too.

| File | What it holds |
| --- | --- |
| `Folder.swift` | `AuthFolder`: the folder's path, default or not (`~/.claude` however spelled), its record (`.claude.json`), its Keychain item names (`Claude Code-credentials`, or `-` and 8 hex of the path's SHA-256), the environment a `claude` run on it gets (no key or other provider; `CLAUDE_CONFIG_DIR` set, or unset for the default folder), and `isReady` (there as a plain folder; never made) |
| `Identity.swift` | `SignedInAccount` from each source (`record`: guessed; `process`, a running claude's `initialize` account, and `server`, Anthropic's reply about the sign-in: verified), the one matching rule (`matches`), and `FolderSignIn.answer`: `verified`, `guessed`, `differs` or `none` |
| `Keychain.swift` | `KeychainSignIn.read`: the item through `/usr/bin/security`, read only, into `Login`'s named fields |
| `Watch.swift` | `RecordStamp` and `SignInChangeWatch`: another account signed in to the folder since the last look (signing out isn't a change) |
| `Runs.swift` | `ClaudeCommand`, `AuthRun` (renew's "Reply with OK." on Haiku, `claude auth logout`, the real runner), `SignInScript` (`claude auth login --claudeai --email` in Terminal) |
| `Authenticator.swift` | `Authenticator`: one folder's sign-in behind one type, with every tool in `AuthTools` (the Keychain tool, the runner, Terminal, the launch guard, the record reader, the environment); `RecordFile`, the bounded record read |

## Rules

- **One profile, one folder.** Nothing here makes a Claude Code folder (a run on a folder that isn't there as a plain
  folder starts nothing: `folderNotReady`), and nothing copies or moves a sign-in or a Keychain item between folders.
  A brand-new folder for a new profile is made by the app before it asks for a sign-in.
- **Read only on the Keychain.** `find-generic-password` only. Sign-out is Claude Code's own `claude auth logout`.
- **No token out.** The item's text stays in memory; only `Login`'s named fields come out. Nothing is printed, logged
  or written to disk (the auth suite's lint holds this).
- **Never another account's sign-in renewed in a profile's name.** `renew(expecting:)` runs only while the folder's
  record names that account (not another one, not nobody, not a record that can't be read).
- **Nothing sent elsewhere.** A `claude` run here never gets a key, a token, another provider, a base URL or extra
  headers from the shell (`AuthFolder.providerVariables`).

## Matching

Two accounts are the same by their account ids when both have one (case doesn't count; no organisation recorded is an
empty one, as `AccountID` has it). Else by the address (case doesn't count; both must have one) and the organisation:
its id when both have one, else its name (case doesn't count) when both have one; an organisation only one side names
doesn't tell them apart (`match` says `.address`, not `.seat`, and the answer then takes no ids or plan from the
record, which may be another seat's on the same address). A running claude names its organisation by name and no ids;
the record has both.

This is the rule between sources. ProfileCore's `AccountIdentity.matches` is stricter where only one side names an
organisation (there: another account) and stays as it is for cl_audit's saved seats; `SignedInAccount.identity` hands
an account to it. Making them one rule is the open question in `Core/README.md` (one seat comparison).

## cl_quick fit

cl_quick never reads the Keychain: it knows the account from the running claude's `initialize` answer (`email`,
`organization` name: verified) and treats the folder's `.claude.json` as a guess. What fits as it is:
`SignedInAccount.process(_:)` takes the `initialize` account, `SignedInAccount.record(_:)` the oauthAccount block
(cl_quick passes its own `FolderFiles` read through `AuthTools.readRecord`), `FolderSignIn.answer` lets the process's
word win over the record (`differs` when they disagree), its sign-in script is `SignInScript.lines(..., removesItself:
true)` with its own marker, and renew and sign-out are there when it wants them. cl_audit adds the Keychain read and
Anthropic's reply (`server`) as its verified word.

Not yet the same as cl_quick's `AccountTrail.owner`, to settle when cl_quick adopts the module:
- an organisation renamed while the process runs: `owner` keeps the reports when the organisation's id is the one the
  process started on; here the names differ, so the answer is `differs` (a "launched on organisation id" input would
  close it);
- `owner` compares organisation names exactly, here case doesn't count;
- a process that said nothing: `owner` takes the folder unchanged since the launch; here the answer is `guessed` (the
  launch-time record and `SignInChangeWatch` give the same).
