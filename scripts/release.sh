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
#   scripts/release.sh --check-signing   the code signing plan (identity, notary profile, what it would sign), nothing else
# Signing: ad hoc, unless CL_SIGN_ID names a Developer ID identity; with CL_NOTARY_PROFILE too, the zip's app and the
# disk image are notarized and stapled before anything is pushed (scripts/signing.sh, docs/signing.md).
# Test overrides: CALENDAR_VERSION_TODAY=YYYY-MM-DD, CALENDAR_VERSION_CURRENT=YY.M.R
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/signing.sh

# Numbers never to use again (for example a tag that was pushed and then deleted). None yet.
BURNED=" "

dry=0 nobump=0 push=0
for a in "$@"; do
  case "$a" in
    --dry-run) dry=1 ;;
    --nobump) nobump=1 ;;
    --push) push=1 ;;
    --check-signing) check_signing; exit 0 ;;
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
# a push needs main to be ahead of origin's: found out now, not after the long build
if [ $push = 1 ]; then
  git fetch -q origin main || { echo "couldn't fetch origin's main" >&2; exit 1; }
  git merge-base --is-ancestor origin/main HEAD || { echo "origin/main has commits this main doesn't: pull (rebase) first" >&2; exit 1; }
  # the signing set-up, found out now too, before the release commit (scripts/release.sh --check-signing shows it)
  if [ -n "$notary_profile" ] && [ -z "$sign_id" ]; then
    echo "CL_NOTARY_PROFILE needs CL_SIGN_ID: Apple notarizes Developer ID signatures only" >&2; exit 1
  fi
  if [ -n "$sign_id" ] && ! sign_id_found; then
    echo "CL_SIGN_ID isn't among this Mac's code signing identities (security find-identity -v -p codesigning)" >&2; exit 1
  fi
  if [ -n "$notary_profile" ] && ! notary_profile_found; then
    echo "the notary profile \"$notary_profile\" doesn't answer (xcrun notarytool store-credentials; see docs/signing.md)" >&2; exit 1
  fi
fi
notes="$(awk '/^## Unreleased/{f=1; next} /^## /{f=0} f' CHANGELOG.md | sed '/^[[:space:]]*$/d')"
if [ -z "$notes" ] || [ "$notes" = "Nothing pending." ]; then
  echo "CHANGELOG.md has no Unreleased notes; add them first" >&2; exit 1
fi

# Unreleased notes become this release's section; Unreleased starts empty again.
awk -v v="$next" -v d="$today" '
  /^## Unreleased/ { print; print ""; print "Nothing pending."; print ""; print "## " v " — " d; next }
  { print }' CHANGELOG.md > CHANGELOG.md.tmp && mv CHANGELOG.md.tmp CHANGELOG.md
printf '%s\n' "$next" > VERSION

before="$(git rev-parse HEAD)"          # (main before the release commit: a failed build's way back)
git add VERSION CHANGELOG.md
git commit -q -m "release $next"
released="$(git rev-parse HEAD)"
git tag -a "v$next" -m "cl_audit $next"
echo "released $next (commit and tag v$next)"

if [ $push = 1 ]; then
  # The app is built, packed and checked FIRST: main and the tag are pushed only once the files to publish are ready, so a
  # failed build, zip or disk image leaves nothing pushed (the commit and tag stay local; the trap below says how to take
  # them back, or push and publish by hand once it builds).

  # The ready-built app for direct download. The file name never changes, so
  # https://github.com/n-uf/cl_audit/releases/latest/download/cl_audit.zip always gets the newest.
  stage="$(mktemp -d)"
  # whatever fails from here on, no image stays mounted and no temp folder stays behind; a failure before the push says how to
  # take back the release commit and tag, to run at once, before any fix. The command stands alone on its line (a copy of
  # it carries nothing else), names the commits by their ids (something may commit to main during the long build: then
  # only the release commit is taken out), and keeps the tree's changes (--keep, never --hard)
  undo_hint() {
    echo "nothing was pushed; the release commit ${released:0:12} and the tag v$next are local only. Take them back now, before any fix:" >&2
    if [ "$(git rev-parse HEAD)" = "$released" ]; then
      echo "git tag -d v$next && git reset --keep $before" >&2
    else
      echo "git tag -d v$next && git rebase --onto $before $released" >&2
      echo "(main has commits on top of the release commit since: that takes out the release commit only)" >&2
    fi
    echo "Then fix it and run this again." >&2
  }
  trap 'rc=$?; hdiutil detach -quiet -force "$stage/mnt" 2>/dev/null || true; rm -rf "$stage"; [ $rc = 0 ] || undo_hint' EXIT
  # One build at a time on this Mac: the build lock installs and checks take too, held from the build until the app is
  # copied out of build/, so the zip and the disk image always hold the app this build made (never another's).
  /usr/bin/lockf -k /private/tmp/cl_audit-build.lock bash -c './build.sh --no-install >/dev/null && ditto build/cl_audit.app "$1/cl_audit.app"' _ "$stage"
  mkdir -p dist && rm -f dist/cl_audit.zip dist/cl_audit.dmg
  ditto -c -k --keepParent "$stage/cl_audit.app" dist/cl_audit.zip
  if [ -n "$sign_id" ]; then
    # a Developer ID build: the signature is the Developer ID's, with the hardened runtime (what notarization needs)
    sig="$(codesign -dvv "$stage/cl_audit.app" 2>&1 || true)"
    grep -q '^Authority=Developer ID Application' <<<"$sig" && grep -qE '^CodeDirectory .*flags=0x[0-9a-f]*\(.*runtime' <<<"$sig" \
      || { echo "the app isn't signed with a Developer ID and the hardened runtime" >&2; exit 1; }
  fi
  if [ -n "$notary_profile" ]; then
    # Apple notarizes the app (the zip is what goes to it); its ticket is stapled into the app, and the zip made again
    # from the stapled app, so the download opens without a network check too
    notarize dist/cl_audit.zip || exit 1
    xcrun stapler staple -q "$stage/cl_audit.app"
    rm -f dist/cl_audit.zip
    ditto -c -k --keepParent "$stage/cl_audit.app" dist/cl_audit.zip
  fi

  # The same app as a disk image (releases/latest/download/cl_audit.dmg): the app and an Applications shortcut to drag
  # it onto. The app inside must be the zip's app, checked by its code directory hash.
  ln -s /Applications "$stage/Applications"
  hdiutil create -quiet -volname "cl_audit $next" -srcfolder "$stage" -fs HFS+ -format UDZO -imagekey zlib-level=9 dist/cl_audit.dmg
  if [ -n "$sign_id" ]; then
    # the image signed too (made from the stapled app), then notarized and stapled itself
    codesign --force --sign "$sign_id" --timestamp dist/cl_audit.dmg
    if [ -n "$notary_profile" ]; then
      notarize dist/cl_audit.dmg || exit 1
      xcrun stapler staple -q dist/cl_audit.dmg
    fi
  fi
  hdiutil verify -quiet dist/cl_audit.dmg
  if [ -n "$notary_profile" ]; then
    # what a downloader's Mac will say: Gatekeeper accepts both, and each carries its ticket
    spctl -a -vv -t exec "$stage/cl_audit.app" || { echo "Gatekeeper rejects the app" >&2; exit 1; }
    xcrun stapler validate -q "$stage/cl_audit.app" || { echo "the app's notarization ticket doesn't validate" >&2; exit 1; }
    spctl -a -vv -t open --context context:primary-signature dist/cl_audit.dmg || { echo "Gatekeeper rejects the disk image" >&2; exit 1; }
    xcrun stapler validate -q dist/cl_audit.dmg || { echo "the disk image's notarization ticket doesn't validate" >&2; exit 1; }
  fi
  mkdir "$stage/mnt"
  hdiutil attach -quiet -nobrowse -readonly -noautoopen -mountpoint "$stage/mnt" dist/cl_audit.dmg
  zip_cd="$(codesign -dvvv "$stage/cl_audit.app" 2>&1 | grep '^CDHash=' || true)"
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

  # the release's notes whole (the changelog section, the Checked with line, Download and SHA-256), in a file beside the
  # files to publish, so a release published by hand says the same. Written (and the by-hand lines made) before anything is
  # pushed: a write that fails stops here, under the trap above, with nothing pushed
  notes_file="$PWD/dist/release-notes-v$next.md"
  # a notarized app opens like any other; an ad hoc one needs Open Anyway once
  if [ -n "$notary_profile" ]; then
    first_open="It is signed with a Developer ID and notarized by Apple, so it opens like any other app."
  else
    first_open="The first time, macOS says it can't verify the app: open System Settings ▸ Privacy & Security and click **Open Anyway** (once)."
  fi
  printf '%s\n' "$section

---

$checked

**Download:** \`cl_audit.zip\` below (Apple silicon, macOS 13 or later). Unzip it, move **cl_audit** to Applications and open it. $first_open Or build it from source, see the README.

Also as a disk image: \`cl_audit.dmg\` below. Open it and drag cl_audit onto Applications.

SHA-256: \`cl_audit.zip\` $zip_sha · \`cl_audit.dmg\` $dmg_sha" > "$notes_file"
  # a release that can't be published (gh missing, signed out, the network) leaves a pushed tag with no release: say the one
  # line that publishes it by hand (full paths: it runs from any folder), and the one that finishes a release made but
  # whose upload was cut short
  zip_abs="$PWD/dist/cl_audit.zip" dmg_abs="$PWD/dist/cl_audit.dmg"
  manual="gh release create v$next $(printf %q "$zip_abs") $(printf %q "$dmg_abs") --repo n-uf/cl_audit --title \"cl_audit $next\" --notes-file $(printf %q "$notes_file")"
  upload="gh release upload v$next $(printf %q "$zip_abs") $(printf %q "$dmg_abs") --repo n-uf/cl_audit --clobber"
  [ -s "$notes_file" ] || { echo "the release notes couldn't be written to $notes_file" >&2; exit 1; }

  # the files are ready: now main and the tag go out, then the release that names the tag
  trap 'hdiutil detach -quiet -force "$stage/mnt" 2>/dev/null || true; rm -rf "$stage"; [ "${tagged:-0}" = 1 ] || { echo "main is $([ "${pushedmain:-0}" = 1 ] && echo pushed || echo "not pushed"); the tag v$next is not. Push them:"; echo "git push origin main v$next"; echo "then publish the release:"; echo "$manual"; } >&2' EXIT
  git push -q origin main; pushedmain=1
  git push -q origin "v$next"; tagged=1
  echo "pushed main and v$next"
  trap 'hdiutil detach -quiet -force "$stage/mnt" 2>/dev/null || true; rm -rf "$stage"; [ "${published:-0}" = 1 ] || { echo "the GitHub Release wasn'"'"'t published; publish it by hand:"; echo "$manual"; echo "or, if the release is there but an upload was cut short:"; echo "$upload"; } >&2' EXIT
  gh release create "v$next" dist/cl_audit.zip dist/cl_audit.dmg --repo n-uf/cl_audit --title "cl_audit $next" --notes-file "$notes_file"
  published=1
  echo "published the GitHub Release v$next with cl_audit.zip and cl_audit.dmg"
fi
