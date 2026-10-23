#!/bin/bash
# Claude Code status line: saves this account's plan usage for the Dock usage icon.
# Reads the status line JSON on stdin, writes <config dir>/usage.json, prints "5h N% · wk N%".
# No network, no credentials: the numbers come from what Claude Code passes in.

input=$(cat)
dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
now=$(date +%s)

# Diagnostic marker: proves the status line ran at all, and from which surface.
printf '{"ran_at":%s,"entrypoint":"%s","has_rate_limits":%s}\n' \
  "$now" "${CLAUDE_CODE_ENTRYPOINT:-unknown}" \
  "$(jq 'has("rate_limits") and .rate_limits != null' <<<"$input" 2>/dev/null || echo false)" \
  > "$dir/usage-statusline.last" 2>/dev/null

usage=$(jq -c --argjson now "$now" --arg entry "${CLAUDE_CODE_ENTRYPOINT:-unknown}" '
  select(.rate_limits.five_hour != null or .rate_limits.seven_day != null)
  | {five_hour: .rate_limits.five_hour, seven_day: .rate_limits.seven_day,
     updated_at: $now, source: $entry}' <<<"$input" 2>/dev/null)

# Only replace the file when there are numbers, so a reply without them keeps the last good data.
if [ -n "$usage" ]; then
  tmp="$dir/.usage.json.$$"
  printf '%s\n' "$usage" > "$tmp" && mv -f "$tmp" "$dir/usage.json"
  jq -r '[
      (if .five_hour then "5h \(.five_hour.used_percentage | floor)%" else empty end),
      (if .seven_day then "wk \(.seven_day.used_percentage | floor)%" else empty end)
    ] | join(" · ")' <<<"$usage"
fi
