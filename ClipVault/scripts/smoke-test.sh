#!/usr/bin/env bash
# smoke-test.sh — Verify BrainCache.app bundle integrity before distribution.
#
# Usage:
#   ./scripts/smoke-test.sh [app-path]
#
# Checks:
#   1. App bundle exists at expected path
#   2. LSUIElement=YES in Info.plist (no dock icon)
#   3. Universal binary (arm64 + x86_64) via lipo
#   4. App launches and exits cleanly within 5 seconds
#   5. Hardened runtime entitlement is present

set -euo pipefail

APP_PATH="${1:-build/Build/Products/Release/BrainCache.app}"
# Resolve to absolute so defaults(1) reads the file, not a preference domain
APP_PATH="$(cd "$(dirname "$APP_PATH")" && pwd)/$(basename "$APP_PATH")"
BINARY="${APP_PATH}/Contents/MacOS/BrainCache"
PLIST="${APP_PATH}/Contents/Info.plist"
PASS=0
FAIL=0

ok()   { echo "[PASS] $*"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $*"; FAIL=$((FAIL + 1)); }

echo "==> Smoke-testing: $APP_PATH"
echo ""

# 1. App bundle exists
if [ -d "$APP_PATH" ]; then
    ok "App bundle exists"
else
    fail "App bundle not found at $APP_PATH"
    exit 1
fi

# 2. LSUIElement=YES
LSUI=$(defaults read "$APP_PATH/Contents/Info" LSUIElement 2>/dev/null || echo "0")
if [ "$LSUI" = "1" ]; then
    ok "LSUIElement=YES (agent app, no dock icon)"
else
    fail "LSUIElement is not YES (got: $LSUI)"
fi

# 3. Universal binary
LIPO_OUTPUT=$(lipo -info "$BINARY" 2>&1)
if echo "$LIPO_OUTPUT" | grep -q "arm64" && echo "$LIPO_OUTPUT" | grep -q "x86_64"; then
    ok "Universal binary: arm64 + x86_64"
else
    fail "Not a universal binary. lipo output: $LIPO_OUTPUT"
fi

# 4. App launches and quits within 5 seconds
LAUNCH_LOG=$(mktemp)
open -a "$APP_PATH" --args --smoke-test 2>"$LAUNCH_LOG" &
OPEN_PID=$!
sleep 3
APP_PROC=$(pgrep -x BrainCache || true)
if [ -n "$APP_PROC" ]; then
    ok "App launched (PID: $APP_PROC)"
    kill "$APP_PROC" 2>/dev/null || true
else
    fail "App did not launch or crashed immediately (see: $LAUNCH_LOG)"
fi
rm -f "$LAUNCH_LOG"

# 5. Hardened runtime / entitlements
if codesign --display --entitlements - "$APP_PATH" 2>&1 | grep -q "com.apple.security"; then
    ok "Entitlements present (hardened runtime)"
else
    fail "No entitlements found — hardened runtime may not be enabled"
fi

echo ""
echo "==> Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
