#!/bin/bash
#
# Cut a Moo release: build, sign, notarize, staple, package, and publish the
# Sparkle appcast so installed copies can update themselves.
#
# Usage:
#   scripts/release.sh                    # version from the project file
#   scripts/release.sh --notes notes.md   # release notes shown in the updater
#   scripts/release.sh --dry-run          # build and package, publish nothing
#
# Requires, one time each (see docs/DEVELOPING.md):
#   - a Developer ID Application certificate in the login keychain
#   - the "moo-notary" notarytool profile        (xcrun notarytool store-credentials)
#   - a Sparkle EdDSA key in the login keychain  (Sparkle's generate_keys)
#   - a logged-in wrangler                       (npx wrangler@latest login)
#
# The Sparkle private key never leaves the login keychain; generate_appcast
# reads it there and writes only signatures into the feed.

set -euo pipefail

readonly IDENTITY="Developer ID Application: Ventzislav Petkov (8J9W3ZG4ZN)"
readonly NOTARY_PROFILE="moo-notary"
readonly BUCKET="moo-mac-terminal-autoupdate"
readonly FEED_HOST="https://moo.vpetkov.net"

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

# Past archives live outside the repo: generate_appcast needs the previous
# releases on hand to keep their entries in the feed, and they are large.
release_dir="${MOO_RELEASE_DIR:-$HOME/moo-releases}"
derived_data="${MOO_DERIVED_DATA:-$repo_root/build/DerivedDataRelease}"
notes_file=""
dry_run=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --notes) notes_file="$2"; shift 2 ;;
        --dry-run) dry_run=1; shift ;;
        -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

say() { printf '\n==> %s\n' "$*"; }

# --- Preflight ---------------------------------------------------------------
# Every check here fails a release hours earlier than it otherwise would.

say "Checking prerequisites"

security find-identity -v -p codesigning | grep -qF "$IDENTITY" \
    || { echo "missing signing identity: $IDENTITY" >&2; exit 1; }

# Both tools are called by their real paths rather than through xcrun. xcrun
# refuses to launch anything until the Xcode license has been accepted, and
# stapling is the very last step of a long release -- through xcrun, a machine
# that has never run `sudo xcodebuild -license accept` notarizes successfully
# and then fails with an unstapled disk image.
developer_dir=$(xcode-select -p)
notarytool="$developer_dir/usr/bin/notarytool"
stapler="$developer_dir/usr/bin/stapler"
for tool in "$notarytool" "$stapler"; do
    [[ -x "$tool" ]] || { echo "not found: $tool" >&2; exit 1; }
done

"$notarytool" history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || { echo "notarytool profile '$NOTARY_PROFILE' is missing or invalid" >&2; exit 1; }

sparkle_bin="$derived_data/SourcePackages/artifacts/sparkle/Sparkle/bin"
if [[ ! -x "$sparkle_bin/generate_appcast" ]]; then
    say "Resolving package dependencies (Sparkle tools not unpacked yet)"
    xcodebuild -resolvePackageDependencies -project Moo.xcodeproj -scheme Moo \
        -skipPackagePluginValidation -derivedDataPath "$derived_data" >/dev/null
fi
[[ -x "$sparkle_bin/generate_appcast" ]] \
    || { echo "generate_appcast not found under $sparkle_bin" >&2; exit 1; }

# CI=1 and the metrics opt-out keep wrangler from stopping on its first-run
# prompts, which block forever in a non-interactive release.
wrangler() { CI=1 WRANGLER_SEND_METRICS=false npx --yes wrangler@latest "$@"; }
if [[ $dry_run -eq 0 ]]; then
    wrangler whoami >/dev/null 2>&1 \
        || { echo "wrangler is not logged in -- run: npx wrangler@latest login" >&2; exit 1; }
fi

# --- Build -------------------------------------------------------------------

say "Building Release (universal)"
xcodebuild build -project Moo.xcodeproj -scheme Moo \
    -configuration Release -destination "generic/platform=macOS" \
    -skipPackagePluginValidation -derivedDataPath "$derived_data" \
    | tail -5

app="$derived_data/Build/Products/Release/Moo.app"
[[ -d "$app" ]] || { echo "build produced no app at $app" >&2; exit 1; }

version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist")
build_number=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$app/Contents/Info.plist")
say "Version $version (build $build_number), architectures: $(lipo -archs "$app/Contents/MacOS/Moo")"

# --- Sign --------------------------------------------------------------------
# Inside-out: nested code first, the bundle last. Signing the outer bundle
# first invalidates the moment anything inside it changes.

say "Signing"

# Standalone Mach-O executables, not just bundles. Sparkle ships
# Versions/B/Autoupdate, a bare executable that --deep --strict happily
# ignores and notarization rejects.
find "$app/Contents/Frameworks" -type f -perm +111 | while read -r f; do
    file "$f" | grep -q "Mach-O" || continue
    codesign --force --sign "$IDENTITY" -o runtime --timestamp "$f"
done

find "$app/Contents/Frameworks" \( -name "*.xpc" -o -name "*.app" \) | sort -r | while read -r p; do
    codesign --force --sign "$IDENTITY" -o runtime --timestamp "$p"
done

for v in "$app/Contents/Frameworks/"*.framework/Versions/[A-Z]; do
    [[ -d "$v" ]] && codesign --force --sign "$IDENTITY" -o runtime --timestamp "$v"
done

codesign --force --sign "$IDENTITY" -o runtime --timestamp "$app"

unsigned=$(find "$app/Contents/Frameworks" -type f -perm +111 | while read -r f; do
    file "$f" | grep -q Mach-O || continue
    codesign -dvv "$f" 2>&1 | grep -q "Authority=Developer ID Application" || echo "$f"
done)
[[ -z "$unsigned" ]] || { echo "ad-hoc signed binaries remain:" >&2; echo "$unsigned" >&2; exit 1; }

codesign --verify --deep --strict "$app"

# get-task-allow is a debugging entitlement and notarization rejects any
# submission carrying it. A Developer ID build ships with no entitlements.
if codesign -d --entitlements - --xml "$app" 2>/dev/null | grep -q "get-task-allow"; then
    echo "app carries get-task-allow -- notarization would reject it" >&2
    exit 1
fi

# --- Package -----------------------------------------------------------------

mkdir -p "$release_dir"
dmg="$release_dir/Moo-$version.dmg"

say "Building $dmg"
rm -f "$dmg"
scripts/create-dmg.sh "$app" "$dmg" "Moo"

if [[ -n "$notes_file" ]]; then
    # generate_appcast attaches notes whose filename matches the archive.
    cp "$notes_file" "$release_dir/Moo-$version.${notes_file##*.}"
fi

# --- Notarize ----------------------------------------------------------------

if [[ $dry_run -eq 1 ]]; then
    say "Dry run -- skipping notarization and publish"
    echo "built: $dmg"
    exit 0
fi

say "Notarizing (a few minutes at Apple)"
"$notarytool" submit "$dmg" --keychain-profile "$NOTARY_PROFILE" --wait
"$stapler" staple "$dmg"

# The only check that reflects what a recipient sees. codesign --verify
# passing says nothing about Gatekeeper.
spctl --assess --type open --context context:primary-signature -vv "$dmg"

# --- Appcast -----------------------------------------------------------------
# Pull the published feed first so earlier releases keep their entries even on
# a machine that has never cut one.

say "Generating appcast"
if curl -fsS "$FEED_HOST/appcast.xml" -o "$release_dir/appcast.xml.remote" 2>/dev/null; then
    mv "$release_dir/appcast.xml.remote" "$release_dir/appcast.xml"
else
    rm -f "$release_dir/appcast.xml.remote"
fi

"$sparkle_bin/generate_appcast" \
    --download-url-prefix "$FEED_HOST/" \
    --maximum-versions 5 \
    "$release_dir"

# --- Publish -----------------------------------------------------------------

say "Publishing to R2 ($BUCKET)"
wrangler r2 object put "$BUCKET/$(basename "$dmg")" \
    --file "$dmg" --content-type application/x-apple-diskimage --remote
# The feed goes last: nothing should advertise a build that is not downloadable.
wrangler r2 object put "$BUCKET/appcast.xml" \
    --file "$release_dir/appcast.xml" --content-type application/xml \
    --cache-control "max-age=300" --remote

say "Published"
echo "  download: $FEED_HOST/$(basename "$dmg")"
echo "  appcast:  $FEED_HOST/appcast.xml"
echo "  local:    $dmg"
