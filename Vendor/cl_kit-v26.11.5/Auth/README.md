# ClaudeAuth

The Claude Code sign-in of a profile's ONE folder, in one Swift module. It answers one question: which account is this
folder signed in to, and is that verified or guessed. Around it: the folder's Keychain item (its name, and reading it),
the watch for a changed sign-in, and Claude Code's own sign-in, renew and sign-out on the folder.

It sits beside ProfileCore (`Core/`), above it: it imports ProfileCore (`Login`, `AccountID`, `AccountIdentity`), and
ProfileCore never imports it (ProfileCore stays Foundation-only, with no Keychain and no processes). It is built
as a static library after ProfileCore and Runs (`scripts/modules.sh`); cl_audit's app links it (its widget doesn't), and
cl_quick links it built without `Keychain.swift`, each from its vendored copy of cl_kit.

| File | What it holds |
| --- | --- |
| `Folder.swift` | `AuthFolder`: the folder's path, default or not (`~/.claude` however spelled), its record (`.claude.json`), its Keychain item names (`Claude Code-credentials`, or `-` and 8 hex of the path's SHA-256), the environment a `claude` run on it gets (no key or other provider; `CLAUDE_CONFIG_DIR` set, or unset for the default folder), and `isReady` (there as a plain folder; never made) |
| `Identity.swift` | `SignedInAccount` from each source (`record`: guessed; `process`, a running claude's `initialize` account, and `server`, Anthropic's reply about the sign-in: verified), `match` (ProfileCore's one seat comparison), and `FolderSignIn.answer`, Claude Code's account on the folder: `verified`, `seatNotKnown`, `guessed`, `differs` or `none`, and `numbersBelongTo`, whose the verified source's numbers are |
| `Trail.swift` | `ProcessTrail`: a running claude's trail, the record at its launch and its own word; `FolderSignIn.answer(record:trail:)` |
| `RecordReader.swift` | `FolderRecordReader`: the one `.claude.json` reader (oauthAccount's named fields only, bounded, parsed again only when the stamp moved, `generation` counting each change for every caller); `AuthTools.reader` and `SignInChangeWatch.look(_:folder:)` read through it; an instance the app owns |
| `AccountKey.swift` | `AccountKey`: the saved key (account id, organisation), with its address and name placeholders upgraded in place; `identity(email:)` and `match(_:email:)` with the address an app saved beside an id key (the key holds none) |
| `StoredSignIn.swift` | `StoredSignInReader`: the one door to a stored sign-in; ClaudeAuth names no store |
| `Keychain.swift` | `KeychainSignIn.read`: the item through `/usr/bin/security`, read only, into `Login`'s named fields; `KeychainSignInReader` (the Keychain as the stored sign-in) and `AuthTools.systemWithKeychain`. The only file that touches the Keychain: an app that never reads it (cl_quick) leaves it out of its build |
| `Watch.swift` | `RecordStamp` and `SignInChangeWatch`: another account signed in to the folder since the last look (signing out isn't a change) |
| `Runs.swift` | `ClaudeCommand`, `AuthRun` (renew's "Reply with OK." on Haiku, `claude auth logout`, the real runner), `SignInScript` (`claude auth login --claudeai --email` in Terminal; `Watch`, the files ClaudeSignIn follows; `write`, the owner-only file writer) |
| `Authenticator.swift` | `Authenticator`: one folder's sign-in behind one type, with every tool in `AuthTools` (the stored sign-in reader, the runner, Terminal, the launch guard, the record reader, the environment); `RecordFile`, the bounded record read |
| `ClaudeSignIn.swift` | `ClaudeSignIn`: a sign-in in a Terminal window, followed to its outcome (signed in or wrong account, as the app's word confirmed; unverified; declined; failed; stopped; timed out) and its window closed after it; one per app; the process guard and the folder's lock (`~/Library/Caches/n-uf/signin-<8 hex>.lock`); the app's verified word passed in (`Confirm`) |

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

One seat comparison, ProfileCore's `AccountIdentity.compare` (`SignedInAccount.match` asks it). The account first: by
the account ids when both have one (case doesn't count; never the address then), else by the address (case doesn't
count; both must have one). Then the organisation: its id when both have one, else its name (case doesn't count) when
both have one; none on either side is the same. An organisation only one side names (or an id on one side and a name on
the other) is `.seatNotKnown`: the same account, maybe another seat. A running claude names its organisation by name
and no ids; the record has both. `maybeSame` here is "not `.different`" (the watch, `isSignedIn(to:)`); ProfileCore's
`matches` is "`.seat`" (the headline). Renew asks for `.seat`.

## The account rule (decided 2026-11-22)

`FolderSignIn.answer` is Claude Code's account on the folder, one answer for both apps
([docs/design/platform-concept.html](../docs/design/platform-concept.html), section 4):

- **D1, signed in by an id or an address.** A record, a word or a reply that names an account id or an address is
  signed in (`isSignedIn`). A saved key still needs the id: `AccountKey` keeps `email:<address>` until the id is known,
  then is upgraded in place (`upgraded(with:)`). A key whose seat isn't known gets an organisation only when the caller
  says the numbers' own source named that seat (`seatOfTheNumbers`): the first seat seen on an address isn't, by itself,
  the seat its numbers were read on.
- **D2, two seats on one address.** A personal plan and a Team seat share the address and the account id; the
  organisation tells them apart, so a seat is (account id, organisation) (`AccountKey`). Only one side naming an
  organisation is `seatNotKnown`: the verified word as it is, no ids, plan or organisation from the record.
- **D3, a verified word beats the record.** A running claude's own `initialize` account, or Anthropic's reply for the
  stored sign-in, wins over `.claude.json`, which is only a guess. When they disagree the answer is `differs`, and the
  numbers are the verified account's (`numbersBelongTo`), never moved to the record's. With a `ProcessTrail`, the word
  takes the launch record's ids and organisation id when it names the seat the process started on, so an organisation
  renamed while it runs keeps its numbers; a process that said nothing owns its numbers only while the record still
  names the seat it started on (a rewrite for the same seat doesn't count as a change, another seat or a sign-out does).
- **D4, two names.** The kit answers only Claude Code's account. Another sign-in an app has (cl_audit's Claude window)
  is that app's own question and name; nothing public here is called plainly "in use" (the auth lint holds it).
- **D5, organisation names in any case.** The organisation's id decides when both sides have one; else its name, case
  not counting.

One folder reader, `FolderRecordReader`, reads `.claude.json` for the account (named fields only, bounded, one stat per
look, parsed again only after a write). Its `generation` moves when the record names someone else: another account or
seat, a sign-in, a sign-out (a seat that was only not known isn't a change). Every caller keeps the generation it last
saw. `Authenticator.record()` reads through it when `AuthTools.reader` is set, and the watch through
`SignInChangeWatch.look(_:folder:)`: one parse per write for the whole app. The watch's own question stays narrower
(another account signed in; signing out isn't one).

## cl_quick fit

cl_quick never reads the Keychain: it knows the account from the running claude's `initialize` answer (`email`,
`organization` name: verified) and treats the folder's `.claude.json` as a guess. It builds ClaudeAuth without
`Keychain.swift` and passes no `StoredSignInReader`; its `ClaudeSignIn.Confirm` is a short claude's `initialize`
account. What fits as it is:
`SignedInAccount.process(_:)` takes the `initialize` account, `FolderRecordReader` replaces its `FolderFiles`,
`ProcessTrail` its `AccountTrail` (`launchedOn` as the process starts, `said` on its `initialize` answer,
`FolderSignIn.answer(record:trail:)` for whose a report is: `numbersBelongTo`), `AccountKey` its `email:` keys with the
organisation added, its sign-in script is `SignInScript.lines(..., removesItself: true)` with its own marker, and renew
and sign-out are there when it wants them. cl_audit adds the Keychain read and Anthropic's reply (`server`) as its
verified word.

Where the kit's rule differs from cl_quick's `AccountTrail.owner` today, by the decisions above (stage 2 moves it):
- a report whose process the record no longer names is kept for the process's own account (`numbersBelongTo`), not
  dropped; it is never put on the record's account;
- organisation names are compared in any case (D5), and two seats on one address are two (D2);
- a word that names another seat than the launch record takes none of its ids, so the launch organisation id keeps a
  renamed organisation's numbers without ever handing them to another seat.
