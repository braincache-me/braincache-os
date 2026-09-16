#!/usr/bin/env bash
# build-dmg.sh — Build, sign, notarize, and package BrainCache as a DMG.
#
# Usage:
#   ./scripts/build-dmg.sh [output-dir]
#
# Defaults:
#   output-dir = dist/
#
# Prerequisites:
#   - Xcode with the ClipVault scheme
#   - "Developer ID Application" certificate in Keychain
#   - Notarization credentials stored via:
#       xcrun notarytool store-credentials "notarytool" \
#         --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID
#
# Environment overrides:
#   SIGNING_IDENTITY  — code signing identity (auto-detected from Keychain)
#   KEYCHAIN_PROFILE  — notarytool credential profile name (default: "notarytool")
#   AUTO_BUMP_MINOR   — set to 0 to keep the current bundle version
#   CUSTOMIZE_DMG_LAYOUT — set to 0 to use Finder's default layout
#   SKIP_NOTARIZE     — set to 1 to skip notarization (ad-hoc distribution)

set -euo pipefail

APP_NAME="BrainCache"
OUTPUT_DIR="${1:-dist}"
KEYCHAIN_PROFILE="${KEYCHAIN_PROFILE:-notarytool}"
AUTO_BUMP_MINOR="${AUTO_BUMP_MINOR:-1}"
CUSTOMIZE_DMG_LAYOUT="${CUSTOMIZE_DMG_LAYOUT:-1}"
DERIVED_DATA="build"
APP_PATH="${DERIVED_DATA}/Build/Products/Release/${APP_NAME}.app"
INFO_PLIST="ClipVault/App/Info.plist"
BASE_ENTITLEMENTS="ClipVault/Resources/ClipVault.entitlements"
STAGING_DIR=""
RW_DMG_DIR=""
MOUNT_DIR=""
DMG_DEVICE=""
NOTARY_RESULT=""

set_plist_string() {
    local plist_path="$1"
    local key="$2"
    local value="$3"

    if /usr/libexec/PlistBuddy -c "Print :${key}" "$plist_path" >/dev/null 2>&1; then
        /usr/libexec/PlistBuddy -c "Set :${key} ${value}" "$plist_path"
    else
        /usr/libexec/PlistBuddy -c "Add :${key} string ${value}" "$plist_path"
    fi
}

bump_minor_version() {
    local plist_path="$1"
    local current_version current_build new_version
    local major minor
    local version_parts

    current_version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$plist_path" 2>/dev/null || echo "1.0")
    current_build=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$plist_path" 2>/dev/null || echo "0")

    IFS='.' read -r -a version_parts <<< "$current_version"
    major="${version_parts[0]:-1}"
    minor="${version_parts[1]:-0}"

    if ! [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]]; then
        echo "ERROR: CFBundleShortVersionString must use numeric components (for example: 1.4 or 1.4.0)."
        echo "  Found: ${current_version}"
        exit 1
    fi

    minor=$((minor + 1))
    new_version="${major}.${minor}"
    if (( ${#version_parts[@]} >= 3 )); then
        new_version="${major}.${minor}.0"
    fi

    set_plist_string "$plist_path" "CFBundleShortVersionString" "$new_version"

    if [[ "$current_build" =~ ^[0-9]+$ ]]; then
        local new_build=$((current_build + 1))
        set_plist_string "$plist_path" "CFBundleVersion" "$new_build"
        echo "==> Version bumped: ${current_version} (${current_build}) -> ${new_version} (${new_build})"
    else
        echo "WARNING: CFBundleVersion is non-numeric (${current_build}); leaving it unchanged."
        echo "==> Version bumped: ${current_version} -> ${new_version}"
    fi
}

cleanup_dmg_artifacts() {
    if [[ -n "${DMG_DEVICE:-}" ]]; then
        hdiutil detach "$DMG_DEVICE" -quiet || true
    elif [[ -n "${MOUNT_DIR:-}" && -d "$MOUNT_DIR" ]]; then
        hdiutil detach "$MOUNT_DIR" -quiet || true
    fi

    [[ -n "${STAGING_DIR:-}" ]] && rm -rf "$STAGING_DIR"
    [[ -n "${RW_DMG_DIR:-}" ]] && rm -rf "$RW_DMG_DIR"
    [[ -n "${MOUNT_DIR:-}" ]] && rm -rf "$MOUNT_DIR"
    [[ -n "${NOTARY_RESULT:-}" && -f "$NOTARY_RESULT" ]] && rm -f "$NOTARY_RESULT"

    return 0
}

layout_dmg_icons() {
    local mount_path="$1"
    local app_bundle_name="${APP_NAME}.app"

    osascript <<EOF
tell application "Finder"
    set mountFolder to POSIX file "${mount_path}" as alias
    open folder mountFolder

    tell container window of folder mountFolder
        set current view to icon view
        set toolbar visible to false
        set statusbar visible to false
        set bounds to {100, 100, 640, 360}
    end tell

    set arrangement of icon view options of container window of folder mountFolder to not arranged
    set icon size of icon view options of container window of folder mountFolder to 128
    set text size of icon view options of container window of folder mountFolder to 14

    set position of item "${app_bundle_name}" of folder mountFolder to {140, 150}
    set position of item "Applications" of folder mountFolder to {400, 150}

    close window of folder mountFolder
    open folder mountFolder
    update folder mountFolder without registering applications
    delay 2
end tell
EOF
}

codesign_release() {
    local target="$1"
    shift

    codesign --force \
        --sign "${SIGNING_IDENTITY}" \
        --options runtime \
        --timestamp \
        "$@" \
        "$target"
}

sign_if_present() {
    local target="$1"
    shift

    if [[ -e "$target" ]]; then
        echo "    signing ${target#${APP_PATH}/}"
        codesign_release "$target" "$@"
    fi
}

sign_bundled_resource_executables() {
    echo "==> Re-signing bundled resource executables…"
    sign_if_present "${APP_PATH}/Contents/Resources/braincache"
}

sign_sparkle_framework() {
    local sparkle_framework="${APP_PATH}/Contents/Frameworks/Sparkle.framework"
    local sparkle_version_dir="${sparkle_framework}/Versions/Current"

    if [[ ! -d "$sparkle_framework" ]]; then
        return
    fi

    if [[ ! -e "$sparkle_version_dir" ]]; then
        sparkle_version_dir="${sparkle_framework}/Versions/B"
    fi

    echo "==> Re-signing Sparkle nested code…"
    sign_if_present "${sparkle_version_dir}/XPCServices/Downloader.xpc"
    sign_if_present "${sparkle_version_dir}/XPCServices/Installer.xpc"
    sign_if_present "${sparkle_version_dir}/Updater.app"
    sign_if_present "${sparkle_version_dir}/Autoupdate"
    sign_if_present "$sparkle_framework"
}

check_notary_credentials() {
    if [[ "${SKIP_NOTARIZE:-0}" == "1" ]]; then
        return
    fi

    echo "==> Checking notarytool keychain profile: ${KEYCHAIN_PROFILE}"
    if ! xcrun notarytool history --keychain-profile "$KEYCHAIN_PROFILE" >/dev/null 2>&1; then
        echo "ERROR: No usable notarytool keychain profile found: ${KEYCHAIN_PROFILE}"
        echo ""
        echo "Create it with:"
        echo "  xcrun notarytool store-credentials ${KEYCHAIN_PROFILE} \\"
        echo "    --apple-id YOUR_APPLE_ID \\"
        echo "    --team-id YOUR_TEAM_ID"
        echo ""
        echo "Or run with SKIP_NOTARIZE=1 for a local, non-shippable DMG."
        exit 1
    fi
}

check_notary_credentials

if [[ "$AUTO_BUMP_MINOR" == "1" ]]; then
    bump_minor_version "$INFO_PLIST"
else
    echo "==> Version bump skipped (AUTO_BUMP_MINOR=0)"
fi

# Auto-detect Developer ID signing identity if not provided
if [[ -z "${SIGNING_IDENTITY:-}" ]]; then
    SIGNING_IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/')
    if [[ -z "$SIGNING_IDENTITY" ]]; then
        echo "ERROR: No 'Developer ID Application' certificate found in Keychain."
        echo "  Install one via Xcode > Settings > Accounts > Manage Certificates,"
        echo "  or set SIGNING_IDENTITY to use a different identity."
        exit 1
    fi
fi
echo "==> Signing identity: ${SIGNING_IDENTITY}"

# ── 1. Build Release ────────────────────────────────────────────────────────

echo "==> Building Release configuration…"
xcodebuild \
    -scheme ClipVault \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA" \
    clean build \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_IDENTITY="${SIGNING_IDENTITY}" \
    CODE_SIGN_STYLE=Manual \
    OTHER_CODE_SIGN_FLAGS="--options runtime" \
    2>&1 | tail -5

if [[ ! -d "$APP_PATH" ]]; then
    echo "ERROR: Build product not found at ${APP_PATH}"
    exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo "1.0")
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
echo "==> Built ${APP_NAME} v${VERSION}"

# ── 2. Re-sign for distribution ─────────────────────────────────────────────
# Strip com.apple.security.get-task-allow (debug entitlement) and add a
# secure timestamp, both required for notarization.

echo "==> Creating release entitlements…"
ENTITLEMENTS="$(mktemp -t entitlements)"
cp "$BASE_ENTITLEMENTS" "$ENTITLEMENTS"
/usr/libexec/PlistBuddy -c "Delete :com.apple.security.get-task-allow" "$ENTITLEMENTS" >/dev/null 2>&1 || true

sign_bundled_resource_executables
sign_sparkle_framework

echo "==> Re-signing app with secure timestamp…"
codesign_release "$APP_PATH" --entitlements "$ENTITLEMENTS"

rm -f "$ENTITLEMENTS"

codesign --verify --deep --strict "$APP_PATH"
echo "==> Signature verified"

# ── 3. Create DMG ───────────────────────────────────────────────────────────

mkdir -p "$OUTPUT_DIR"
STAGING_DIR="$(mktemp -d)"
RW_DMG_DIR="$(mktemp -d)"
MOUNT_DIR="$(mktemp -d "/tmp/${APP_NAME}.mount.XXXXXX")"
DMG_PATH="${OUTPUT_DIR}/${DMG_NAME}"
RW_DMG_PATH="${RW_DMG_DIR}/${APP_NAME}-rw.dmg"

trap cleanup_dmg_artifacts EXIT

echo "==> Staging app and Applications symlink…"
APP_SIZE_MB=$(du -sm "$APP_PATH" | awk '{ print $1 }')
DMG_SIZE_MB=$((APP_SIZE_MB + 128))

echo "==> Creating temporary read-write DMG…"
hdiutil create \
    -size "${DMG_SIZE_MB}m" \
    -fs HFS+ \
    -volname "$APP_NAME" \
    -ov \
    "$RW_DMG_PATH" \
    >/dev/null

echo "==> Mounting DMG…"
ATTACH_OUTPUT=$(hdiutil attach \
    -readwrite -noverify -noautoopen \
    -mountpoint "$MOUNT_DIR" \
    "$RW_DMG_PATH")
DMG_DEVICE=$(awk '/^\/dev\// { device = $1 } END { print device }' <<< "$ATTACH_OUTPUT")
if [[ -z "$DMG_DEVICE" ]]; then
    echo "ERROR: Could not determine mounted DMG device."
    echo "$ATTACH_OUTPUT"
    exit 1
fi

echo "==> Copying app into DMG…"
cp -R "$APP_PATH" "$MOUNT_DIR/"
ln -s /Applications "$MOUNT_DIR/Applications"

if [[ "$CUSTOMIZE_DMG_LAYOUT" == "1" ]]; then
    echo "==> Customizing Finder layout…"
    layout_dmg_icons "$MOUNT_DIR"
else
    echo "==> DMG layout customization skipped (CUSTOMIZE_DMG_LAYOUT=0)"
fi

hdiutil detach "$DMG_DEVICE" -quiet
DMG_DEVICE=""

echo "==> Creating compressed DMG…"
rm -f "$DMG_PATH"
hdiutil convert "$RW_DMG_PATH" \
    -ov -format UDZO \
    -imagekey zlib-level=9 \
    -o "$DMG_PATH" \
    >/dev/null

codesign --force --sign "${SIGNING_IDENTITY}" --timestamp "$DMG_PATH"
echo "==> DMG created and signed: ${DMG_PATH}"

# ── 4. Notarize ─────────────────────────────────────────────────────────────

if [[ "${SKIP_NOTARIZE:-0}" == "1" ]]; then
    echo "==> Skipping notarization (SKIP_NOTARIZE=1)"
    echo "==> Done: ${DMG_PATH}"
    exit 0
fi

echo "==> Submitting for notarization (this may take a few minutes)…"
NOTARY_RESULT="$(mktemp -t notary-result.XXXXXX.json)"
if ! xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$KEYCHAIN_PROFILE" \
    --wait \
    --output-format json \
    > "$NOTARY_RESULT"; then
    cat "$NOTARY_RESULT"
    exit 1
fi

cat "$NOTARY_RESULT"
NOTARY_STATUS=$(/usr/bin/plutil -extract status raw -o - "$NOTARY_RESULT" 2>/dev/null || true)
NOTARY_ID=$(/usr/bin/plutil -extract id raw -o - "$NOTARY_RESULT" 2>/dev/null || true)

if [[ "$NOTARY_STATUS" != "Accepted" ]]; then
    echo "ERROR: Notarization failed with status: ${NOTARY_STATUS:-unknown}"
    if [[ -n "$NOTARY_ID" ]]; then
        echo "==> Notarization log:"
        xcrun notarytool log "$NOTARY_ID" --keychain-profile "$KEYCHAIN_PROFILE" || true
    fi
    exit 1
fi

echo "==> Stapling notarization ticket…"
xcrun stapler staple "$DMG_PATH"
# Staple the .app bundle too — Sparkle's .zip is built from this bundle, so
# without an .app-level ticket auto-updated installs would fail Gatekeeper
# even though the DMG download is fine.
xcrun stapler staple "$APP_PATH"

# ── 5. Verify ───────────────────────────────────────────────────────────────

echo "==> Verifying Gatekeeper acceptance…"
spctl --assess --type open --context context:primary-signature -v "$DMG_PATH"

SIZE=$(du -sh "$DMG_PATH" | cut -f1)
echo ""
echo "==> Done! ${DMG_PATH} (${SIZE})"
echo "    Signed, notarized, and stapled — ready to distribute."
