// Structural checks against what github.com emits for the same input
// (verified 2026-09-05 via the GitHub Markdown API). Not byte-for-byte:
// GitHub post-processes in its app layer, so these assert the shapes
// github-markdown-css styles rather than exact strings.

import {test} from 'node:test'
import assert from 'node:assert/strict'
import {createRenderer} from '../src/renderer.js'

const renderer = createRenderer()

test('GFM basics: tables, task lists, strikethrough, autolinks, footnotes', async () => {
  const html = await renderer.render([
    '| a | b |',
    '|---|:-:|',
    '| 1 | 2 |',
    '',
    '- [x] done',
    '- [ ] todo',
    '',
    '~~gone~~ visit https://example.com now[^1]',
    '',
    '[^1]: A note.'
  ].join('\n'))
  assert.match(html, /<table>/)
  assert.match(html, /<td align="center">2<\/td>/)
  assert.match(html, /class="contains-task-list"/)
  assert.match(html, /<input type="checkbox" checked disabled>/)
  assert.match(html, /<del>gone<\/del>/)
  assert.match(html, /<a href="https:\/\/example\.com">https:\/\/example\.com<\/a>/)
  assert.match(html, /class="footnotes"/)
})

test('alerts are GitHub divs, not blockquotes', async () => {
  const html = await renderer.render('> [!NOTE]\n> Careful.')
  assert.match(html, /<div class="markdown-alert markdown-alert-note">/)
  assert.match(html, /<p class="markdown-alert-title">/)
  assert.match(html, /<svg class="octicon/)
  assert.doesNotMatch(html, /<blockquote/)
})

test('headings get user-content ids', async () => {
  const html = await renderer.render('## Quick Install')
  assert.match(html, /<h2 id="user-content-quick-install">Quick Install<\/h2>/)
})

test('code blocks carry prettylights classes in GitHub wrappers', async () => {
  const html = await renderer.render('```python\ndef f():\n    return 1\n```')
  assert.match(html, /<div class="highlight highlight-source-python" data-language="python">/)
  assert.match(html, /<pre class="notranslate">/)
  assert.match(html, /<span class="pl-k">def<\/span>/)
})

test('unknown languages still get the wrapper, plain', async () => {
  const html = await renderer.render('```nosuchlang\nx\n```')
  assert.match(html, /<div class="highlight" data-language="nosuchlang"><pre class="notranslate"><code class="language-nosuchlang">x\n<\/code><\/pre><\/div>/)
})

test('mermaid is left for the page to draw', async () => {
  const html = await renderer.render('```mermaid\ngraph TD; A-->B\n```')
  assert.match(html, /<pre class="mermaid-source"><code class="language-mermaid">/)
})

test('math renders with KaTeX', async () => {
  const html = await renderer.render('Inline $E=mc^2$ and\n\n$$\n\\int_0^1 x\n$$')
  assert.match(html, /class="katex"/)
  assert.match(html, /class="katex-display"/)
})

test('emoji shortcodes become characters', async () => {
  const html = await renderer.render('ship it :rocket:')
  assert.match(html, /ship it 🚀/)
})

test('raw HTML is sanitized like GitHub', async () => {
  const html = await renderer.render([
    '<details><summary>More</summary>hidden</details>',
    '<script>alert(1)</script>',
    '<img src="x" onerror="alert(1)">',
    '<a href="javascript:alert(1)">bad</a>',
    '<kbd>⌘</kbd>'
  ].join('\n\n'))
  assert.match(html, /<details><summary>More<\/summary>hidden<\/details>/)
  assert.doesNotMatch(html, /<script/)
  assert.doesNotMatch(html, /onerror/)
  assert.doesNotMatch(html, /javascript:/)
  assert.match(html, /<kbd>⌘<\/kbd>/)
})

test('relative images and links are preserved for the scheme handler', async () => {
  const html = await renderer.render('![shot](docs/shot.png) and [more](docs/more.md)')
  assert.match(html, /<img src="docs\/shot\.png" alt="shot">/)
  assert.match(html, /<a href="docs\/more\.md">more<\/a>/)
})
