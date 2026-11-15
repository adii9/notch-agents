#!/bin/bash
# Signs a release DMG with the Sparkle EdDSA key and writes dist/appcast.xml for it.
#
# Usage: Scripts/make-appcast.sh <version> <dmg> [download-url]
#   download-url  default: the DMG's asset URL on the GitHub release v<version>
# Env:
#   SPARKLE_PRIVATE_KEY  the private key (as exported by generate_keys -x). Unset: use the login Keychain.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$1"
DMG="$2"
URL="${3:-https://github.com/adii9/notch-agents/releases/download/v$VERSION/$(basename "$DMG")}"
SIGN_UPDATE=".build/artifacts/sparkle/Sparkle/bin/sign_update"
[ -x "$SIGN_UPDATE" ] || swift package resolve >/dev/null

if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
  KEY_FILE="$(mktemp)"
  trap 'rm -f -- "$KEY_FILE"' EXIT
  printf '%s' "$SPARKLE_PRIVATE_KEY" > "$KEY_FILE"
  SIG="$("$SIGN_UPDATE" --ed-key-file "$KEY_FILE" "$DMG")"
else
  SIG="$("$SIGN_UPDATE" "$DMG")"
fi
# sign_update prints: sparkle:edSignature="…" length="…"
[[ "$SIG" == *'sparkle:edSignature="'* ]] || { echo "sign_update failed: $SIG" >&2; exit 1; }

cat > dist/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Notch Agents</title>
    <item>
      <title>Version $VERSION</title>
      <link>https://github.com/adii9/notch-agents/releases/tag/v$VERSION</link>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$VERSION</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure url="$URL" type="application/octet-stream" $SIG />
    </item>
  </channel>
</rss>
XML
echo "Wrote dist/appcast.xml for $VERSION"
