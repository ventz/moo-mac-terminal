// The Markdown → HTML pipeline, kept free of any DOM so the same code runs
// in the preview page and under Node for the fixture tests.
//
// The target is what github.com emits, verified against its own output:
//   - alerts are <div class="markdown-alert markdown-alert-note"> with an
//     Octicon and a <p class="markdown-alert-title">, not a blockquote
//   - code is <div class="highlight highlight-source-x"><pre class="notranslate">
//     with prettylights `pl-*` spans, which is what starry-night produces
//     from GitHub's own grammars and what github-markdown-css styles
//   - heading ids carry the `user-content-` prefix
//   - raw HTML survives only what GitHub's sanitizer allows
// Math is rendered with KaTeX rather than GitHub's MathJax; Mermaid blocks
// are left as `pre.mermaid-source` for the page to draw lazily.

import {unified} from 'unified'
import remarkParse from 'remark-parse'
import remarkGfm from 'remark-gfm'
import remarkGemoji from 'remark-gemoji'
import remarkMath from 'remark-math'
import remarkRehype from 'remark-rehype'
import rehypeRaw from 'rehype-raw'
import rehypeSanitize, {defaultSchema} from 'rehype-sanitize'
import {rehypeGithubAlerts} from 'rehype-github-alerts'
import rehypeSlug from 'rehype-slug'
import rehypeKatex from 'rehype-katex'
import rehypeStringify from 'rehype-stringify'
import {toString} from 'hast-util-to-string'
import {visit} from 'unist-util-visit'
import {common, createStarryNight} from '@wooorm/starry-night'

export const HEADING_PREFIX = 'user-content-'

/// GitHub's sanitizer schema, widened only for what the later passes need:
/// the math classes remark-math sets so rehype-katex can find them, and
/// `align` on tables/cells which GFM tables use.
const schema = structuredClone(defaultSchema)
schema.attributes = schema.attributes || {}
schema.attributes.code = [
  ...(schema.attributes.code || []).filter((rule) => !(Array.isArray(rule) && rule[0] === 'className')),
  ['className', /^language-./, 'math-inline', 'math-display']
]
schema.attributes.div = [...(schema.attributes.div || []), ['className', 'math', 'math-display']]
schema.attributes.span = [...(schema.attributes.span || []), ['className', 'math', 'math-inline']]
schema.clobberPrefix = HEADING_PREFIX

/// Wraps highlighted code the way GitHub does. `<pre>` gets GitHub's
/// `notranslate` class; the wrapper carries the scope for CSS hooks.
function rehypeStarryNight(starryNight) {
  return (tree) => {
    visit(tree, 'element', (node, index, parent) => {
      if (!parent || index === null || node.tagName !== 'pre') return
      const code = node.children.find((child) => child.type === 'element' && child.tagName === 'code')
      if (!code) return
      const classes = Array.isArray(code.properties?.className) ? code.properties.className : []
      const language = classes.find((name) => String(name).startsWith('language-'))
      const flag = language ? String(language).slice('language-'.length) : null
      if (flag === 'math') return

      if (flag === 'mermaid') {
        node.properties = {...node.properties, className: ['mermaid-source']}
        code.properties = {...code.properties, className: ['language-mermaid']}
        return
      }

      const scope = flag ? starryNight.flagToScope(flag) : null
      const text = toString(code)
      if (scope) {
        const fragment = starryNight.highlight(text, scope)
        code.children = fragment.children
      }
      node.properties = {...node.properties, className: ['notranslate']}
      parent.children[index] = {
        type: 'element',
        tagName: 'div',
        properties: {
          className: ['highlight', ...(scope ? [`highlight-${scope.replace(/^source\./, 'source-').replace(/^text\./, 'text-').replaceAll('.', '-')}`] : [])],
          dataLanguage: flag || undefined
        },
        children: [node]
      }
    })
  }
}

let processorPromise = null

/// Builds the processor once; starry-night needs its WebAssembly first.
/// `getOnigurumaUrlFetch` tells it where the app serves onig.wasm.
export function createRenderer(options = {}) {
  if (!processorPromise) {
    processorPromise = (async () => {
      const starryNight = await createStarryNight(common, {
        getOnigurumaUrlFetch: options.getOnigurumaUrlFetch
      })
      return unified()
        .use(remarkParse)
        .use(remarkGfm, {singleTilde: false})
        .use(remarkGemoji)
        .use(remarkMath)
        .use(remarkRehype, {allowDangerousHtml: true})
        .use(rehypeRaw)
        .use(rehypeSanitize, schema)
        .use(rehypeGithubAlerts)
        .use(rehypeSlug, {prefix: HEADING_PREFIX})
        .use(rehypeStarryNight, starryNight)
        // `trust` must stay at its default (false): every published KaTeX
        // XSS needed it on, and KaTeX output runs after the sanitizer.
        // The size/expansion caps stop a README from hanging the renderer.
        .use(rehypeKatex, {throwOnError: false, strict: 'ignore', maxSize: 100, maxExpand: 1000})
        .use(rehypeStringify)
    })()
  }
  return {
    async render(markdown) {
      const processor = await processorPromise
      const file = await processor.process(markdown)
      return String(file)
    }
  }
}
