# ProfileCore

The rules any app reading Claude Code's accounts and usage needs, in one Swift module: Foundation only, no app's paths,
files, wording or global state, every input a parameter (`now`, a calendar, thresholds, the data). cl_audit builds it
first (`build.sh`, `Checks/run.sh`) as a static library that the app, the widget and the checks import. Later it moves to
its own repository and cl_quick compiles it from source too.

| File | What it holds |
| --- | --- |
| `Identity.swift` | `Seat` and `SeatID` with their exact `same` (as cl_audit has always compared them), `SeatID.sameIgnoringCase` where cl_audit already ignored case, the loose comparison `AccountID` (case doesn't count, no organisation = empty); `AccountIdentity` for an account known by address and organisation only, with where it came from (`verified` by the running process, or `guessed` from a file) |
| `Standby.swift` | `StandbyAccount`, `AccountBook` (`ago`, `sane`, `offerOrder` and the picks `best` and `mostRecent`), `AccountNote`, `StandbyTidy` over any `StandbyHolder` |
| `Limits.swift` | `Usage`, `Freshness` (thresholds are parameters; `Freshness.current`, the one "reset passed" rule: no percent and no reset once a limit's reset has passed), `ScopedLimit`, `FullLimit` (data only: which limit, its reset, the other full one), `AtLimit` (`isFull`, `holding`, `blocker`, and `full` in two modes), `Credits` |
| `Headline.swift` | `Headline`: whose numbers a profile's headline may show, and how. `Headline.of(owner, signedIn:, readAt:, now:, ages:)` takes `Owner` (the account in use, the sign-in's, the reading's and the label's as `AccountIdentity`, or a resolver's own `differs`; another profile has the account; stale; unconfirmed) and `Ages` (`freshFor`, `hiddenAfter`, `datedFullStays`) and answers `Answer` (`otherReading`, `split`, `unconfirmed`, `signedIn`, `age`; `numbers(split:)`, `plan(split:)`, `readTime`, `acts`, and `limit(_:resets:readAt:split:now:)` for each limit). `Headline.split`, `otherReading` and `age` are its parts |
| `TimeWords.swift` | `TimeWords` (`when`, `back`, `countdown`, with a calendar parameter; always written in the Gregorian calendar, only the time zone is the caller's) and `Level`, the one colour level |
| `Parsing.swift` | `Login.parse` (a sign-in item's text) and `UsageParser` (Anthropic's usage and profile replies; the caller names the source) |

What stays in each app: its screens, colours and words (cl_audit's names and times for a full limit, `FullLimit.id`/
`name`/`other`/`countdown`/`back`/`both`, in `Widget/WidgetViews.swift` so the widget shares them, and `title`; the Dock
icon's countdown face `TileCountdown`/`TimeWords.tile`; `Credits.line`; `AccountBook.switchWords`; `AccountNote.words`;
the usage source's name), reading files and the Keychain, and its own records. cl_audit's status record
(status/<profile>.json) is one of those: its JSON shape, its one codec and where the file is stay in the app
(`Sources/StatusRecord.swift`: `IconStatus`, `ResolvedAccount`, `StatusCodec`, which the widget compiles too); the record
asks `Headline` what may show (`IconStatus.headline`, `shown`), and the app adds its lines (the split's, "account not
confirmed").

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
  both sides have one, else by address and organisation, and carries `source` (`verified` / `guessed`). cl_audit still
  compares seats by id (`Seat.same`), exactly.
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
  - cl_quick: `freshFor` 5 minutes, `hiddenAfter` an hour, `datedFullStays` on (5 to 60 minutes grey "last known");
  - cl_audit (`Store.ages`, the widget the same): `freshFor` the profile's read interval (5 minutes at least) plus a
    minute, so 6 minutes by default; `hiddenAfter` none (the headline never hides old numbers; its screens grey them on
    their own thresholds until step 3); `datedFullStays` off (a last-known full limit is left out, never grey).
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
- **Open question: the seat comparisons outside the headline.** For the headline it is settled (above). `Seat.same` and
  `SeatID.same` still compare the ids exactly (case counts; for `Seat`, no organisation is not an empty one), while
  cl_audit's id reads (`AccountResolver`, a switch reaching its account, a move's folders) ignore case. Whether those
  move onto `AccountIdentity.matches` too would make `Seat("ABC", nil)` and `Seat("abc", "")` one seat, an
  accounts-identity change, so it waits for its own step and checks. Also open: the resolver's own comparison (address
  first) moving onto `matches` (ids first) when the reader's logic comes into the core (step 5).
- **Later steps.** Reading usage (the two input scales, partial answers, refusals and how they lift, which windows hold
  back the account) isn't in the core yet.
