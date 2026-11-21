#!/bin/bash
set -euo pipefail

# ── Znote release ───────────────────────────────────────────
#
# Does the whole release from this machine, because the artifacts must be
# signed and notarized with the local Developer ID:
#
#   1. checks (clean tree, on main, in sync, gh logged in, notary reachable)
#   2. ./selftest/run.sh
#   3. stamps the version into Info.plist and the site, commits if it changed
#   4. ./package.sh  → dist/Znote.zip   (signed + notarized + stapled)
#      ./dmg.sh      → dist/Znote.dmg
#   5. pushes main, creates and pushes the tag
#   6. creates the GitHub Release with the DMG and the zip
#   7. downloads the published DMG and compares it with the local one
#
# CI (.github/workflows/build.yml) only verifies that the tag builds; it
# does not publish anything.
#
# Usage:
#   ./release.sh v0.9.0                      Release (asks before the irreversible part)
#   ./release.sh v0.9.0 --notes notes.md     Use this file as the release notes
#   ./release.sh v0.9.0 -m "tag message"     Custom tag message
#   ./release.sh v0.9.0 -y                   Don't ask
#   ./release.sh v0.9.0 --skip-tests         Skip step 2
#   ./release.sh v0.9.0 --dry-run            Run the checks, change nothing
#   ./release.sh --list                      List tags
#   ./release.sh --delete v0.9.0             Delete a tag locally and remotely
# ────────────────────────────────────────────────────────────

cd "$(dirname "$0")"

REPO="nicetooo/Znote"
PLIST="Sources/Znote/Resources/Info.plist"
SITE="site/index.html"
NOTARY_PROFILE="Znote-notary"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${CYAN}▸${NC} $*"; }
ok()   { echo -e "${GREEN}✔${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; }
err()  { echo -e "${RED}✖${NC} $*" >&2; }

usage() { sed -n '4,29p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

list_tags() {
    info "Existing tags:"
    git tag -l --sort=-v:refname | while read -r tag; do
        printf "  ${GREEN}%-12s${NC} ${YELLOW}%s${NC}\n" "$tag" "$(git log -1 --format='%ai' "$tag" | cut -d' ' -f1)"
    done
    exit 0
}

delete_tag() {
    local tag="$1"
    git rev-parse "$tag" &>/dev/null || { err "Tag '$tag' does not exist"; exit 1; }
    warn "This deletes tag '$tag' locally and on origin. It does not delete the GitHub Release."
    read -rp "Continue? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { info "Cancelled."; exit 0; }
    git tag -d "$tag"
    git push origin ":refs/tags/$tag" 2>/dev/null && ok "Deleted remote tag" || warn "Remote tag not found"
    exit 0
}

# ── Arguments ───────────────────────────────────────────────
[ $# -lt 1 ] && usage
case "$1" in
    --list|-l) list_tags ;;
    --delete|-d) [ $# -ge 2 ] || { err "Specify the tag to delete"; exit 1; }; delete_tag "$2" ;;
    --help|-h) usage ;;
esac

VERSION="$1"; shift
MESSAGE=""; NOTES=""; ASSUME_YES=false; DRY_RUN=false; SKIP_TESTS=false
while [ $# -gt 0 ]; do
    case "$1" in
        -m) MESSAGE="$2"; shift 2 ;;
        --notes) NOTES="$2"; shift 2 ;;
        -y|--yes) ASSUME_YES=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --skip-tests) SKIP_TESTS=true; shift ;;
        *) err "Unknown option: $1"; usage ;;
    esac
done

if [[ ! "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    err "Invalid version '$VERSION' — expected v<major>.<minor>.<patch>, e.g. v0.9.0"
    exit 1
fi
NUMBER="${VERSION#v}"

# ── 1. Checks ───────────────────────────────────────────────
# In a dry run every failed check is reported and the run carries on, so one
# pass shows everything that would stop a real release.
PROBLEMS=0
problem() {
    err "$*"
    PROBLEMS=$((PROBLEMS + 1))
    $DRY_RUN || exit 1
}

info "Checking..."
[[ -z "$NOTES" || -f "$NOTES" ]] || problem "Release notes file not found: $NOTES"

if ! git diff --quiet || ! git diff --cached --quiet; then
    problem "Uncommitted changes — commit or stash them first:"$'\n'"$(git status --short)"
fi
git rev-parse "$VERSION" &>/dev/null && problem "Tag '$VERSION' already exists"
BRANCH=$(git branch --show-current)
[[ "$BRANCH" == "main" ]] || problem "On branch '$BRANCH', not main"

git fetch origin --quiet || problem "Couldn't reach origin"
if [[ -n "$(git rev-list HEAD..origin/main 2>/dev/null)" ]]; then
    problem "origin/main has commits this checkout doesn't — pull first"
fi

command -v gh >/dev/null || problem "gh not installed — brew install gh"
gh auth status >/dev/null 2>&1 || problem "gh is not logged in — run: gh auth login"
gh release view "$VERSION" -R "$REPO" >/dev/null 2>&1 && problem "A GitHub Release for $VERSION already exists"
command -v create-dmg >/dev/null || problem "create-dmg not installed — brew install create-dmg"

# Show Apple's own words: "no such profile" and "agreement expired" need
# different fixes.
if ! notary_out=$(xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" 2>&1); then
    problem "Apple's notary service refused the request:"$'\n'"  $(echo "$notary_out" | head -3 | sed 's/^/  /')"
fi

CURRENT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")
NEEDS_STAMP=false
[[ "$CURRENT" == "$NUMBER" ]] || NEEDS_STAMP=true
grep -q "id=\"download-version\">$VERSION " "$SITE" || NEEDS_STAMP=true

if $DRY_RUN; then
    echo
    info "Dry run for $VERSION — nothing was changed. A real run would:"
    $SKIP_TESTS || echo "    run ./selftest/run.sh"
    $NEEDS_STAMP && echo "    set the version to $NUMBER in $PLIST and $SITE (now $CURRENT), and commit"
    echo "    run ./package.sh and ./dmg.sh"
    echo "    push main, create and push tag $VERSION"
    echo "    create the GitHub Release with dist/Znote.dmg and dist/Znote.zip (${NOTES:-generated notes})"
    echo "    verify the published DMG"
    if (( PROBLEMS > 0 )); then err "$PROBLEMS problem(s) would stop it."; exit 1; fi
    ok "All checks pass."
    exit 0
fi
ok "Checks passed"

# ── 2. Tests ────────────────────────────────────────────────
if $SKIP_TESTS; then
    warn "Skipping the self-test"
else
    info "Running the self-test..."
    ./selftest/run.sh > build/release-selftest.log 2>&1 || {
        tail -25 build/release-selftest.log >&2
        err "Self-test failed — full log: build/release-selftest.log"
        exit 1
    }
    ok "Self-test passed"
fi

# ── 3. Version stamp ────────────────────────────────────────
if $NEEDS_STAMP; then
    info "Stamping version $NUMBER"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NUMBER" "$PLIST"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NUMBER" "$PLIST"
    # The site's button falls back to this text when the GitHub API is unreachable.
    sed -i '' -E "s|(id=\"download-version\">)v[0-9]+\.[0-9]+\.[0-9]+ |\1$VERSION |; s|(the static \")v[0-9]+\.[0-9]+\.[0-9]+(\" fallback)|\1$VERSION\2|" "$SITE"
    git add "$PLIST" "$SITE"
    git commit -q -m "release: $VERSION"
    ok "Committed the version stamp"
fi

# ── 4. Package ──────────────────────────────────────────────
info "Packaging (build, sign, notarize)..."
./package.sh
./dmg.sh

echo
info "Ready to publish ${GREEN}$VERSION${NC} from $(git log -1 --oneline)"
ls -lh dist/Znote.dmg dist/Znote.zip | awk '{print "    " $NF "  " $5}'
if ! $ASSUME_YES; then
    read -rp "Push, tag and publish? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { info "Stopped before publishing. dist/ is ready; re-run to continue."; exit 0; }
fi

# ── 5. Push + tag ───────────────────────────────────────────
git push origin main
git tag -a "$VERSION" -m "${MESSAGE:-Release $VERSION}"
git push origin "$VERSION"
ok "Pushed main and tag $VERSION"

# ── 6. GitHub Release ───────────────────────────────────────
if [[ -n "$NOTES" ]]; then
    gh release create "$VERSION" dist/Znote.dmg dist/Znote.zip -R "$REPO" --title "$VERSION" --verify-tag --notes-file "$NOTES"
else
    gh release create "$VERSION" dist/Znote.dmg dist/Znote.zip -R "$REPO" --title "$VERSION" --verify-tag --generate-notes
fi
ok "Release published"

# ── 7. Verify what users will download ──────────────────────
info "Verifying the published DMG..."
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
if curl -sfL --max-time 120 -o "$TMP/Znote.dmg" "https://github.com/$REPO/releases/latest/download/Znote.dmg" \
   && [[ "$(shasum -a 256 < "$TMP/Znote.dmg")" == "$(shasum -a 256 < dist/Znote.dmg)" ]]; then
    ok "The site's download link serves this build"
else
    warn "Couldn't confirm the download link serves this build — check the release page"
fi

echo
ok "Released $VERSION"
echo "    https://github.com/$REPO/releases/tag/$VERSION"
echo "    https://nicetooo.github.io/Znote/"
