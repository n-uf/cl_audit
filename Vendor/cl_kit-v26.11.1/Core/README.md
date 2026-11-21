# ProfileCore

The rules any app reading Claude Code's accounts and usage needs, in one Swift module: Foundation only, no app's paths,
files, wording or global state, every input a parameter (`now`, a calendar, thresholds, the data). It is built
first (`scripts/modules.sh`) as a static library; cl_audit's app, widget and checks and cl_quick import it from their
vendored copy of cl_kit. `Sources/…` paths below are cl_audit's.

| File | What it holds |
| --- | --- |
| `Identity.swift` | `Seat` and `SeatID` with their exact `same` (change detection and saved keys), `SeatID.sameIgnoringCase` where cl_audit already ignored case, the loose comparison `AccountID` (case doesn't count, no organisation = empty); `AccountIdentity` for an account known by address and organisation only, with where it came from (`verified` by the running process, or `guessed` from a file); the one owner rule `AccountIdentity.sameAccount` (`matches`, with one side known by its address only matched by the address; `Seat.sameAccount`, `StandbyAccount.identity`, `withoutOrganization` for a source that names no organisation) |
| `Standby.swift` | `StandbyAccount`, `AccountBook` (`ago`, `sane`, `offerOrder` and the picks `best` and `mostRecent`), `AccountNote`, `StandbyTidy` over any `StandbyHolder` |
| `Limits.swift` | `Usage`, `Freshness` (thresholds are parameters; `Freshness.current`, the one "reset passed" rule: no percent and no reset once a limit's reset has passed), `ScopedLimit`, `FullLimit` (data only: which limit, its reset, the other full one), `AtLimit` (`isFull`, `holding`, `blocker`, and `full` in two modes), `Credits` |
| `Headline.swift` | `Headline`: whose numbers a profile's headline may show, and how. `Headline.of(owner, signedIn:, readAt:, now:, ages:)` takes `Owner` (the account in use, the sign-in's, the reading's and the label's as `AccountIdentity`, or a resolver's own `differs`; another profile has the account; stale; unconfirmed) and `Ages` (`freshFor`, `hiddenAfter`, `datedFullStays`) and answers `Answer` (`otherReading`, `split`, `unconfirmed`, `signedIn`, `age`; `numbers(split:)`, `plan(split:)`, `readTime`, `acts`, and `limit(_:resets:readAt:split:now:)` for each limit). `Headline.split`, `otherReading` and `age` are its parts |
| `Display.swift` | `ProfileDisplay`: the one "what to show" value per profile, `ProfileDisplay.make(answer, read:, sign:, otherAccount:, inUse:, clash:, note:, splitTo:, ages:, now:)` from the headline's answer and what the caller read. It carries `usage` (each limit as the answer lets it show) or `none` (why: `notRead`, `expired`, `signedOut`, `otherReading`, `split`, `hidden`), `readAt`, `tier` (`fresh`, `lastKnown`, `stale`: grey past `Ages.greyAfter`, else, or when it is below `freshFor`, as soon as last known), `full` (only numbers that act; `full(now:)` drops it once its reset passes, for drawing), `lamp`, `key` (`logIn`, `logInCode(to:)`), `line` (`unconfirmed`, `split`, the caller's `given`), `clash` (the other profile's id and name), `split`, `sign`, `otherAccount`; `grey`, `level(_:)`, `needsLogin`. No words: each app says it |
| `TimeWords.swift` | `TimeWords` (`when`, `back`, `countdown`, with a calendar parameter; always written in the Gregorian calendar, only the time zone is the caller's) and `Level`, the one colour level |
| `Parsing.swift` | `Login.parse` (a sign-in item's text) and `UsageParser` (Anthropic's usage and profile replies; the caller names the source, and which `limits[]` kind is the week) |
| `Reading.swift` | The reading rules as parameters, `ReadingRules` (`clAudit`, `clQuick`: `fractionSources`, `partial`, `week`, `refusals`, `messageText`; `percents`, `take`, `lifts`, `readsMessage`), with `UsageAnswer` (an answer in its source's scale and the windows it named), `Refusal` (`until`, `at`, `on`), `RateLimitEvent`, `LimitMessage`; `FetchState` (the reader's state, whose description the status record keeps) and `SignInRead` (a sign-in as read, by its token's key, never the token) |
| `ReaderMachine.swift` | `ReaderMachine`: one profile's reading as a state machine, `handle(Event) -> [Action]`. Events: a tick (with the status line's numbers and whether the folder is there), the folder looked at, the profile's settings, relinked, folder moved, read now, Refresh now, adopt the saved record, a sign-in read, the sign-in record changed, the usage endpoint's answer or failure (`Failure`: rejected, busy, HTTP, network, unexpected), the lookup's answer, an account found, a lookup failed, numbers, a renewal refused, started or ended, a rate-limit event, a limit message, written, stop. Actions: read the sign-in, keep or forget it, look its account up, fetch the usage (`Request`: the key, the generation, when; never the token), consider a renewal, numbers taken (the app's alerts), plan the read at a reset, started over, look afresh, the sign-in not there yet, the record changed, save, tick. `Timing` holds the intervals; `belongs(_:expected:)` is the one "is it another account" rule (`onOtherAccount`, `renewsIn`, `mayRenewByItself`, the new sign-in's retries and relinking all use it); `needsSignInRead`, `watchesSignIn`, `resetPassed`, `resetReadAt` |

What stays in each app: its screens, colours and words (cl_audit's names and times for a full limit, `FullLimit.id`/
`name`/`other`/`countdown`/`back`/`both`, in `Widget/WidgetViews.swift` so the widget shares them, and `title`; the Dock
icon's countdown face `TileCountdown`/`TimeWords.tile`; `Credits.line`; `AccountBook.switchWords`; `AccountNote.words`;
the usage source's name), reading files and the Keychain, and its own records. cl_audit's status record
(status/<profile>.json) is one of those: its JSON shape, its one codec and where the file is stay in the app
(`Sources/StatusRecord.swift`: `IconStatus`, `ResolvedAccount`, `StatusCodec`, which the widget compiles too); the record
asks `Headline` what may show (`IconStatus.headline`, `shown`), and the app adds its lines (the split's, "account not
confirmed"). The menu bar icon, the Dock icon and its panel draw `ProfileDisplay` only, through `Sources/ProfileShow.swift`
(it makes the value from the record and says it in cl_audit's words); the other screens move onto it in steps 3b to 3d.

Keys that are data, not wording, stay here: `ScopedLimit.key` ("mfable") is kept in saved alert marks, so it must not
change with an app's words.

Default clocks: every `now` is a parameter; where it defaults to `Date()` (and `StandbyAccount.init`'s `addedAt`, and
its decoder when no clock is in `userInfo[StandbyAccount.now]`), a caller that needs a fixed time passes one.

The rule for an account remembered by its address only (no seat yet): it is listed and can be picked by hand, but no
pick (`best`, `mostRecent`) ever names it: whether it has room isn't known, and switching to it moves nothing.

## Differences from cl_quick

Where cl_quick does it another way on purpose, the core leaves room for both; cl_audit's visible output doesn't change
in step 1, nor in step 2 beyond the widget now following the headline exactly.

- **Identity without an id.** cl_quick knows the account from the running claude process (`initialize.account`: address
  and organisation, no account id) and treats a folder's `.claude.json` as a guess. `AccountIdentity` matches by ids when
  both sides have one, else by address and organisation, and carries `source` (`verified` / `guessed`). Every owner
  check in cl_audit compares by `sameAccount` (below, the one owner rule).
- **The headline's identity rule (settled in step 2).** `Headline` compares accounts with `AccountIdentity.matches` only:
  the ids decide whenever both sides have one (in their normal form, `AccountID`; cl_audit's record already writes its
  ids in lower case, so for its records that is the exact id), else address (any case) and organisation. cl_quick passes
  its process identity (`verified`, no id) for the sign-in and the reading. cl_audit's resolver compares the account in
  use with Claude Code's when the agent reads (address first, as it always has) and writes the answer into the record;
  the headline takes that as `Owner.differs`, and it uses `matches` itself for the label against the reading.
  `Seat.same` and `SeatID.same` keep their exact behaviour for their callers.
- **Full in two modes, and the age tiers.** cl_quick acts on a full limit only from fresh numbers (under 5 minutes) and
  shows an older, dated full grey as "last known" until its reset. `AtLimit.full(_:resets:readAt:mode:)` has both
  (`.acts(freshFor:)`, `.display`), and the headline's `Ages` carries the tiers as parameters:
  - cl_quick: `freshFor` 5 minutes, `hiddenAfter` an hour, `datedFullStays` on (5 to 60 minutes grey "last known";
    `greyAfter` none, so `ProfileDisplay` greys as soon as numbers are last known);
  - cl_audit (`StatusAges` in `Sources/StatusRecord.swift`, one formula for `Store.ages` and the widget): `freshFor` the
    profile's read interval (5 minutes at least) plus a minute, so 6 minutes by default; `greyAfter` three read intervals,
    30 minutes at least (the Dock icon's old rule; since step 3a the menu bar greys by it too, and the dashboard card
    moves onto it in 3b); `hiddenAfter` none (old numbers are never hidden, only grey); `datedFullStays` off (a last-known
    full limit is left out).
  cl_audit's other screens keep `holding`/`blocker` (full while the reset is ahead or unknown) on what the headline left.
- **Freshness of a status line file.** `Freshness.isFresh` takes the window; cl_audit keeps its 15 minutes for a status
  line file.
- **Picks.** cl_quick's switch offer names the standby account seen most recently (no numbers), and its "Ask on" picks the
  other profile with the most room. The core has `AccountBook.best` (cl_audit's: the least used with room) and
  `AccountBook.mostRecent` side by side; "most room" between profiles needs their numbers and comes with a later step.
- **Standby shows no usage.** Both: a standby account shows no numbers at all.
- **Shared as they are.** The level (green, amber from 50, red from 80, crimson from 95), `TimeWords.countdown` ("19m",
  "1h 42m", "2d 19h", "16 days"), "back at 15:28" / "back Thu 09:00", and `AccountBook.ago` ("12 min ago", "3 h ago",
  "yesterday").
- **Standby is never read.** A standby account's numbers are never read and show nowhere; the headline is only ever
  asked about the account in use.
- **One Claude Code folder per profile.** A profile has exactly one Claude Code folder, and a new profile gets a new one;
  every account of the profile, the one in use and each standby, shares that folder. No hidden, per-account or helper
  folder is ever made (they would drift apart from the profile's own), so only the account signed in to the folder can be
  read, which is why standby is never read.
- **The one owner rule (settled in step 7).** Every "is this the same account / whose account is it" check compares by
  `AccountIdentity.sameAccount`: `matches` (the ids in any case when both have one, never the address then; else the
  address, any case, and the organisation, nil and "" one), except that one side known by its address only (no id, no
  organisation: an address typed, a standby entry remembered by its address, the address a reading was for) is matched
  by the address, as cl_quick's placeholder rule. In cl_audit: New profile's owner rule (`FolderRules.seatOwner`, step
  6), the folder's own following (`noteAccounts`, its standby entries, `seatTaken`, `AccountEntry.has`), the reader's
  `belongs`, the resolver (another profile's account in use, the app's account among the profile's, `differs`, a switch
  waiting for the app) and the lists' `isActive`/`isCodeRow`. A status record and the Claude app's config.json name no
  organisation, so a seat compared with them leaves its own out (`withoutOrganization`): an organisation not known isn't
  "none". The resolver keeps its order (the numbers' own address first, as the reading names it, then the ids), which
  is the address-only rule for a reading known by its address. `Seat("ABC", nil)` and `Seat("abc", "")` are one account
  now; no saved data changes. `Seat.same` and `SeatID.same` stay exact for what isn't an owner check: change detection
  (a profile's seat changed, the sign-in changed since asked) and a switch's receipts and keys. The found accounts
  (`AccountList.adding`) and `StandbyTidy` stay one entry per account id in any organisation, on purpose (`StandbyTidy.key`;
  the default-profile move's standby merge compares by it too, so the next tidy changes nothing). `Headline` keeps
  `matches`, deliberately: the two differ only for an identity known by its address only (no id, nil organisation)
  against one with an organisation. `sameAccount` lets the address decide (a typed address, a standby entry remembered
  by its address, is that seat's account); `matches` also asks the organisation, so nil against a seat's organisation is
  another account. cl_audit's headline identities carry no organisation (the record names none), so for cl_audit the two
  agree; cl_quick's process identity has one, and there `matches` keeps an address-only label or reading apart from
  numbers of another organisation, which the headline must never show as the profile's.
- **Reading usage (step 5).** `ReaderMachine` is cl_audit's reader as it was (`Sources/Reader.swift` is now its driver:
  the timers, the Keychain read through ClaudeAuth, the endpoints, the status line file, the alerts and the record). The
  rules where cl_quick differs are `ReadingRules`, cl_audit's set `clAudit`, cl_quick's `clQuick`:
  - *Two input scales.* The usage endpoint and the status line give 0–100, a rate-limit event 0–1 (`fractionSources`, the
    same for both); `percents` makes them 0–100.
  - *Partial and empty answers.* cl_audit: `replace` (an endpoint answer is the numbers; one with no limit at all is
    "unexpected reply", parsed so in the app). cl_quick: `keepLast` (a window named is taken whole, its reset included; one
    not named keeps its last numbers; the read time moves on only when every window the last numbers had was named;
    `rate_limits: null` changes nothing).
  - *The week.* cl_audit's parser takes any `limits[]` kind naming "seven" or "week"; cl_quick's `sevenDayOnly` takes
    `seven_day` only (`UsageParser.fromAPI(…, week:)`; `RateLimitEvent.Window.named`). A model's, spend or overage window
    is `scoped`: it holds back a model or a spend, never the account.
  - *Refusals.* cl_audit keeps none (`refusals: nil`: full is 100% in the numbers, nothing else). cl_quick's `Refusal` has
    `until`, `at` and `on` (5h, wk, unknown); a rate-limit event "rejected" sets it, "allowed" lifts it at once; the
    usage endpoint lifts it only when it was said at least 5 minutes ago (`liftAfter`) and the answer names the window that
    refused (for unknown, every window it names) with room. A model's or a spend window neither sets nor lifts one.
  - *Limit words from message text.* cl_audit reads none (`never`); cl_quick only from an error or a "<synthetic>"
    message (`errorOrSynthetic`, `readsMessage`, also for "Prompt is too long"). The app parses the words into a
    `LimitMessage`; the machine applies the gate.
  - *What stays cl_audit's.* The status line file's merge (its two limits over the endpoint's model limits and credits,
    no account named), the held reading and "account not confirmed", and the sign-in schedule are cl_audit's reader as it
    was; cl_quick, which reads usage from its running claude, need not send those events.
