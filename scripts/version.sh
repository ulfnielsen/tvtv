#!/usr/bin/env bash
#
# version.sh — read or stamp the TVTV app version (semantic major.minor.patch).
#
# The version lives in project.yml as the single source of truth:
#   MARKETING_VERSION       -> CFBundleShortVersionString (e.g. 1.2.3)
#   CURRENT_PROJECT_VERSION -> CFBundleVersion (monotonic build number)
# TVTVApp/Info.plist references these via $(MARKETING_VERSION) substitution,
# so stamping here flows into every build after `xcodegen generate`.
#
# Usage:
#   scripts/version.sh                 # print current version + build number
#   scripts/version.sh set 1.2.3       # set an explicit X.Y.Z
#   scripts/version.sh bump patch      # 1.2.3 -> 1.2.4
#   scripts/version.sh bump minor      # 1.2.3 -> 1.3.0
#   scripts/version.sh bump major      # 1.2.3 -> 2.0.0
#
# Any set/bump also increments the build number (CURRENT_PROJECT_VERSION)
# by 1, unless you pass --keep-build. Pass --no-gen to skip regenerating the
# Xcode project (e.g. to stamp several things then regenerate once).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
YML="$REPO_ROOT/project.yml"

[ -f "$YML" ] || { echo "project.yml not found at $YML" >&2; exit 1; }

read_field() {  # read_field KEY -> value (unquoted)
    sed -nE "s/^[[:space:]]*$1:[[:space:]]*\"?([^\"]*)\"?[[:space:]]*$/\1/p" "$YML" | head -1
}
write_field() { # write_field KEY VALUE  (keeps quotes + indentation)
    # macOS/BSD sed in-place
    sed -i '' -E "s|^([[:space:]]*$1:[[:space:]]*).*$|\1\"$2\"|" "$YML"
}

CUR_MV="$(read_field MARKETING_VERSION)"
CUR_CPV="$(read_field CURRENT_PROJECT_VERSION)"
[ -n "$CUR_MV" ] || { echo "MARKETING_VERSION not found in project.yml" >&2; exit 1; }

# ---- no args: just print -------------------------------------------------
if [ "$#" -eq 0 ]; then
    echo "version:      $CUR_MV"
    echo "build number: ${CUR_CPV:-<unset>}"
    exit 0
fi

# ---- parse flags + command ----------------------------------------------
KEEP_BUILD=0
RUN_GEN=1
CMD=""
ARG=""
for a in "$@"; do
    case "$a" in
        --keep-build) KEEP_BUILD=1 ;;
        --no-gen)     RUN_GEN=0 ;;
        set|bump)     CMD="$a" ;;
        *)            ARG="$a" ;;
    esac
done

semver_ok() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

NEW_MV=""
case "$CMD" in
    set)
        semver_ok "$ARG" || { echo "set expects X.Y.Z (got: '$ARG')" >&2; exit 2; }
        NEW_MV="$ARG"
        ;;
    bump)
        semver_ok "$CUR_MV" || { echo "current version '$CUR_MV' is not X.Y.Z; use 'set' first" >&2; exit 2; }
        IFS=. read -r MA MI PA <<<"$CUR_MV"
        case "$ARG" in
            major) MA=$((MA+1)); MI=0; PA=0 ;;
            minor) MI=$((MI+1)); PA=0 ;;
            patch) PA=$((PA+1)) ;;
            *) echo "bump expects: major | minor | patch (got: '$ARG')" >&2; exit 2 ;;
        esac
        NEW_MV="$MA.$MI.$PA"
        ;;
    *)
        echo "usage: version.sh [set X.Y.Z | bump major|minor|patch] [--keep-build] [--no-gen]" >&2
        exit 2
        ;;
esac

write_field MARKETING_VERSION "$NEW_MV"

NEW_CPV="$CUR_CPV"
if [ "$KEEP_BUILD" -eq 0 ]; then
    if [[ "$CUR_CPV" =~ ^[0-9]+$ ]]; then
        NEW_CPV=$((CUR_CPV+1))
        write_field CURRENT_PROJECT_VERSION "$NEW_CPV"
    else
        echo "note: CURRENT_PROJECT_VERSION ('$CUR_CPV') is not an integer; left unchanged" >&2
    fi
fi

echo "version:      $CUR_MV -> $NEW_MV"
echo "build number: ${CUR_CPV:-<unset>} -> ${NEW_CPV:-<unset>}"

if [ "$RUN_GEN" -eq 1 ]; then
    if command -v xcodegen >/dev/null 2>&1; then
        echo "==> Regenerating Xcode project (xcodegen)…"
        xcodegen generate >/dev/null
        echo "    done. Build with scripts/build.sh to stamp the bundle."
    else
        echo "⚠️  xcodegen not found — project.yml updated, but run 'xcodegen generate' to apply." >&2
    fi
fi
