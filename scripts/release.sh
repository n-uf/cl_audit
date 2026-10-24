#!/bin/bash
# Calendar-version release for cl_audit: YY.M.R (see README ▸ Versioning).
# YY.M is the release DATE's year and month, never "last month + 1"; R counts releases within that
# month and starts again at 0 when the month changes, skipping burned numbers and existing tags.
#
#   scripts/release.sh --dry-run   print the next version
#   scripts/release.sh             bump VERSION, date the CHANGELOG's Unreleased notes,
#                                  commit "release X" and tag vX
#   scripts/release.sh --nobump    the same without changing VERSION
#   scripts/release.sh --push      also push main and the tag, and publish the GitHub Release with a
#                                  ready-built cl_audit.zip for direct download
# Test overrides: CALENDAR_VERSION_TODAY=YYYY-MM-DD, CALENDAR_VERSION_CURRENT=YY.M.R
set -euo pipefail
cd "$(dirname "$0")/.."

# Numbers never to use again (for example a tag that was pushed and then deleted). None yet.
BURNED=" "

dry=0 nobump=0 push=0
for a in "$@"; do
  case "$a" in
    --dry-run) dry=1 ;;
    --nobump) nobump=1 ;;
    --push) push=1 ;;
    *) echo "unknown option $a" >&2; exit 1 ;;
  esac
done

current="${CALENDAR_VERSION_CURRENT:-$(tr -d '[:space:]' < VERSION)}"
if [[ ! $current =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  echo "VERSION \"$current\" is not a three-part number such as 26.10.0" >&2; exit 1
fi
cy=$((10#${BASH_REMATCH[1]})) cm=$((10#${BASH_REMATCH[2]})) cr=$((10#${BASH_REMATCH[3]}))

today="${CALENDAR_VERSION_TODAY:-$(date +%F)}"
if [[ ! $today =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then echo "date \"$today\" is not YYYY-MM-DD" >&2; exit 1; fi
ty=$((10#${today:2:2})) tm=$((10#${today:5:2}))

if [ $nobump = 1 ]; then
  next="$current"
else
  if [ $cy = $ty ] && [ $cm = $tm ]; then r=$((cr + 1)); else r=0; fi
  while [[ $BURNED == *" $ty.$tm.$r "* ]] || git rev-parse -q --verify "refs/tags/v$ty.$tm.$r" >/dev/null; do r=$((r + 1)); done
  next="$ty.$tm.$r"
fi

if [ $dry = 1 ]; then echo "$next"; exit 0; fi

# Release only a clean main with notes waiting.
[ "$(git rev-parse --abbrev-ref HEAD)" = main ] || { echo "release from main" >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "commit or stash your changes first" >&2; exit 1; }
if git rev-parse -q --verify "refs/tags/v$next" >/dev/null; then echo "v$next is already tagged" >&2; exit 1; fi
notes="$(awk '/^## Unreleased/{f=1; next} /^## /{f=0} f' CHANGELOG.md | sed '/^[[:space:]]*$/d')"
if [ -z "$notes" ] || [ "$notes" = "Nothing pending." ]; then
  echo "CHANGELOG.md has no Unreleased notes; add them first" >&2; exit 1
fi

# Unreleased notes become this release's section; Unreleased starts empty again.
awk -v v="$next" -v d="$today" '
  /^## Unreleased/ { print; print ""; print "Nothing pending."; print ""; print "## " v " — " d; next }
  { print }' CHANGELOG.md > CHANGELOG.md.tmp && mv CHANGELOG.md.tmp CHANGELOG.md
printf '%s\n' "$next" > VERSION

git add VERSION CHANGELOG.md
git commit -q -m "release $next"
git tag -a "v$next" -m "cl_audit $next"
echo "released $next (commit and tag v$next)"

if [ $push = 1 ]; then
  git push -q origin main
  git push -q origin "v$next"
  echo "pushed main and v$next"

  # The ready-built app for direct download. The file name never changes, so
  # https://github.com/n-uf/cl_audit/releases/latest/download/cl_audit.zip always gets the newest.
  ./build.sh --no-install >/dev/null
  mkdir -p dist && rm -f dist/cl_audit.zip
  ditto -c -k --keepParent build/cl_audit.app dist/cl_audit.zip
  section="$(awk -v h="## $next " 'index($0, h) == 1 {f=1; next} /^## /{f=0} f' CHANGELOG.md)"
  gh release create "v$next" dist/cl_audit.zip --repo n-uf/cl_audit --title "cl_audit $next" --notes "$section

---

**Download:** \`cl_audit.zip\` below (Apple silicon, macOS 13 or later). Unzip it, move **cl_audit** to Applications and open it. The first time, macOS says it can't verify the app: open System Settings ▸ Privacy & Security and click **Open Anyway** (once). Or build it from source, see the README."
  echo "published the GitHub Release v$next with cl_audit.zip"
fi
