#!/usr/bin/env fish
#
# release.fish [major|minor|patch]   (default: patch)
#
# Cuts a TVTV release:
#   1. checks preconditions (clean tree, origin remote, gh auth)
#   2. runs the test suite (package + app)
#   3. bumps MARKETING_VERSION in project.yml (or releases the current version
#      as-is on the very first release, when no tag exists yet)
#   4. regenerates the Xcode project and builds a signed dist/TVTV.app
#   5. zips it (ditto, preserving the code signature)
#   6. commits "Release vX.Y.Z", tags vX.Y.Z
#   7. pushes branch + tag, and creates a GitHub Release with the zip attached
#
# Prereqs: a git `origin` remote on GitHub, `gh` authenticated, `xcodegen` on
# PATH, a clean working tree. Builds are ad-hoc signed (not notarized).

set -l part $argv[1]
test -z "$part"; and set part patch
if not contains -- $part major minor patch
    echo "usage: release.fish [major|minor|patch]" >&2
    exit 1
end

# Repo root = this script's parent's parent (script lives in <root>/build/).
set -l repo_root (path resolve (status filename) | path dirname | path dirname)
cd $repo_root; or exit 1

if test -d /Applications/Xcode.app/Contents/Developer
    set -gx DEVELOPER_DIR /Applications/Xcode.app/Contents/Developer
end

# --- Preconditions --------------------------------------------------------
if test (count (git status --porcelain)) -gt 0
    echo "error: working tree has uncommitted changes — commit or stash first." >&2
    exit 1
end
if not git remote get-url origin >/dev/null 2>&1
    echo "error: no 'origin' remote. Create the GitHub repo first:" >&2
    echo "  gh repo create ulfnielsen/tvtv --source=. --remote=origin --push --private" >&2
    exit 1
end
if not gh auth status >/dev/null 2>&1
    echo "error: gh is not authenticated (run: gh auth login)." >&2
    exit 1
end
if not type -q xcodegen
    echo "error: xcodegen not found on PATH (brew install xcodegen)." >&2
    exit 1
end

# --- Compute the new version ---------------------------------------------
# Version lives in project.yml as `MARKETING_VERSION: "X.Y.Z"`.
set -l cur (grep -E 'MARKETING_VERSION:' project.yml | head -1 | string match -rg '"([0-9]+\.[0-9]+\.[0-9]+)"')
if test -z "$cur"
    echo "error: could not read MARKETING_VERSION from project.yml." >&2
    exit 1
end
set -l have_tag 0
git describe --tags --abbrev=0 >/dev/null 2>&1; and set have_tag 1

set -l p (string split . $cur)
set -l maj $p[1]; set -l min $p[2]; set -l pat $p[3]
if test $have_tag -eq 1
    # Normal release: bump from the current version.
    switch $part
        case major; set maj (math $maj + 1); set min 0; set pat 0
        case minor; set min (math $min + 1); set pat 0
        case patch; set pat (math $pat + 1)
    end
else
    echo "==> first release: publishing the current version $cur as-is (no bump)."
end
set -l ver "$maj.$min.$pat"
set -l tag "v$ver"

if git rev-parse "$tag" >/dev/null 2>&1
    echo "error: tag $tag already exists." >&2
    exit 1
end

echo "==> Releasing TVTV $ver — $part from $cur"

# --- Changelog (commits since the previous tag) --------------------------
set -l prev (git describe --tags --abbrev=0 2>/dev/null)
set -l changelog
if test -n "$prev"
    set changelog (git log "$prev..HEAD" --no-merges --pretty="- %s")
else
    set changelog (git log --no-merges --pretty="- %s")
end

# --- Run tests ------------------------------------------------------------
echo "==> swift test (TVTVCore)"
swift test --package-path Packages/TVTVCore; or begin
    echo "error: package tests failed — aborting release." >&2
    exit 1
end
echo "==> xcodebuild test (app)"
xcodebuild test -project TVTV.xcodeproj -scheme TVTVApp -destination 'platform=macOS' -quiet; or begin
    echo "error: app tests failed — aborting release." >&2
    exit 1
end

# --- Stamp the version + build -------------------------------------------
if test "$ver" != "$cur"
    sed -i '' "s/MARKETING_VERSION: \"$cur\"/MARKETING_VERSION: \"$ver\"/" project.yml
end
echo "==> xcodegen generate"
xcodegen generate; or begin
    echo "error: xcodegen failed — reverting." >&2
    git checkout -- project.yml
    exit 1
end
echo "==> scripts/build.sh --release"
if not ./scripts/build.sh --release
    echo "error: build failed — reverting version stamp." >&2
    git checkout -- project.yml
    exit 1
end

# --- Package (ditto preserves the code signature) -------------------------
set -l zip $repo_root/dist/TVTV-$tag.zip
rm -f $zip
ditto -c -k --sequesterRsrc --keepParent $repo_root/dist/TVTV.app $zip
echo "==> packaged $zip"

# --- Commit + tag ---------------------------------------------------------
git add project.yml TVTV.xcodeproj
# Only commit if the version stamp actually changed something (on the very
# first release the version is already current, so there may be nothing to
# commit — just tag the current HEAD in that case).
if test (count (git status --porcelain project.yml TVTV.xcodeproj)) -gt 0
    git commit -m "Release $tag"
end
git tag -a "$tag" -m "TVTV $ver"

# --- Push -----------------------------------------------------------------
set -l branch (git rev-parse --abbrev-ref HEAD)
git push origin $branch
git push origin "$tag"

# --- GitHub Release -------------------------------------------------------
set -l notes_file (mktemp)
begin
    echo "## TVTV $ver"
    echo
    echo "### Changes"
    for line in $changelog
        echo $line
    end
    echo
    echo "### Install"
    echo "Download \`TVTV-$tag.zip\`, unzip, and move **TVTV.app** to \`/Applications\`."
    echo
    echo "This build is ad-hoc signed (not notarized), so on first launch macOS may"
    echo "block it. Right-click the app → **Open** → **Open**, or clear quarantine:"
    echo
    echo '```sh'
    echo "xattr -dr com.apple.quarantine /Applications/TVTV.app"
    echo '```'
end > $notes_file

gh release create "$tag" $zip --title "TVTV $ver" --notes-file $notes_file
rm -f $notes_file

set -l nwo (gh repo view --json nameWithOwner -q .nameWithOwner)
echo "==> done: https://github.com/$nwo/releases/tag/$tag"
