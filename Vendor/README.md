# Vendored: cl_kit, the modules shared with cl_quick

`cl_kit-<tag>/` is a tagged release of [n-uf/cl_kit](https://github.com/n-uf/cl_kit), exactly as the tag has it (without
cl_kit's own `.github/`). `CL_KIT` names the tag and its commit; `scripts/modules.sh` builds from the folder it names.

| Folder | Module | Layer |
| --- | --- | --- |
| `Core/` | ProfileCore | Foundation only; imports nothing of ours. The app, the widget and the checks import it |
| `Run/` | Runs | Foundation only; the one runner, the cleaned environment, the process table. The widget doesn't link it |
| `Auth/` | ClaudeAuth | imports ProfileCore and Runs: one folder's Claude Code sign-in, ClaudeSignIn and the read-only Keychain read (`Keychain.swift`) |
| `Privacy/` | AddressPrivacy | Foundation, AppKit, CoreImage, Combine and SwiftUI; imports nothing of ours: how an account address is hidden on screen (a fixed blurred stand-in, "hidden address"). The app links it; the widget doesn't |

Until 26.11.70 these were cl_audit's own `Core/`, `Run/` and `Auth/`; their history is in cl_kit.

## The rule

**Never edit these files here.** A change is a pull request to cl_kit, then a new tag there, then here:

```bash
scripts/vendor.sh v26.11.2   # copies the tag, removes the old folder, rewrites CL_KIT; then commit Vendor/
scripts/vendor.sh --check    # the copy is exactly its tag, and the tag still names the recorded commit
```

`build.sh` and `Checks/run.sh` build the three with `Auth/Keychain.swift` (cl_audit reads the Keychain, read only), and
AddressPrivacy (`build_privacy` in `scripts/modules.sh`: cl_kit's `kit_build_privacy`; `privacy_link` its link flags).
`Checks/run.sh kit` runs cl_kit's own suites on the copy (`cl_kit-<tag>/Checks/run.sh`), AddressPrivacy's among them.
