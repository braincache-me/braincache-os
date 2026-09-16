#!/usr/bin/env bash
# reset-and-test.sh — Wipe local BrainCache state and run a clean build or test build.
#
# Usage:
#   ./scripts/reset-and-test.sh [--skip-tests] [--launch]
#
# What it resets:
#   1. Running BrainCache app process
#   2. Sandboxed prefs in ~/Library/Containers/com.TalkFlow.BrainCache/
#   3. Sandboxed database/media in ~/Library/Containers/com.TalkFlow.BrainCache/
#   4. Legacy defaults domains
#   5. OpenAI keychain item used by the app
#   6. TCC decisions for Accessibility and Screen Recording
#   7. Local and project-specific DerivedData/build artifacts
#
# What it runs:
#   - xcodebuild clean test
#   - or xcodebuild clean build when --skip-tests is used
#
# Optional:
#   --skip-tests   Skip tests and only do a clean build
#   --launch       Open the freshly built app after the build succeeds

set -euo pipefail

APP_NAME="BrainCache"
SCHEME="ClipVault"
BUNDLE_ID="com.TalkFlow.BrainCache"
SETTINGS_SUITE="com.clipvault.settings"
KEYCHAIN_SERVICE="com.clipvault.openai"
DESTINATION="platform=macOS"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DERIVED_DATA="${PROJECT_DIR}/build"
APP_PATH="${DERIVED_DATA}/Build/Products/Debug/${APP_NAME}.app"

CONTAINER_DIR="${HOME}/Library/Containers/${BUNDLE_ID}"
PREFERENCES_DIR="${CONTAINER_DIR}/Data/Library/Preferences"
APP_SUPPORT_DIR="${CONTAINER_DIR}/Data/Library/Application Support/ClipVault"

LAUNCH_APP=0
SKIP_TESTS=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --launch)
            LAUNCH_APP=1
            ;;
        --skip-tests)
            SKIP_TESTS=1
            ;;
        -h|--help)
            sed -n '1,24p' "$0"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Usage: ./scripts/reset-and-test.sh [--skip-tests] [--launch]" >&2
            exit 1
            ;;
    esac
    shift
done

step() {
    echo ""
    echo "==> $*"
}

delete_if_present() {
    local path="$1"
    if [[ -e "$path" ]]; then
        rm -rf "$path"
        echo "Removed: $path"
    fi
}

cd "$PROJECT_DIR"

step "Stopping running app"
killall "$APP_NAME" 2>/dev/null || true
sleep 1

step "Removing local build artifacts"
rm -rf "$DERIVED_DATA"
for path in "$HOME"/Library/Developer/Xcode/DerivedData/ClipVault-*; do
    [[ -e "$path" ]] || continue
    rm -rf "$path"
    echo "Removed: $path"
done

step "Resetting sandboxed app state"
delete_if_present "${PREFERENCES_DIR}/${SETTINGS_SUITE}.plist"
delete_if_present "${PREFERENCES_DIR}/${BUNDLE_ID}.plist"
delete_if_present "$APP_SUPPORT_DIR"

step "Resetting legacy defaults domains"
defaults delete "$SETTINGS_SUITE" 2>/dev/null || true
defaults delete "$BUNDLE_ID" 2>/dev/null || true

step "Resetting keychain item"
security delete-generic-password -s "$KEYCHAIN_SERVICE" 2>/dev/null || true

step "Resetting TCC permissions"
tccutil reset Accessibility "$BUNDLE_ID" 2>/dev/null || true
tccutil reset ScreenCapture "$BUNDLE_ID" 2>/dev/null || true

if [[ "$SKIP_TESTS" == "1" ]]; then
    step "Running clean build (tests skipped)"
    xcodebuild \
        -scheme "$SCHEME" \
        -destination "$DESTINATION" \
        -derivedDataPath "$DERIVED_DATA" \
        clean build \
        -quiet
else
    step "Running clean test build"
    xcodebuild \
        -scheme "$SCHEME" \
        -destination "$DESTINATION" \
        -derivedDataPath "$DERIVED_DATA" \
        clean test \
        -quiet
fi

step "Done"
echo "Fresh app path: $APP_PATH"

if [[ "$LAUNCH_APP" == "1" ]]; then
    step "Launching app"
    open "$APP_PATH"
fi
