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
#   - a logged-in gh, when origin is a GitHub repository  (gh auth login)
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

identities=$(security find-identity -v -p codesigning)
[[ "$identities" == *"$IDENTITY"* ]] \
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

# The GitHub release tags the commit the app is built from, so a real release
# needs a clean checkout whose HEAD is already on origin. A repository with no
# GitHub remote skips the GitHub release rather than failing.
build_commit=$(git rev-parse HEAD)
github_repo=""
if [[ $dry_run -eq 0 ]]; then
    tracked_changes=$(git status --porcelain --untracked-files=no)
    [[ -z "$tracked_changes" ]] \
        || { echo "uncommitted changes -- commit or stash them so the release matches its tag" >&2; exit 1; }
    origin_url=$(git remote get-url origin 2>/dev/null || true)
    if [[ "$origin_url" == *github.com* ]]; then
        gh auth status >/dev/null 2>&1 \
            || { echo "gh is not logged in -- run: gh auth login" >&2; exit 1; }
        github_repo=$(gh repo view "$origin_url" --json nameWithOwner --jq .nameWithOwner)
        git fetch --quiet origin
        pushed=$(git branch -r --contains "$build_commit")
        [[ -n "$pushed" ]] \
            || { echo "$build_commit is not on origin -- push it before releasing" >&2; exit 1; }
    fi
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

# Checked before notarizing, not after publishing: a version already released
# on GitHub means CFBundleShortVersionString was not bumped.
if [[ -n "$github_repo" ]]; then
    existing=$(git ls-remote --tags origin "refs/tags/v$version")
    [[ -z "$existing" ]] \
        || { echo "v$version is already tagged on origin -- bump the version" >&2; exit 1; }
fi
say "Version $version (build $build_number), architectures: $(lipo -archs "$app/Contents/MacOS/Moo")"

# --- Sign --------------------------------------------------------------------
# Inside-out: nested code first, the bundle last. Signing the outer bundle
# first invalidates the moment anything inside it changes.

say "Signing"

# Every check below reads a command's output from a variable rather than
# piping it into `grep -q`. Under `set -o pipefail`, grep exits the moment it
# matches, the writer dies on SIGPIPE, and the pipeline reports failure --
# intermittently, depending on how much the writer had left to say. That
# turned a passing signature audit into a random one.
is_mach_o() {
    local description
    description=$(file "$1")
    [[ "$description" == *Mach-O* ]]
}

# Standalone Mach-O executables, not just bundles. Sparkle ships
# Versions/B/Autoupdate, a bare executable that --deep --strict happily
# ignores and notarization rejects.
find "$app/Contents/Frameworks" -type f -perm +111 | while read -r f; do
    is_mach_o "$f" || continue
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
    is_mach_o "$f" || continue
    signature=$(codesign -dvv "$f" 2>&1 || true)
    [[ "$signature" == *"Authority=Developer ID Application"* ]] || echo "$f"
done)
[[ -z "$unsigned" ]] || { echo "ad-hoc signed binaries remain:" >&2; echo "$unsigned" >&2; exit 1; }

codesign --verify --deep --strict "$app"

# get-task-allow is a debugging entitlement and notarization rejects any
# submission carrying it. A Developer ID build ships with no entitlements.
entitlements=$(codesign -d --entitlements - --xml "$app" 2>/dev/null || true)
if [[ "$entitlements" == *get-task-allow* ]]; then
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

# The disk image needs its own signature, separate from the app inside it.
# Notarization and stapling both succeed on an unsigned image, and only the
# final spctl assessment catches it -- as "rejected / no usable signature",
# which reads like a signing failure in the app rather than a missing one on
# the container.
say "Signing the disk image"
codesign --force --sign "$IDENTITY" --timestamp "$dmg"

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

# The versioned name is what the appcast points at, and it must never be
# overwritten: Sparkle re-downloads by that URL and checks the signature it
# recorded for that exact file.
wrangler r2 object put "$BUCKET/$(basename "$dmg")" \
    --file "$dmg" --content-type application/x-apple-diskimage --remote

# Moo.dmg is a plain copy of the newest release, for handing someone a link
# that does not go stale. Nothing in the update path reads it, so it is short
# lived in cache and safe to replace on every release.
wrangler r2 object put "$BUCKET/Moo.dmg" \
    --file "$dmg" --content-type application/x-apple-diskimage \
    --cache-control "max-age=300" --remote

# The feed goes last: nothing should advertise a build that is not downloadable.
wrangler r2 object put "$BUCKET/appcast.xml" \
    --file "$release_dir/appcast.xml" --content-type application/xml \
    --cache-control "max-age=300" --remote

say "Published"
echo "  share:    $FEED_HOST/Moo.dmg        (always the newest release)"
echo "  download: $FEED_HOST/$(basename "$dmg")"
echo "  appcast:  $FEED_HOST/appcast.xml"
echo "  local:    $dmg"

# --- GitHub release ----------------------------------------------------------
# The same notarized disk image the feed serves, attached to a tag at the
# commit it was built from. Last, like the feed: it is one more place that
# advertises the build.

if [[ -z "$github_repo" ]]; then
    say "No GitHub remote -- skipping the GitHub release"
    exit 0
fi

tag="v$version"
say "Creating GitHub release $tag ($github_repo)"

checksum=$(shasum -a 256 "$dmg")
checksum=${checksum%% *}
# Outside release_dir: generate_appcast treats notes files there as its own.
github_notes=$(mktemp -t Moo-github-notes)
{
    if [[ -n "$notes_file" ]]; then
        cat "$notes_file"
        printf '\n'
    fi
    cat <<NOTES
## Install

Download **$(basename "$dmg")** below, open it, and drag Moo to Applications.
It is signed with a Developer ID and notarized by Apple, and it updates itself
from then on.

## Verify

\`\`\`
spctl --assess --type open --context context:primary-signature -vv $(basename "$dmg")
shasum -a 256 $(basename "$dmg")
# $checksum
\`\`\`
NOTES
} > "$github_notes"

gh release create "$tag" "$dmg" \
    --repo "$github_repo" \
    --target "$build_commit" \
    --title "Moo $version" \
    --notes-file "$github_notes" \
    --latest

echo "  github:   https://github.com/$github_repo/releases/tag/$tag"
