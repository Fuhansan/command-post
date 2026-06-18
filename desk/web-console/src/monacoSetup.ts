// 让 @monaco-editor/react 用本地打包的 monaco(离线,不从 CDN 拉);配置各语言 worker。
import { loader } from '@monaco-editor/react'
import * as monaco from 'monaco-editor'
import editorWorker from 'monaco-editor/esm/vs/editor/editor.worker?worker'
import jsonWorker from 'monaco-editor/esm/vs/language/json/json.worker?worker'
import cssWorker from 'monaco-editor/esm/vs/language/css/css.worker?worker'
import htmlWorker from 'monaco-editor/esm/vs/language/html/html.worker?worker'
import tsWorker from 'monaco-editor/esm/vs/language/typescript/ts.worker?worker'

;(self as any).MonacoEnvironment = {
  getWorker(_: unknown, label: string) {
    if (label === 'json') return new jsonWorker()
    if (label === 'css' || label === 'scss' || label === 'less') return new cssWorker()
    if (label === 'html' || label === 'handlebars' || label === 'razor') return new htmlWorker()
    if (label === 'typescript' || label === 'javascript') return new tsWorker()
    return new editorWorker()
  },
}
loader.config({ monaco })

const EXT: Record<string, string> = {
  ts: 'typescript', tsx: 'typescript', js: 'javascript', jsx: 'javascript', mjs: 'javascript',
  swift: 'swift', py: 'python', rb: 'ruby', go: 'go', rs: 'rust', java: 'java', kt: 'kotlin',
  json: 'json', md: 'markdown', html: 'html', css: 'css', scss: 'scss', sh: 'shell', bash: 'shell',
  yml: 'yaml', yaml: 'yaml', xml: 'xml', sql: 'sql', c: 'c', cpp: 'cpp', cc: 'cpp', h: 'cpp', hpp: 'cpp',
  php: 'php', toml: 'ini', ini: 'ini', dockerfile: 'dockerfile',
}
export function langOf(path: string): string {
  const ext = path.split('.').pop()?.toLowerCase() ?? ''
  return EXT[ext] ?? 'plaintext'
}
