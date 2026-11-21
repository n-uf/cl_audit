#!/usr/bin/env bash
# Build cl_kit's modules as static libraries into build/ (or OUT), in their layers ProfileCore -> Runs -> ClaudeAuth,
# optimised, Swift 5 language mode, macOS 13 (scripts/modules.sh).
#   scripts/build.sh                  with Auth/Keychain.swift (as cl_audit builds it)
#   scripts/build.sh --no-keychain    without it (as cl_quick builds it: nothing it compiles can read the Keychain)
#   OUT=<dir> scripts/build.sh ...    somewhere else than build/
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/modules.sh"
keychain=keychain
for a in "$@"; do
  case "$a" in
    --no-keychain) keychain=no-keychain ;;
    -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
    *) echo "unknown argument: $a" >&2; exit 64 ;;
  esac
done
out="${OUT:-$kit_root/build}"
echo "cl_kit $(tr -d '[:space:]' < "$kit_root/VERSION"): ProfileCore, Runs, ClaudeAuth ($keychain) into $out"
kit_build "$out" "$keychain" -O
ls "$out"/lib*.a
