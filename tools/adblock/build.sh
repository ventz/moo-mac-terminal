#!/usr/bin/env bash
#
# Builds the ad-blocking rulesets bundled with Tecolot's browser tabs.
#
# Sources: AdGuard's Safari-optimized filter lists — EasyList plus AdGuard's
# own base list, and AdGuard Tracking Protection — already stripped of rules
# Safari cannot express. They are converted to WebKit's content-blocker JSON
# with AdGuard's SafariConverterLib (used as a build-time tool only; the
# GPL library is never linked into the app), compacted, and stored as raw
# DEFLATE so ~24 MB of JSON ships as ~3 MB. The app inflates and compiles
# them once per version with WKContentRuleListStore.
#
# Output goes to Tecolot/Browser/Resources/ and is committed, so an Xcode
# build never needs this script. Re-run it to refresh the lists.
#
# Requirements: swift (Xcode), curl, python3, git.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
OUT="$REPO/Tecolot/Browser/Resources"
WORK="${ADBLOCK_WORK_DIR:-$HERE/.work}"
CONVERTER_REPO="https://github.com/AdguardTeam/SafariConverterLib.git"
CONVERTER_TAG="v4.3.0"
# The oldest Safari the app runs on (macOS 15 → Safari 18). Newer Safari
# accepts more, but rules must load on the floor.
SAFARI_VERSION="18.0"

# name|url|title
LISTS=(
  "base|https://filters.adtidy.org/extension/safari/filters/2_optimized.txt|AdGuard Base filter (EasyList + AdGuard English), optimized"
  "tracking|https://filters.adtidy.org/extension/safari/filters/3.txt|AdGuard Tracking Protection filter"
)

mkdir -p "$WORK" "$OUT"

# 1. The converter, built once.
CONVERTER="$WORK/SafariConverterLib/.build/release/ConverterTool"
if [ ! -x "$CONVERTER" ]; then
  echo "== building SafariConverterLib $CONVERTER_TAG"
  rm -rf "$WORK/SafariConverterLib"
  git clone -q --depth 1 --branch "$CONVERTER_TAG" "$CONVERTER_REPO" "$WORK/SafariConverterLib"
  (cd "$WORK/SafariConverterLib" && swift build -c release --product ConverterTool 2>&1 | tail -1)
fi

# 2. Download, convert, compress.
rm -f "$OUT"/adblock-*.deflate "$OUT"/adblock-manifest.json
MANIFEST_ENTRIES=()
for entry in "${LISTS[@]}"; do
  IFS='|' read -r name url title <<<"$entry"
  echo "== $name: $url"
  curl -sSfL -o "$WORK/$name.txt" "$url"
  version="$(grep -m1 '^! Version:' "$WORK/$name.txt" | sed 's/^! Version: *//' | tr -d '\r')"
  updated="$(grep -m1 '^! TimeUpdated:' "$WORK/$name.txt" | sed 's/^! TimeUpdated: *//' | tr -d '\r')"
  "$CONVERTER" convert --safari-version "$SAFARI_VERSION" \
    --input-path "$WORK/$name.txt" --safari-rules-json-path "$WORK/$name.json" 2>"$WORK/$name.log"
  count="$(python3 - "$WORK/$name.json" "$OUT/adblock-$name.deflate" <<'PY'
import json, sys, zlib
rules = json.load(open(sys.argv[1]))
compact = json.dumps(rules, separators=(",", ":")).encode()
c = zlib.compressobj(9, zlib.DEFLATED, -15)
open(sys.argv[2], "wb").write(c.compress(compact) + c.flush())
print(len(rules))
PY
)"
  if [ "$count" -ge 150000 ]; then
    echo "!! $name has $count rules, over WebKit's 150,000 per-list cap" >&2
    exit 1
  fi
  size="$(wc -c <"$OUT/adblock-$name.deflate" | tr -d ' ')"
  echo "   $count rules, $size bytes deflated (list version $version, $updated)"
  MANIFEST_ENTRIES+=("{\"name\":\"$name\",\"title\":\"$title\",\"source\":\"$url\",\"version\":\"$version\",\"updated\":\"$updated\",\"rules\":$count,\"file\":\"adblock-$name.deflate\"}")
done

# 3. The manifest drives the app's cache identifiers.
{
  echo "{"
  echo "  \"safariVersion\": \"$SAFARI_VERSION\","
  echo "  \"converter\": \"SafariConverterLib $CONVERTER_TAG\","
  echo "  \"built\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
  echo "  \"lists\": ["
  printf '    %s' "${MANIFEST_ENTRIES[0]}"
  for e in "${MANIFEST_ENTRIES[@]:1}"; do printf ',\n    %s' "$e"; done
  echo
  echo "  ]"
  echo "}"
} >"$OUT/adblock-manifest.json"

echo "== wrote:"
ls -la "$OUT"
