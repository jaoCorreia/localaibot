#!/bin/bash
# Signs a DMG with the Sparkle key in this Mac's Keychain and prints an
# appcast.xml with that one update.
#
#   scripts/appcast.sh <dmg> <download-url> <version> [notes-file] > appcast.xml
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DMG="$1" URL="$2" VERSION="$3" NOTES="${4:-}"
SPARKLE_BIN="$ROOT/apps/mac/.build/artifacts/sparkle/Sparkle/bin"
[ -x "$SPARKLE_BIN/sign_update" ] || swift package resolve --package-path "$ROOT/apps/mac" >/dev/null

# Prints: sparkle:edSignature="…" length="…"
SIGNATURE="$("$SPARKLE_BIN/sign_update" --account localbot "$DMG")"

escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
DESCRIPTION=""
if [ -n "$NOTES" ] && [ -s "$NOTES" ]; then
  DESCRIPTION="<description><![CDATA[<pre style=\"white-space: pre-wrap; font: 12px -apple-system\">$(escape < "$NOTES" | sed 's/]]>/]] >/g')</pre>]]></description>"
fi

cat <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Local Bot</title>
    <item>
      <title>Version $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$VERSION</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      $DESCRIPTION
      <enclosure url="$URL" type="application/octet-stream" $SIGNATURE />
    </item>
  </channel>
</rss>
XML
