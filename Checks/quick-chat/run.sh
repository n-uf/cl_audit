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
# the engine runs its claude through Runs (Run/, the one runner): built first, as build.sh does
swiftc -swift-version 5 -parse-as-library -module-name Runs -target arm64-apple-macos13.0 \
  -emit-module -emit-module-path "$out/Runs.swiftmodule" -emit-library -static -o "$out/libRuns.a" "$repo"/Run/*.swift
swiftc -swift-version 5 -target arm64-apple-macos13.0 -o "$out/checks" -I "$out" -L "$out" -lRuns \
  "$repo/Sources/QuickChatEngine.swift" "$repo/Sources/QuickChatMarkdown.swift" "$repo/Sources/FolderGuard.swift" "$here/main.swift"
QC_STUB_PATH="$here/stub-claude" QC_WORK="$out/work" "$out/checks"
