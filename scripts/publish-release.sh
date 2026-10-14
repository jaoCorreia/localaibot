#!/bin/bash
# Signs and publishes a release that CI built as a draft.
#
#   scripts/publish-release.sh v0.5.0
#
# Runs on the maintainer's Mac: the Sparkle private key lives in this Keychain
# and never goes to GitHub. Before signing it checks that the DMG is the one
# GitHub has, that its version matches the tag and that it carries our public
# key (a build with another key could never be updated by us again).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="patrick-mns/localbot"
TAG="${1:?usage: scripts/publish-release.sh vX.Y.Z}"
VERSION="${TAG#v}"
DMG_NAME="LocalBot-$VERSION.dmg"
WORK="$(mktemp -d)"
MOUNT="$WORK/mnt"
trap 'hdiutil detach -quiet "$MOUNT" 2>/dev/null || true; rm -rf "$WORK"' EXIT

[ "$(gh release view "$TAG" -R "$REPO" --json isDraft -q .isDraft)" = "true" ] \
  || { echo "$TAG is not a draft release (already published?)"; exit 1; }

echo "==> Download $DMG_NAME"
gh release download "$TAG" -R "$REPO" -p "$DMG_NAME" -D "$WORK"
DIGEST="$(gh api "repos/$REPO/releases" -q ".[] | select(.tag_name == \"$TAG\") | .assets[] | select(.name == \"$DMG_NAME\") | .digest")"
ACTUAL="sha256:$(shasum -a 256 "$WORK/$DMG_NAME" | cut -d' ' -f1)"
[ -z "$DIGEST" ] || [ "$DIGEST" = "$ACTUAL" ] || { echo "Checksum mismatch: GitHub $DIGEST, downloaded $ACTUAL"; exit 1; }

echo "==> Check the app inside"
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$MOUNT" "$WORK/$DMG_NAME"
PLIST="$MOUNT/Local Bot.app/Contents/Info.plist"
[ "$(plutil -extract CFBundleShortVersionString raw "$PLIST")" = "$VERSION" ] || { echo "App version doesn't match $TAG"; exit 1; }
[ "$(plutil -extract SUPublicEDKey raw "$PLIST")" = "$(cat "$ROOT/assets/sparkle-public-key.txt")" ] \
  || { echo "App carries a different Sparkle public key"; exit 1; }
codesign --verify --strict "$MOUNT/Local Bot.app"
hdiutil detach -quiet "$MOUNT"

echo "==> Sign and write appcast.xml"
gh release view "$TAG" -R "$REPO" --json body -q .body > "$WORK/notes.md"
"$ROOT/scripts/appcast.sh" "$WORK/$DMG_NAME" \
  "https://github.com/$REPO/releases/download/$TAG/$DMG_NAME" "$VERSION" "$WORK/notes.md" > "$WORK/appcast.xml"

echo "==> Publish"
gh release upload "$TAG" -R "$REPO" "$WORK/appcast.xml" --clobber
gh release edit "$TAG" -R "$REPO" --draft=false --latest
echo "Published https://github.com/$REPO/releases/tag/$TAG"
