#!/bin/bash
# Build Claude Sessions.app (release) into ./build, optionally install to /Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Claude Sessions"
# build.noindex: keep Spotlight from registering a second copy of the app
APP="build.noindex/${APP_NAME}.app"
VERSION="0.1.0"

swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/ClaudeSessions"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ClaudeSessions"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key><string>local.claude-sessions</string>
  <key>CFBundleExecutable</key><string>ClaudeSessions</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
</dict>
</plist>
PLIST

# Icon Composer source -> Assets.car (Liquid Glass icon) + AppIcon.icns fallback.
ICON_OUT="build.noindex/icon"
rm -rf "$ICON_OUT" && mkdir -p "$ICON_OUT"
xcrun actool Resources/AppIcon.icon --compile "$ICON_OUT" --platform macosx \
  --minimum-deployment-target 15.0 --app-icon AppIcon \
  --output-partial-info-plist "$ICON_OUT/partial.plist" >/dev/null
cp "$ICON_OUT/Assets.car" "$ICON_OUT/AppIcon.icns" "$APP/Contents/Resources/"
# Sign with a stable local identity: TCC (Documents, Desktop, ...) grants are tied to
# the signature, and ad-hoc signing changes it every build, re-triggering every prompt.
SIGN_ID="${SIGN_ID:-LiveSubtitle Developer}"
if security find-identity -v -p codesigning | grep -q "\"$SIGN_ID\""; then
  codesign --force --sign "$SIGN_ID" --identifier local.claude-sessions "$APP"
else
  echo "warning: signing identity '$SIGN_ID' not found, falling back to ad-hoc (permissions will re-prompt)"
  codesign --force --sign - "$APP"
fi
echo "Built $APP ($(du -sh "$APP" | cut -f1))"

if [ "${1:-}" = "--install" ]; then
  rm -rf "/Applications/${APP_NAME}.app"
  cp -R "$APP" /Applications/
  echo "Installed /Applications/${APP_NAME}.app"
  # Only the installed copy should show up in Launchpad / the Applications list.
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -u "$PWD/$APP" 2>/dev/null || true
fi
