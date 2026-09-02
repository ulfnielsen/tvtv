#!/usr/bin/env bash
#
# release.sh [major|minor|patch] [--dry-run]   (default: patch)
#
# Cuts a TVTV release:
#   1. runs the test suite
#   2. bumps MARKETING_VERSION + CURRENT_PROJECT_VERSION (scripts/version.sh)
#   3. builds + signs TVTV.app with Developer ID (scripts/build.sh --release)
#   4. asserts the app AND the embedded QuickLook appex are release-signed
#   5. notarizes the app and staples the ticket to it
#   6. packages a stapled .zip and a notarized + stapled .dmg
#   7. commits "Release vX.Y.Z", tags vX.Y.Z
#   8. pushes branch + tag, and creates a GitHub Release with both assets
#
# --dry-run runs steps 1-6 and then stops: nothing is committed, tagged, pushed
# or published, and the version stamp is rolled back. That exercises the whole
# signing/notarization path — the part that can actually fail — without burning
# a version number. Note that it DOES submit to Apple's notary service; the
# submissions are real, only the release is not.
#
# Prereqs: a git `origin` remote on GitHub, `gh` authenticated, a clean working
# tree, a Developer ID Application certificate, and a notarytool keychain
# profile (default name "tvtv-notary", override with $TVTV_NOTARY_PROFILE):
#
#   xcrun notarytool store-credentials tvtv-notary \
#       --key <AuthKey_XXXXXXXXXX.p8> --key-id <KEYID> --issuer <ISSUER-UUID>
#
# Notarization needs network access and normally takes 1-5 minutes per
# submission; there are two per release (the app, then the disk image).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Use the full Xcode toolchain (XCTest + release build) even when Command Line
# Tools is the active xcode-select choice, matching build.sh.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

APP="$REPO_ROOT/dist/TVTV.app"
APPEX="$APP/Contents/PlugIns/TVTVQuickLook.appex"
DERIVED="$REPO_ROOT/build/xcode"
# Files the version stamp rewrites — reverted verbatim if the release aborts,
# committed together if it succeeds. project.yml is the source of truth;
# project.pbxproj is regenerated from it by xcodegen and is tracked in git.
STAMPED=(project.yml TVTV.xcodeproj/project.pbxproj)

PART="patch"
DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        major|minor|patch) PART="$arg" ;;
        --dry-run)         DRY_RUN=1 ;;
        -h|--help) sed -n '2,29p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "usage: release.sh [major|minor|patch] [--dry-run]" >&2; exit 2 ;;
    esac
done

die() { echo "error: $*" >&2; exit 1; }

# --- Preconditions --------------------------------------------------------
# Everything here is checked BEFORE the test suite and a full release build,
# because each of these failures costs minutes to discover the slow way.

[ -z "$(git status --porcelain)" ] \
    || die "working tree has uncommitted changes — commit or stash first."
git remote get-url origin >/dev/null 2>&1 \
    || die "no 'origin' remote (expected git@github.com:<owner>/tvtv.git)."
gh auth status >/dev/null 2>&1 \
    || die "gh is not authenticated (run: gh auth login)."
command -v xcodegen >/dev/null 2>&1 \
    || die "xcodegen not found (brew install xcodegen) — needed to stamp the version."

# A release MUST be Developer ID signed: an ad-hoc build cannot be notarized,
# and Gatekeeper rejects it on every Mac but this one.
# shellcheck source=scripts/signing.sh
source "$REPO_ROOT/scripts/signing.sh"
tvtv_report_identity
if [ "$TVTV_SIGN_KIND" = "adhoc" ]; then
    echo "  create a certificate: Xcode > Settings > Accounts > <team> >" >&2
    echo "  Manage Certificates > + > Developer ID Application" >&2
    echo "  (team Account Holder only)" >&2
    die "no Developer ID Application certificate found — cannot cut a release."
fi

# Fail fast on missing notary credentials. This is a live authenticated call, so
# it catches a revoked, expired or mistyped key now rather than after the build.
NOTARY_PROFILE="${TVTV_NOTARY_PROFILE:-tvtv-notary}"
echo "==> checking notary credentials (profile: $NOTARY_PROFILE)"
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "  create it with:" >&2
    echo "    xcrun notarytool store-credentials $NOTARY_PROFILE \\" >&2
    echo "        --key <AuthKey_XXXXXXXXXX.p8> --key-id <KEYID> --issuer <ISSUER-UUID>" >&2
    die "notarytool profile '$NOTARY_PROFILE' is missing or invalid."
fi
echo "    credentials OK"

# --- Compute the new version ---------------------------------------------
# Read the same field version.sh writes, so there is one source of truth
# (project.yml) even though the bump arithmetic is duplicated here — the tag
# collision has to be caught BEFORE anything is stamped.
read_field() {
    sed -nE "s/^[[:space:]]*$1:[[:space:]]*\"?([^\"]*)\"?[[:space:]]*$/\1/p" project.yml | head -1
}
CUR="$(read_field MARKETING_VERSION)"
[[ "$CUR" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "MARKETING_VERSION in project.yml is '$CUR', not X.Y.Z."
IFS=. read -r MA MI PA <<<"$CUR"
case "$PART" in
    major) MA=$((MA+1)); MI=0; PA=0 ;;
    minor) MI=$((MI+1)); PA=0 ;;
    patch) PA=$((PA+1)) ;;
esac
VER="$MA.$MI.$PA"
TAG="v$VER"

if [ "$DRY_RUN" -eq 0 ] && git rev-parse "$TAG" >/dev/null 2>&1; then
    die "tag $TAG already exists."
fi

if [ "$DRY_RUN" -eq 1 ]; then
    echo "==> DRY RUN: TVTV $VER ($PART bump from $CUR) — will not commit, tag or push"
else
    echo "==> Releasing TVTV $VER — $PART bump from $CUR"
fi

# --- Changelog (commits since the previous tag) --------------------------
PREV="$(git describe --tags --abbrev=0 2>/dev/null || true)"
if [ -n "$PREV" ]; then
    CHANGELOG="$(git log "$PREV..HEAD" --no-merges --pretty='- %s')"
else
    CHANGELOG="$(git log --no-merges --pretty='- %s')"
fi

# abort_release <reason> — bail out, undoing the version stamp so a failed
# release leaves the working tree exactly as it was found.
abort_release() {
    echo "error: $1 — reverting version stamp." >&2
    git checkout -- "${STAMPED[@]}" 2>/dev/null || true
    exit 1
}

# notarize <path> — submit to the notary service and wait for a verdict. On
# rejection, fetch and print the notary log: it names the offending binary and
# the reason, which is the only practical way to debug a rejection.
notarize() {
    local target="$1" out sid
    out="$(mktemp)"
    echo "==> notarizing $(basename "$target") — typically 1-5 minutes"
    xcrun notarytool submit "$target" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1 | tee "$out"
    if grep -q 'status: Accepted' "$out"; then
        echo "    notarization accepted"
        rm -f "$out"
        return 0
    fi
    echo "error: notarization failed for $(basename "$target")" >&2
    sid="$(grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' "$out" | head -1 || true)"
    if [ -n "$sid" ]; then
        echo "==> notary log for submission $sid:" >&2
        xcrun notarytool log "$sid" --keychain-profile "$NOTARY_PROFILE" >&2 || true
    fi
    rm -f "$out"
    return 1
}

# assert_release_signature <bundle> <label> — check the end state instead of
# assuming xcodebuild honoured the settings it was handed. Every condition here
# is one the notary service would otherwise reject the submission for, minutes
# later and with a less obvious message.
assert_release_signature() {
    local bundle="$1" label="$2" info
    [ -d "$bundle" ] || abort_release "$label is missing at $bundle"
    info="$(codesign -dvvv --entitlements - "$bundle" 2>&1)"

    grep -q 'Authority=Developer ID Application' <<<"$info" \
        || abort_release "$label is not Developer ID signed (ad-hoc build?)"
    # The flags line reads e.g. "CodeDirectory ... flags=0x10000(runtime)".
    grep -qE '^CodeDirectory .*\(.*runtime.*\)' <<<"$info" \
        || abort_release "$label is signed without the hardened runtime"
    grep -q 'Timestamp=' <<<"$info" \
        || abort_release "$label has no secure timestamp"
    # get-task-allow lets a debugger attach; the notary service rejects any
    # submission carrying it. Xcode injects it into Debug builds, so this is a
    # real hazard if the configuration is ever wrong, not a theoretical one.
    if grep -q 'com.apple.security.get-task-allow' <<<"$info"; then
        abort_release "$label carries the get-task-allow entitlement (Debug build?)"
    fi
    echo "    $label: Developer ID, hardened runtime, timestamped"
}

# --- Run tests ------------------------------------------------------------
# Debug configuration with Xcode's default signing, deliberately: the unit test
# bundle is injected into the app at runtime, which the hardened runtime only
# permits under a signature that allows it. Tests validate the code; the signed
# artifact that ships is built and verified separately below.
echo "==> running tests"
# PIPESTATUS, not the pipeline's own status: under `set -o pipefail` the filter
# grep returns 1 when it happens to drop every line, which would report a
# passing build as a failure. Only xcodebuild's exit code decides.
set +e
xcodebuild test \
    -project TVTV.xcodeproj -scheme TVTVApp -configuration Debug \
    -destination 'platform=macOS' -derivedDataPath "$DERIVED" 2>&1 \
    | grep -avE 'CoreSimulator|DVTCoreSimulator|Simulator device support disabled'
TEST_STATUS=${PIPESTATUS[0]}
set -e
[ "$TEST_STATUS" -eq 0 ] || die "tests failed — aborting release."

# --- Stamp the version ----------------------------------------------------
# version.sh writes project.yml and regenerates the Xcode project.
scripts/version.sh set "$VER" || die "version stamp failed."
BUILD_NO="$(read_field CURRENT_PROJECT_VERSION)"
echo "==> stamped version $VER (build $BUILD_NO)"

# --- Build + sign the .app ------------------------------------------------
scripts/build.sh --release || abort_release "build failed"

echo "==> verifying signatures"
assert_release_signature "$APP" "TVTV.app"
assert_release_signature "$APPEX" "TVTVQuickLook.appex"
# A test bundle inside the app is signed for development only and the notary
# service rejects the whole submission for it. build.sh now starts each build
# from an empty bundle, but check the artifact rather than trust the process.
if find "$APP" -name '*.xctest' -print -quit | grep -q .; then
    abort_release "the app bundle contains a test bundle (*.xctest) — a stale product?"
fi
echo "    no test bundles inside the app"
# --verify --deep is fine and correct: verification walks nested code, unlike
# --deep on *signing*, which re-signs it blind.
codesign --verify --deep --strict "$APP" \
    || abort_release "codesign --verify rejected the app bundle"
echo "    nested code verifies"

# --- Notarize the app, then staple the ticket -----------------------------
# notarytool cannot take a bare .app directory, so submit a throwaway zip. The
# ticket is issued against the app's cdhash, so once accepted we staple it onto
# the .app itself — and every container built FROM that stapled app (the release
# zip, the dmg) then carries the ticket with it. Stapling is what lets first
# launch succeed OFFLINE; without it macOS must reach Apple to confirm.
NOTARIZE_DIR="$(mktemp -d)"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$NOTARIZE_DIR/TVTV.zip"
if ! notarize "$NOTARIZE_DIR/TVTV.zip"; then
    rm -rf "$NOTARIZE_DIR"
    abort_release "notarization of the app failed"
fi
rm -rf "$NOTARIZE_DIR"

echo "==> stapling ticket to TVTV.app"
xcrun stapler staple "$APP"    || abort_release "stapling the app failed"
xcrun stapler validate "$APP"  || abort_release "stapled ticket does not validate"

# Assert the end state rather than assume it. Note that spctl passing is not
# proof of stapling — it can succeed via an online check — which is why
# `stapler validate` above is a separate assertion.
echo "==> verifying Gatekeeper acceptance"
if ! spctl -a -t exec "$APP" 2>/dev/null; then
    spctl -a -vv -t exec "$APP" 2>&1 | sed 's/^/    /' >&2
    abort_release "Gatekeeper still rejects the app after notarization"
fi
spctl -a -vv -t exec "$APP" 2>&1 | sed 's/^/    /'

# --- Package the zip ------------------------------------------------------
# ditto preserves the code signature and the stapled ticket.
ZIP="$REPO_ROOT/dist/TVTV-$TAG.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
echo "==> packaged $ZIP"

# --- Package the dmg ------------------------------------------------------
# Built from the already-stapled app, then notarized and stapled in its own
# right so the disk image ALSO passes Gatekeeper when opened directly.
DMG="$REPO_ROOT/dist/TVTV-$TAG.dmg"
rm -f "$DMG"
STAGE_PARENT="$(mktemp -d)"
STAGE="$STAGE_PARENT/TVTV"
mkdir -p "$STAGE"
# ditto, not cp -R: extended attributes and the signature survive verbatim, so
# the stapled ticket makes it into the image intact.
ditto "$APP" "$STAGE/TVTV.app" || { rm -rf "$STAGE_PARENT"; abort_release "staging the app for the dmg failed"; }
ln -s /Applications "$STAGE/Applications"   # classic drag-to-install layout
echo "==> building $DMG"
if ! hdiutil create -volname "TVTV $VER" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"; then
    rm -rf "$STAGE_PARENT"
    abort_release "hdiutil failed to build the disk image"
fi
rm -rf "$STAGE_PARENT"

# A disk image is data, not code, so it gets a plain timestamped signature — no
# hardened runtime, which only means something for an executable.
echo "==> signing $DMG"
codesign --sign "$TVTV_SIGN_IDENTITY" --force --timestamp "$DMG" \
    || abort_release "signing the disk image failed"

notarize "$DMG" || abort_release "notarization of the disk image failed"
echo "==> stapling ticket to the disk image"
xcrun stapler staple "$DMG"   || abort_release "stapling the disk image failed"
xcrun stapler validate "$DMG" || abort_release "dmg stapled ticket does not validate"
echo "==> packaged $DMG"

if [ "$DRY_RUN" -eq 1 ]; then
    echo
    echo "==> DRY RUN complete — signing, notarization and packaging all passed."
    echo "    artifacts: $ZIP"
    echo "               $DMG"
    echo "    reverting the version stamp; nothing committed, tagged or pushed."
    git checkout -- "${STAMPED[@]}"
    exit 0
fi

# --- Commit + tag ---------------------------------------------------------
git add "${STAMPED[@]}"
git commit -m "Release $TAG"
git tag -a "$TAG" -m "TVTV $VER"

# --- Push -----------------------------------------------------------------
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
git push origin "$BRANCH"
git push origin "$TAG"

# --- GitHub Release -------------------------------------------------------
NOTES="$(mktemp)"
{
    echo "## TVTV $VER"
    echo
    echo "### Changes"
    echo "$CHANGELOG"
    echo
    echo "### Install"
    echo "**Disk image** — download \`TVTV-$TAG.dmg\`, open it, and drag **TVTV** to Applications."
    echo
    echo "**Zip** — download \`TVTV-$TAG.zip\`, unzip, and move **TVTV.app** to \`/Applications\`."
    echo
    echo "Signed with Developer ID and notarized by Apple, with the ticket stapled, so it"
    echo "launches normally on first run — no Gatekeeper warning, no right-click → Open,"
    echo "and no \`xattr\` workaround. Requires macOS 14 or later (Apple silicon)."
} > "$NOTES"

gh release create "$TAG" "$DMG" "$ZIP" --title "TVTV $VER" --notes-file "$NOTES"
rm -f "$NOTES"

NWO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
echo "==> done: https://github.com/$NWO/releases/tag/$TAG"
