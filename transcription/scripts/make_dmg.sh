#!/bin/bash
# Packages the notarized app into a drag-to-install DMG, then notarizes and
# staples the DMG itself too (Apple's recommendation -- Gatekeeper checks the
# thing that was actually downloaded, so the .dmg needs its own ticket).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_BUNDLE="$ROOT/dist/Armin's Long to Short Converter.app"
DMG_PATH="$ROOT/dist/Armin's Long to Short Converter.dmg"
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
hdiutil create -volname "Armin's Long to Short Converter" -srcfolder "$STAGING" -ov -format UDZO "$DMG_PATH"
rm -rf "$STAGING"

echo "==> Signing the DMG..."
codesign --force --sign "Developer ID Application: David Moser (UBB9PBT3N5)" "$DMG_PATH"

if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    echo "==> Notarizing the DMG..."
    xcrun notarytool submit "$DMG_PATH" --keychain-profile "$PROFILE" --wait

    echo "==> Stapling..."
    xcrun stapler staple "$DMG_PATH"
else
    echo "(No notarytool profile '$PROFILE' -- skipping DMG notarization.)"
    echo "(First launch will need right-click -> Open instead of double-click.)"
fi

echo ""
echo "Ready to send: $DMG_PATH"
