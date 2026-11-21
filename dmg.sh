#!/bin/bash
set -euo pipefail

# ── Znote DMG builder ──────────────────────────────────────
#
# Wraps the already-signed-and-notarized build/Znote.app into a DMG with
# a classic "drag to Applications" layout, then signs + notarizes +
# staples the DMG itself so Gatekeeper is happy on mount too.
#
# Prereq: run ./package.sh first so build/Znote.app is Developer-ID
# signed, notarized, and stapled.
#
# Usage:
#   ./dmg.sh           Produce dist/Znote.dmg
# ───────────────────────────────────────────────────────────

APP="build/Znote.app"
IDENTITY="Developer ID Application: naisierding aihemaiti (ZVZ4AP4H2T)"
NOTARY_PROFILE="Znote-notary"
DIST_DIR="dist"
OUT_DMG="$DIST_DIR/Znote.dmg"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${CYAN}▸${NC} $*"; }
ok()   { echo -e "${GREEN}✔${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; }
err()  { echo -e "${RED}✖${NC} $*" >&2; }

# ── 0. Prereq checks ──────────────────────────────────────
if [ ! -d "$APP" ]; then
    err "$APP not found — run ./package.sh first"
    exit 1
fi

if ! command -v create-dmg &>/dev/null; then
    err "create-dmg not installed — run: brew install create-dmg"
    exit 1
fi

if ! notary_out=$(xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" 2>&1); then
    err "Apple's notary service refused the request:"
    echo "$notary_out" | head -5 | sed 's/^/    /' >&2
    echo "    (profile setup: see the package.sh header; agreements: https://developer.apple.com/account)" >&2
    exit 1
fi

# Sanity-check the .app is already notarized+stapled (dmg.sh can't know
# what the user has done; a DMG containing an unnotarized .app would
# trip Gatekeeper even after we notarize the DMG itself).
if ! spctl --assess --type execute "$APP" 2>&1 | grep -q "accepted"; then
    warn "$APP is not notarized+stapled — run ./package.sh first for a clean result"
fi

mkdir -p "$DIST_DIR"
rm -f "$OUT_DMG"

# ── 1. Build DMG with drag-to-Applications layout ─────────
info "Building DMG with create-dmg..."
create-dmg \
    --volname "Znote" \
    --volicon "$APP/Contents/Resources/Znote.icns" \
    --window-pos 200 120 \
    --window-size 540 380 \
    --icon-size 100 \
    --icon "Znote.app" 140 190 \
    --app-drop-link 400 190 \
    --hide-extension "Znote.app" \
    --no-internet-enable \
    "$OUT_DMG" \
    "$APP"
ok "DMG created: $OUT_DMG"

# ── 2. Sign the DMG ───────────────────────────────────────
info "Signing DMG..."
codesign --force --sign "$IDENTITY" "$OUT_DMG"
ok "Signed"

# ── 3. Submit DMG for notarization ────────────────────────
# Submissions occasionally bounce with a transient error (seen: a 403 about
# agreements one minute after another submission was accepted), so retry.
info "Submitting DMG for notarization..."
accepted=false
for attempt in 1 2 3; do
    if submit_out=$(xcrun notarytool submit "$OUT_DMG" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1) \
       && echo "$submit_out" | grep -q "status: Accepted"; then
        accepted=true
        break
    fi
    warn "Attempt $attempt failed:"
    echo "$submit_out" | tail -4 | sed 's/^/    /' >&2
    [[ $attempt -lt 3 ]] && sleep 20
done
if ! $accepted; then
    err "Notarization failed after 3 attempts."
    exit 1
fi
ok "Notarization accepted"

# ── 4. Staple the DMG ─────────────────────────────────────
info "Stapling notarization ticket..."
xcrun stapler staple "$OUT_DMG"
ok "Stapled"

# ── 5. Verify ─────────────────────────────────────────────
info "Verifying DMG with spctl + stapler..."
# Rely on exit codes — spctl is silent on success for `--type open`
if spctl --assess --type open --context context:primary-signature "$OUT_DMG" &>/dev/null; then
    ok "Gatekeeper accepts DMG"
else
    err "spctl rejected the DMG:"
    spctl --assess --type open --context context:primary-signature --verbose "$OUT_DMG" 2>&1
    exit 1
fi
if xcrun stapler validate "$OUT_DMG" &>/dev/null; then
    ok "Staple validated"
else
    warn "Staple validation failed — ticket may not be embedded"
fi

SIZE=$(du -h "$OUT_DMG" | awk '{print $1}')
ok "Wrote: $OUT_DMG ($SIZE)"
echo ""
ok "Ready to distribute. Share $OUT_DMG — users double-click to mount, drag Znote to Applications."
