#!/bin/bash
# Builds dist/NotchAgents.app (universal) and dist/NotchAgents-<version>.dmg.
#
# Env:
#   VERSION         default 0.1.0
#   SIGN_IDENTITY   codesign identity, e.g. "Developer ID Application: Name (TEAMID)". Default: ad-hoc (-)
#   NOTARY_PROFILE  notarytool keychain profile; if set (with a Developer ID identity) the DMG is notarized + stapled
#   FEED_URL        Sparkle appcast URL. Default: appcast.xml of the latest GitHub release
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
IDENTITY="${SIGN_IDENTITY:--}"
APP="dist/Notch Agents.app"
FEED_URL="${FEED_URL:-https://github.com/adii9/notch-agents/releases/latest/download/appcast.xml}"
# Public half of the Sparkle EdDSA key; the private half signs each release in CI.
SPARKLE_PUBLIC_KEY="BnJkSCFGMYwVT4a2iD7Iud6PxkBo+SS2Nh/KGS45Xuk="
DMG="dist/NotchAgents-$VERSION.dmg"

rm -rf dist && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}" || { echo "universal build failed, falling back to host arch"; ARCHS=(); swift build -c release; }
BIN_DIR="$(swift build -c release "${ARCHS[@]}" --show-bin-path)"
cp "$BIN_DIR/NotchAgents" "$APP/Contents/MacOS/NotchAgents"

# Sparkle: embed the framework and let the binary find it in Contents/Frameworks.
mkdir -p "$APP/Contents/Frameworks"
cp -R "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/"
# The XPC services are only needed by sandboxed apps; this app isn't sandboxed.
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Notch Agents</string>
  <key>CFBundleDisplayName</key><string>Notch Agents</string>
  <key>CFBundleIdentifier</key><string>com.notchagents.app</string>
  <key>CFBundleExecutable</key><string>NotchAgents</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>SUFeedURL</key><string>$FEED_URL</string>
  <key>SUPublicEDKey</key><string>$SPARKLE_PUBLIC_KEY</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Notch Agents selects the tab a Claude Code session runs in when you click jump to terminal.</string>
</dict></plist>
PLIST
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/" \
  && /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist"

# Inside-out signing, as Sparkle's docs require (no --deep). The hardened runtime is only for
# Developer ID (notarization): with ad-hoc signatures there's no Team ID, so its library
# validation would refuse to load the embedded Sparkle.framework and the app would crash at launch.
SIGN=(codesign --force --sign "$IDENTITY")
[ "$IDENTITY" != "-" ] && SIGN+=(--options runtime)
SPK="$APP/Contents/Frameworks/Sparkle.framework"
"${SIGN[@]}" "$SPK/Versions/B/Autoupdate"
"${SIGN[@]}" "$SPK/Versions/B/Updater.app"
"${SIGN[@]}" "$SPK"
APP_SIGN=("${SIGN[@]}")
[ "$IDENTITY" != "-" ] && APP_SIGN+=(--entitlements Resources/NotchAgents.entitlements)
"${APP_SIGN[@]}" "$APP"
codesign --verify --strict "$APP"

STAGE="dist/stage"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"; ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Notch Agents" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

if [ -n "${NOTARY_PROFILE:-}" ] && [ "$IDENTITY" != "-" ]; then
  codesign --force --sign "$IDENTITY" "$DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi

echo "Built $APP and $DMG (signed with: ${IDENTITY/-/ad-hoc})"
