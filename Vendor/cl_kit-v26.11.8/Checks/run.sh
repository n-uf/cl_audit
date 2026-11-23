#!/usr/bin/env bash
# The one entry point for cl_kit's check suites. Run here, or on an app's vendored copy (Vendor/cl_kit-<tag>/Checks/run.sh):
# it always checks the tree it is in.
#
#   Checks/run.sh [core|runs|auth|claudesignin|nokeychain|addressprivacy|menurows|all] [--no-build]
#
#   core          ProfileCore (Core/), compiled against it only: ids, standby, limits, times, levels, parsing, the reader;
#                 its lint: Foundation only, no app's paths, files, words or global state
#   runs          Runs (Run/), compiled against it only: timeouts, SIGTERM then SIGKILL after the grace, output read while
#                 running, caps, the environment; its lint: Foundation only, never logs
#   auth          ClaudeAuth (Auth/), compiled against it, Runs and ProfileCore only, with a fake Keychain tool, claude and
#                 Terminal: the folder's item names, the one answer, the Keychain read, the watch, sign-in, renew, sign-out;
#                 its lint: no Keychain outside Auth/Keychain.swift, never logs, never writes the Keychain
#   claudesignin  ClaudeSignIn (Auth/ClaudeSignIn.swift) against a stand-in Terminal and a stand-in `claude auth login`
#                 (Checks/claudesignin/bin), Terminal's preferences in memory. Lints first: no Keychain, no real Terminal
#                 preferences
#   nokeychain    ClaudeAuth built without Auth/Keychain.swift and Auth/DiscoveryApp.swift, as an incognito app that never
#                 reads the Keychain builds it: it compiles, the libraries name no Security API and no `security` tool, and
#                 hold no session or chat reader
#   addressprivacy  AddressPrivacy (Privacy/) built on its own and its suite against it alone: a hidden address is the fixed
#                 stand-in or "hidden address", never part of the real one, in every form; the reveal; the setting as a value.
#                 Its lint first: Apple's frameworks only, no logging, no app named, imported by no layer
#   menurows      MenuRows (MenuRows/) built on ProfileCore and AddressPrivacy, its suite against the three: the usage line is
#                 the display value's, a hidden address is nowhere in a row's words or pixels, only the pointer reveals it,
#                 the tick, the item. Its lint first: ProfileCore, AddressPrivacy, Foundation and AppKit only, no logging,
#                 no app named, imported by nothing of ours
#   all           all of them (the default)
#
#   --no-build    run the binaries built by the last run
#
# Safety: each suite runs with HOME and CFFIXED_USER_HOME at Checks/.work/<suite>/home, a throwaway folder it empties and
# fills with sample accounts (example.com). Nothing reads the real Keychain, Terminal's real preferences or the real
# Claude Code folders; only processes a suite started are signalled, by their pids. A suite refuses to run when its home is
# anywhere else. Outside Checks/.work only ~/Library/Preferences/cl_kit-checks-<suite>.plist is ever removed (a process's
# name is its preference domain), and only when this run made it.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
kit_root="$(cd "$HERE/.." && pwd)"
WORK="$HERE/.work"
LOCK=/private/tmp/cl_kit-build.lock
. "$kit_root/scripts/modules.sh"

suites=(); build=1
for a in "$@"; do
  case "$a" in
    core|runs|auth|claudesignin|nokeychain|addressprivacy|menurows) suites+=("$a") ;;
    all) suites+=(core runs auth claudesignin nokeychain addressprivacy menurows) ;;
    --no-build) build=0 ;;
    -h|--help) sed -n '2,34p' "$0"; exit 0 ;;
    *) echo "unknown argument: $a" >&2; exit 64 ;;
  esac
done
[[ ${#suites[@]} -gt 0 ]] || suites=(core runs auth claudesignin nokeychain addressprivacy menurows)

# swiftc through one lock, so parallel runs (this tree and a vendored copy) take turns
locked() { /usr/bin/lockf -k "$LOCK" "$@"; }

# the modules with Auth/Keychain.swift, testing on (a suite may `@testable import` them)
MODS="$WORK/modules"
if [[ $build -eq 1 ]]; then
  rm -rf "$MODS"
  locked bash -c '. "$1/scripts/modules.sh"; kit_build "$2" keychain -Onone -enable-testing' _ "$kit_root" "$MODS" \
    || { echo "compile failed: the modules" >&2; exit 1; }
fi
[[ -f "$MODS/libClaudeAuth.a" ]] || { echo "no modules at $MODS (run without --no-build)" >&2; exit 1; }
link=(); while IFS= read -r f; do link+=("$f"); done < <(kit_link "$MODS")

fresh_home() {   # fresh_home DIR: DIR must be Checks/.work/<suite>/home; it is emptied and made again
  case "$1" in "$WORK"/*/home) ;; *) echo "refusing: $1 is not a Checks/.work/<suite>/home" >&2; exit 2 ;; esac
  [[ -n "$HOME" && "$1" != "$HOME" ]] || { echo "refusing: home is the real home" >&2; exit 2; }
  rm -rf "$1"; mkdir -p "$1"
}

# run_binary SUITE BIN [env...]: in the throwaway home; the binary's own preference file goes after, if this run made it
run_binary() {
  local s="$1" bin="$2"; shift 2
  local home="$WORK/$s/home" plist="$HOME/Library/Preferences/$(basename "$bin").plist" had=0 status=0
  fresh_home "$home"
  [[ -e "$plist" ]] && had=1
  env "$@" HOME="$home" CFFIXED_USER_HOME="$home" "$bin" || status=$?
  if [[ $had -eq 0 ]] && ! pgrep -f "$bin" >/dev/null 2>&1; then sleep 1; rm -f -- "$plist"; fi
  return $status
}

compile_suite() {   # compile_suite SUITE: Checks/<suite>/main.swift against the modules only
  local s="$1" bin="$WORK/$1/cl_kit-checks-$1"
  mkdir -p "$WORK/$s"
  if [[ $build -eq 1 ]]; then
    rm -f "$bin"
    locked swiftc -Onone -swift-version 5 -target "$kit_target" -o "$bin" "$HERE/$s/main.swift" "${link[@]}" || true
  fi
  [[ -x "$bin" ]] || { echo "compile failed: $bin" >&2; return 1; }
}

run_simple() {   # core, runs, auth
  compile_suite "$1" || return 1
  run_binary "$1" "$WORK/$1/cl_kit-checks-$1"
}

run_claudesignin() {
  local main="$HERE/claudesignin/main.swift" lint=0 made handed f
  local keys='KeychainSignIn|/usr/bin/security|find-generic-password|SecItem|SecKeychain|kSecClass|import Security|StoredSignInReader|systemWithKeychain|KeychainSignInReader|stored:'
  for f in "$kit_root/Auth/ClaudeSignIn.swift" "$main"; do
    if grep -n -E "$keys" "$f" | grep -v -E '^[0-9]+: *//' | grep -q .; then
      echo "FAIL keychain lint: $f names the Keychain or a stored sign-in reader: $(grep -n -E "$keys" "$f" | grep -v -E '^[0-9]+: *//' | head -2)"; lint=1
    fi
  done
  [[ $lint -ne 0 ]] || echo "keychain lint: ClaudeSignIn.swift and its suite name no Keychain and pass no stored reader"
  made="$(grep -c 'ClaudeSignIn(' "$main" || true)"
  handed="$(grep -c 'terminalProfiles: prefs.tool' "$main" || true)"
  if [[ "$made" != "$handed" || "$made" == 0 ]]; then
    echo "FAIL terminal lint: $made ClaudeSignIn(...) in the suite, $handed with a stand-in for Terminal's preferences"; lint=1
  elif grep -n -E 'com\.apple\.Terminal|TerminalProfiles\.system|\.system\b.*terminalProfiles' "$main" | grep -v -E '^[0-9]+: *//' | grep -q .; then
    echo "FAIL terminal lint: the suite names Terminal's real preferences"; lint=1
  else
    echo "terminal lint: $made/$made sign-ins in the suite are handed Terminal-preferences stand-ins"
  fi
  compile_suite claudesignin || return 1
  # the ad-hoc stand-in for the environment branch (bash, a platform binary, shows the kernel no environment)
  local adhoc="$WORK/claudesignin/adhoc/claude"
  if [[ $build -eq 1 ]]; then mkdir -p "$(dirname "$adhoc")"; rm -f "$adhoc"; clang -O0 -o "$adhoc" "$HERE/claudesignin/adhoc.c" || true; fi
  [[ -x "$adhoc" ]] || { echo "compile failed: $adhoc" >&2; return 1; }
  [[ -x "$HERE/claudesignin/bin/claude" ]] || chmod +x "$HERE/claudesignin/bin/claude"
  local status=0
  run_binary claudesignin "$WORK/claudesignin/cl_kit-checks-claudesignin" \
    CL_SIGNIN_CLAUDE="$HERE/claudesignin/bin/claude" CL_SIGNIN_ADHOC="$adhoc" || status=$?
  [[ $lint -eq 0 ]] || status=1
  return $status
}

run_nokeychain() {
  local out="$WORK/nokeychain/modules" n=0 bad=0 lib
  mkdir -p "$WORK/nokeychain"
  if [[ $build -eq 1 ]]; then
    rm -rf "$out"
    locked bash -c '. "$1/scripts/modules.sh"; kit_build "$2" no-keychain -O' _ "$kit_root" "$out" \
      || { echo "FAIL nokeychain: ClaudeAuth doesn't build without Auth/Keychain.swift"; return 1; }
  fi
  # each tool's output is captured whole first, then searched: a `tool | grep -q` under pipefail can pass vacuously (an
  # early match ends grep, the tool dies of SIGPIPE, and the pipeline's status is the tool's); an empty capture is a failure
  local undefined syms text
  for lib in "$out"/libProfileCore.a "$out"/libRuns.a "$out"/libClaudeAuth.a; do
    [[ -f "$lib" ]] || { echo "FAIL nokeychain: no $lib"; return 1; }
    n=$((n + 2))
    undefined="$(nm -u "$lib" 2>/dev/null)"; text="$(strings "$lib" 2>/dev/null)"
    [[ -n "$text" ]] || { echo "FAIL nokeychain: $(basename "$lib") couldn't be read"; bad=1; }
    if grep -q -E '_Sec[A-Z]' <<<"$undefined"; then echo "FAIL nokeychain: $(basename "$lib") calls the Security API"; bad=1; fi
    if grep -q -E '/usr/bin/security|find-generic-password' <<<"$text"; then echo "FAIL nokeychain: $(basename "$lib") holds the security tool"; bad=1; fi
  done
  syms="$(nm "$out/libClaudeAuth.a" 2>/dev/null)"; text="$(strings "$out/libClaudeAuth.a" 2>/dev/null)"
  [[ -n "$syms" ]] || { echo "FAIL nokeychain: ClaudeAuth's symbols couldn't be read"; bad=1; }
  n=$((n + 1))
  if grep -q -E 'KeychainSignIn' <<<"$syms"; then echo "FAIL nokeychain: ClaudeAuth still has KeychainSignIn"; bad=1; fi
  # the same build ships no session or chat reader (Auth/DiscoveryApp.swift left out): an incognito app's. The functions by
  # their mangled names (FoundAccount.Source's own case names, appSessions among them, stay in Discovery.swift)
  n=$((n + 2))
  if grep -q -E 'AccountSourcesO18transcriptAccounts|AccountSourcesO11appSessions' <<<"$syms"; then
    echo "FAIL nokeychain: ClaudeAuth still has the transcript or app-session reader"; bad=1; fi
  if grep -q -E 'local-agent-mode-sessions|claude-code-sessions' <<<"$text"; then
    echo "FAIL nokeychain: ClaudeAuth still holds the session folders' names"; bad=1; fi
  [[ $bad -eq 0 ]] && echo "nokeychain: $n passed, 0 failed (ClaudeAuth builds without Auth/Keychain.swift and Auth/DiscoveryApp.swift: no Keychain, no session or chat reader)"
  return $bad
}

# the addressprivacy suite: AddressPrivacy (Privacy/) built on its own, and Checks/addressprivacy/main.swift against it alone.
# Its lint first (a failed lint makes the suite red, the checks still run): Privacy/ imports Apple's Foundation, AppKit,
# CoreImage, Combine and SwiftUI only (no module of ours), never logs, names no app; and no layer module imports it.
run_addressprivacy() {
  local lint=0 n=0 f bad
  for f in "$kit_root"/Privacy/*.swift; do
    n=$((n + 3))
    # every import, attributed ones too (@testable, @_exported, @preconcurrency); only the plain form of the five is allowed
    bad="$(grep -n -E '^[[:space:]]*(@[A-Za-z_]+(\([^)]*\))?[[:space:]]+)*import[[:space:]]' "$f" \
      | grep -v -E '^[0-9]+:[[:space:]]*import (Foundation|AppKit|CoreImage|Combine|SwiftUI)[[:space:]]*$' || true)"
    [[ -z "$bad" ]] || { echo "FAIL privacy lint: $f imports more than Apple's UI frameworks: $bad"; lint=1; }
    bad="$(grep -n -E '\b(NSLog|os_log|Logger\(|print\()' "$f" | grep -v -E '^[0-9]+: *//' || true)"
    [[ -z "$bad" ]] || { echo "FAIL privacy lint: $f logs: $(printf '%s' "$bad" | head -2)"; lint=1; }
    bad="$(grep -n -i -E 'cl_audit|cl_quick|cl-audit|cl-quick|usage-n-uf' "$f" || true)"
    [[ -z "$bad" ]] || { echo "FAIL privacy lint: $f names an app: $(printf '%s' "$bad" | head -2)"; lint=1; }
  done
  n=$((n + 1))
  bad="$(grep -n -E '^[[:space:]]*(@[A-Za-z_]+(\([^)]*\))?[[:space:]]+)*import[[:space:]]+([a-z]+[[:space:]]+)?AddressPrivacy([^A-Za-z0-9_]|$)' \
    "$kit_root"/Core/*.swift "$kit_root"/Run/*.swift "$kit_root"/Auth/*.swift || true)"
  [[ -z "$bad" ]] || { echo "FAIL privacy lint: a layer module imports AddressPrivacy: $bad"; lint=1; }
  [[ $lint -ne 0 ]] || echo "privacy lint: $n/$n (Apple's frameworks only, no logging, no app named, imported by no layer)"
  local mods="$WORK/addressprivacy/modules" bin="$WORK/addressprivacy/cl_kit-checks-addressprivacy" plink=()
  mkdir -p "$WORK/addressprivacy"
  if [[ $build -eq 1 ]]; then
    rm -rf "$mods" "$bin"
    locked bash -c '. "$1/scripts/modules.sh"; kit_build_privacy "$2" -Onone' _ "$kit_root" "$mods" \
      || { echo "compile failed: AddressPrivacy" >&2; return 1; }
    while IFS= read -r f; do plink+=("$f"); done < <(kit_privacy_link "$mods")
    locked swiftc -Onone -swift-version 5 -target "$kit_target" -o "$bin" "$HERE/addressprivacy/main.swift" "${plink[@]}" || true
  fi
  [[ -x "$bin" ]] || { echo "compile failed: $bin" >&2; return 1; }
  local status=0
  run_binary addressprivacy "$bin" || status=$?
  [[ $lint -eq 0 ]] || status=1
  return $status
}

# the menurows suite: MenuRows (MenuRows/) built on ProfileCore (the modules above) and AddressPrivacy, testing on, and
# Checks/menurows/main.swift against the three. Its lint first (a failed lint makes the suite red, the checks still run):
# MenuRows imports ProfileCore, AddressPrivacy, Foundation and AppKit only, never logs, names no app; nothing of ours
# imports it.
run_menurows() {
  local lint=0 n=0 f bad
  for f in "$kit_root"/MenuRows/*.swift; do
    n=$((n + 3))
    bad="$(grep -n -E '^[[:space:]]*(@[A-Za-z_]+(\([^)]*\))?[[:space:]]+)*import[[:space:]]' "$f" \
      | grep -v -E '^[0-9]+:[[:space:]]*import (Foundation|AppKit|ProfileCore|AddressPrivacy)[[:space:]]*$' || true)"
    [[ -z "$bad" ]] || { echo "FAIL menurows lint: $f imports more than ProfileCore, AddressPrivacy and Apple's AppKit: $bad"; lint=1; }
    bad="$(grep -n -E '\b(NSLog|os_log|Logger\(|print\(|debugPrint\(|dump\(|fputs\()' "$f" | grep -v -E '^[0-9]+: *//' || true)"
    [[ -z "$bad" ]] || { echo "FAIL menurows lint: $f logs: $(printf '%s' "$bad" | head -2)"; lint=1; }
    bad="$(grep -n -i -E 'cl_audit|cl_quick|cl-audit|cl-quick|usage-n-uf' "$f" | grep -v -E '^[0-9]+: *//' || true)"
    [[ -z "$bad" ]] || { echo "FAIL menurows lint: $f names an app: $(printf '%s' "$bad" | head -2)"; lint=1; }
  done
  n=$((n + 1))
  bad="$(grep -n -E '^[[:space:]]*(@[A-Za-z_]+(\([^)]*\))?[[:space:]]+)*import[[:space:]]+([a-z]+[[:space:]]+)?MenuRows([^A-Za-z0-9_]|$)' \
    "$kit_root"/Core/*.swift "$kit_root"/Run/*.swift "$kit_root"/Auth/*.swift "$kit_root"/Privacy/*.swift || true)"
  [[ -z "$bad" ]] || { echo "FAIL menurows lint: a module of ours imports MenuRows: $bad"; lint=1; }
  [[ $lint -ne 0 ]] || echo "menurows lint: $n/$n (ProfileCore, AddressPrivacy and AppKit only, no logging, no app named, imported by nothing of ours)"
  local mods="$WORK/menurows/modules" bin="$WORK/menurows/cl_kit-checks-menurows" mlink=()
  mkdir -p "$WORK/menurows"
  if [[ $build -eq 1 ]]; then
    rm -rf "$mods" "$bin"; mkdir -p "$mods"
    cp -R "$MODS"/ProfileCore.swiftmodule "$MODS"/libProfileCore.a "$mods"/
    locked bash -c '. "$1/scripts/modules.sh"; kit_build_privacy "$2" -Onone && kit_build_menurows "$2" -Onone -enable-testing' \
      _ "$kit_root" "$mods" || { echo "compile failed: AddressPrivacy or MenuRows" >&2; return 1; }
    while IFS= read -r f; do mlink+=("$f"); done < <(kit_menurows_link "$mods")
    while IFS= read -r f; do mlink+=("$f"); done < <(kit_privacy_link "$mods")
    locked swiftc -Onone -swift-version 5 -target "$kit_target" -o "$bin" "$HERE/menurows/main.swift" "${mlink[@]}" \
      -lProfileCore || true
  fi
  [[ -x "$bin" ]] || { echo "compile failed: $bin" >&2; return 1; }
  local status=0
  run_binary menurows "$bin" || status=$?
  [[ $lint -eq 0 ]] || status=1
  return $status
}

status=0; failed=()
for s in "${suites[@]}"; do
  echo "── $s"
  case "$s" in
    claudesignin) run_claudesignin ;;
    nokeychain) run_nokeychain ;;
    addressprivacy) run_addressprivacy ;;
    menurows) run_menurows ;;
    *) run_simple "$s" ;;
  esac
  [[ $? -eq 0 ]] || { status=1; failed+=("$s"); }
done
if [[ $status -eq 0 ]]; then echo "cl_kit checks: all green (${suites[*]})"; else echo "cl_kit checks: RED: ${failed[*]}"; fi
exit $status
