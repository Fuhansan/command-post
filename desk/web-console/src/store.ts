import type { AppState, Msg, Entry, FileBody, UsageData, Conn, Session, Manual, Project, HiddenEntry } from './types'

export interface TranscriptMeta { earliest: number; hasEarlier: boolean }

let state: AppState = { projects: [], sessions: [], manual: [], hidden: [] }
let usage: UsageData | null = null
let conn: Conn | null = null
let transcripts: Record<string, Msg[]> = {}
let transcriptMeta: Record<string, TranscriptMeta> = {}
let dirs: Record<string, Entry[]> = {}
let files: Record<string, FileBody> = {}
const listeners = new Set<() => void>()
const notify = () => listeners.forEach((l) => l())

export function getState(): AppState { return state }
export function setState(s: AppState) {
  state = { projects: s.projects ?? [], sessions: s.sessions ?? [], manual: s.manual ?? [], hidden: s.hidden ?? [] }
  notify()
}
// 增量合并:Swift 端按会话推 upsert/remove,只动变化的那条,其余引用不变(配合 memo 减少重渲染)。
export function upsertSession(s: Session) {
  const i = state.sessions.findIndex((x) => x.id === s.id)
  const sessions = state.sessions.slice()
  if (i >= 0) sessions[i] = s; else sessions.push(s)
  state = { ...state, sessions }; notify()
}
export function removeSession(id: string) {
  if (!state.sessions.some((x) => x.id === id)) return
  state = { ...state, sessions: state.sessions.filter((x) => x.id !== id) }; notify()
}
export function upsertManual(m: Manual) {
  const i = state.manual.findIndex((x) => x.id === m.id)
  const manual = state.manual.slice()
  if (i >= 0) manual[i] = m; else manual.push(m)
  state = { ...state, manual }; notify()
}
export function removeManual(id: string) {
  if (!state.manual.some((x) => x.id === id)) return
  state = { ...state, manual: state.manual.filter((x) => x.id !== id) }; notify()
}
export function setProjects(projects: Project[], hidden?: HiddenEntry[]) {
  state = { ...state, projects: projects ?? [], hidden: hidden ?? state.hidden }; notify()
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
export function getConn() { return conn }
export function setConn(c: Conn) { conn = c; notify() }
export function getDirs() { return dirs }
export function setDir(path: string, entries: Entry[]) { dirs = { ...dirs, [path]: entries }; notify() }
export function getFiles() { return files }
export function setFile(path: string, body: FileBody) { files = { ...files, [path]: body }; notify() }
export function subscribe(l: () => void): () => void {
  listeners.add(l)
  return () => { listeners.delete(l) }
}

// 图片粘贴即上传:桥上传完回推 {attachId,id,ext},发送时按 attachId 取到 id 就只发 id(不再现传)。
const imgUploads: Record<string, { id: string; ext: string }> = {}
export function setImgReady(p: { attachId: string; id: string; ext: string }) { imgUploads[p.attachId] = { id: p.id, ext: p.ext }; notify() }
export function getImgUpload(attachId: string): { id: string; ext: string } | undefined { return imgUploads[attachId] }
