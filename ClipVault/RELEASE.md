# Releasing BrainCache

How to cut a new production release and ship it to `braincache.me`.

> The legacy hostname `braincache.bots.partners` still resolves to the same files
> (`momai-backend` middleware aliases both hosts to `braincache/landing/`), so older
> 1.7-and-below clients with `SUFeedURL = https://braincache.bots.partners/appcast.xml`
> keep auto-updating. New builds from 1.8 onward point at `braincache.me`.

The whole pipeline is two scripts:

```
./scripts/build-dmg.sh           # build, sign, notarize, staple
./scripts/deploy-braincache.sh   # zip, sign appcast, upload, bump landing
```

Everything else in this doc is one-time setup, prerequisites, and what to check.

---

## Per-release flow (the 90% path)

```
cd ClipVault
./scripts/build-dmg.sh                       # bumps minor version automatically
open dist/BrainCache-<version>.dmg           # smoke-test the build
# … drag to /Applications, run it, check basic features …
./scripts/deploy-braincache.sh               # uploads to remote
```

That's it. After `deploy-braincache.sh`:

- `https://braincache.me/BrainCache-<version>.dmg` — direct download
- `https://braincache.me/BrainCache-<version>-<build>-<sha>.zip` — Sparkle update payload
- `https://braincache.me/appcast.xml` — Sparkle feed (with new signed `<item>`)
- `https://braincache.me/index.html` — landing page now links to the new DMG

Existing users running a Sparkle-enabled BrainCache will pick up the update on their next polling check (default daily) or via **BrainCache menu → Check for Updates…**.

### Optional: per-version release notes

Write HTML release notes to `dist/release-notes-<version>.html` before running the deploy script. They get embedded as `<description>` in the appcast and shown in Sparkle's update dialog. Without this file, the script ships a generic "Bug fixes and improvements" placeholder.

```
cat > dist/release-notes-1.8.html <<'EOF'
<h2>What's new in 1.8</h2>
<ul>
  <li>Auto-updates via Sparkle</li>
  <li>Faster activity capture pipeline</li>
</ul>
EOF
```

---

## One-time setup

You only need to do this once per machine.

### 1. Apple Developer ID + notarization credentials

```
xcrun notarytool store-credentials notarytool \
  --apple-id YOUR_APPLE_ID \
  --team-id YOUR_TEAM_ID
```

`build-dmg.sh` reads the `notarytool` keychain profile to submit notarization.

### 2. `sshpass` for the upload step

```
brew install esolitos/ipa/sshpass
```

`deploy-braincache.sh` uses it to authenticate to the remote (matches `momai-backend/deploy.sh`).

### 3. Sparkle release tools + EdDSA signing key

```
./scripts/install-sparkle-tools.sh --patch-plist
```

This downloads `sign_update` and `generate_keys` to `scripts/sparkle-bin/`, generates an EdDSA key (private stored in your login Keychain, public written into `Info.plist` as `SUPublicEDKey`), and is what makes signed Sparkle updates possible.

**Back up the private key.** Open Keychain Access → search for `ed25519` (Sparkle's key entry) → File → Export. Losing it means losing the ability to sign updates — clients running on the old `SUPublicEDKey` would refuse anything new, forcing a manual reinstall for every user.

---

## What gets shipped

| File | Purpose |
|---|---|
| `BrainCache-X.Y.dmg` | First-time download from the landing page (drag-to-Applications). |
| `BrainCache-X.Y-build-sha.zip` | In-place auto-update payload for Sparkle. The SHA prefix keeps each payload URL unique so a CDN cannot serve an older ZIP with a newer appcast signature. |
| `appcast.xml` | Sparkle's RSS feed — clients poll this and verify the EdDSA signature on each `<item>`. |
| `index.html` | Landing page, with the download button rewritten to point at the new DMG. |

The remote layout under `~/momai-backend/braincache/landing/` mirrors what `https://braincache.me/` serves.

---

## Verifying a release went out

1. **Landing page** — open https://braincache.me/ in a browser. The download button should link to `BrainCache-<new>.dmg`.
2. **Direct download** — `curl -I https://braincache.me/BrainCache-<new>.dmg` should return `200`.
3. **Appcast** — `curl https://braincache.me/appcast.xml` should contain a `<sparkle:shortVersionString><new></sparkle:shortVersionString>` and a `sparkle:edSignature="…"` attribute on a content-addressed ZIP enclosure.
4. **End-to-end auto-update** — install the previous version, run it, **Check for Updates…**, confirm the prompt shows the new version's release notes.

---

## How auto-update detection works

`SPUStandardUpdaterController` (in `AppDelegate`) does an HTTPS GET on `SUFeedURL` (configured in `Info.plist`) every `SUScheduledCheckInterval` seconds (default 86400 = once a day). It picks the newest `<item>` whose `sparkle:minimumSystemVersion` the user satisfies, compares its `sparkle:version` to the running app's `CFBundleVersion`, and if higher, downloads the `<enclosure>` zip, verifies the EdDSA signature against the embedded `SUPublicEDKey`, then atomically replaces the app and relaunches.

There is no server-side push — it's a periodic poll of a static XML file plus signature verification. The appcast can be cached on a CDN; the EdDSA signature is the trust root, not the URL.

---

## Useful overrides

```
# Deploy a specific version (e.g. re-deploy after editing release notes).
# The ZIP URL still changes if the archive bytes changed.
VERSION=1.8 ./scripts/deploy-braincache.sh

# Use a custom release-notes file
RELEASE_NOTES=path/to/notes.html ./scripts/deploy-braincache.sh

# Test the deploy without uploading anything (still mutates local dist/)
DRY_RUN=1 ./scripts/deploy-braincache.sh

# Skip notarization (fast iteration, ad-hoc only — never ship this)
SKIP_NOTARIZE=1 ./scripts/build-dmg.sh

# Don't auto-bump the version
AUTO_BUMP_MINOR=0 ./scripts/build-dmg.sh
```

---

## Troubleshooting

**`sign_update not found`** — run `./scripts/install-sparkle-tools.sh`. The deploy script will then sign automatically.

**`Cannot reach <host> via SSH`** — make sure you're on the right network (Tailscale / VPN). The remote IP is hardcoded in `deploy-braincache.sh`; override with `REMOTE_HOST=…` if it changes.

**`xcrun notarytool: keychain item not found`** — the `notarytool` keychain profile isn't set. Re-run `xcrun notarytool store-credentials notarytool` (see one-time setup).

**Sparkle: "Couldn't verify update signature" / "improperly signed"** — the deployed `appcast.xml`'s `sparkle:edSignature` doesn't match the ZIP Sparkle downloaded or the `SUPublicEDKey` baked into the running app. Common causes are using the wrong Sparkle key, running an app built before `SUPublicEDKey` was patched in, or a CDN serving an older ZIP at the same URL as a freshly signed appcast. The deploy script now gives each ZIP a SHA-based filename and verifies the public ZIP after upload; if this happens for an older same-version deploy, wait for the CDN cache to expire or ship a new build.

**Older versions can't auto-update** — Sparkle was integrated in 1.8. Versions 1.7 and earlier have no `SUFeedURL` and don't poll. Users on those versions need to manually download once.

**Appcast entry shows up unsigned** — the deploy script couldn't find `sign_update`. Run `install-sparkle-tools.sh`, then re-run `deploy-braincache.sh` with the same `VERSION=` to overwrite the unsigned entry.
