import type { AppState, Msg, Entry, FileBody, UsageData } from './types'

export interface TranscriptMeta { earliest: number; hasEarlier: boolean }

let state: AppState = { projects: [], sessions: [], manual: [] }
let usage: UsageData | null = null
let transcripts: Record<string, Msg[]> = {}
let transcriptMeta: Record<string, TranscriptMeta> = {}
let dirs: Record<string, Entry[]> = {}
let files: Record<string, FileBody> = {}
const listeners = new Set<() => void>()
const notify = () => listeners.forEach((l) => l())

export function getState(): AppState { return state }
export function setState(s: AppState) {
  state = { projects: s.projects ?? [], sessions: s.sessions ?? [], manual: s.manual ?? [] }
  notify()
}
export function getTranscripts() { return transcripts }
export function getTranscriptMeta() { return transcriptMeta }
// 合并:历史/手动转录分窗加载,「加载更早」时把旧消息并进来(按 id 去重)。
export function setTranscript(id: string, messages: Msg[], meta?: TranscriptMeta) {
  const prev = transcripts[id] ?? []
  const seen = new Set(prev.map((m) => m.id))
  const merged = prev.concat(messages.filter((m) => !seen.has(m.id)))
  transcripts = { ...transcripts, [id]: merged }
  if (meta) transcriptMeta = { ...transcriptMeta, [id]: meta }
  notify()
}
export function getUsage() { return usage }
export function setUsage(u: UsageData) { usage = u; notify() }
export function getDirs() { return dirs }
export function setDir(path: string, entries: Entry[]) { dirs = { ...dirs, [path]: entries }; notify() }
export function getFiles() { return files }
export function setFile(path: string, body: FileBody) { files = { ...files, [path]: body }; notify() }
export function subscribe(l: () => void): () => void {
  listeners.add(l)
  return () => { listeners.delete(l) }
}
