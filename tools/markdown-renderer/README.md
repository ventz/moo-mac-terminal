# Markdown renderer

The JavaScript half of Moo's Markdown preview tab. It turns a `.md` file
into HTML that matches what github.com renders, and runs inside a `WKWebView`
served over the app's private `moo-md://` scheme.

The built output is committed under `Moo/MarkdownPreview/Resources/`, so
an Xcode build never needs Node. Rebuild only after changing `src/` or a
dependency.

## Rebuild

```bash
cd tools/markdown-renderer
npm install
npm run build      # writes Moo/MarkdownPreview/Resources/
npm test           # structural checks against GitHub's markup
```

## What it matches

Verified against GitHub's own `POST /markdown` output (2026-09-05):

- GFM tables, task lists, strikethrough, autolinks, footnotes (`remark-gfm`)
- Alerts as `<div class="markdown-alert markdown-alert-note">` with the
  Octicon and title paragraph (`rehype-github-alerts`)
- Code as `<div class="highlight highlight-source-x"><pre class="notranslate">`
  with prettylights `pl-*` spans from GitHub's grammars (`@wooorm/starry-night`)
- Heading ids prefixed `user-content-`
- Raw HTML limited to GitHub's sanitizer schema (`rehype-sanitize`)
- Emoji shortcodes (`remark-gemoji`)
- Styling from `github-markdown-css`, light and dark via `prefers-color-scheme`

Deliberate differences: math is KaTeX rather than MathJax, and Mermaid is
drawn in the page with `securityLevel: "strict"` (GitHub does both in its
frontend too, so the Markdown itself is treated identically).

## Page ↔ app bridge

The app calls `window.moo.render(markdown)`. The page posts to
`webkit.messageHandlers.moo`: `ready`, `rendered`, `error`, `openLink`,
`copy`, `runCommand`. Links never navigate the page; the app decides.

## Layout of the output

One flat directory. Xcode copies resources flat into the bundle and the
scheme handler looks files up by name, so nothing may rely on subdirectories.
Mermaid's diagram renderers are split into `markdown-preview-chunk-*.js` files
that load on demand; `markdown-preview-onig.wasm` is starry-night's regex
engine and must be served as `application/wasm`.
