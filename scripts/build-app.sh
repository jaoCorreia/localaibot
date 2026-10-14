#!/bin/bash
# Builds "Local Bot.app" (Swift shell + bundled brain + Node runtime) and a DMG.
#
#   scripts/build-app.sh            → dist/Local Bot.app and dist/LocalBot-<version>.dmg
#
# Apple silicon only for now. The app is ad-hoc signed (no Apple Developer ID):
# on first open, macOS asks the user to allow it (see README).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(cat "$ROOT/VERSION")"
NODE_VERSION="22.22.3"
ARCH="arm64"
APP_NAME="Local Bot"
BUNDLE_ID="io.github.patrick-mns.localbot"
REPO="patrick-mns/localbot"
# Sparkle installs only updates signed with the matching private key (kept in
# the maintainer's Keychain, never on GitHub; see scripts/publish-release.sh).
SPARKLE_KEY="$(cat "$ROOT/assets/sparkle-public-key.txt")"

DIST="$ROOT/dist"
CACHE="$ROOT/.build-cache"
APP="$DIST/$APP_NAME.app"
mkdir -p "$DIST" "$CACHE"
rm -rf "$APP"

echo "==> Swift shell (release, $ARCH)"
swift build -c release --arch "$ARCH" --package-path "$ROOT/apps/mac"
BIN="$(swift build -c release --arch "$ARCH" --package-path "$ROOT/apps/mac" --show-bin-path)/LocalBot"

echo "==> Brain bundle"
(cd "$ROOT/brain" && [ -d node_modules ] || npm ci --silent)
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/brain"
"$ROOT/brain/node_modules/.bin/esbuild" "$ROOT/brain/src/index.ts" --bundle --platform=node --format=esm \
  --target=node22 --outfile="$APP/Contents/Resources/brain/brain.mjs" --log-level=warning \
  --define:process.env.LOCALBOT_VERSION="\"$VERSION\""

echo "==> Node $NODE_VERSION runtime"
TARBALL="node-v$NODE_VERSION-darwin-$ARCH.tar.gz"
if [ ! -f "$CACHE/$TARBALL" ]; then
  curl -fsSL "https://nodejs.org/dist/v$NODE_VERSION/$TARBALL" -o "$CACHE/$TARBALL.part"
  curl -fsSL "https://nodejs.org/dist/v$NODE_VERSION/SHASUMS256.txt" -o "$CACHE/SHASUMS256-$NODE_VERSION.txt"
  EXPECTED="$(grep " $TARBALL\$" "$CACHE/SHASUMS256-$NODE_VERSION.txt" | cut -d' ' -f1)"
  ACTUAL="$(shasum -a 256 "$CACHE/$TARBALL.part" | cut -d' ' -f1)"
  [ -n "$EXPECTED" ] && [ "$EXPECTED" = "$ACTUAL" ] || { echo "Node checksum mismatch"; exit 1; }
  mv "$CACHE/$TARBALL.part" "$CACHE/$TARBALL"
fi
tar -xzf "$CACHE/$TARBALL" -C "$CACHE" "node-v$NODE_VERSION-darwin-$ARCH/bin/node"
cp "$CACHE/node-v$NODE_VERSION-darwin-$ARCH/bin/node" "$APP/Contents/Resources/node"

echo "==> App bundle"
cp "$BIN" "$APP/Contents/MacOS/LocalBot"
mkdir -p "$APP/Contents/Frameworks"
cp -R "$(dirname "$BIN")/Sparkle.framework" "$APP/Contents/Frameworks/"
cp "$ROOT/assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>LocalBot</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
  <key>SUFeedURL</key><string>https://github.com/$REPO/releases/latest/download/appcast.xml</string>
  <key>SUPublicEDKey</key><string>$SPARKLE_KEY</string>
  <key>SUEnableAutomaticChecks</key><true/>
</dict>
</plist>
PLIST

echo "==> Ad-hoc signature"
# Node keeps its own nodejs.org signature; the app bundle is signed around it.
# Sparkle's helpers are signed inside out, as its docs ask for ad-hoc builds.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
for item in "$SPARKLE"/Versions/B/XPCServices/*.xpc "$SPARKLE/Versions/B/Autoupdate" "$SPARKLE/Versions/B/Updater.app" "$SPARKLE"; do
  codesign --force --sign - --timestamp=none --options runtime "$item"
done
codesign --force --sign - --entitlements "$ROOT/apps/mac/LocalBot.entitlements" --options runtime \
  --timestamp=none "$APP/Contents/MacOS/LocalBot"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict "$APP"

echo "==> DMG"
DMG="$DIST/LocalBot-$VERSION.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG"

echo "Built $APP"
echo "Built $DMG ($(du -h "$DMG" | cut -f1))"
