# cl_audit's code signing, shared by build.sh and scripts/release.sh (sourced, bash). See docs/signing.md.
#
#   CL_SIGN_ID          a Developer ID Application identity ("Developer ID Application: Name (TEAMID)", or its SHA-1 as
#                       `security find-identity -v -p codesigning` lists it). Unset: ad hoc, exactly as before.
#   CL_NOTARY_PROFILE   a notarytool keychain profile (xcrun notarytool store-credentials). Unset: no notarization.
#                       Needs CL_SIGN_ID: Apple notarizes Developer ID signatures only.
#
# Nothing here reads, prints or stores a password, a token or a private key: codesign and notarytool take them from the
# Keychain themselves (the first codesign with a new identity may ask once to use its key: Always Allow).

sign_id="${CL_SIGN_ID:-}"
notary_profile="${CL_NOTARY_PROFILE:-}"

# sign PATH [codesign options...]: ad hoc without CL_SIGN_ID, the very command build.sh always ran (its errors hidden, as
# before); with it, the Developer ID, the hardened runtime and a secure timestamp, errors shown. Never --deep: build.sh
# signs inside out, each nested piece before the bundle that seals it.
sign() {
  local path="$1"; shift
  if [ -z "$sign_id" ]; then
    codesign --force --sign - "$@" "$path" 2>/dev/null
  else
    codesign --force --sign "$sign_id" --options runtime --timestamp "$@" "$path"
  fi
}

# The app's and the agent's entitlements, under the Developer ID only (an ad hoc build has no hardened runtime, so it
# needs none, and stays as it was).
dev_entitlements() { [ -n "$sign_id" ] && printf '%s\n' --entitlements "$1/Signing/cl_audit.entitlements"; return 0; }

# What gets signed, in order (inside out), relative to build/: what --check-signing lists. build.sh follows this order.
sign_plan=(
  "cl_audit.app/Contents/Helpers/cl_audit-agent|the agent's launcher (identifier local.usage-n-uf-agent-launcher)"
  "cl_audit.app/Contents/Library/LoginItems/cl_audit Agent.app|the agent (local.usage-n-uf-agent), with Signing/cl_audit.entitlements under a Developer ID"
  "cl_audit.app/Contents/PlugIns/cl_audit Widget.appex|the widget (local.usage-n-uf.widget), with Widget/widget.entitlements"
  "cl_audit.app/Contents/PlugIns/Dock Tile.docktileplugin|the Dock tile plug-in (local.usage-n-uf.docktile)"
  "cl_audit.app|the app (local.usage-n-uf), with Signing/cl_audit.entitlements under a Developer ID, sealing all of the above"
)

# The identity is in this Mac's Keychain (no secret read: find-identity lists names and hashes only).
sign_id_found() { [ -n "$sign_id" ] && security find-identity -v -p codesigning 2>/dev/null | grep -qF "$sign_id"; }

# The notary profile answers (one call to Apple's notary service, nothing printed; its credentials stay in the Keychain).
notary_profile_found() {
  [ -n "$notary_profile" ] && xcrun notarytool history --keychain-profile "$notary_profile" --output-format json >/dev/null 2>&1
}

# notarize FILE: sends it to Apple's notary service and waits for the verdict; anything but Accepted fails, with the
# command that shows Apple's log. Only the verdict and the submission id are read from the answer.
notarize() {
  local f="$1" out status id
  echo "notarizing $(basename "$f") (Apple's notary service; usually a few minutes)…"
  out="$(xcrun notarytool submit "$f" --keychain-profile "$notary_profile" --wait --output-format json 2>/dev/null)" || true
  status="$(printf '%s' "$out" | plutil -extract status raw -o - - 2>/dev/null || true)"
  id="$(printf '%s' "$out" | plutil -extract id raw -o - - 2>/dev/null || true)"
  if [ "$status" != Accepted ]; then
    echo "the notarization of $(basename "$f") ended ${status:-without an answer}${id:+ (submission $id)}" >&2
    [ -z "$id" ] || echo "Apple's log of it: xcrun notarytool log $id --keychain-profile \"$notary_profile\"" >&2
    return 1
  fi
  echo "notarized $(basename "$f") (submission $id)"
}

# check_signing: the plan, signing nothing: the identity and profile found or not, then each thing it would sign, in order,
# and the release's notarization steps.
check_signing() {
  echo "Code signing plan (nothing is signed or sent):"
  if [ -z "$sign_id" ]; then
    echo "  CL_SIGN_ID unset: ad hoc signing (codesign --sign -), as today"
  elif sign_id_found; then
    echo "  CL_SIGN_ID: found in this Mac's Keychain; Developer ID, --options runtime --timestamp"
  else
    echo "  CL_SIGN_ID: NOT found among this Mac's code signing identities (security find-identity -v -p codesigning)"
  fi
  if [ -z "$notary_profile" ]; then
    echo "  CL_NOTARY_PROFILE unset: no notarization"
  elif [ -z "$sign_id" ]; then
    echo "  CL_NOTARY_PROFILE set without CL_SIGN_ID: a release would stop (Apple notarizes Developer ID signatures only)"
  elif notary_profile_found; then
    echo "  CL_NOTARY_PROFILE: the profile answers (notarytool history)"
  else
    echo "  CL_NOTARY_PROFILE: NOT usable (no such keychain profile, or Apple's notary service not reachable)"
  fi
  echo "Signed, in this order:"
  local i=1 p
  for p in "${sign_plan[@]}"; do echo "  $i. ${p%%|*}: ${p#*|}"; i=$((i + 1)); done
  if [ -n "$sign_id" ] && [ -n "$notary_profile" ]; then
    echo "Then, in scripts/release.sh --push, before anything is pushed:"
    echo "  zip the app; notarytool submit --wait (Accepted or the release stops); staple the app; zip it again"
    echo "  the disk image from the stapled app; sign it; notarize it; staple it"
    echo "  check: spctl -t exec on the app, spctl -t open (primary signature) on the image, stapler validate on both"
  elif [ -n "$sign_id" ]; then
    echo "Then the release signs the disk image too; without CL_NOTARY_PROFILE nothing is notarized."
  fi
}
