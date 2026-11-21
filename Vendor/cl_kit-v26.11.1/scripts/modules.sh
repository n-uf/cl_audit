# cl_kit's modules, built from source as static libraries in their layers. Sourced (bash) by scripts/build.sh,
# Checks/run.sh and by each app that vendors cl_kit (its own build and checks source the vendored copy's file):
#
#   ProfileCore  Core/*.swift   Foundation only; imports nothing of ours. Built as an app extension may use it (a widget links it)
#   Runs         Run/*.swift    Foundation only; the one runner, the cleaned environment, the process table
#   ClaudeAuth   Auth/*.swift   imports ProfileCore and Runs: one folder's Claude Code sign-in, ClaudeSignIn.
#                               Auth/Keychain.swift is optional: an app that never reads the Keychain builds without it
#
#   kit_build OUT keychain|no-keychain [swiftc flags...]   builds the three into OUT (-O, -Onone, -enable-testing are the caller's)
#   kit_link OUT                                           prints the flags that link them, one per line
#   kit_sources Core|Run|Auth [left-out file names...]     prints a module's source files, one per line
#
# Every module: Swift 5 language mode, macOS 13, arm64. Needs $kit_root only if this file isn't in <kit>/scripts/.

kit_root="${kit_root:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
kit_target="arm64-apple-macos13.0"

kit_sources() {
  local dir="$1"; shift
  local f b s out
  for f in "$kit_root/$dir"/*.swift; do
    [ -e "$f" ] || continue
    b="$(basename "$f")"
    out=0; for s in "$@"; do [ "$s" = "$b" ] && out=1; done
    [ "$out" = 1 ] || printf '%s\n' "$f"
  done
}

kit_build() {
  local out="$1" keychain="$2"; shift 2
  case "$keychain" in keychain|no-keychain) ;; *) echo "kit_build: say keychain or no-keychain, not '$keychain'" >&2; return 64 ;; esac
  local common=(-swift-version 5 -parse-as-library -target "$kit_target" "$@")
  local core=() runs=() auth=() f
  while IFS= read -r f; do core+=("$f"); done < <(kit_sources Core)
  while IFS= read -r f; do runs+=("$f"); done < <(kit_sources Run)
  if [ "$keychain" = keychain ]; then
    while IFS= read -r f; do auth+=("$f"); done < <(kit_sources Auth)
  else
    while IFS= read -r f; do auth+=("$f"); done < <(kit_sources Auth Keychain.swift)
  fi
  mkdir -p "$out"
  rm -f "$out"/libProfileCore.a "$out"/libRuns.a "$out"/libClaudeAuth.a
  swiftc "${common[@]}" -module-name ProfileCore -application-extension \
    -emit-module -emit-module-path "$out/ProfileCore.swiftmodule" -emit-library -static -o "$out/libProfileCore.a" "${core[@]}" || return 1
  swiftc "${common[@]}" -module-name Runs \
    -emit-module -emit-module-path "$out/Runs.swiftmodule" -emit-library -static -o "$out/libRuns.a" "${runs[@]}" || return 1
  swiftc "${common[@]}" -module-name ClaudeAuth -I "$out" \
    -emit-module -emit-module-path "$out/ClaudeAuth.swiftmodule" -emit-library -static -o "$out/libClaudeAuth.a" "${auth[@]}" || return 1
}

kit_link() { printf '%s\n' -I "$1" -L "$1" -lClaudeAuth -lRuns -lProfileCore; }
