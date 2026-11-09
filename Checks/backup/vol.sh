#!/usr/bin/env bash
# A small HFS+ disk image (no clones there) mounted inside the work folder, to try the cross-volume fallback.
#   WORK_BACKUP=Checks/.work/backup backup/vol.sh up|down
set -euo pipefail
dir="${WORK_BACKUP:?set WORK_BACKUP to Checks/.work/backup}"
case "$dir" in */Checks/.work/backup) ;; *) echo "refusing: $dir" >&2; exit 2 ;; esac
case "${1:-}" in
  up)
    rm -f "$dir/vol.dmg"; mkdir -p "$dir/vol"
    hdiutil create -size 300m -fs HFS+ -volname bktestvol -ov "$dir/vol.dmg" >/dev/null
    hdiutil attach "$dir/vol.dmg" -mountpoint "$dir/vol" -nobrowse >/dev/null
    echo up ;;
  down)
    hdiutil detach "$dir/vol" >/dev/null && rm -f "$dir/vol.dmg" && echo down ;;
  *) echo "usage: vol.sh up|down" >&2; exit 64 ;;
esac
