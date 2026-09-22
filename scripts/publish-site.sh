#!/bin/bash
#
# Publish the landing page at https://moo.vpetkov.net to the R2 bucket that
# also serves the releases and the Sparkle appcast.
#
# The page is static and independent of any release, so this is deliberately
# not part of scripts/release.sh -- editing copy should not require cutting a
# build, and cutting a build should not silently republish the site.
#
# Screenshots live outside the repo, in ~/moo-releases/screenshots (override
# with MOO_SCREENSHOTS_DIR): each as a .webp the page shows and the original
# .png it links to. They are uploaded when that directory exists.
#
# Requires a logged-in wrangler: npx wrangler@4.136.0 login (see WRANGLER_VERSION)

set -euo pipefail

readonly BUCKET="moo-mac-terminal-autoupdate"
readonly SITE_HOST="https://moo.vpetkov.net"
readonly ZONE_ID="792ac1cce71566cf301c50241f783e51"   # vpetkov.net

# Purging needs an API token with only Zone > Cache Purge on vpetkov.net;
# wrangler's OAuth login cannot purge. Kept in the login keychain:
#   security add-generic-password -a "$USER" -s moo-cf-purge -w <token>
# Without it everything still publishes, and edits show within the 5 minute
# max-age instead of at once.
purge_token=${CLOUDFLARE_PURGE_TOKEN:-$(security find-generic-password -s moo-cf-purge -w 2>/dev/null || true)}
published=()

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

# CI=1 and the metrics opt-out keep wrangler off its first-run prompts, which
# block forever when nothing is there to answer them.
# Pinned, and bumped on purpose. This runs on the machine holding the
# Developer ID key, the notary profile, the Sparkle signing key and a Cloudflare
# session that can write the bucket serving the update feed; "@latest" would
# execute whatever npm published most recently. 4.136.0 cut 0.1.3.
readonly WRANGLER_VERSION="4.136.0"
wrangler() { CI=1 WRANGLER_SEND_METRICS=false npx --yes "wrangler@$WRANGLER_VERSION" "$@"; }

wrangler whoami >/dev/null 2>&1 \
    || { echo "wrangler is not logged in -- run: npx wrangler@$WRANGLER_VERSION login" >&2; exit 1; }

# The page's icon is the same artwork the app bundle uses, so it is copied
# from docs/ rather than kept as a second copy under site/.
icon="docs/moo-icon.png"
[[ -f "$icon" ]] || { echo "missing $icon" >&2; exit 1; }

# Content types are passed bare, with no charset parameter -- wrangler hangs
# rather than erroring when given one.
echo "==> Publishing site to $BUCKET"
wrangler r2 object put "$BUCKET/index.html" \
    --file site/index.html --content-type "text/html" \
    --cache-control "max-age=300" --remote
wrangler r2 object put "$BUCKET/icon.png" \
    --file "$icon" --content-type "image/png" \
    --cache-control "max-age=86400" --remote
published+=("$SITE_HOST/" "$SITE_HOST/index.html" "$SITE_HOST/icon.png")

screenshots="${MOO_SCREENSHOTS_DIR:-$HOME/moo-releases/screenshots}"
if [[ -d "$screenshots" ]]; then
    for shot in "$screenshots"/*.webp "$screenshots"/*.png; do
        [[ -f "$shot" ]] || continue
        case "$shot" in
            *.webp) type="image/webp" ;;
            *) type="image/png" ;;
        esac
        # Short-lived like the page, so a replaced screenshot keeps its URL:
        # no ?v= to bump, and browsers pick it up within minutes.
        wrangler r2 object put "$BUCKET/screenshots/$(basename "$shot")" \
            --file "$shot" --content-type "$type" \
            --cache-control "max-age=300" --remote
        published+=("$SITE_HOST/screenshots/$(basename "$shot")")
    done
else
    echo "==> No screenshots at $screenshots -- leaving the published ones as they are"
fi

# Clear Cloudflare's copy of everything just uploaded, 30 URLs per request.
if [[ -n "$purge_token" ]]; then
    echo "==> Purging ${#published[@]} URLs from the Cloudflare cache"
    for ((i = 0; i < ${#published[@]}; i += 30)); do
        files=$(printf '"%s",' "${published[@]:i:30}")
        response=$(curl -sS -X POST \
            "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/purge_cache" \
            -H "Authorization: Bearer $purge_token" \
            -H "Content-Type: application/json" \
            --data "{\"files\":[${files%,}]}")
        [[ $response == *'"success":true'* ]] \
            || { echo "cache purge failed: $response" >&2; exit 1; }
    done
else
    echo "==> No moo-cf-purge token -- Cloudflare serves the old copies for up to 5 minutes"
fi

cat <<NOTE

Published. One thing this does not do:

  - Serve the page at the bare root. That is a zone rewrite rule
    ("Moo site: serve index.html at the root"), because an R2 custom domain
    has no index-document behavior of its own and answers / with a 404.
NOTE
