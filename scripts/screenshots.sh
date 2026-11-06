#!/bin/bash
#
# Screenshots of the ⌘K palette for the website and README, from the real
# Debug app with nothing of yours in them: a scratch HOME holds sample
# projects, a ~/.z and a plain .zshrc, and Moo (MOO_CAPTURE=1, Debug builds
# only, see Moo/Debug/DemoCapture.swift) builds sample workspaces, opens the
# palette and captures its own window. The terminal needs no Screen
# Recording permission for that.
#
# Usage: scripts/screenshots.sh [Debug Moo.app]
# Writes PNGs and 1600 px WebPs to ~/moo-releases/screenshots, which
# scripts/publish-site.sh uploads. Look at every image before publishing.

set -euo pipefail
trap 'echo "screenshots.sh: line $LINENO failed (exit $?): $BASH_COMMAND" >&2' ERR

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
app="${1:-$repo_root/build/DerivedData/Build/Products/Debug/Moo.app}"
out="${MOO_SCREENSHOTS_DIR:-$HOME/moo-releases/screenshots}"
[[ -d "$app" ]] || { echo "screenshots.sh: no Debug app at $app" >&2; exit 1; }
command -v cwebp >/dev/null || { echo "screenshots.sh: brew install webp" >&2; exit 1; }

# Short: shells and sockets dislike long paths, and none of it is shown (~).
# Under /tmp, spelled the way macOS spells the home it is given (it drops
# /private), so ~ abbreviates every path Moo shows. Moo matches the kernel's
# /private/tmp spelling to it with realpath.
demo=$(mktemp -d /private/tmp/moo-demo.XXXXXX)
demo=${demo#/private}
# A free port for the sample site: whatever runs on a usual one (3000, 8080)
# is yours, and DemoCapture checks the page before showing it.
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
mkdir -p "$demo/captures" "$demo/code"

# Sample projects.
mkdir -p "$demo/code/shop-web/src" "$demo/code/shop-web/docs" "$demo/code/shop-api/logs" \
         "$demo/code/shop-api/docs/api" "$demo/code/blog/posts" "$demo/code/blog/docs" \
         "$demo/code/infra" "$demo/notes/design-docs"
cat > "$demo/code/shop-web/index.html" <<'HTML'
<!doctype html><html><head><meta charset="utf-8"><title>Shop · localhost</title>
<style>body{font:16px -apple-system,sans-serif;margin:48px;color:#222}h1{font-size:32px}.card{display:inline-block;width:200px;margin:12px;padding:16px;border:1px solid #ddd;border-radius:10px}</style></head>
<body><h1>Shop</h1><p>Development build.</p><div class="card"><b>Mug</b><br>$12</div><div class="card"><b>Tote bag</b><br>$18</div><div class="card"><b>Stickers</b><br>$4</div></body></html>
HTML
cat > "$demo/code/shop-web/README.md" <<'MD'
# shop-web

The storefront for the sample shop.

## Run it

```sh
python3 -m http.server
```

Then open http://localhost:8000.
MD
cat > "$demo/code/shop-web/src/checkout.ts" <<'TS'
export interface LineItem {
  sku: string;
  quantity: number;
  unitPrice: number;
}

export function subtotal(items: LineItem[]): number {
  return items.reduce((sum, item) => sum + item.quantity * item.unitPrice, 0);
}

export function total(items: LineItem[], taxRate = 0.0625): number {
  const amount = subtotal(items);
  return Math.round(amount * (1 + taxRate) * 100) / 100;
}
TS
cat > "$demo/code/shop-api/logs/api.log" <<'LOG'
12:04:01 GET  /api/products        200  14ms
12:04:02 GET  /api/products/mug    200   6ms
12:04:05 POST /api/cart            201  11ms
12:04:09 GET  /api/cart            200   4ms
LOG
printf '# Hello, world\n\nFirst post.\n' > "$demo/code/blog/posts/hello-world.md"
touch "$demo/code/shop-web/package.json" "$demo/code/infra/main.tf"
for repo in shop-web shop-api blog infra; do
    git -C "$demo/code/$repo" init -q
    git -C "$demo/code/$repo" -c user.name=Demo -c user.email=demo@example.com add -A
    git -C "$demo/code/$repo" -c user.name=Demo -c user.email=demo@example.com commit -qm "Initial commit"
done
for message in "Add checkout totals" "Show tax on the cart page" "Fix rounding of totals"; do
    git -C "$demo/code/shop-web" -c user.name=Demo -c user.email=demo@example.com commit -q --allow-empty -m "$message"
done

# A zsh-z history, so ⌘J has directories to rank.
now=$(date +%s)
{
    echo "$demo/code/shop-web/docs|42|$now"
    echo "$demo/code/blog/docs|25|$((now - 3600))"
    echo "$demo/code/shop-api/docs/api|11|$((now - 86400))"
    echo "$demo/notes/design-docs|6|$((now - 5 * 86400))"
    echo "$demo/code/shop-web|80|$now"
    echo "$demo/code/shop-api|30|$now"
} > "$demo/.z"

# A plain prompt, nothing from your own shell setup.
cat > "$demo/.zshrc" <<ZSH
export HOME="$demo"
export PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
PROMPT='%F{green}%~%f %# '
export LSCOLORS=ExGxFxdxCxDxDxhbadExEx CLICOLOR=1
ZSH
: > "$demo/.zprofile"
printf 'syntax on\nset number\n' > "$demo/.vimrc"

osascript -e 'quit app id "net.vpetkov.Moo.debug"' >/dev/null 2>&1 || true
env -i HOME="$HOME" USER="$USER" LOGNAME="$USER" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    open -W -n --stdout "$demo/capture.log" --stderr "$demo/capture.log" \
    --env HOME="$demo" --env CFFIXED_USER_HOME="$demo" --env ZDOTDIR="$demo" \
    --env MOO_CAPTURE=1 --env MOO_CAPTURE_DIR="$demo/captures" --env MOO_CAPTURE_PORT="$port" \
    "$app" --args -projectsSidebarVisible YES -attentionShowsBanners NO -attentionShowsStatusItem NO

# The dev server outlives Moo only if its shell did; make sure.
pkill -f "http.server $port" 2>/dev/null || true

mkdir -p "$out"
shopt -s nullglob
shots=("$demo/captures"/*.png)
(( ${#shots[@]} > 0 )) || { echo "screenshots.sh: nothing captured; see $demo/capture.log" >&2; exit 1; }
for shot in "${shots[@]}"; do
    name=$(basename "$shot" .png)
    command cp -f "$shot" "$out/$name.png"
    scaled="$demo/$name-scaled.png"
    command cp -f "$shot" "$scaled"
    width=$(sips -g pixelWidth "$scaled" | awk '/pixelWidth/ {print $2}')
    if (( width > 1600 )); then sips --resampleWidth 1600 "$scaled" >/dev/null; fi
    cwebp -quiet -q 84 -alpha_q 90 -m 6 "$scaled" -o "$out/$name.webp"
    echo "  $out/$name.webp"
done
echo "Scratch home: $demo"
