#!/usr/bin/env bash
# One real question through the quick chat's engine and the installed `claude`.
#   Checks/quick-chat/real.sh              a throwaway, signed-out folder: Claude Code says it isn't signed in
#   QC_CONFIG=~/.claude-x Checks/quick-chat/real.sh   that folder's account answers (uses a little of its usage)
# QC_MODEL (haiku), QC_EFFORT (empty: thinking off), QC_QUESTION. The work folder and the throwaway folder are under
# build/; with QC_CONFIG, the session Claude Code keeps for the work folder is removed afterwards.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
out="$repo/build/checks/quick-chat"
mkdir -p "$out"
claude="${QC_CLAUDE:-$(command -v claude)}"
work="$out/real-work"
config="${QC_CONFIG:-$out/throwaway-config}"
mkdir -p "$config" "$work"
swiftc -swift-version 5 -target arm64-apple-macos13.0 -o "$out/real" \
  "$repo/Sources/QuickChatEngine.swift" "$here/real/main.swift"
status=0
QC_CLAUDE="$claude" QC_CONFIG="$config" QC_WORK="$work" "$out/real" || status=$?
# what Claude Code kept for this run: in a real folder, its session under projects/; the throwaway folder goes whole
key="$(printf '%s' "$work" | sed 's/[^A-Za-z0-9]/-/g')"
if [ -z "${QC_CONFIG:-}" ]; then rm -rf "$config"; elif [ -n "$key" ]; then rm -rf "$config/projects/$key"; fi
exit "$status"
