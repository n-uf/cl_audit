#!/usr/bin/env bash
# The quick chat's checks: the stream-json parser, the `claude` command and its environment, the Markdown blocks, and
# the kept-alive process against a stand-in `claude` (stub-claude). No account, no network, nothing outside the repo
# but a work folder under build/.
#   Checks/quick-chat/run.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
out="$repo/build/checks/quick-chat"
mkdir -p "$out"
chmod +x "$here/stub-claude"
swiftc -swift-version 5 -target arm64-apple-macos13.0 -o "$out/checks" \
  "$repo/Sources/QuickChatEngine.swift" "$repo/Sources/QuickChatMarkdown.swift" "$here/main.swift"
QC_STUB_PATH="$here/stub-claude" QC_WORK="$out/work" "$out/checks"
