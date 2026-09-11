#!/bin/bash
# Packages the notarized app into a drag-to-install DMG, then notarizes and
# staples the DMG itself too (Apple's recommendation -- Gatekeeper checks the
# thing that was actually downloaded, so the .dmg needs its own ticket).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_BUNDLE="$ROOT/dist/Long to Short.app"
DMG_PATH="$ROOT/dist/Long to Short.dmg"
STAGING="$ROOT/dist/dmg-staging"
PROFILE="longtoshort-notary"

if [ ! -d "$APP_BUNDLE" ]; then
    echo "No built app found. Run ./scripts/build_release.sh and ./scripts/notarize_release.sh first."
    exit 1
fi

echo "==> Staging DMG contents..."
rm -rf "$STAGING" "$DMG_PATH"
mkdir -p "$STAGING"
cp -R "$APP_BUNDLE" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

echo "==> Creating DMG..."
hdiutil create -volname "Long to Short" -srcfolder "$STAGING" -ov -format UDZO "$DMG_PATH"
rm -rf "$STAGING"

echo "==> Signing the DMG..."
codesign --force --sign "Developer ID Application: David Moser (UBB9PBT3N5)" "$DMG_PATH"

echo "==> Notarizing the DMG..."
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$PROFILE" --wait

echo "==> Stapling..."
xcrun stapler staple "$DMG_PATH"

echo ""
echo "Ready to send: $DMG_PATH"
