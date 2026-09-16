#!/usr/bin/env bash
# dev-run.sh — Build and launch BrainCache as an isolated dev app.
#
# Usage:
#   ./scripts/dev-run.sh
#
# What this gives you:
#   - Separate bundle ID (com.TalkFlow.BrainCache.dev) so macOS treats the dev
#     and prod apps as different apps for Accessibility / Screen Recording /
#     Microphone TCC permissions. Re-signing dev no longer kicks prod's
#     permissions, and vice versa.
#   - Separate Application Support folder (`ClipVault-Dev/`) and UserDefaults
#     suite (`com.clipvault.settings.dev`), driven by `BuildVariant.swift`.
#     Prod's database, media, preferences, and activity-capture log root are
#     untouched.
#   - Renamed bundle (`BrainCache Dev.app`) and patched CFBundleDisplayName so
#     menu-bar text and Finder make the dev variant obvious.
#   - Keychain (OpenAI API key) is intentionally shared with prod — no need to
#     re-enter the key.
#
# Environment overrides:
#   DEV_BUNDLE_ID   default: com.TalkFlow.BrainCache.dev
#   DEV_DISPLAY     default: "BrainCache Dev"
#   REGEN           set to 1 to force `xcodegen generate` first
#   NO_LAUNCH       set to 1 to build only (don't open the app)
#   CONFIGURATION   default: Debug
#   SCREEN_CAPTURE  set to 1 to make panel windows (Voice, AI Assist) visible
#                   to screen-recording / screen-sharing APIs. Defines the
#                   DEV_SCREEN_CAPTURE Swift flag. Has no effect on prod —
#                   `BuildVariant.allowsScreenCapture` hard-refuses when the
#                   bundle ID matches prod.

set -euo pipefail

cd "$(dirname "$0")/.."

DEV_BUNDLE_ID="${DEV_BUNDLE_ID:-com.TalkFlow.BrainCache.dev}"
DEV_DISPLAY="${DEV_DISPLAY:-BrainCache Dev}"
CONFIGURATION="${CONFIGURATION:-Debug}"
SCREEN_CAPTURE="${SCREEN_CAPTURE:-0}"
DERIVED_DATA="build-dev"
BUILT_APP="${DERIVED_DATA}/Build/Products/${CONFIGURATION}/BrainCache.app"
DEV_APP="${DERIVED_DATA}/Build/Products/${CONFIGURATION}/${DEV_DISPLAY}.app"

# ── 1. Regenerate Xcode project if needed ───────────────────────────────────

if [[ "${REGEN:-0}" == "1" || ! -d "ClipVault.xcodeproj" ]]; then
    if ! command -v xcodegen >/dev/null 2>&1; then
        echo "ERROR: xcodegen not found. Install via 'brew install xcodegen'."
        exit 1
    fi
    echo "==> Regenerating ClipVault.xcodeproj…"
    xcodegen generate >/dev/null
fi

# ── 2. Quit any running dev instance ────────────────────────────────────────

# Match by bundle path so we don't kill the prod app, which shares the
# executable name "BrainCache".
if [[ -d "$DEV_APP" ]]; then
    DEV_APP_ABS="$(cd "$(dirname "$DEV_APP")" && pwd)/$(basename "$DEV_APP")"
    DEV_PIDS=$(pgrep -f "${DEV_APP_ABS}/Contents/MacOS/BrainCache" || true)
    if [[ -n "$DEV_PIDS" ]]; then
        echo "==> Quitting running ${DEV_DISPLAY} (pids: ${DEV_PIDS})…"
        # shellcheck disable=SC2086
        kill $DEV_PIDS 2>/dev/null || true
        sleep 1
    fi
fi

# ── 3. Build (override only the bundle ID; PRODUCT_NAME unchanged) ──────────
#
# Why we don't override PRODUCT_NAME: doing so confuses Xcode's SwiftPM
# resource-bundle copy step (GRDB_GRDB.bundle) and the SwiftUI preview shim
# linker invocation in Xcode 16. Bundle ID alone is enough to give the dev
# app its own TCC identity; we patch the user-visible name post-build.

EXTRA_SWIFT_FLAGS=""
if [[ "${SCREEN_CAPTURE}" == "1" ]]; then
    echo "==> SCREEN_CAPTURE=1 — panels will be visible to screen recording (dev only)."
    EXTRA_SWIFT_FLAGS="-DDEV_SCREEN_CAPTURE"
fi

echo "==> Building ${CONFIGURATION} (${DEV_BUNDLE_ID})…"
xcodebuild \
    -scheme ClipVault \
    -configuration "${CONFIGURATION}" \
    -derivedDataPath "${DERIVED_DATA}" \
    build \
    ONLY_ACTIVE_ARCH=YES \
    PRODUCT_BUNDLE_IDENTIFIER="${DEV_BUNDLE_ID}" \
    OTHER_SWIFT_FLAGS="${EXTRA_SWIFT_FLAGS}" \
    | tail -5

if [[ ! -d "$BUILT_APP" ]]; then
    echo "ERROR: Build product not found at ${BUILT_APP}"
    exit 1
fi

# ── 4. Rename bundle and patch display name ─────────────────────────────────

if [[ -d "$DEV_APP" ]]; then
    rm -rf "$DEV_APP"
fi

# Use ditto to preserve metadata; rsync would also work.
ditto "$BUILT_APP" "$DEV_APP"

INFO_PLIST="${DEV_APP}/Contents/Info.plist"

set_plist_string() {
    local key="$1"
    local value="$2"
    if /usr/libexec/PlistBuddy -c "Print :${key}" "$INFO_PLIST" >/dev/null 2>&1; then
        /usr/libexec/PlistBuddy -c "Set :${key} ${value}" "$INFO_PLIST"
    else
        /usr/libexec/PlistBuddy -c "Add :${key} string ${value}" "$INFO_PLIST"
    fi
}

set_plist_string "CFBundleName" "${DEV_DISPLAY}"
set_plist_string "CFBundleDisplayName" "${DEV_DISPLAY}"

# Re-sign with a STABLE code identity (not ad-hoc) so macOS TCC treats every
# dev rebuild as the same app and keeps the permissions you have granted —
# Accessibility, Screen Recording, Microphone, Input Monitoring, etc.
#
# Ad-hoc signing (`--sign -`) has no stable identity: each code rebuild changes
# the code hash, macOS sees a "new" app, and every TCC grant is silently
# invalidated — you'd have to re-grant Accessibility after every run. Signing
# with a real "Apple Development" identity gives a stable designated
# requirement (cert + Team ID + bundle ID), so the grants persist.
#
# Override the identity with DEV_SIGN_IDENTITY (a name substring or SHA-1
# hash). Falls back to ad-hoc when no matching identity exists.
DEV_SIGN_IDENTITY="${DEV_SIGN_IDENTITY:-Apple Development}"
SIGN_HASH="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -F "$DEV_SIGN_IDENTITY" | head -1 | awk '{print $2}')"
if [[ -n "$SIGN_HASH" ]]; then
    echo "==> Re-signing with stable identity (${DEV_SIGN_IDENTITY})…"
    if ! codesign --force --sign "$SIGN_HASH" --timestamp=none "$DEV_APP" >/dev/null 2>&1; then
        echo "    warning: stable re-sign failed — falling back to ad-hoc"
        codesign --force --sign - --timestamp=none "$DEV_APP" >/dev/null 2>&1 || true
    fi
else
    echo "==> No '${DEV_SIGN_IDENTITY}' identity found — ad-hoc signing."
    echo "    (TCC permissions will reset on every rebuild; see dev-run.sh notes.)"
    codesign --force --sign - --timestamp=none "$DEV_APP" >/dev/null 2>&1 || true
fi

echo "==> Built: $DEV_APP"
echo "    bundle id: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")"
echo "    display:   $(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$INFO_PLIST")"

# ── 5. Launch ───────────────────────────────────────────────────────────────

if [[ "${NO_LAUNCH:-0}" == "1" ]]; then
    echo "==> Skipping launch (NO_LAUNCH=1)"
    exit 0
fi

echo "==> Launching ${DEV_DISPLAY}…"
open -n "$DEV_APP"
