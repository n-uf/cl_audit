# Runs

The shared way to run a program, in one Swift module: Foundation only (Process), no app's paths, words or global state.
ProfileCore never depends on it; the widget doesn't link it. cl_audit builds it first (`build.sh`, `Checks/run.sh`, and the
quick chat's own `Checks/quick-chat/run.sh`) as a static library; cl_quick can compile it from source too.

Who runs through it:

| Caller | How |
| --- | --- |
| ClaudeAuth (`Auth/`) | renew and sign-out (`AuthRun`), the Keychain read (whole text only), opening Terminal |
| `Processes` (`Sources/Processes.swift`) | `run` and `output` (lsof, npm, `claude --version`, the login shell), `claudeEnvironment` |
| `Installer.run` (`Sources/Config.swift`) | the app's tools: `open`, lsregister, launchctl, defaults, xattr, killall, the agent's own `--forget-login-item`; in the app's own folder and environment, no limit unless given one, then SIGTERM only |
| Export's `Tool.run` (`Sources/SessionsExport.swift`) | ditto and hdiutil: a password as input, both outputs kept, no limit, stopped only when asked (cancel or a watch), its pid listed for `killAll` |
| `UsageReader.post` (`Sources/Reader.swift`) | an alert through the app's own program: 20 s, then SIGTERM only |
| `QuickChatProcess` (`Sources/QuickChatEngine.swift`) | the chat's `claude`, kept running: `RunningProgram` |

Not through it (yet): the code checklist's git reads (`CodeChecklist`, its own `posix_spawn`).

| File | What it holds |
| --- | --- |
| `Runner.swift` | `Program` (executable, arguments, environment, folder, input, timeout, grace, killed after it or not, output and errors kept or not, their cap, the drain), `Ran` (status, ended by a signal, output, errors, complete, stopped), `Runner.run` (with a poll and a started hook), `Runner.stop` (SIGTERM, the grace, SIGKILL or not, reaped), `Runner.waitQuietly` |
| `Running.swift` | `RunningProgram`: one that keeps running and is talked to: `start`, `write`, `onOutput` / `onErrors` (each chunk, in order, off the main thread; output's end as nil), `onExit`, `stop(grace:)` (input closed, SIGTERM, SIGKILL after the grace, without blocking) |
| `Environment.swift` | `ProviderEnvironment`: the variables a `claude` run never gets (a key, a token, another provider, a base URL, extra headers) and `cleaned(_:)` (without them and without CLAUDE_CONFIG_DIR) |

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
