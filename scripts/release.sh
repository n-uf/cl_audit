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
#                                  ready-built cl_audit.zip and cl_audit.dmg for direct download
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
  mkdir -p dist && rm -f dist/cl_audit.zip dist/cl_audit.dmg
  ditto -c -k --keepParent build/cl_audit.app dist/cl_audit.zip

  # The same app as a disk image (releases/latest/download/cl_audit.dmg): the app and an Applications shortcut to drag
  # it onto. The app inside must be the zip's app, checked by its code directory hash.
  stage="$(mktemp -d)"
  # whatever fails from here on, no image stays mounted and no temp folder stays behind
  trap 'hdiutil detach -quiet -force "$stage/mnt" 2>/dev/null || true; rm -rf "$stage"' EXIT
  ditto build/cl_audit.app "$stage/cl_audit.app"
  ln -s /Applications "$stage/Applications"
  hdiutil create -quiet -volname "cl_audit $next" -srcfolder "$stage" -fs HFS+ -format UDZO -imagekey zlib-level=9 dist/cl_audit.dmg
  hdiutil verify -quiet dist/cl_audit.dmg
  mkdir "$stage/mnt"
  hdiutil attach -quiet -nobrowse -readonly -noautoopen -mountpoint "$stage/mnt" dist/cl_audit.dmg
  zip_cd="$(codesign -dvvv build/cl_audit.app 2>&1 | grep '^CDHash=' || true)"
  dmg_cd="$(codesign -dvvv "$stage/mnt/cl_audit.app" 2>&1 | grep '^CDHash=' || true)"
  # the same hash says the same signature; this says the files on the image still match it
  codesign --verify --deep --strict "$stage/mnt/cl_audit.app" || { echo "the disk image's app fails its signature check" >&2; exit 1; }
  hdiutil detach -quiet "$stage/mnt" || hdiutil detach -quiet -force "$stage/mnt"
  rm -rf "$stage"
  [ -n "$zip_cd" ] && [ "$zip_cd" = "$dmg_cd" ] || { echo "the disk image's app differs from the zip's ($zip_cd vs $dmg_cd)" >&2; exit 1; }
  zip_sha="$(shasum -a 256 dist/cl_audit.zip | awk '{print $1}')"
  dmg_sha="$(shasum -a 256 dist/cl_audit.dmg | awk '{print $1}')"

  section="$(awk -v h="## $next " 'index($0, h) == 1 {f=1; next} /^## /{f=0} f' CHANGELOG.md)"
  # The Claude versions on this Mac, which this release was checked with (they can drift: see README ▸ Install).
  cc="$(claude --version 2>/dev/null | awk '{print $1}')"
  app="$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" /Applications/Claude.app/Contents/Info.plist 2>/dev/null)"
  checked="Checked with Claude Code ${cc:-?} and the Claude app ${app:-?}. A newer Claude version can change how Claude Code saves its login or the usage figures; if something stops working, update cl_audit."
  echo "$checked  (update README ▸ Install and the site's checkedWith if these changed)"
  gh release create "v$next" dist/cl_audit.zip dist/cl_audit.dmg --repo n-uf/cl_audit --title "cl_audit $next" --notes "$section

---

$checked

**Download:** \`cl_audit.zip\` below (Apple silicon, macOS 13 or later). Unzip it, move **cl_audit** to Applications and open it. The first time, macOS says it can't verify the app: open System Settings ▸ Privacy & Security and click **Open Anyway** (once). Or build it from source, see the README.

Also as a disk image: \`cl_audit.dmg\` below. Open it and drag cl_audit onto Applications.

SHA-256: \`cl_audit.zip\` $zip_sha · \`cl_audit.dmg\` $dmg_sha"
  echo "published the GitHub Release v$next with cl_audit.zip and cl_audit.dmg"
fi
