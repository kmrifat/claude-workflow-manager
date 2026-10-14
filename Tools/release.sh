#!/bin/bash
#
#  release.sh — build Pitwall for distribution outside the Mac App Store.
#
#  This is the channel VS Code, iTerm2, Ghostty, Zed and Docker all use, and it
#  is not a workaround: Developer ID signing plus notarization is a first-class
#  Apple distribution path. Same $99 account, no review queue, and — the reason
#  it is the only option here — **no App Sandbox**.
#
#  Pitwall cannot be sandboxed. It spawns `gh`, `git`, `claude` and a login
#  shell in the user's own repositories, and a sandboxed child inherits the
#  parent's container: the terminal would open on a shell that cannot write to
#  your checkout, cannot see /opt/homebrew, and cannot run `claude` from an nvm
#  path. Removing the terminal would not change that; the GitHub and Claude
#  integrations are built the same way. The Mac App Store is therefore closed to
#  this app by construction, which is a decision the project already made —
#  `ENABLE_APP_SANDBOX = NO`, documented in CLAUDE.md.
#
#  What notarization *does* require is the Hardened Runtime, which is already on
#  for both configurations. Spawning child processes is allowed under it; the
#  restrictions that bite (JIT, unsigned libraries, DYLD injection) are ones this
#  app never relied on.
#
#  Prerequisites, both one-time and both yours to do — this script never handles
#  a credential:
#
#    1. A "Developer ID Application" certificate in the login keychain.
#       Check with:  security find-identity -v -p codesigning
#       Create it in Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates.
#
#    2. A notarytool keychain profile holding an app-specific password:
#         xcrun notarytool store-credentials "ClaudeWM" \
#           --apple-id "you@example.com" --team-id R3YZ9PF9N6
#       It prompts for the password; generate one at appleid.apple.com.
#
#  Usage:
#    Tools/release.sh                 build, sign, notarize, staple, package
#    SKIP_NOTARIZE=1 Tools/release.sh sign and package only (no Apple round-trip)
#    NOTARY_PROFILE=other Tools/release.sh    use a different keychain profile
#    VERSION=1.2.0 BUILD_NUMBER=42 Tools/release.sh   stamp the version
#
#  SIGNING picks how the app is signed:
#    automatic  (default) Xcode's automatic signing — needs the Apple account
#               signed in to Xcode, so it is for a Mac, not for CI.
#    manual     the "Developer ID Application" certificate in the keychain, by
#               name — no account needed. What .github/workflows/release.yml
#               uses, after importing the certificate into a temporary keychain.
#    adhoc      no certificate at all, and no notarization. The app runs, but
#               macOS refuses its first launch until the user allows it in
#               Privacy & Security. For a project with no Developer ID yet.
#
#  NOTARY_KEYCHAIN names the keychain holding the notarytool profile, when it
#  is not the login keychain (CI).
#

set -euo pipefail

cd "$(dirname "$0")/.."

SCHEME="workflow-manager"
APP_NAME="Pitwall"
TEAM_ID="${TEAM_ID:-R3YZ9PF9N6}"
NOTARY_PROFILE="${NOTARY_PROFILE:-ClaudeWM}"
SIGNING="${SIGNING:-automatic}"
VERSION="${VERSION:-}"
BUILD_NUMBER="${BUILD_NUMBER:-}"

case "$SIGNING" in
    automatic|manual) ;;
    adhoc) SKIP_NOTARIZE=1 ;;
    *) printf 'SIGNING must be automatic, manual or adhoc, not "%s".\n' "$SIGNING" >&2; exit 64 ;;
esac

# notarytool reads a profile from the login keychain unless told otherwise.
NOTARY_AUTH=(--keychain-profile "$NOTARY_PROFILE")
[ -n "${NOTARY_KEYCHAIN:-}" ] && NOTARY_AUTH+=(--keychain "$NOTARY_KEYCHAIN")

# Everything lands beside the app's own DerivedData, on whichever disk the
# repository lives on. `.build/` belongs to SPM and must stay untouched.
OUT="$PWD/.xcbuild/release"
ARCHIVE="$OUT/$APP_NAME.xcarchive"
EXPORTED="$OUT/export"
APP="$EXPORTED/$APP_NAME.app"
ZIP="$OUT/$APP_NAME.zip"
DMG="$OUT/$APP_NAME${VERSION:+-$VERSION}.dmg"

say() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }
die() { printf '\n\033[1;31m✗ %s\033[0m\n' "$1" >&2; exit 1; }

# --- Preflight -------------------------------------------------------------
# Failing here costs seconds; failing after a ten-minute archive does not.

if [ "$SIGNING" != adhoc ] && ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
    die "No 'Developer ID Application' certificate in the keychain.
   Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ + ▸ Developer ID Application.
   Then re-run this script."
fi

if [ -z "${SKIP_NOTARIZE:-}" ]; then
    if ! xcrun notarytool history "${NOTARY_AUTH[@]}" >/dev/null 2>&1; then
        die "No notarytool keychain profile named '$NOTARY_PROFILE'.
   Create one (it will prompt for an app-specific password):
     xcrun notarytool store-credentials \"$NOTARY_PROFILE\" \\
       --apple-id \"you@example.com\" --team-id \"$TEAM_ID\"
   Or set SKIP_NOTARIZE=1 to build a signed but un-notarized app."
    fi
fi

rm -rf "$OUT"
mkdir -p "$OUT"

# --- Archive ---------------------------------------------------------------

say "Archiving $APP_NAME${VERSION:+ $VERSION}"

# How the archive is signed, by mode. Manual names the certificate instead of
# asking Xcode to find one through a signed-in account, which CI does not have;
# a Developer ID app with no restricted entitlements needs no profile.
case "$SIGNING" in
    automatic) SIGN_ARGS=(CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="$TEAM_ID"
                          "CODE_SIGN_IDENTITY=Developer ID Application") ;;
    manual)    SIGN_ARGS=(CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="$TEAM_ID"
                          "CODE_SIGN_IDENTITY=Developer ID Application"
                          "OTHER_CODE_SIGN_FLAGS=--timestamp") ;;
    adhoc)     SIGN_ARGS=(CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
                          "CODE_SIGN_IDENTITY=-") ;;
esac

VERSION_ARGS=()
[ -n "$VERSION" ] && VERSION_ARGS+=(MARKETING_VERSION="$VERSION")
[ -n "$BUILD_NUMBER" ] && VERSION_ARGS+=(CURRENT_PROJECT_VERSION="$BUILD_NUMBER")

xcodebuild archive \
    -project workflow-manager.xcodeproj \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE" \
    -derivedDataPath "$PWD/.xcbuild" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    "${SIGN_ARGS[@]}" \
    ${VERSION_ARGS[@]+"${VERSION_ARGS[@]}"} \
    | grep -E '^(\*\*|error:|warning: .*deprecat)' || true

[ -d "$ARCHIVE" ] || die "Archive failed."

# --- Export ----------------------------------------------------------------
#
# `developer-id` is the method that produces a Gatekeeper-acceptable app for
# distribution off the store. `app-store-connect` is the one this app can never
# use, for the sandbox reason at the top of this file.
#
# The archive above overrides CODE_SIGN_IDENTITY on the command line because the
# project pins it to "Apple Development" for macOS. By its plain name: xcodebuild
# splits an argument at its first "=", so the SDK-conditional spelling
# (`CODE_SIGN_IDENTITY[sdk=macosx*]=…`) arrives as a setting called
# `CODE_SIGN_IDENTITY[sdk` — and a command-line setting overrides the
# conditional ones anyway. That is right for everyday
# builds and wrong here: an Apple Development certificate signs for machines
# registered to the account and can never be notarized.

if [ "$SIGNING" = adhoc ]; then
    # Nothing to re-sign for: the archive's ad-hoc signature is the signature.
    say "Taking the app from the archive (ad-hoc, no export)"
    mkdir -p "$EXPORTED"
    ditto "$ARCHIVE/Products/Applications/$APP_NAME.app" "$APP"
else
    if [ "$SIGNING" = manual ]; then
        EXPORT_SIGNING='<key>signingStyle</key><string>manual</string>
    <key>signingCertificate</key><string>Developer ID Application</string>'
    else
        EXPORT_SIGNING='<key>signingStyle</key><string>automatic</string>'
    fi
    cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>teamID</key><string>$TEAM_ID</string>
    $EXPORT_SIGNING
    <key>destination</key><string>export</string>
</dict>
</plist>
PLIST

    say "Exporting with Developer ID"
    xcodebuild -exportArchive \
        -archivePath "$ARCHIVE" \
        -exportPath "$EXPORTED" \
        -exportOptionsPlist "$OUT/ExportOptions.plist" \
        | grep -E '^(\*\*|error:)' || true
fi

[ -d "$APP" ] || die "Export failed — no app at $APP"

# Universal, said explicitly above and checked here: Intel Macs from 2018 on are
# supported (the deployment target is macOS 14 for them), and an arm64-only
# build fails on one with nothing more helpful than "not supported on this Mac".
say "Checking it runs on Intel and Apple Silicon"
ARCHS_BUILT=$(lipo -archs "$APP/Contents/MacOS/$APP_NAME")
[[ "$ARCHS_BUILT" == *x86_64* && "$ARCHS_BUILT" == *arm64* ]] \
    || die "Expected a universal app, got: $ARCHS_BUILT"

say "Verifying the signature"
codesign --verify --deep --strict --verbose=2 "$APP"
# The Hardened Runtime flag is what notarization checks for; catch a missing one
# now rather than in Apple's rejection log.
if [ "$SIGNING" != adhoc ]; then
    codesign -d --verbose=2 "$APP" 2>&1 | grep -q "flags=.*runtime" \
        || die "The app is signed without the Hardened Runtime. Notarization will reject it."
fi

# --- Notarize --------------------------------------------------------------
#
# The app is notarized as a zip and stapled *before* the disk image is built:
# a DMG is read-only, so an app stapled only after packaging is not stapled at
# all, and every first launch then needs a working network connection.

if [ -z "${SKIP_NOTARIZE:-}" ]; then
    say "Submitting the app to Apple"
    ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" "${NOTARY_AUTH[@]}" --wait

    say "Stapling the ticket to the app"
    xcrun stapler staple "$APP"
    rm -f "$ZIP"
else
    say "Skipping notarization (SKIP_NOTARIZE is set)"
fi

# --- Package ---------------------------------------------------------------

say "Building the disk image"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGE" \
    -ov -format UDZO \
    "$DMG" >/dev/null
rm -rf "$STAGE"

if [ -z "${SKIP_NOTARIZE:-}" ]; then
    say "Notarizing the disk image"
    xcrun notarytool submit "$DMG" "${NOTARY_AUTH[@]}" --wait
    xcrun stapler staple "$DMG"

    say "Checking it the way Gatekeeper will"
    # `spctl -a` on a .app is the real test; on the DMG it checks the image.
    spctl --assess --type execute --verbose=2 "$APP"
    xcrun stapler validate "$DMG"
fi

say "Done"
printf '   %s\n' "$DMG"
printf '   %s\n' "$APP"
