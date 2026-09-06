# Ad blocking for browser tabs

Browser tabs block ads and trackers with WebKit's own mechanism,
`WKContentRuleList` — the declarative rule format Safari content blockers
use. A `WKWebView` cannot load browser extensions, so uBlock Origin itself
is out of reach; this is the same engine-level blocking that Safari ad
blockers rely on.

## What is bundled

`build.sh` produces `Tecolot/Browser/Resources/`:

| File | Source | Rules |
|---|---|---|
| `adblock-base.deflate` | AdGuard Base filter, Safari-optimized (EasyList + AdGuard English) | ~38k |
| `adblock-tracking.deflate` | AdGuard Tracking Protection filter | ~101k |
| `adblock-manifest.json` | list versions, timestamps, rule counts; drives the app's cache keys | — |

Each list stays under WebKit's hard cap of 150,000 rules per list. The
JSON is stored as raw DEFLATE (about 24 MB → 3 MB); the app inflates and
compiles each list once per list version and WebKit caches the result.

## Refresh the lists

```bash
tools/adblock/build.sh      # needs swift, curl, python3, git
```

The first run clones and builds AdGuard's `SafariConverterLib` (v4.3.0)
into `tools/adblock/.work/`. The converter is a build-time tool only; the
GPL library is never linked into the app. Commit the regenerated files.

## Limits

Content blockers cannot run scriptlets or extended CSS, so sites that need
uBlock Origin's anti-adblock scriptlets are not covered. Cosmetic hiding is
limited to what Safari supports. Blocking is on by default and can be
turned off under Settings › General › Browser tabs.

## Licenses

The filter lists are © AdGuard Software Ltd and their contributors, and
EasyList's authors, distributed under the GNU GPL v3. The converted JSON is
a derivative of those lists and is redistributed under the same license,
as data files separate from the app's MIT-licensed code. Sources:

- https://github.com/AdguardTeam/AdguardFilters (GPL-3.0)
- https://easylist.to (GPL-3.0 / CC BY-SA 3.0)
- https://github.com/AdguardTeam/SafariConverterLib (GPL-3.0, build tool)
