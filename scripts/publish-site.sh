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
# Requires a logged-in wrangler: npx wrangler@latest login

set -euo pipefail

readonly BUCKET="moo-mac-terminal-autoupdate"
readonly SITE_HOST="https://moo.vpetkov.net"

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

# CI=1 and the metrics opt-out keep wrangler off its first-run prompts, which
# block forever when nothing is there to answer them.
wrangler() { CI=1 WRANGLER_SEND_METRICS=false npx --yes wrangler@latest "$@"; }

wrangler whoami >/dev/null 2>&1 \
    || { echo "wrangler is not logged in -- run: npx wrangler@latest login" >&2; exit 1; }

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

screenshots="${MOO_SCREENSHOTS_DIR:-$HOME/moo-releases/screenshots}"
if [[ -d "$screenshots" ]]; then
    for shot in "$screenshots"/*.webp "$screenshots"/*.png; do
        [[ -f "$shot" ]] || continue
        case "$shot" in
            *.webp) type="image/webp" ;;
            *) type="image/png" ;;
        esac
        wrangler r2 object put "$BUCKET/screenshots/$(basename "$shot")" \
            --file "$shot" --content-type "$type" \
            --cache-control "max-age=86400" --remote
    done
else
    echo "==> No screenshots at $screenshots -- leaving the published ones as they are"
fi

cat <<NOTE

Published. Two things this does not do:

  - Purge the Cloudflare cache. Edits appear within the 5 minute max-age, or
    purge $SITE_HOST/index.html to see them now. Screenshots are cached for a
    day, so a replaced one needs a new ?v= in site/index.html and README.md.
  - Serve the page at the bare root. That is a zone rewrite rule
    ("Moo site: serve index.html at the root"), because an R2 custom domain
    has no index-document behavior of its own and answers / with a 404.
NOTE
