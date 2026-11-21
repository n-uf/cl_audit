#!/usr/bin/env bash
# Copy a tagged release of n-uf/cl_kit (the Swift modules shared with cl_quick) into Vendor/cl_kit-<tag>/ and point the
# build at it (Vendor/CL_KIT: the tag and its commit). The copy is never edited here: a change is a pull request to cl_kit,
# then a new tag, then this script again.
#   scripts/vendor.sh v26.11.1        copy that tag (any other Vendor/cl_kit-* folder is removed); then commit Vendor/
#   scripts/vendor.sh --check         the vendored copy is exactly its tag, and the tag still names the recorded commit
#   CL_KIT_REPO=<url or path> ...     another source than https://github.com/n-uf/cl_kit.git (a local clone, for a try)
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
src="${CL_KIT_REPO:-https://github.com/n-uf/cl_kit.git}"
pin="$repo/Vendor/CL_KIT"

tmp="$(mktemp -d -t cl_kit-vendor)"
trap 'rm -rf "$tmp"' EXIT

# fetch TAG: the tag's tree into $tmp/tree (without .github: cl_kit's own CI), its commit into $commit
fetch() {
  local tag="$1"
  [[ "$tag" =~ ^v[0-9]{2}\.[0-9]{1,2}\.[0-9]+$ ]] || { echo "not a cl_kit tag (vYY.M.R): $tag" >&2; exit 64; }
  git init -q "$tmp/git"
  git -C "$tmp/git" fetch -q --depth 1 "$src" "refs/tags/$tag:refs/tags/$tag" || { echo "no tag $tag in $src" >&2; exit 1; }
  commit="$(git -C "$tmp/git" rev-parse "refs/tags/$tag^{commit}")"
  mkdir -p "$tmp/tree"
  git -C "$tmp/git" archive "refs/tags/$tag" | tar -x -C "$tmp/tree"
  rm -rf "$tmp/tree/.github"
  [ -f "$tmp/tree/scripts/modules.sh" ] && [ -f "$tmp/tree/Checks/run.sh" ] || { echo "$tag has no scripts/modules.sh or Checks/run.sh" >&2; exit 1; }
}

if [ "${1:-}" = --check ]; then
  [ -f "$pin" ] || { echo "no Vendor/CL_KIT" >&2; exit 1; }
  read -r tag want < "$pin"
  fetch "$tag"
  [ "$commit" = "$want" ] || { echo "FAIL: $tag is $commit in $src, Vendor/CL_KIT says $want" >&2; exit 1; }
  if diff -r -q -x .work -x build "$tmp/tree" "$repo/Vendor/cl_kit-$tag"; then
    echo "vendor: Vendor/cl_kit-$tag is exactly $tag ($commit)"
  else
    echo "FAIL: Vendor/cl_kit-$tag differs from $tag (it is never edited here)" >&2; exit 1
  fi
  exit 0
fi

tag="${1:?usage: scripts/vendor.sh <tag> | --check}"
fetch "$tag"
for old in "$repo"/Vendor/cl_kit-*; do [ -e "$old" ] && rm -rf "$old"; done
mkdir -p "$repo/Vendor"
mv "$tmp/tree" "$repo/Vendor/cl_kit-$tag"
printf '%s %s\n' "$tag" "$commit" > "$pin"
echo "vendored cl_kit $tag ($commit) into Vendor/cl_kit-$tag; commit Vendor/ (git add -A Vendor)"
