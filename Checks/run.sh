#!/usr/bin/env bash
# The one entry point for cl_audit's check suites.
#
#   Checks/run.sh [signin|backup|firstrun|retention|render|quick-chat|scan|all] [--volume] [--no-build]
#
#   signin    the model, rules and page logic checks (sign-in, switch, backups, export and import, crimson faces ...)
#   backup    the Sessions backup, restore, export and import checks (hostile zips, an encrypted image, a second volume)
#   firstrun  the first-run page and the Claude lookup
#   retention which transcripts Claude Code's clean-up deletes (window sessions, release markers, managed settings), Restore/Import's Would be deleted
#   render    pictures of the pages (switch, backups, restore, export, import, first run) into Checks/.work/render
#   quick-chat  the quick chat's own checks (Checks/quick-chat/run.sh, run here under the build lock)
#   scan      the app's own SecretScan over every file in Checks/ (zero hits expected)
#   all       signin, backup, firstrun, retention, render, quick-chat, scan (the default)
#
#   --volume    backup: mount a small HFS+ disk image and run the cross-volume checks on it (it is unmounted again)
#   --no-build  run the binaries built by the last run
#   APP=<worktree>  check another tree than the one this file is in
#
# Every compile goes through the shared build lock. The suites are heavy: wrap the whole call in a heavy-work queue if your
# machine has one.
#
# Safety: each suite runs with HOME and CFFIXED_USER_HOME at Checks/.work/<suite>/home, a throwaway folder it empties and
# fills with sample accounts and sessions. Nothing here opens the app, the Dock or Terminal, and nothing reads the real
# data. A suite (and this script) refuses to run when its home is anywhere else. Outside Checks/.work it only touches the
# preference files named in clean_prefs below (it removes them) and, for quick-chat, the build/checks folder of the repo.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
APP="${APP:-$REPO}"
WORK="$HERE/.work"
LOCK=/private/tmp/cl_audit-build.lock

suites=(); volume=0; build=1
for a in "$@"; do
  case "$a" in
    signin|backup|firstrun|retention|render|quick-chat|scan) suites+=("$a") ;;
    all) suites+=(signin backup firstrun retention render quick-chat scan) ;;
    --volume) volume=1 ;;
    --no-build) build=0 ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "unknown argument: $a" >&2; exit 64 ;;
  esac
done
[[ ${#suites[@]} -gt 0 ]] || suites=(signin backup firstrun retention render quick-chat scan)

# the app's sources without its own main.swift, plus the widget views the app compiles in
srcs=()
for f in "$APP"/Sources/*.swift; do [[ "$(basename "$f")" == main.swift ]] || srcs+=("$f"); done
srcs+=("$APP/Widget/WidgetViews.swift")
frameworks=(-framework AppKit -framework SwiftUI -framework Charts -framework Security -framework ServiceManagement
            -framework UserNotifications -framework WidgetKit)

# compile BIN MAIN...: through the build lock; a failed compile must not leave the last binary to run
compile() {
  local bin="$1"; shift
  [[ $build -eq 1 ]] || { [[ -x "$bin" ]] || { echo "no binary at $bin (run without --no-build)" >&2; return 1; }; return 0; }
  rm -f "$bin"
  /usr/bin/lockf -k "$LOCK" swiftc -Onone -swift-version 5 -target arm64-apple-macos14.0 \
    -o "$bin" -D STAGE3 "${srcs[@]}" "$@" "${frameworks[@]}" 2>&1 | grep -E "error" || true
  [[ -x "$bin" ]] || { echo "compile failed: $bin" >&2; return 1; }
}

# fresh_home DIR: DIR must be Checks/.work/<suite>/home (or below render/); it is emptied and made again
fresh_home() {
  case "$1" in
    "$WORK"/*/home|"$WORK"/render/*/home) ;;
    # the second homes the backup suite's child roles run in (it makes them itself; they are emptied here before a run)
    "$WORK"/backup/other/backup-test/home|"$WORK"/backup/other-tz/backup-test/home) ;;
    *) echo "refusing: $1 is not a Checks/.work/<suite>/home" >&2; exit 2 ;;
  esac
  [[ -n "$HOME" && "$1" != "$HOME" ]] || { echo "refusing: home is the real home" >&2; exit 2; }
  rm -rf "$1"; mkdir -p "$1"
}

# The checks' preference suites land in the real ~/Library/Preferences whatever CFFIXED_USER_HOME says (cfprefsd writes them,
# sometimes a moment after the run ends). Only these names are ever removed, and only when no run of ours is alive:
#  - cl-audit-{signin,hide,switch,plan}-test-<pid>.plist, when that pid is dead (the suites' own domains, pid in the name);
#  - <binary name>.plist for the binaries this script builds (cl_audit-checks-signin, -backup, -firstrun, -retention, -render-pages,
#    -render-firstrun, -scan): a process's name is its preference domain, and these names belong to no other program;
#  - cl_audit-backwatch-test.plist and cl_audit-reader-switch-test.plist (named by the suites' own code, no pid), only when
#    they were not there before this run.
suite_prefs=(cl_audit-backwatch-test.plist cl_audit-reader-switch-test.plist)
pref_before=()
note_prefs() {
  pref_before=()
  for n in "${suite_prefs[@]}"; do [[ -e "$HOME/Library/Preferences/$n" ]] && pref_before+=("$n"); done
}
clean_prefs() {   # clean_prefs BIN
  sleep 2
  local f p n had b alive=0
  pgrep -f "$WORK/[^ ]*/cl_audit-checks-" >/dev/null 2>&1 && alive=1
  for f in "$HOME"/Library/Preferences/cl-audit-{signin,hide,switch,plan}-test-*.plist; do
    [[ -e "$f" ]] || continue
    p="${f##*-}"; p="${p%.plist}"
    [[ "$p" =~ ^[0-9]+$ ]] || continue
    kill -0 "$p" 2>/dev/null || rm -f -- "$f"
  done
  pgrep -f "$1" >/dev/null 2>&1 || rm -f -- "$HOME/Library/Preferences/$(basename "$1").plist"
  [[ $alive -eq 0 ]] || return 0
  for n in "${suite_prefs[@]}"; do
    [[ -e "$HOME/Library/Preferences/$n" ]] || continue
    had=0; for b in ${pref_before[@]+"${pref_before[@]}"}; do [[ "$b" == "$n" ]] && had=1; done
    [[ $had -eq 1 ]] || rm -f -- "$HOME/Library/Preferences/$n"
  done
}

run_binary() {  # run_binary SUITE-DIR BIN [args...]: in the throwaway home, with the prefs cleaned afterwards
  local dir="$1" bin="$2"; shift 2
  fresh_home "$dir/home"
  note_prefs
  local status=0
  HOME="$dir/home" CFFIXED_USER_HOME="$dir/home" "$bin" "$@" || status=$?
  clean_prefs "$bin"
  return $status
}

run_signin() {
  [[ -f "$HERE/signin/main.swift" ]] || { echo "signin: not in this tree yet (see 'Not recovered' in Checks/README.md)"; return 0; }
  local dir="$WORK/signin"; mkdir -p "$dir"
  compile "$dir/cl_audit-checks-signin" "$HERE/signin/main.swift" || return 1
  run_binary "$dir" "$dir/cl_audit-checks-signin"
}

run_backup() {
  [[ -f "$HERE/backup/main.swift" ]] || { echo "backup: not in this tree yet (see 'Not recovered' in Checks/README.md)"; return 0; }
  local dir="$WORK/backup"; mkdir -p "$dir"
  compile "$dir/cl_audit-checks-backup" "$HERE/backup/main.swift" || return 1
  # the suite reads the hostile-zip maker and the zlib probe zips next to its home
  cp "$HERE/backup/mkzips.py" "$dir/mkzips.py"
  fresh_home "$dir/other/backup-test/home"; fresh_home "$dir/other-tz/backup-test/home"   # the child roles' homes (under .work only)
  python3 -I -B "$HERE/backup/xz.py" "$dir/xz" || return 1
  local status=0
  if [[ $volume -eq 1 ]]; then
    # the trap carries its own WORK_BACKUP (and the paths, expanded now: `dir` is gone when it runs), so an interrupted run
    # still unmounts the image
    trap "WORK_BACKUP='$dir' bash '$HERE/backup/vol.sh' down >/dev/null 2>&1 || true" EXIT
    WORK_BACKUP="$dir" bash "$HERE/backup/vol.sh" up || return 1
    BK_VOL="$dir/vol" run_binary "$dir" "$dir/cl_audit-checks-backup" || status=$?
    WORK_BACKUP="$dir" bash "$HERE/backup/vol.sh" down || true
    trap - EXIT
  else
    run_binary "$dir" "$dir/cl_audit-checks-backup" || status=$?
  fi
  return $status
}

run_firstrun() {
  local dir="$WORK/firstrun"; mkdir -p "$dir"
  compile "$dir/cl_audit-checks-firstrun" "$HERE/firstrun/main.swift" || return 1
  run_binary "$dir" "$dir/cl_audit-checks-firstrun"
}

# the retention suite points the organisation's managed-settings sources at folders inside its throwaway home
run_retention() {
  local dir="$WORK/retention"; mkdir -p "$dir"
  compile "$dir/cl_audit-checks-retention" "$HERE/retention/main.swift" || return 1
  run_binary "$dir" "$dir/cl_audit-checks-retention"
}

run_render() {
  local status=0 dir
  dir="$WORK/render/pages"; mkdir -p "$dir"
  rm -rf "$dir/raw" "$dir/out"; mkdir -p "$dir/raw" "$dir/out"
  if compile "$dir/cl_audit-checks-render-pages" "$HERE/render/pages/main.swift"; then
    run_binary "$dir" "$dir/cl_audit-checks-render-pages" "$dir/raw" || status=$?
    # the pages are drawn in tall windows: crop the empty bottom (needs Pillow; without it the raw pictures stay)
    python3 -I -B "$HERE/render/trim.py" "$dir/raw" "$dir/out" >/dev/null 2>&1 || true
  else status=1; fi
  dir="$WORK/render/firstrun"; mkdir -p "$dir"
  rm -rf "$dir/out"; mkdir -p "$dir/out"
  if compile "$dir/cl_audit-checks-render-firstrun" "$HERE/render/firstrun/main.swift"; then
    run_binary "$dir" "$dir/cl_audit-checks-render-firstrun" "$dir/out" || status=$?
  else status=1; fi
  echo "pictures: $WORK/render/pages/raw ($(ls "$WORK/render/pages/raw" 2>/dev/null | wc -l | tr -d ' ')), $WORK/render/firstrun/out ($(ls "$WORK/render/firstrun/out" 2>/dev/null | wc -l | tr -d ' '))"
  return $status
}

run_quick-chat() {
  # its own script compiles with swiftc: held under the build lock for the compile and the (short) run
  /usr/bin/lockf -k "$LOCK" bash "$HERE/quick-chat/run.sh"
}
run_scan() {
  local dir="$WORK/scan"; mkdir -p "$dir"
  compile "$dir/cl_audit-checks-scan" "$HERE/tools/secretscan/main.swift" || return 1
  local st=0
  (cd "$HERE" && find . -path ./.work -prune -o -type f -print0 | xargs -0 "$dir/cl_audit-checks-scan") || st=1
  clean_prefs "$dir/cl_audit-checks-scan"
  # real addresses, ids, personal paths and names too (quick-chat/ is the quick chat's own, with its sample home-folder paths)
  python3 -I -B "$HERE/tools/leakscan.py" "$HERE" --skip quick-chat || st=1
  return $st
}

overall=0
for s in "${suites[@]}"; do
  echo "=== $s"
  "run_${s}"; st=$?
  echo "=== $s exit $st"
  [[ $st -eq 0 ]] || overall=1
done
exit $overall
