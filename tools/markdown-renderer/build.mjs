// Bundles the preview page into Tecolot/MarkdownPreview/Resources. The
// output is committed, so an Xcode build never needs Node; run
// `npm run build` after changing anything under src/ or bumping a package.
//
// Everything lands in one flat directory on purpose: Xcode's synchronized
// group copies resources flat into the bundle, and the app's scheme handler
// looks files up by name.

import {build} from 'esbuild'
import {copyFileSync, mkdirSync, readdirSync, rmSync, statSync} from 'node:fs'
import {dirname, join, resolve} from 'node:path'
import {fileURLToPath} from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const outdir = resolve(here, '../../Tecolot/MarkdownPreview/Resources')

mkdirSync(outdir, {recursive: true})
for (const name of readdirSync(outdir)) {
  rmSync(join(outdir, name), {recursive: true, force: true})
}

await build({
  entryPoints: [{in: join(here, 'src/page.js'), out: 'markdown-preview'}],
  bundle: true,
  format: 'esm',
  splitting: true,
  minify: true,
  sourcemap: false,
  target: ['safari17'],
  outdir,
  chunkNames: 'markdown-preview-chunk-[name]-[hash]',
  assetNames: '[name]',
  loader: {
    '.woff2': 'file',
    // KaTeX's CSS also lists woff and ttf fallbacks; WebKit only needs woff2.
    '.woff': 'empty',
    '.ttf': 'empty'
  },
  logLevel: 'info'
})

copyFileSync(join(here, 'src/markdown-preview.html'), join(outdir, 'markdown-preview.html'))
copyFileSync(
  join(here, 'node_modules/vscode-oniguruma/release/onig.wasm'),
  join(outdir, 'markdown-preview-onig.wasm')
)

let total = 0
for (const name of readdirSync(outdir).sort()) {
  const size = statSync(join(outdir, name)).size
  total += size
  console.log(`${String(size).padStart(9)}  ${name}`)
}
console.log(`${String(total).padStart(9)}  total`)
