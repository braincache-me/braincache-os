#!/usr/bin/env bash
# install-sparkle-tools.sh — One-time setup of Sparkle's release CLI.
#
# Downloads the Sparkle release tarball, extracts sign_update + generate_keys
# into ClipVault/scripts/sparkle-bin/, and (optionally) generates an EdDSA
# signing key in your login Keychain. The deploy script picks up sign_update
# automatically once it's in scripts/sparkle-bin/.
#
# Usage:
#   ./scripts/install-sparkle-tools.sh                # first time: download + generate key
#   ./scripts/install-sparkle-tools.sh --no-keygen    # download only, skip key generation
#   SPARKLE_VERSION=2.6.4 ./scripts/install-sparkle-tools.sh
#
# After running, paste the printed public key into Info.plist's SUPublicEDKey,
# or pass --patch-plist to do that automatically.

set -euo pipefail

SPARKLE_VERSION="${SPARKLE_VERSION:-2.6.4}"
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN_DIR="${PROJECT_ROOT}/scripts/sparkle-bin"
INFO_PLIST="${PROJECT_ROOT}/ClipVault/App/Info.plist"

DO_KEYGEN=1
PATCH_PLIST=0
for arg in "$@"; do
    case "$arg" in
        --no-keygen)   DO_KEYGEN=0 ;;
        --patch-plist) PATCH_PLIST=1 ;;
        *) echo "Unknown flag: $arg" >&2; exit 1 ;;
    esac
done

info()  { printf '\033[1;34m=> %s\033[0m\n' "$*"; }
ok()    { printf '\033[1;32m✓  %s\033[0m\n' "$*"; }
warn()  { printf '\033[1;33m⚠  %s\033[0m\n' "$*"; }
fail()  { printf '\033[1;31m✗  %s\033[0m\n' "$*"; exit 1; }

# ── 1. Download Sparkle release tarball ─────────────────────────
mkdir -p "$BIN_DIR"
TARBALL_URL="https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

info "Downloading Sparkle ${SPARKLE_VERSION}…"
curl -fL --progress-bar "$TARBALL_URL" -o "${TMP_DIR}/sparkle.tar.xz" \
    || fail "Failed to download $TARBALL_URL"

info "Extracting CLI tools…"
tar -xJf "${TMP_DIR}/sparkle.tar.xz" -C "$TMP_DIR" \
    || fail "Failed to extract tarball"

# Sparkle's tarball layout: bin/sign_update, bin/generate_keys, etc.
[[ -x "${TMP_DIR}/bin/sign_update"   ]] || fail "sign_update not found in tarball"
[[ -x "${TMP_DIR}/bin/generate_keys" ]] || fail "generate_keys not found in tarball"

cp "${TMP_DIR}/bin/sign_update"   "${BIN_DIR}/"
cp "${TMP_DIR}/bin/generate_keys" "${BIN_DIR}/"
chmod +x "${BIN_DIR}/sign_update" "${BIN_DIR}/generate_keys"
ok "Installed to ${BIN_DIR}/"

# ── 2. Optionally generate an EdDSA key ─────────────────────────
if [[ "$DO_KEYGEN" != "1" ]]; then
    info "Skipping key generation (--no-keygen)."
    exit 0
fi

# generate_keys is idempotent: if a key already exists it prints the public one.
info "Generating / fetching EdDSA key (private key stays in your login Keychain)…"
KEYGEN_OUTPUT="$("${BIN_DIR}/generate_keys" 2>&1 || true)"

# Extract the public key. Sparkle prints something like:
#   "A key has been generated… Its public key is:"
#   "<base64 string>"
PUBLIC_KEY="$(printf '%s\n' "$KEYGEN_OUTPUT" | grep -E '^[A-Za-z0-9+/=]{40,}$' | tail -1 || true)"

if [[ -z "$PUBLIC_KEY" ]]; then
    # Fallback: query for the existing key non-destructively.
    PUBLIC_KEY="$("${BIN_DIR}/generate_keys" -p 2>/dev/null | tr -d '[:space:]' || true)"
fi

if [[ -z "$PUBLIC_KEY" ]]; then
    warn "Could not parse public key from generate_keys output. Raw output:"
    printf '%s\n' "$KEYGEN_OUTPUT"
    fail "Run '${BIN_DIR}/generate_keys -p' manually and paste the result into Info.plist."
fi

ok "Public EdDSA key:"
echo ""
echo "    ${PUBLIC_KEY}"
echo ""

# ── 3. Optionally patch Info.plist ──────────────────────────────
if [[ "$PATCH_PLIST" == "1" ]]; then
    [[ -f "$INFO_PLIST" ]] || fail "Info.plist not found at $INFO_PLIST"
    /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey ${PUBLIC_KEY}" "$INFO_PLIST" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string ${PUBLIC_KEY}" "$INFO_PLIST"
    ok "Wrote SUPublicEDKey to ${INFO_PLIST}"
else
    info "Next step:"
    echo "    Set :SUPublicEDKey in Info.plist to the value above, or re-run with --patch-plist."
fi

echo ""
ok "Done. Build a release with this key embedded — that becomes your trust anchor"
ok "for every future auto-update."
