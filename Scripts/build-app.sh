#!/bin/bash
# Builds dist/NotchAgents.app (universal) and dist/NotchAgents-<version>.dmg.
#
# Env:
#   VERSION         default 0.1.0
#   SIGN_IDENTITY   codesign identity, e.g. "Developer ID Application: Name (TEAMID)". Default: ad-hoc (-)
#   NOTARY_PROFILE  notarytool keychain profile; if set (with a Developer ID identity) the DMG is notarized + stapled
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
IDENTITY="${SIGN_IDENTITY:--}"
APP="dist/Notch Agents.app"
DMG="dist/NotchAgents-$VERSION.dmg"

rm -rf dist && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}" || { echo "universal build failed, falling back to host arch"; ARCHS=(); swift build -c release; }
cp "$(swift build -c release "${ARCHS[@]}" --show-bin-path)/NotchAgents" "$APP/Contents/MacOS/NotchAgents"

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
</dict></plist>
PLIST
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/" \
  && /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist"

codesign --force --options runtime --sign "$IDENTITY" "$APP"
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
