#!/bin/bash
# Build "cl-audit" (the settings app) and install it into /Applications, then bring the
# per-account Dock icon apps up to date from the local account list.
#   ./build.sh               build, install, update the icons
#   ./build.sh --no-install  build into ./build only
# Accounts are set up in the app's window and saved on this Mac in
# ~/Library/Application Support/usage-n-uf/accounts.json (see accounts.example.json).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
out="$here/build"
dest="/Applications"   # Spotlight finds apps here; earlier versions used ~/Applications
name="cl-audit"
install=1
[ "${1:-}" = "--no-install" ] && install=0

rm -rf "$out"; mkdir -p "$out"
echo "compiling…"
swiftc -O -swift-version 5 -target arm64-apple-macos13.0 \
  -o "$out/UsageDock" "$here"/Sources/*.swift \
  -framework AppKit -framework SwiftUI -framework Charts -framework Security -framework ServiceManagement -framework UserNotifications

app="$out/$name.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$out/UsageDock" "$app/Contents/MacOS/UsageDock"
"$out/UsageDock" --render-iconset "$out/AppIcon.iconset" USAGE
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
  <key>CFBundleShortVersionString</key><string>0.2</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$app" 2>/dev/null
echo "built $name"

if [ $install = 1 ]; then
  pkill -f "$dest/$name.app/Contents/MacOS/UsageDock" 2>/dev/null || true
  mkdir -p "$dest"
  rm -rf "$dest/$name.app"
  cp -R "$app" "$dest/"
  echo "installed $dest/$name.app"
  # Earlier versions were called "Claude Usage"; the icon apps are renamed by --sync.
  if [ -d "$dest/Claude Usage.app" ]; then
    pkill -f "$dest/Claude Usage.app/Contents/MacOS/UsageDock" 2>/dev/null || true
    rm -rf "$dest/Claude Usage.app"; echo "removed the old $dest/Claude Usage.app"
  fi
  # Earlier versions installed the settings app in ~/Applications; the icon apps move with --sync.
  if [ -d "$HOME/Applications/$name.app" ]; then rm -rf "$HOME/Applications/$name.app"; echo "removed the old ~/Applications/$name.app"; fi
  # Update the per-account icon apps from the account list (does nothing before the first setup).
  "$dest/$name.app/Contents/MacOS/UsageDock" --sync
fi
