# Runs

The shared way to run a program, in one Swift module: Foundation only (Process, and posix_spawn for `ownGroup`), no app's paths,
words or global state.
ProfileCore never depends on it; the widget doesn't link it. It is built after ProfileCore (`scripts/modules.sh`) as a
static library; cl_audit and cl_quick build it from their vendored copy of cl_kit. The callers below are cl_audit's.

Who runs through it:

| Caller | How |
| --- | --- |
| ClaudeAuth (`Auth/`) | renew and sign-out (`AuthRun`), the Keychain read (whole text only), opening Terminal |
| `Processes` (`Sources/Processes.swift`) | `run` and `output` (lsof, npm, `claude --version`, the login shell), `claudeEnvironment` |
| `Installer.run` (`Sources/Config.swift`) | the app's tools: `open`, lsregister, launchctl, defaults, xattr, killall, the agent's own `--forget-login-item`; in the app's own folder and environment, no limit unless given one, then SIGTERM only |
| Export's `Tool.run` (`Sources/SessionsExport.swift`) | ditto and hdiutil: a password as input, both outputs kept, no limit, stopped only when asked (cancel or a watch), its pid listed for `killAll` |
| `UsageReader.post` (`Sources/Reader.swift`) | an alert through the app's own program: 20 s, then SIGTERM only |
| `QuickChatProcess` (`Sources/QuickChatEngine.swift`) | the chat's `claude`, kept running: `RunningProgram` |
| `CodeChecklist.spawn` (`Sources/CodeChecklist.swift`) | a move's read-only git reads: `ownGroup`, its output kept (1 MB), errors dropped, the caller's folder, 10 s at most, a one-second grace, cancelled every 50 ms with the Export page's Stop |

| File | What it holds |
| --- | --- |
| `Runner.swift` | `Program` (executable, arguments, environment, folder, input, timeout, grace, killed after it or not, output and errors kept or not, their cap, the drain), `Ran` (status, ended by a signal, output, errors, complete, stopped), `Runner.run` (with a poll and a started hook), `Runner.stop` (SIGTERM, the grace, SIGKILL or not, reaped), `Runner.waitQuietly` |
| `Group.swift` | `Program.ownGroup`'s run: posix_spawn in a group of its own, every other descriptor closed, the group stopped and cleaned up as one |
| `Running.swift` | `RunningProgram`: one that keeps running and is talked to: `start`, `write`, `onOutput` / `onErrors` (each chunk, in order, off the main thread; output's end as nil, which waits for whatever still holds the output open), `onExit` (after the output's end), `onTermination` (as the process itself ends), `closeInput()` (its input alone), `stop(grace:)` (input closed, SIGTERM, SIGKILL after the grace, without blocking) |
| `Environment.swift` | `ClaudeEnvironment`: the one allow-list for a `claude` run (`passed`: who and where the user is, the language, proxies and certificates, `LC_*`; `make`: the folder, `claude`'s own folder and the install places first on PATH, `quiet` (non-essential traffic off), `traceless` when asked); `ProviderEnvironment`: the variables a `claude` run never gets (a key, a token, another provider, a base URL, extra headers) and `cleaned(_:)`, for the finder's own programs |
| `ClaudeFinder.swift` | `ClaudeFinder.find`: the one claude finder (the usual places, the login shell, Volta, nvm newest first, npm's prefix, the desktop app's own Mach-O copy last; `quick`: files only), every look a `Lookup` closure; `version(of:)` |
| `ClaudeAsk.swift` | `ClaudeAsk.ask`: the short ask (`claude` with nothing kept or loaded, the `initialize` and `get_usage` control requests, no model message, a timeout, then stopped step by step): `Answer` (the account as `initialize` says it, `Limits`, how it ended: `answered` when every answer asked for came, a late one read as `claude` ended after a timeout too; else `timedOut`, or `exited` when it ended with none; `initialize`, the answer as it came: `Initialize`'s account and models, each nil when absent; `stop`, the step that ended `claude`: by itself, input closed, SIGTERM or SIGKILL, with `exitStatus` and `signaled`); `event`, `initializeAnswer` and `limits`, the parse |

## Rules

- By default a program runs in the temporary folder, with no input and its errors dropped. `folder` can be the caller's own or
  one given; `input` is written and then closed (a password goes this way, never as an argument; SIGPIPE is ignored, so a
  program that ends without reading it never takes the caller with it).
- Past its timeout it is asked to end (SIGTERM); if it hasn't within its grace, it is killed (SIGKILL); then waited for a second
  at most. `run` then returns nil: a run never blocks much past its limit, and never holds a thread for good. With
  `killAfterGrace` false it is only asked to end, and after the grace the caller goes on. `.infinity` for the timeout, the grace
  or the drain: no limit there.
- `poll` is asked right away and every `pollEvery` seconds while it runs; true stops it (as a timeout does) and the result says
  `stopped`, with its status as it ended. `started` hears its pid as soon as it runs.
- What it prints (and its errors, when kept) is read while it runs (a program printing more than a pipe holds never stalls), up
  to its cap; after it ended, for the drain at most (a program it started may hold the output open).
- `Ran.signaled`: ended by a signal it didn't get from the runner (a crash). Callers that treat any end but a clean exit as a
  failure check `ok`.
- `Ran.complete`: all it printed was read and none of it cut at the cap. A caller that needs the whole text (the Keychain read)
  refuses a result that isn't; one that takes what there is (a version line) doesn't need to.
- A reader still blocked after the drain, on an output a child of the program holds open, ends when that child does.
- `ownGroup` (opt-in): started with posix_spawn as the leader of a process group of its own, with only its input, output and
  errors passed (every other descriptor of the caller closed) and signals as a fresh program has them. It is stopped as a group:
  SIGTERM to all of it, SIGKILL to all of it after the grace. When the leader ends, whatever of its group is left (a filter, a
  pager, a helper holding its output) is killed before the leader is reaped, so the kill never reaches a pid given to someone
  else. A leader left to end by itself (`killAfterGrace` false, or stuck in the kernel) is dealt with the same way when it does
  end, off the caller's thread, holding no thread meanwhile. It relies on nothing else in the process reaping its children (no
  `waitpid(-1)`, SIGCHLD not ignored); a leader found already reaped is taken as gone, its status unknown, and nothing is sent to
  its group. `killGroupOnEnd` false: the group is ended only by a timeout or a stop; what the program leaves running when it
  ends by itself (an updater, say) is left to finish. A child that starts a session or group of its own is never reached either
  way. Only `Runner.run` has it; `RunningProgram` doesn't.
