#!/bin/bash
#
# Little Boring Notch: build, sign with the local certificate and install into
# /Applications. The certificate keeps the app's identity the same from build to
# build, so macOS permissions (Reminders, Screen Recording, ...) stay granted.
#
# Usage: scripts/install-local.sh [--no-launch]
#
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Little Boring Notch"
BUNDLE_ID="com.crvb.littleboringnotch"
KEYCHAIN="$HOME/Library/Keychains/littleboringnotch-signing.keychain-db"
IDENTITY_NAME="Little Boring Notch Local Signing"
DERIVED="build/DerivedData"

if [ ! -f "$KEYCHAIN" ]; then
    echo "Signing keychain not found: $KEYCHAIN" >&2
    echo "It holds the local signing certificate; see the project notes to recreate it." >&2
    exit 1
fi

security unlock-keychain -p "" "$KEYCHAIN"
IDENTITY=$(security find-identity -p codesigning "$KEYCHAIN" | awk -v name="$IDENTITY_NAME" '$0 ~ name { print $2; exit }')
if [ -z "$IDENTITY" ]; then
    echo "Certificate \"$IDENTITY_NAME\" not found in $KEYCHAIN" >&2
    exit 1
fi

echo "Building…"
# Hardened runtime stays off: with a self-signed certificate (no Team ID) it
# refuses to load the Debug build's own .debug.dylib.
xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration Debug \
    -derivedDataPath "$DERIVED" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" \
    CODE_SIGNING_REQUIRED=YES CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM="" \
    ENABLE_HARDENED_RUNTIME=NO \
    OTHER_CODE_SIGN_FLAGS="--keychain $KEYCHAIN" \
    build | tail -n 3

SRC="$DERIVED/Build/Products/Debug/$APP_NAME.app"
DST="/Applications/$APP_NAME.app"

echo "Installing into /Applications…"
osascript -e "quit app id \"$BUNDLE_ID\"" 2>/dev/null || true
sleep 1
rm -rf "$DST"
ditto "$SRC" "$DST"
codesign -dr - "$DST" 2>&1 | tail -n 1

if [ "${1:-}" != "--no-launch" ]; then
    open "$DST"
fi
echo "Done."
