# Changelog

All notable changes to cl_kit are listed here, newest first. Calendar versions, `YY.M.R`, tagged `vYY.M.R` (see README ▸
Versions and release).

## 26.11.8

A patch: shared seats in the status record, the split's numbers for a caller that names their account, and the short ask's
end and its `initialize` answer for cl_quick (no app changes). No source breaks for ordinary use: the record's fields stay,
the rest is new API or a new parameter with a default. Two edge cases: a function reference to an initialiser that gained
a defaulted parameter (`Headline.Ages.init`, `Headline.Answer.init`, `ClaudeAsk.Answer.init`) has a new type, and
`ClaudeAsk.Answer`'s synthesized `==` now also compares `initialize`, `stop`, `exitStatus` and `signaled`.

- **Behaviour change: an older record's clash no longer hides the split.** cl_audit dropped "one profile per account"
  (an account may be several profiles': shared seats). `ResolvedAccount.clash` and `clashID` are an older build's,
  decoded only and never used: `ResolvedAccount.owner` sets `elsewhere: false`, and `ProfileDisplay.of` shows no clash from
  a record. So a record that carries a clash shows its split (no numbers, no plan) as one without it does, as cl_audit's
  own copy has it.
- **The split's numbers, for a caller that names their account** (opt-in): `Headline.Ages.splitShowsNumbersOwner` (and
  `StatusAges.of(pollMinutes:splitShowsNumbersOwner:)`), false by default so nothing changes unless asked. With it, in the
  split (the Claude app and Terminal on different accounts) the numbers are shown as their own account's (cl_audit names it:
  "<address> · Terminal"): `Headline.Answer` keeps the numbers and the plan, `ProfileDisplay` its usage, level, grey, full
  and what holds it back, and they act for that named account (a full limit there really holds its work back; an app's
  alert never names an account). With numbers to show, `none` is nil; without, it gives the real reason (hidden by age,
  not read), never `.split`. Another reading, an unconfirmed owner and a sign-in gone still win. The split is still said
  (`split`), so the app still draws its line. cl_quick has no split, and never reads or writes a record's clash.
- **The short ask's end** (Runs): `ClaudeAsk.Answer.stop` says which step ended `claude` (`byItself`, `inputClosed`,
  `terminated` by SIGTERM, `killed` by SIGKILL), with its `exitStatus` and `signaled`, heard as the process ends (not as
  its output ends: something it started may hold the output open), and a signal is sent only to a process still running.
  **Behaviour change:** the stop now runs step by step: the input closed, then SIGTERM only a grace later (it came at once
  before), then SIGKILL a grace after that; so `ask` can block up to `timeout` + 2 × `grace` + 2 s.
  `RunningProgram.closeInput()` closes a program's input alone, and `RunningProgram.onTermination` hears its end as the
  process ends.
- **`initialize` as it came** (Runs): `ClaudeAsk.Answer.initialize` (`Initialize`: the account object's named fields and
  the models' values, each nil when absent) and `ClaudeAsk.initializeAnswer(_:)`, so an account without a model list can be
  checked directly.
- **Checks:** the core suite gains a record with a clash that still splits, and the split with and without
  `splitShowsNumbersOwner` (in the headline, the display and `StatusRecord.shown`: numbers, level, grey, full, what holds
  it back, dated fulls past the hour, an old full left out, `none`'s real reason, and what still wins over it); the runs
  suite the stop step and exit status of each stand-in `claude` (input closed, SIGTERM, one that ignores it and is killed,
  one that quits), `initialize` as it came, `closeInput` and `onTermination`.

## 26.11.7

MenuRows, a new module: one menu bar account row for both apps (stage 8 of the platform concept, the kit part; no app
changes yet). No source breaks: a new module, nothing else in the kit changes.

- **MenuRows** (`MenuRows/`): one account row of a menu bar menu, from cl_audit's address row and cl_quick's standby row.
  It imports ProfileCore and AddressPrivacy only (and Foundation, AppKit), holds no rule of its own, names no app and
  never logs; nothing of ours imports it. Its API:
  - `MenuAccountRow`, the row as data: `prefix`, `address`, `inUse`, `usage`, `note`, `tag`, `hint`, `enabled`, `dimmed`,
    `marker` (`Marker`: a tick, or the standby look's hollow lamp);
  - `MenuUsageLine.of(_ display: ProfileDisplay, words:now:)`: the compact usage line from ProfileCore's display value
    (each limit's rounded percent in its level, the 5-hour part only where `hasFiveHour` lets it, a full limit's countdown
    instead, grey for old numbers; nil without numbers), its `parts`, `full`, `grey` and `words`;
  - `MenuRowWords` (`standard`: "5h", "Week", "full", "✓", "selected", or the app's own) and `MenuRowColumns` (`standard`:
    the tick in the margin, the address at 14 pt);
  - `MenuAccountRowView` (an `NSView`) and `MenuAccountRowView.item(_:words:columns:blur:pick:)`, the menu item: the
    address through AddressPrivacy (while addresses are hidden the one stand-in, blurred, sharp only while the row is lit
    and the pointer is on it; its room the stand-in's), the title and VoiceOver's label with "hidden address" in the
    address's place, the account in use as the item's `.on` state; a click closes the menu, then runs `pick` once the
    menu's tracking has ended; `refresh()` for a row kept across a change of the setting.
- **Build.** `scripts/modules.sh` gains `kit_build_menurows OUT` (after `kit_build` and `kit_build_privacy` into the same
  OUT) and `kit_menurows_link OUT`. Link order: put `kit_menurows_link`'s flags BEFORE `kit_privacy_link`'s and
  `kit_link`'s (ProfileCore), since a static library comes before the ones it needs. `scripts/build.sh` builds it too.
- **Checks:** the new `menurows` suite (in `all`, so in CI), its lint first (imports, no logging, no app named, imported by
  nothing of ours), with sample addresses: the usage line against display values, nothing of a hidden address in words or
  pixels, the pointer-only reveal, the tick, the item, the sizes.

## 26.11.6

Finding accounts on this Mac, each source a plain function (stage 9 of the platform concept, the kit part; no app
changes yet). No source breaks: all of it is new API.

- **One shape.** `FoundAccount`: one sighting of an account, named fields only (its id in normal form, the organisation's
  id, the address, the organisation's name and type as written, the plan, when last used, where it was seen).
  `FoundAccounts` puts sightings together first seen first, as cl_audit's account list does: each account's address and
  plan as written (an id that isn't UUID-shaped too), each organisation's name and type from one record, every seat
  (both ids UUID-shaped) in order, when each was last used, the ids a transcript names alone, accounts in the order seen.
- **The sources** (`AccountSources`, every path the caller's): a folder's record and its backups (`folderRecordFiles`,
  exact backup names), the Claude Code folders in a home (`claudeFolders`: links to folders included, never
  ~/.claude-switch), every ~/.claude* and claude-transplant switch record (`homeRecordFiles`), and their accounts
  (`records`, bounded reads).
- **Options, cl_audit's** (`Auth/DiscoveryApp.swift`): the desktop app's session folders (`appSessions`: names and dates,
  an agent record's address, at most 1 MB a record and none for an address already known) and the account ids
  transcripts name (`transcriptAccounts`: it reads chats). No link is followed in either.
- **The incognito build ships no chat reader.** `kit_build OUT no-keychain` (cl_quick's) now leaves out
  `Auth/DiscoveryApp.swift` as well as `Auth/Keychain.swift`; the nokeychain suite checks that ClaudeAuth holds neither
  reader.
- `RecordFile.head`: the first bytes of a regular file, never a FIFO or a device.
- **Checks:** the auth suite gains each source on a throwaway home with sample records (linked folders, backup names,
  bounded and linked records, the caps); the nokeychain suite checks for the session and chat readers.

## 26.11.5

The usage rules and the runner cl_quick still copies (stage 5 of the platform concept; no app changes yet). ProfileCore: no
source breaks, every addition is new API or a new parameter with a default.

- **The week-only rule.** `Usage.hasFiveHour(fiveHour:week:refusedOn:heldBack:)`, cl_quick's exact form, and
  `Usage.hasFiveHour(refusal:now:)` from the raw numbers (never `current()`'s; a plan without the window, `noFiveHour`, never
  shows it); `ProfileDisplay.hasFiveHour`, from the raw read.
- **What holds a profile back.** `AtLimit.heldBack` and `HeldBack`: the full limit (`blocker`, unchanged), else a standing
  refusal: the window the numbers leave (only one known: the other), `any` when both are known, the refusal's own window
  only when neither is. `ProfileDisplay.heldBack`, from the raw read and the refusal `make` is given.
- **Behaviour change, for callers that keep dated fulls (`datedFullStays`, cl_quick's ages) only:**
  - past `hiddenAfter`, `Headline.Answer.limit`, `ProfileDisplay.make` and `StatusRecord.shown` keep a full limit whose known
    reset is ahead, grey, until that reset (`Answer.datedFullOnly`): `ProfileDisplay.usage` is then non-nil (that limit only)
    and `none` nil; `ProfileDisplay.heldBack` keeps a refusal with a known end in the same way;
  - a dateless 100% read between `freshFor` and `hiddenAfter` shows as a grey, last-known 100% with no reset; it never acts
    and never sets `full`.
  Callers without dated fulls (cl_audit) are unchanged.
- **Not taken in this stage** (the reader's rules, where cl_quick still differs): a rate-limit event's `used × 100` clamped
  to 0…100; `get_usage`'s `locked_reason` as a refusal; the refusal lift (cl_quick lifts only when every window given is
  below 100, the kit when the refusing window has room).
- **One claude finder** (Runs): `ClaudeFinder.find` (the usual places, the login shell, Volta, nvm, npm's prefix, the
  desktop app's own Mach-O copy last; `quick`: files only), every look a `Lookup` closure; `version(of:)`.
- **One environment allow-list for a claude run** (Runs): `ClaudeEnvironment.make` (who and where the user is, the
  language, proxies and certificates, a company's certificate store and client certificate (`CLAUDE_CODE_CERT_STORE`,
  `CLAUDE_CODE_CLIENT_CERT`, `CLAUDE_CODE_CLIENT_KEY`, `CLAUDE_CODE_CLIENT_KEY_PASSPHRASE`); the folder; claude's own folder
  first on PATH, absolute entries only (`ClaudeEnvironment.path`); non-essential traffic off; `traceless` when asked).
  **Behaviour change for renew and sign-out:** `AuthFolder.environment` is now that allow-list (was a deny-list), so they
  no longer pass on anything else of the caller's environment (`NODE_OPTIONS`, a model override, telemetry export, cloud
  credentials are dropped), and get the non-essential traffic off.
- **The short ask** (Runs): `ClaudeAsk.ask`, claude with nothing kept or loaded and always traceless, the `initialize` and
  `get_usage` control requests, never a model message, a timeout, then stopped; the account as `initialize` says it (an
  answer with neither models nor an account is ignored) and the two windows. Run so far against stand-in `claude` scripts;
  its run against a real `claude` comes with cl_quick's move onto it (stage 6).
- **AccountKey with its address.** `AccountKey.identity(email:)` and `match(_:email:)`: an id key with the address the app
  saved beside it (from cl_quick's own helper).
- **Checks:** the core suite gains `heldBack`, the week-only rule and a dated full past the hour; the runs suite gains the
  finder, the allow-list and the short ask against stand-in `claude` scripts; the auth suite the allow-list's use and the
  key's address.

## 26.11.4

The account rule, one for both apps (stage 1 of the platform concept, `docs/design/platform-concept.html`; no app changes
yet).

- **One seat comparison.** ProfileCore's `AccountIdentity.compare` (`SeatMatch`: `seat`, `seatNotKnown`, `different`) with
  the organisation's name beside its id; ClaudeAuth's `SignedInAccount.match` asks it. ProfileCore's `matches` (`.seat`)
  answers as before. In ClaudeAuth, the same account id with an organisation on one side only is now `seatNotKnown` (was
  another account), and the same address with no organisation on either side is the same seat (was address only).
- **Claude Code's account, settled (D1–D5).** `FolderSignIn.answer`: signed in by an id or an address (`isSignedIn`); a new
  `seatNotKnown` verdict when only one side names an organisation (nothing taken from the record); a verified word over the
  record, and `numbersBelongTo`, the account the verified source's numbers belong to, never the record's when they differ.
- **ProcessTrail**, a running claude's trail (from cl_quick's `AccountTrail`): `FolderSignIn.answer(record:trail:)` keeps the
  launch organisation id across a rename and trusts a silent process only while the record names the seat it started on;
  `Authenticator.signIn(trail:)`.
- **FolderRecordReader**, the one `.claude.json` reader: named fields only, bounded, parsed again only when the stamp moved;
  `generation` counts each time the record names someone else (another account or seat, a sign-in, a sign-out), so every
  caller sees every change. `AuthTools.reader` puts `Authenticator.record()` on it, and `SignInChangeWatch.look(_:folder:)`
  reads through it.
- **AccountKey**, the saved key (account id, organisation): an `email:` placeholder upgraded to the id in place, a `name:`
  placeholder to the organisation's id of the same seat; a key whose seat isn't known gets an organisation only when the
  caller says the numbers' own source named it (`seatOfTheNumbers`), never moved onto another account or seat; a text form
  for larger keys.
- **The owner rule follows the names.** `AccountIdentity.addressOnly` needs no organisation name either, so a running
  claude's word (it names its organisation by name) never takes the other seat on its address by the address alone.
- **ClaudeSignIn** judges a `seatNotKnown` answer as it judged the loose verified one before, except when the account
  wanted names its organisation: then the sign-in is unverified (which seat it landed on isn't known).
- **A seat may belong to several profiles.** ProfileCore's `StandbyTidy` tidies within one profile, by seat (account id
  and organisation): only the same seat twice in one profile and the profile's own account in use go, so a seat in use in
  one profile can stand by in another, and a personal plan and a Team seat on one account id are two entries (was one entry
  per account id, and another profile's account in use was dropped). An entry whose organisation isn't known joins the
  account's one seat there, or its record's, adding only a newer last use; the account in use with no organisation known
  never takes a known seat of its id. `StandbyTidy.merge(_:into:inUse:)` joins entries to a list as the tidy keeps it (a
  caller adding entries uses it); `StandbyTidy.key` is per seat.
- **Source breaks** (no app calls these yet):
  - `FolderSignIn.Verdict` has a new case, `seatNotKnown`: a `switch` over it needs the case.
  - `SignedInAccount.Match` is ProfileCore's `SeatMatch`: `.address` is gone, `.seatNotKnown` takes its place.
  - `SignedInAccount.matches` is renamed `maybeSame` (it is "not `.different`", looser than ProfileCore's `matches`), and
    answers yes in two more places: the same account id with an organisation on one side only, and the same address with
    no organisation on either side.
  - ProfileCore's `AccountIdentity.matches`, `sameAccount` and `addressOnly` answer differently only for identities that
    carry an organisation name (none did before): an address alone against a named organisation is a seat not known.
- **Checks:** the auth suite gains one case per disagreement (D1–D5), the risks (a sign-in under a running claude, personal
  plus Team on one address, a one-sided organisation, a renamed organisation, a silent process with the record changed), the
  saved key, the folder reader (its generation, shared by the watch and the authenticator), and a lint that ClaudeAuth
  declares nothing named plainly "in use" (types, functions, properties, enum cases, extension members; ClaudeAuth only);
  the core suite gains the one seat comparison and headline cases with organisation names; the claudesignin suite gains a
  seat not known against a seat wanted (unverified) and against an address wanted (signed in).
- **docs/design/**: the platform concept page.

And the status record and the face, into ProfileCore:

- **The status record moves into ProfileCore.** `StatusRecord`, `ResolvedAccount` and `StatusCodec` (with the drawable
  clamp) are cl_audit's status record as it writes it, so every app reads one shape. `StatusAges` gives its age formula,
  and `ProfileDisplay.of` turns a record into the one display value.
- **The account answer's line is a fact, not a sentence.** `ResolvedAccount` gains `codeUsageLine` and `splitLine`
  (optional, left out when empty: older records decode) and `usageOnPrefix`; the app builds the sentence when it shows it,
  so no record holds an address as text. `StatusCodec.drawable` turns an older record's stored "Usage: Claude Code on …"
  into the fact, so the address never reaches a display value's note, and `ProfileDisplay.of` takes the app's builder for
  the line (`lineText:`, the record's own `line` by default).
- **A profile's small picture, as data.** `StatusFace.of` gives the numbers, grey, the other-account warning, the full
  limit, the elapsed shares and the window mark from a display value and a `ProfileLook` (a plain value with its own
  defaults), so every picture of a profile follows the same rules. How it looks stays the app's.
- **Checks:** the core suite gains the codec, the ages, the look's defaults and the picture in each state.
- Additive: nothing that was in ProfileCore changes.

## 26.11.3

- **AddressPrivacy joins** (`Privacy/`, from cl_quick's `Shared/AddressPrivacy/` at 190fa1b): an account address on screen
  is one fixed stand-in or the words "hidden address", never the real address blurred or masked, in views, labels and plain
  text, revealed only on purpose; the setting is a value the app passes in. Its own static library, apart from the layers
  (Apple's UI frameworks, no module of ours): `kit_build_privacy` and `kit_privacy_link` in `scripts/modules.sh`, and the
  `addressprivacy` suite with its lint.

## 26.11.2

ClaudeSignIn as cl_quick last had it (cl_quick 0568102), with its checks.

- **A late script is ended.** A sign-in stopped while Terminal was still starting its window ends the script once it shows,
  its login with it, for at least 5 s after the end (also after a restart, at quit, and when the window never opened).
- **Each run has its own files:** `sign-in-<run>.pid`, `.status` and `.declined`, so a late script never writes into the
  next sign-in's; a start ends other runs' scripts by their files and waits for a pending one's login.
- **Checks:** the claudesignin suite gains the late-start, late-restart and late-quit cases (150 checks).

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
