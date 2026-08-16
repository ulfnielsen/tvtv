#!/usr/bin/env bash
#
# signing.sh — shared code-signing configuration.
#
# Sourced (not executed) by scripts/build.sh and scripts/release.sh so a single
# build resolves ONE identity and every nested piece — TVTV.app and the
# TVTVQuickLook.appex embedded inside it — is signed the same way.
#
# Identity resolution, in priority order:
#   1. $TVTV_IDENTITY           — explicit override (any `codesign -s` argument:
#                                 a SHA-1 hash, a full certificate name, or "-")
#   2. Developer ID Application — auto-detected from the keychain (releases)
#   3. "-"                      — ad-hoc fallback so a Mac with no certificate
#                                 can still build and run TVTV locally
#
# Ad-hoc builds run on THIS Mac only: they cannot be notarized, and Gatekeeper
# rejects them on every other machine. release.sh therefore REQUIRES a
# Developer ID identity and refuses to cut a release from an ad-hoc build.
#
# Hardened runtime is deliberately NOT set here: project.yml already sets
# ENABLE_HARDENED_RUNTIME on both targets, so every build — ad-hoc included —
# exercises it. Notarization requires the hardened runtime, so a build that
# breaks under it must fail on the dev loop rather than at release time.
#
# Signing stays inside-out and stays Xcode's job: xcodebuild signs
# TVTVQuickLook.appex with its own entitlements first, embeds it, then seals it
# by reference in the app's signature. We only choose the identity. Nothing here
# re-signs a finished bundle, and nothing uses --deep — Apple deprecates it for
# signing, and it re-signs nested code blind, discarding the entitlements the
# nested code was built with.
#
# Sets:
#   TVTV_SIGN_IDENTITY       resolved `codesign -s` argument
#   TVTV_SIGN_IDENTITY_NAME  human-readable description (for logging)
#   TVTV_SIGN_KIND           developer-id | adhoc | override
#   TVTV_SIGN_TEAM           team ID parsed from the certificate ("" if unknown)
# Defines:
#   tvtv_report_identity
#   tvtv_sign_settings <Debug|Release>
#       fills TVTV_SIGN_SETTINGS — the build-setting assignments for xcodebuild

TVTV_SIGN_TEAM=""

if [ -n "${TVTV_IDENTITY:-}" ]; then
    TVTV_SIGN_IDENTITY="$TVTV_IDENTITY"
    TVTV_SIGN_IDENTITY_NAME="$TVTV_IDENTITY (TVTV_IDENTITY override)"
    if [ "$TVTV_IDENTITY" = "-" ]; then
        TVTV_SIGN_KIND="adhoc"
    else
        TVTV_SIGN_KIND="override"
    fi
else
    # `find-identity -v -p codesigning` lists only identities whose private key
    # is actually present, so a hit here means we can genuinely sign with it.
    # Match on the 40-char SHA-1 rather than the name: signing by hash stays
    # unambiguous if the keychain ever holds more than one Developer ID cert.
    _tvtv_di="$(security find-identity -v -p codesigning 2>/dev/null \
        | grep 'Developer ID Application:' | head -1 || true)"
    if [ -n "$_tvtv_di" ]; then
        TVTV_SIGN_IDENTITY="$(printf '%s' "$_tvtv_di" | grep -oE '[0-9A-F]{40}')"
        TVTV_SIGN_IDENTITY_NAME="$(printf '%s' "$_tvtv_di" | sed -nE 's/.*"(.*)".*/\1/p')"
        TVTV_SIGN_KIND="developer-id"
        # "Developer ID Application: ULF HOLM NIELSEN (9LTFHV87LB)" -> 9LTFHV87LB
        # Parsed rather than hardcoded, so the repo carries no team ID and a
        # different signer's certificate works unchanged.
        TVTV_SIGN_TEAM="$(printf '%s' "$TVTV_SIGN_IDENTITY_NAME" | sed -nE 's/.*\(([A-Z0-9]+)\)$/\1/p')"
    else
        TVTV_SIGN_IDENTITY="-"
        TVTV_SIGN_IDENTITY_NAME="ad-hoc (no Developer ID certificate found)"
        TVTV_SIGN_KIND="adhoc"
    fi
    unset _tvtv_di
fi

# tvtv_sign_settings <Debug|Release> — fill TVTV_SIGN_SETTINGS with the build
# settings xcodebuild needs for this identity and configuration.
#
# Manual signing with an explicit identity: a Developer ID Mac app needs no
# provisioning profile, so automatic signing has nothing to resolve and only
# adds a dependency on Xcode's account state.
tvtv_sign_settings() {
    local config="${1:-Release}"

    TVTV_SIGN_SETTINGS=(
        "CODE_SIGN_STYLE=Manual"
        "CODE_SIGN_IDENTITY=$TVTV_SIGN_IDENTITY"
    )

    if [ "$TVTV_SIGN_KIND" != "adhoc" ]; then
        # A secure timestamp is what keeps a shipped signature valid after the
        # signing certificate expires. It means nothing for an ad-hoc signature
        # — Apple's timestamp server has nothing to bind one to, and codesign
        # errors on the combination — so it is requested only for real
        # identities.
        TVTV_SIGN_SETTINGS+=("OTHER_CODE_SIGN_FLAGS=--timestamp")
    fi

    if [ -n "$TVTV_SIGN_TEAM" ]; then
        TVTV_SIGN_SETTINGS+=("DEVELOPMENT_TEAM=$TVTV_SIGN_TEAM")
    fi

    if [ "$config" = "Release" ]; then
        # TVTV declares no entitlements — it is unsandboxed and uses no
        # capabilities — but with no .entitlements file Xcode still injects its
        # "base entitlements", which on macOS means com.apple.security.
        # get-task-allow (the one that lets a debugger attach). The notary
        # service REJECTS any submission carrying it, so a Release build must
        # opt out. Verified: without this, `codesign -d --entitlements -` on a
        # Release build prints get-task-allow => true.
        #
        # Debug keeps the injection, so attaching a debugger to a local
        # `build.sh --debug` build still works.
        TVTV_SIGN_SETTINGS+=("CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO")
    fi
}

tvtv_report_identity() {
    echo "==> signing identity: $TVTV_SIGN_IDENTITY_NAME [$TVTV_SIGN_KIND]"
    if [ "$TVTV_SIGN_KIND" = "adhoc" ]; then
        echo "    NOTE: ad-hoc build — runs on this Mac only, cannot be notarized."
    fi
}
