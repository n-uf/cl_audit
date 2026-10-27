#!/bin/bash
# Build "cl_audit" (the settings app) and install it into /Applications, then bring the
# per-account Dock icon apps up to date from the local account list.
#   ./build.sh               build, install, update the icons
#   ./build.sh --no-install  build into ./build only
# Accounts are set up in the app's window and saved on this Mac in
# ~/Library/Application Support/usage-n-uf/accounts.json (see accounts.example.json).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
out="$here/build"
dest="/Applications"   # Spotlight finds apps here; earlier versions used ~/Applications
name="cl_audit"
install=1
[ "${1:-}" = "--no-install" ] && install=0
# YY.M.R from VERSION (set by scripts/release.sh); the build number counts commits, so it only grows.
version="$(tr -d '[:space:]' < "$here/VERSION")"
build="$(git -C "$here" rev-list --count HEAD 2>/dev/null || echo 1)"

rm -rf "$out"; mkdir -p "$out"
echo "compiling…"
swiftc -O -swift-version 5 -target arm64-apple-macos13.0 \
  -o "$out/UsageDock" "$here"/Sources/*.swift \
  -framework AppKit -framework SwiftUI -framework Charts -framework Security -framework ServiceManagement -framework UserNotifications

app="$out/$name.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$out/UsageDock" "$app/Contents/MacOS/UsageDock"
"$out/UsageDock" --render-app-iconset "$out/AppIcon.iconset" panel   # the default app icon (Settings ▸ General ▸ App icon)
iconutil -c icns -o "$app/Contents/Resources/AppIcon.icns" "$out/AppIcon.iconset"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.usage-n-uf</string>
  <key>CFBundleName</key><string>$name</string>
  <key>CFBundleDisplayName</key><string>$name</string>
  <key>CFBundleExecutable</key><string>UsageDock</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$build</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# The cl_audit agent: the same program in a helper app inside cl_audit.app, registered as its one login item
# (Sources/Agent.swift). Signed first, then sealed into cl_audit.app's own signature.
helper="$app/Contents/Library/LoginItems/$name Agent.app"
mkdir -p "$helper/Contents/MacOS" "$helper/Contents/Resources"
cp "$out/UsageDock" "$helper/Contents/MacOS/UsageDock"
cp "$app/Contents/Resources/AppIcon.icns" "$helper/Contents/Resources/AppIcon.icns"
cat > "$helper/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.usage-n-uf-agent</string>
  <key>CFBundleName</key><string>$name</string>
  <key>CFBundleDisplayName</key><string>$name</string>
  <key>CFBundleExecutable</key><string>UsageDock</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$build</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$helper" 2>/dev/null
codesign --force --sign - "$app" 2>/dev/null
echo "built $name $version ($build)"

if [ $install = 1 ]; then
  pkill -f "$dest/$name.app/Contents/MacOS/UsageDock" 2>/dev/null || true
  mkdir -p "$dest"
  rm -rf "$dest/$name.app"
  cp -R "$app" "$dest/"
  echo "installed $dest/$name.app"
  # Earlier versions were called "Claude Usage" and "cl-audit"; the icon apps are renamed by --sync.
  for old in "Claude Usage" "cl-audit"; do
    if [ "$old" != "$name" ] && [ -d "$dest/$old.app" ]; then
      pkill -f "$dest/$old.app/Contents/MacOS/UsageDock" 2>/dev/null || true
      rm -rf "$dest/$old.app"; echo "removed the old $dest/$old.app"
    fi
  done
  # Earlier versions installed the settings app in ~/Applications; the icon apps move with --sync.
  if [ -d "$HOME/Applications/$name.app" ]; then rm -rf "$HOME/Applications/$name.app"; echo "removed the old ~/Applications/$name.app"; fi
  # Update the per-account icon apps from the account list (does nothing before the first setup).
  "$dest/$name.app/Contents/MacOS/UsageDock" --sync
fi
