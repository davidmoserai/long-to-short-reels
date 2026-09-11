#!/bin/bash
# Notarizes and staples the already-built, already-signed app bundle.
# Requires a notarytool keychain profile to already exist -- see setup below.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_BUNDLE="$ROOT/dist/Long to Short.app"
ZIP_PATH="$ROOT/dist/LongToShort-notarize.zip"
PROFILE="longtoshort-notary"

if [ ! -d "$APP_BUNDLE" ]; then
    echo "No built app found at: $APP_BUNDLE"
    echo "Run ./scripts/build_release.sh first."
    exit 1
fi

if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    echo "No notarytool credential profile named '$PROFILE' found."
    echo ""
    echo "One-time setup -- run this yourself, it will interactively prompt you"
    echo "for your Apple ID, Team ID, and an app-specific password (generate one"
    echo "at https://account.apple.com -> Sign-In and Security -> App-Specific"
    echo "Passwords -- nothing to do with App Store Connect or publishing):"
    echo ""
    echo "  xcrun notarytool store-credentials \"$PROFILE\""
    echo ""
    echo "Team ID is UBB9PBT3N5 (from your Developer ID Application certificate)."
    echo ""
    exit 1
fi

echo "==> Zipping for submission..."
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"

echo "==> Submitting to Apple notary service (this can take a few minutes)..."
xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$PROFILE" --wait

echo "==> Stapling ticket to app..."
xcrun stapler staple "$APP_BUNDLE"

echo "==> Verifying Gatekeeper acceptance..."
spctl --assess --type execute --verbose "$APP_BUNDLE"

echo ""
echo "Notarized: $APP_BUNDLE"
