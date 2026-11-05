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
  -o "$out/UsageDock" "$here"/Sources/*.swift "$here/Widget/WidgetViews.swift" \
  -framework AppKit -framework SwiftUI -framework Charts -framework Security -framework ServiceManagement -framework UserNotifications \
  -framework WidgetKit

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
  <key>CFBundleName</key><string>$name Agent</string>
  <key>CFBundleDisplayName</key><string>$name Agent</string>
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
# launchd runs the helper from this plist (SMAppService.agent): at login, and again if it crashes.
mkdir -p "$app/Contents/Library/LaunchAgents"
cat > "$app/Contents/Library/LaunchAgents/local.usage-n-uf-agent.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>local.usage-n-uf-agent</string>
  <key>BundleProgram</key><string>Contents/Helpers/cl_audit-agent</string>
  <key>AssociatedBundleIdentifiers</key><array><string>local.usage-n-uf</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
PLIST
# What launchd starts: a tiny launcher (Launcher/main.c) that hands over to the agent. Built the same way it comes
# out byte for byte the same, so an update doesn't change it and macOS goes on accepting it without a new notice.
mkdir -p "$app/Contents/Helpers"
clang -O2 -arch arm64 -mmacosx-version-min=13.0 -o "$app/Contents/Helpers/cl_audit-agent" "$here/Launcher/main.c"
codesign --force --sign - --identifier local.usage-n-uf-agent-launcher "$app/Contents/Helpers/cl_audit-agent" 2>/dev/null
codesign --force --sign - "$helper" 2>/dev/null

# The widget (Widget/Widget.swift): every profile's limits on the desktop or in Notification Center. A sandboxed
# extension that may only read the agent's folder (one read-only exception, Widget/widget.entitlements). macOS 14
# and later; signed before cl_audit.app, which seals it. The Dock icon copies leave it out.
wx="$app/Contents/PlugIns/$name Widget.appex"
mkdir -p "$wx/Contents/MacOS"
echo "compiling the widget…"
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 -application-extension -parse-as-library \
  -o "$wx/Contents/MacOS/cl_audit-widget" "$here/Widget/Widget.swift" "$here/Widget/WidgetViews.swift" \
  -framework WidgetKit -framework SwiftUI -Xlinker -e -Xlinker _NSExtensionMain
cat > "$wx/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.usage-n-uf.widget</string>
  <key>CFBundleName</key><string>$name Widget</string>
  <key>CFBundleDisplayName</key><string>$name</string>
  <key>CFBundleExecutable</key><string>cl_audit-widget</string>
  <key>CFBundlePackageType</key><string>XPC!</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$build</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSExtension</key><dict><key>NSExtensionPointIdentifier</key><string>com.apple.widgetkit-extension</string></dict>
</dict>
</plist>
PLIST
codesign --force --sign - --entitlements "$here/Widget/widget.entitlements" "$wx" 2>/dev/null
codesign --force --sign - "$app" 2>/dev/null
echo "built $name $version ($build)"

if [ $install = 1 ]; then
  pkill -f "$dest/$name.app/Contents/MacOS/UsageDock" 2>/dev/null || true
  # the widget: macOS keeps running the copy it started until that process ends, so the new one is used only after
  pkill -f "$dest/$name.app/Contents/PlugIns/$name Widget.appex/Contents/MacOS/cl_audit-widget" 2>/dev/null || true
  mkdir -p "$dest"
  rm -rf "$dest/$name.app"
  cp -R "$app" "$dest/"
  echo "installed $dest/$name.app"
  # Replacing the app drops its widget from macOS ("unknown extension") until something registers it again: register
  # the app and the widget now, so placed widgets keep working and the redraw asked for by --sync reaches them.
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$dest/$name.app"
  pluginkit -a "$dest/$name.app/Contents/PlugIns/$name Widget.appex" 2>/dev/null || true
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
