#!/usr/bin/env bash
# notarize.sh — Submit BrainCache.app to Apple Notary Service and staple the ticket.
#
# Usage:
#   ./scripts/notarize.sh <path-to-BrainCache.app> <apple-id> <team-id> <keychain-profile>
#
# Prerequisites:
#   - Developer ID Application certificate in the login keychain
#   - Notarytool credentials stored in keychain:
#       xcrun notarytool store-credentials <profile-name> \
#           --apple-id <email> --team-id <team-id> --password <app-specific-password>
#   - Xcode Command Line Tools installed
#
# Example:
#   ./scripts/notarize.sh build/BrainCache.app dev@example.com ABCDE12345 notarytool-profile

set -euo pipefail

APP_PATH="${1:?Usage: $0 <app-path> <apple-id> <team-id> <keychain-profile>}"
APPLE_ID="${2:?missing apple-id}"
TEAM_ID="${3:?missing team-id}"
PROFILE="${4:?missing keychain-profile}"

ZIP_PATH="${APP_PATH%.app}-notarize.zip"

echo "==> Creating zip archive for notarization…"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo "==> Submitting to Apple Notary Service…"
xcrun notarytool submit "$ZIP_PATH" \
    --apple-id "$APPLE_ID" \
    --team-id "$TEAM_ID" \
    --keychain-profile "$PROFILE" \
    --wait

echo "==> Stapling notarization ticket…"
xcrun stapler staple "$APP_PATH"

echo "==> Verifying staple…"
xcrun stapler validate "$APP_PATH"

rm -f "$ZIP_PATH"
echo "==> Notarization complete: $APP_PATH"
