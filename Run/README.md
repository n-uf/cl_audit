# Runs

The shared way to run a program, in one Swift module: Foundation only (Process), no app's paths, words or global state.
ClaudeAuth (`Auth/`: renew, sign-out, the Keychain read, opening Terminal) and the app's `Processes` (`Sources/Processes.swift`:
`run`, `output`, `claudeEnvironment`) both run through it. Not yet: the app's `Installer.run` (Terminal, `open`, codesign and
the like) and the long-running launches that keep a process (quick chat's `claude`, export's archivers), which start their own. ProfileCore never depends on it; the widget doesn't link it. cl_audit
builds it first (`build.sh`, `Checks/run.sh`) as a static library; cl_quick can compile it from source too.

| File | What it holds |
| --- | --- |
| `Runner.swift` | `Program` (executable, arguments, environment, timeout, grace, output kept or not, its cap, the drain), `Ran` (status, ended by a signal, output), `Runner.run`, `Runner.stop` (SIGTERM, the grace, SIGKILL, reaped), `Runner.waitQuietly` |
| `Environment.swift` | `ProviderEnvironment`: the variables a `claude` run never gets (a key, a token, another provider, a base URL, extra headers) and `cleaned(_:)` (without them and without CLAUDE_CONFIG_DIR) |

## Rules

- A program runs in the temporary folder, with no input and its errors dropped.
- Past its timeout it is asked to end (SIGTERM); if it hasn't within its grace, it is killed (SIGKILL); then waited for a second
  at most. `run` then returns nil: a run never blocks much past its limit, and never holds a thread for good.
- What it prints is read while it runs (a program printing more than a pipe holds never stalls), up to its cap; after it ended,
  for the drain at most (a program it started may hold the output open).
- `Ran.signaled`: ended by a signal it didn't get from the runner (a crash). Callers that treat any end but a clean exit as a
  failure check `ok`.
- `Ran.complete`: all it printed was read and none of it cut at the cap. A caller that needs the whole text (the Keychain read)
  refuses a result that isn't; one that takes what there is (a version line) doesn't need to.
- A reader still blocked after the drain, on an output a child of the program holds open, ends when that child does.
