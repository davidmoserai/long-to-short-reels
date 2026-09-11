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
    echo "One-time setup, run this yourself (needs an App Store Connect API key"
    echo "from https://appstoreconnect.apple.com/access/integrations/api):"
    echo ""
    echo "  xcrun notarytool store-credentials \"$PROFILE\" \\"
    echo "    --key /path/to/AuthKey_XXXXXXXXXX.p8 \\"
    echo "    --key-id XXXXXXXXXX \\"
    echo "    --issuer YOUR-ISSUER-ID-UUID"
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
