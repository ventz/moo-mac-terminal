// The preview page: receives Markdown from the app, renders it, keeps the
// reader's place across reloads, and hands every click on a link back to
// the app, which decides whether it is another preview, a browser tab or
// the outside world. Nothing here ever navigates the page itself.

import './styles.css'
import {createRenderer, HEADING_PREFIX} from './renderer.js'

const ASSET_BASE = '/app/'
const bridge = window.webkit?.messageHandlers?.moo
const content = document.getElementById('content')
const status = document.getElementById('status')

const renderer = createRenderer({
  getOnigurumaUrlFetch: () => new URL(ASSET_BASE + 'markdown-preview-onig.wasm', location.href)
})

function post(message) {
  if (bridge) bridge.postMessage(message)
}

// MARK: Scroll preservation

/// The nearest heading at or above the top of the viewport, with how far
/// past it the reader has scrolled. Editing above the viewport changes the
/// document height, so an anchor beats a raw scroll offset.
function captureAnchor() {
  const headings = content.querySelectorAll('h1[id],h2[id],h3[id],h4[id],h5[id],h6[id]')
  let anchor = null
  for (const heading of headings) {
    const top = heading.getBoundingClientRect().top
    if (top <= 8) anchor = heading
    else break
  }
  if (!anchor) {
    const height = document.documentElement.scrollHeight - window.innerHeight
    return {ratio: height > 0 ? window.scrollY / height : 0}
  }
  return {id: anchor.id, offset: window.scrollY - (anchor.getBoundingClientRect().top + window.scrollY)}
}

function restoreAnchor(anchor) {
  if (!anchor) return
  if (anchor.id) {
    const target = document.getElementById(anchor.id)
    if (target) {
      const top = target.getBoundingClientRect().top + window.scrollY
      window.scrollTo(0, top + anchor.offset)
      return
    }
  }
  const height = document.documentElement.scrollHeight - window.innerHeight
  window.scrollTo(0, (anchor.ratio || 0) * height)
}

// MARK: Rendering

let mermaidModule = null
let renderSerial = 0
let lastMarkdown = null
const darkScheme = window.matchMedia('(prefers-color-scheme: dark)')

function isDark() {
  return darkScheme.matches
}

async function loadMermaid() {
  if (!mermaidModule) {
    mermaidModule = import('mermaid').then((module) => module.default)
  }
  const mermaid = await mermaidModule
  // Initialize every time: the theme follows the appearance, which changes.
  mermaid.initialize({
    startOnLoad: false,
    securityLevel: 'strict',
    theme: isDark() ? 'dark' : 'default'
  })
  return mermaid
}

/// Draws the diagrams of render `serial`, and stops as soon as a newer
/// render has replaced the content it was drawing into.
async function drawMermaid(serial) {
  const blocks = content.querySelectorAll('pre.mermaid-source')
  if (blocks.length === 0) return
  const mermaid = await loadMermaid()
  if (serial !== renderSerial) return
  let index = 0
  for (const block of blocks) {
    const source = block.textContent
    const id = `mermaid-${serial}-${index++}`
    try {
      const {svg} = await mermaid.render(id, source)
      if (serial !== renderSerial) return
      // Import only the SVG element, parsed as XML, rather than trusting
      // the string wholesale into innerHTML.
      const parsed = new DOMParser().parseFromString(svg, 'image/svg+xml')
      const root = parsed.documentElement
      if (!root || root.nodeName.toLowerCase() !== 'svg') throw new Error('not an SVG')
      const figure = document.createElement('div')
      figure.className = 'mermaid'
      figure.append(document.importNode(root, true))
      block.replaceWith(figure)
    } catch (error) {
      block.classList.add('mermaid-error')
      block.title = String(error?.message || error)
    }
  }
}

const SHELL_LANGUAGES = new Set(['sh', 'bash', 'zsh', 'shell', 'console', 'shellsession'])

/// GitHub's copy button on every block, plus — because this preview lives
/// in a terminal — a run button on shell blocks.
function decorateCodeBlocks() {
  for (const block of content.querySelectorAll('div.highlight')) {
    const pre = block.querySelector('pre')
    if (!pre) continue
    const language = block.dataset.language || ''
    const actions = document.createElement('div')
    actions.className = 'code-actions'

    const copy = document.createElement('button')
    copy.type = 'button'
    copy.className = 'code-action'
    copy.title = 'Copy'
    copy.textContent = 'Copy'
    copy.addEventListener('click', () => {
      post({type: 'copy', text: pre.textContent})
      copy.textContent = 'Copied'
      setTimeout(() => { copy.textContent = 'Copy' }, 1200)
    })
    actions.append(copy)

    if (SHELL_LANGUAGES.has(language)) {
      const run = document.createElement('button')
      run.type = 'button'
      run.className = 'code-action'
      run.title = 'Run in the terminal'
      run.textContent = 'Run'
      run.addEventListener('click', () => post({type: 'runCommand', text: pre.textContent}))
      actions.append(run)
    }
    block.append(actions)
  }
}

async function render(markdown) {
  lastMarkdown = markdown
  const serial = ++renderSerial
  const anchor = captureAnchor()
  let html
  try {
    html = await renderer.render(markdown)
  } catch (error) {
    showStatus(`Could not render: ${error?.message || error}`)
    post({type: 'error', message: String(error?.message || error)})
    return
  }
  if (serial !== renderSerial) return
  content.innerHTML = html
  showStatus(null)
  decorateCodeBlocks()
  restoreAnchor(anchor)
  post({type: 'rendered'})
  drawMermaid(serial).then(() => {
    if (serial === renderSerial) restoreAnchor(anchor)
  })
}

// Diagrams carry their theme in the SVG, so a light/dark flip redraws.
darkScheme.addEventListener('change', () => {
  if (lastMarkdown !== null && content.querySelector('.mermaid, pre.mermaid-source')) {
    render(lastMarkdown)
  }
})

function showStatus(text) {
  status.hidden = !text
  status.textContent = text || ''
}

// MARK: Links

/// Same-document fragments scroll here (GitHub prefixes ids, so `#usage`
/// means `#user-content-usage`); everything else is the app's decision.
document.addEventListener('click', (event) => {
  const anchor = event.target.closest('a[href]')
  if (!anchor || event.button !== 0) return
  event.preventDefault()
  const href = anchor.getAttribute('href') || ''
  if (href.startsWith('#')) {
    const raw = decodeURIComponent(href.slice(1))
    const target = document.getElementById(HEADING_PREFIX + raw) || document.getElementById(raw)
    if (target) target.scrollIntoView({block: 'start'})
    return
  }
  post({type: 'openLink', href: anchor.href})
})

// Task-list checkboxes are rendered disabled, as on GitHub. A stray form
// submit must never navigate.
document.addEventListener('submit', (event) => event.preventDefault())

window.moo = {render}

post({type: 'ready'})
