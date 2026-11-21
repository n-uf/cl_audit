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
# The shared modules, from the vendored cl_kit tag (Vendor/CL_KIT; scripts/vendor.sh copies a tag), built first as static
# libraries in their layers by cl_kit's own recipe (scripts/modules.sh): ProfileCore (Core/: the rules, Foundation only,
# built as an app extension may use it, so the widget links it too), Runs (Run/: the one runner and the cleaned environment
# of a `claude` run; the widget doesn't link it) and ClaudeAuth (Auth/: a profile's one folder's Claude Code sign-in, with
# Auth/Keychain.swift, the read-only Keychain read; the app and the Dock tile plug-in link it, the widget doesn't).
repo="$here"
. "$here/scripts/modules.sh"
echo "compiling the shared modules (cl_kit $modules_tag)…"
build_modules "$out" keychain -O
# and AddressPrivacy (cl_kit's Privacy/: how an account address is hidden on screen), a fourth, standalone one: the app links
# it, and so does the Dock tile plug-in, which is the same objects (the plug-in itself draws no address); the widget doesn't
echo "compiling AddressPrivacy…"
build_privacy "$out" -O
privacy=(); while IFS= read -r f; do privacy+=("$f"); done < <(privacy_link "$out")
echo "compiling…"
# One compile for the app and its Dock tile plug-in (DockTile/): the same objects linked twice, so the plug-in draws a
# tile with the app's own code. The plug-in's load-time function (docktile_load.c) goes into the plug-in only, and the
# app's entry file (main.swift: its command line and start) stays out of it; what the plug-in never reaches is stripped.
mkdir -p "$out/obj"
(cd "$out/obj" && swiftc -O -swift-version 5 -target arm64-apple-macos13.0 -module-name UsageDock -c \
  "$here"/Sources/*.swift "$here/Widget/WidgetViews.swift" "$here/DockTile/Plugin.swift" -I "$out")
frameworks=(-framework AppKit -framework SwiftUI -framework Charts -framework Security -framework ServiceManagement
  -framework UserNotifications -framework WidgetKit)
swiftc -target arm64-apple-macos13.0 -o "$out/UsageDock" "$out"/obj/*.o \
  -L "$out" -lProfileCore -lClaudeAuth -lRuns "${privacy[@]}" "${frameworks[@]}"
echo "linking the Dock tile plug-in…"
clang -O2 -arch arm64 -mmacosx-version-min=13.0 -c -o "$out/docktile_load.o" "$here/DockTile/docktile_load.c"
objs=()
for o in "$out"/obj/*.o; do [[ "$(basename "$o")" == main.o ]] || objs+=("$o"); done
swiftc -target arm64-apple-macos13.0 -emit-library -module-name DockTile -o "$out/DockTile" "${objs[@]}" "$out/docktile_load.o" \
  -L "$out" -lProfileCore -lClaudeAuth -lRuns "${privacy[@]}" "${frameworks[@]}" -Xlinker -dead_strip -Xlinker -dead_strip_dylibs

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
  <key>NSAppleEventsUsageDescription</key><string>After a switch, cl_audit sends the profile's own Claude window one link: a new session there that arranges its sidebar as before.</string>
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
  -o "$wx/Contents/MacOS/cl_audit-widget" "$here/Widget/Widget.swift" "$here/Widget/WidgetViews.swift" "$here/Sources/StatusRecord.swift" \
  -I "$out" -L "$out" -lProfileCore \
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

# The Dock tile plug-in (DockTile/Plugin.swift): the Dock draws a profile's tile with it while its Dock icon app isn't
# running. Unused in cl_audit.app (which names no Dock tile plug-in); each Dock icon app gets its own copy, named for
# its profile (Installer.installTile). Signed before cl_audit.app, which seals it.
tile="$app/Contents/PlugIns/Dock Tile.docktileplugin"
mkdir -p "$tile/Contents/MacOS"
cp "$out/DockTile" "$tile/Contents/MacOS/DockTile"
cat > "$tile/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.usage-n-uf.docktile</string>
  <key>CFBundleName</key><string>Dock Tile</string>
  <key>CFBundleExecutable</key><string>DockTile</string>
  <key>CFBundlePackageType</key><string>BNDL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$build</string>
  <key>NSPrincipalClass</key><string>ClAuditDockTileBase</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$tile" 2>/dev/null
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
