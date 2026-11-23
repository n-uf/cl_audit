# cl_kit's modules, built from source as static libraries in their layers. Sourced (bash) by scripts/build.sh,
# Checks/run.sh and by each app that vendors cl_kit (its own build and checks source the vendored copy's file):
#
#   ProfileCore  Core/*.swift   Foundation only; imports nothing of ours. Built as an app extension may use it (a widget links it)
#   Runs         Run/*.swift    Foundation only; the one runner, the cleaned environment, the process table
#   ClaudeAuth   Auth/*.swift   imports ProfileCore and Runs: one folder's Claude Code sign-in, ClaudeSignIn.
#                               Auth/Keychain.swift is optional: an app that never reads the Keychain builds without it
#                               (no-keychain), and without Auth/DiscoveryApp.swift too (the sources that read sessions
#                               and chats: an incognito app ships no chat reader)
#
# and on its own, apart from the layers (it imports none of them, and they never import it):
#
#   AddressPrivacy  Privacy/*.swift  Foundation, AppKit, CoreImage, Combine, SwiftUI: an account address hidden on screen
#
# and on top of ProfileCore and AddressPrivacy (it imports those two only; nothing of ours imports it):
#
#   MenuRows     MenuRows/*.swift   Foundation, AppKit: one account row of a menu, its usage line from ProfileCore's display
#
#   kit_build OUT keychain|no-keychain [swiftc flags...]   builds the three into OUT (-O, -Onone, -enable-testing are the caller's)
#   kit_link OUT                                           prints the flags that link them, one per line
#   kit_build_privacy OUT [swiftc flags...]                builds AddressPrivacy into OUT
#   kit_privacy_link OUT                                   prints the flags that link it (with its frameworks), one per line
#   kit_build_menurows OUT [swiftc flags...]               builds MenuRows into OUT, which must already hold ProfileCore and
#                                                          AddressPrivacy (kit_build, kit_build_privacy into the same OUT)
#   kit_menurows_link OUT                                  prints the flags that link it, one per line: put them BEFORE
#                                                          kit_privacy_link's and ProfileCore's (a static library comes
#                                                          before the ones it needs)
#   kit_sources Core|Run|Auth|Privacy|MenuRows [left-out names...]  prints a module's source files, one per line
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
    # an app that never reads the Keychain (cl_quick, incognito) also ships no session or chat reader
    while IFS= read -r f; do auth+=("$f"); done < <(kit_sources Auth Keychain.swift DiscoveryApp.swift)
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

kit_build_privacy() {
  local out="$1"; shift
  local srcs=() f
  while IFS= read -r f; do srcs+=("$f"); done < <(kit_sources Privacy)
  mkdir -p "$out"
  rm -f "$out"/libAddressPrivacy.a
  swiftc -swift-version 5 -parse-as-library -target "$kit_target" "$@" -module-name AddressPrivacy \
    -emit-module -emit-module-path "$out/AddressPrivacy.swiftmodule" -emit-library -static -o "$out/libAddressPrivacy.a" \
    "${srcs[@]}" || return 1
}

kit_privacy_link() {
  printf '%s\n' -I "$1" -L "$1" -lAddressPrivacy -framework AppKit -framework SwiftUI -framework CoreImage -framework Combine
}

kit_build_menurows() {
  local out="$1"; shift
  local srcs=() f
  [ -f "$out/ProfileCore.swiftmodule" ] || [ -d "$out/ProfileCore.swiftmodule" ] || { echo "kit_build_menurows: no ProfileCore in $out (kit_build first)" >&2; return 1; }
  [ -f "$out/AddressPrivacy.swiftmodule" ] || [ -d "$out/AddressPrivacy.swiftmodule" ] || { echo "kit_build_menurows: no AddressPrivacy in $out (kit_build_privacy first)" >&2; return 1; }
  while IFS= read -r f; do srcs+=("$f"); done < <(kit_sources MenuRows)
  rm -f "$out"/libMenuRows.a
  swiftc -swift-version 5 -parse-as-library -target "$kit_target" "$@" -module-name MenuRows -I "$out" \
    -emit-module -emit-module-path "$out/MenuRows.swiftmodule" -emit-library -static -o "$out/libMenuRows.a" \
    "${srcs[@]}" || return 1
}

kit_menurows_link() { printf '%s\n' -I "$1" -L "$1" -lMenuRows; }
