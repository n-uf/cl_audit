#!/bin/bash
# Build "cl_audit" (the settings app) and install it into /Applications, then bring the
# per-account Dock icon apps up to date from the local account list.
#   ./build.sh               build, install, update the icons
#   ./build.sh --no-install  build into ./build only
# Signed ad hoc, unless CL_SIGN_ID names a Developer ID identity (scripts/signing.sh, docs/signing.md).
# Accounts are set up in the app's window and saved on this Mac in
# ~/Library/Application Support/usage-n-uf/accounts.json (see accounts.example.json).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
out="$here/build"
dest="/Applications"   # Spotlight finds apps here; earlier versions used ~/Applications
name="cl_audit"
install=1
[ "${1:-}" = "--no-install" ] && install=0
# --check-signing: the signing plan (identity, notary profile, what it would sign in order), building and signing nothing
if [ "${1:-}" = "--check-signing" ]; then . "$here/scripts/signing.sh"; check_signing; exit 0; fi
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
# sign(): ad hoc, or the Developer ID with the hardened runtime when CL_SIGN_ID is set; inside out, in sign_plan's order
. "$here/scripts/signing.sh"
ent=(); while IFS= read -r f; do ent+=("$f"); done < <(dev_entitlements "$here")   # (none for an ad hoc build)
echo "compiling the shared modules (cl_kit $modules_tag)…"
build_modules "$out" keychain -O
# and AddressPrivacy (cl_kit's Privacy/: how an account address is hidden on screen), a fourth, standalone one: the app links
# it, and so does the Dock tile plug-in, which is the same objects (the plug-in itself draws no address); the widget doesn't
echo "compiling AddressPrivacy…"
build_privacy "$out" -O
# and MenuRows (cl_kit's MenuRows/: the menu bar menu's account rows, over ProfileCore and AddressPrivacy). Its flags go
# before AddressPrivacy's, as cl_kit says; ProfileCore stays earlier on the line, which Apple's linker takes (it searches
# every static library given for what's still missing, not only the later ones)
echo "compiling MenuRows…"
build_menurows "$out" -O
privacy=(); while IFS= read -r f; do privacy+=("$f"); done < <(menurows_link "$out"; privacy_link "$out")
echo "compiling…"
# One compile for the app (its Dock tile plug-in's sources included, so the app and the checks have its code too); the plug-in
# itself is compiled on its own below, from its few sources and ProfileCore.
mkdir -p "$out/obj"
(cd "$out/obj" && swiftc -O -swift-version 5 -target arm64-apple-macos13.0 -module-name UsageDock -c \
  "$here"/Sources/*.swift "$here/Widget/WidgetViews.swift" "$here/DockTile/Plugin.swift" -I "$out")
frameworks=(-framework AppKit -framework SwiftUI -framework Charts -framework Security -framework ServiceManagement
  -framework UserNotifications -framework WidgetKit)
swiftc -target arm64-apple-macos13.0 -o "$out/UsageDock" "$out"/obj/*.o \
  -L "$out" -lProfileCore -lClaudeAuth -lRuns "${privacy[@]}" "${frameworks[@]}"
# The Dock tile plug-in runs inside the Dock's shared process: it is built from its own few sources (what the tile draws
# and its menu needs, each file saying so at its top) with ProfileCore and AppKit only, never the app's other code (no
# sign-in, Keychain, process or network code is even linked in). A file here that reaches the app's other code fails this
# compile. The load-time function (docktile_load.c) registers each copy's class.
echo "compiling the Dock tile plug-in…"
clang -O2 -arch arm64 -mmacosx-version-min=13.0 -c -o "$out/docktile_load.o" "$here/DockTile/docktile_load.c"
plugin_sources=(DockTile/Plugin.swift Sources/PluginProfile.swift Sources/DockTile.swift Sources/DockMenu.swift Sources/ClQuick.swift
  Sources/SafeRead.swift Sources/Painter.swift Sources/IconDesigns.swift Sources/StatusStyles.swift Sources/TileCountdown.swift)
swiftc -O -swift-version 5 -target arm64-apple-macos13.0 -emit-library -module-name DockTile -o "$out/DockTile" \
  "${plugin_sources[@]/#/$here/}" "$out/docktile_load.o" -I "$out" -L "$out" -lProfileCore -framework AppKit \
  -Xlinker -dead_strip -Xlinker -dead_strip_dylibs

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
# (Under a Developer ID macOS knows it by its team instead, so that holds across updates too.)
# The signing below goes inside out, in scripts/signing.sh's sign_plan order (the order --check-signing prints): the
# launcher, the agent, the widget, the Dock tile plug-in, then the app. A new nested piece goes into both.
mkdir -p "$app/Contents/Helpers"
clang -O2 -arch arm64 -mmacosx-version-min=13.0 -o "$app/Contents/Helpers/cl_audit-agent" "$here/Launcher/main.c"
sign "$app/Contents/Helpers/cl_audit-agent" --identifier local.usage-n-uf-agent-launcher
sign "$helper" ${ent[@]+"${ent[@]}"}

# The widget (Widget/Widget.swift): every profile's limits on the desktop or in Notification Center. A sandboxed
# extension that may only read the agent's folder (one read-only exception, Widget/widget.entitlements). macOS 14
# and later; signed before cl_audit.app, which seals it. The Dock icon copies leave it out.
wx="$app/Contents/PlugIns/$name Widget.appex"
mkdir -p "$wx/Contents/MacOS"
echo "compiling the widget…"
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 -application-extension -parse-as-library \
  -o "$wx/Contents/MacOS/cl_audit-widget" "$here/Widget/Widget.swift" "$here/Widget/WidgetViews.swift" "$here/Sources/TileCountdown.swift" \
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
sign "$wx" --entitlements "$here/Widget/widget.entitlements"

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
sign "$tile"
sign "$app" ${ent[@]+"${ent[@]}"}
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
