#!/bin/bash
# Builds, bundles, and codesigns LongToShortApp.app for direct (non-App-Store)
# distribution. Notarization is a separate step (notarize_release.sh) since it
# needs credentials that must be set up interactively once.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SIGNING_IDENTITY="Developer ID Application: David Moser (UBB9PBT3N5)"
APP_NAME="LongToShortApp"
DIST_DIR="$ROOT/dist"
APP_BUNDLE="$DIST_DIR/Armin's Long to Short Converter.app"
SPARKLE_FRAMEWORK="$ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"

echo "==> Building release binary..."
swift build -c release --product "$APP_NAME"

echo "==> Assembling app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources" "$APP_BUNDLE/Contents/Frameworks"

cp ".build/release/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "Resources/AppBundle/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "Resources/Branding/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

# SwiftPM links binary frameworks through @rpath; packaged apps load them here.
install_name_tool -add_rpath "@loader_path/../Frameworks" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

if [ ! -d "$SPARKLE_FRAMEWORK" ]; then
    echo "Sparkle.framework is missing. Run swift package resolve first."
    exit 1
fi
cp -R "$SPARKLE_FRAMEWORK" "$APP_BUNDLE/Contents/Frameworks/"

# Stamp a fresh build number every release so Finder/Dock/Stage Manager
# drop their cached bundle icon instead of reusing a stale generic one.
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%Y%m%d%H%M)" "$APP_BUNDLE/Contents/Info.plist"

# Copy any SPM resource bundles (e.g. FluidAudio's model config bundle) so
# Bundle.module resolution still works once wrapped in a proper .app.
for bundle in .build/release/*.bundle; do
    [ -d "$bundle" ] && cp -R "$bundle" "$APP_BUNDLE/Contents/Resources/"
done

echo "==> Code signing (hardened runtime)..."
codesign --force --deep \
    --options runtime \
    --entitlements "Resources/AppBundle/LongToShortApp.entitlements" \
    --sign "$SIGNING_IDENTITY" \
    --timestamp \
    "$APP_BUNDLE"

echo "==> Verifying signature..."
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
spctl --assess --type execute --verbose "$APP_BUNDLE" || echo "(spctl will reject until notarized -- expected at this stage)"

echo ""
echo "Built and signed: $APP_BUNDLE"
echo "Next: ./scripts/notarize_release.sh"
