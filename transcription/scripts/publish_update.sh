#!/bin/bash
# Builds a notarized Sparkle update, publishes it to GitHub, and refreshes the
# appcast that installed copies poll automatically.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$ROOT/.." && pwd)"
APP_BUNDLE="$ROOT/dist/Armin's Long to Short Converter.app"
DMG_PATH="$ROOT/dist/Armins-Long-to-Short-Converter.dmg"
SPARKLE_BIN="$ROOT/.build/artifacts/sparkle/Sparkle/bin"
REPO="davidmoserai/long-to-short-reels"

cd "$ROOT"

if [ -n "$(git -C "$REPO_ROOT" status --porcelain)" ]; then
    echo "Commit or stash source changes before publishing an update."
    exit 1
fi

./scripts/build_release.sh
./scripts/notarize_release.sh
./scripts/make_dmg.sh

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_BUNDLE/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_BUNDLE/Contents/Info.plist")"
ASSET_NAME="Armins-Long-to-Short-Converter.dmg"
DOWNLOAD_URL="https://github.com/$REPO/releases/download/v$VERSION/$ASSET_NAME"
SIGNATURE="$("$SPARKLE_BIN/sign_update" "$DMG_PATH")"

gh release create "v$VERSION" "$DMG_PATH#$ASSET_NAME" \
    --repo "$REPO" \
    --target master \
    --title "Armin's Long to Short Converter $VERSION" \
    --notes "Automatic update release."

cat > "$REPO_ROOT/appcast.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Armin's Long to Short Converter updates</title>
    <item>
      <title>Version $VERSION</title>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0.0</sparkle:minimumSystemVersion>
      <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
      <pubDate>$(LC_ALL=C date -Ru)</pubDate>
      <enclosure url="$DOWNLOAD_URL" $SIGNATURE type="application/octet-stream" />
    </item>
  </channel>
</rss>
EOF

git -C "$REPO_ROOT" add appcast.xml
git -C "$REPO_ROOT" commit -m "Publish appcast for v$VERSION"
git -C "$REPO_ROOT" push origin master

echo "Published v$VERSION and updated $DOWNLOAD_URL"
