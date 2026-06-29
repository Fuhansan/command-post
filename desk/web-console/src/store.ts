import type { AppState, Msg, Entry, FileBody, UsageData, Conn, Prefs, Session, Manual, Project, HiddenEntry } from './types'

export interface QueuedItem { text: string; images?: { id: string; ext: string }[] }
export interface TranscriptMeta { earliest: number; hasEarlier: boolean; queued?: QueuedItem[] }

let state: AppState = { projects: [], sessions: [], manual: [], hidden: [], defaultWorkdir: '', defaultRoots: [], defaultSessionDirs: [] }
let usage: UsageData | null = null
let conn: Conn | null = null
let prefs: Prefs | null = null
let transcripts: Record<string, Msg[]> = {}
let transcriptMeta: Record<string, TranscriptMeta> = {}
let dirs: Record<string, Entry[]> = {}
let files: Record<string, FileBody> = {}
const listeners = new Set<() => void>()
// 用 rAF 批处理:运行中会话(console 逐 token / hook 频繁推)每秒上百次更新,
// 不批处理就每次都重渲染整个长列表 → 卡。合并到每帧最多一次,突发也只渲一次。
let notifyScheduled = false
const notify = () => {
  if (notifyScheduled) return
  notifyScheduled = true
  requestAnimationFrame(() => { notifyScheduled = false; listeners.forEach((l) => l()) })
}

export function getState(): AppState { return state }
export function setState(s: AppState) {
  state = { projects: s.projects ?? [], sessions: s.sessions ?? [], manual: s.manual ?? [], hidden: s.hidden ?? [], defaultWorkdir: s.defaultWorkdir ?? '', defaultRoots: s.defaultRoots ?? [], defaultSessionDirs: s.defaultSessionDirs ?? [] }
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
export function setProjects(projects: Project[], hidden?: HiddenEntry[], defaultWorkdir?: string, defaultRoots?: string[], defaultSessionDirs?: string[]) {
  state = { ...state, projects: projects ?? [], hidden: hidden ?? state.hidden, defaultWorkdir: defaultWorkdir ?? state.defaultWorkdir, defaultRoots: defaultRoots ?? state.defaultRoots, defaultSessionDirs: defaultSessionDirs ?? state.defaultSessionDirs }; notify()
}
export function getTranscripts() { return transcripts }
export function getTranscriptMeta() { return transcriptMeta }
// 合并:同 id **替换**(流式正文增长就地更新)、新 id **追加**(加载更早 / 新消息)。
// 顺序由 MsgList 按 ord 排,数组顺序无所谓。Map 保插入序:旧的留位、新的接尾。
export function setTranscript(id: string, messages: Msg[], meta?: TranscriptMeta) {
  const byId = new Map<string, Msg>((transcripts[id] ?? []).map((m) => [m.id, m]))
  for (const m of messages) byId.set(m.id, m)   // 存在则替换,不存在则追加
  transcripts = { ...transcripts, [id]: Array.from(byId.values()) }
  if (meta) transcriptMeta = { ...transcriptMeta, [id]: meta }
  notify()
}
export function getUsage() { return usage }
export function setUsage(u: UsageData) { usage = u; notify() }
export function getConn() { return conn }
export function setConn(c: Conn) { conn = c; notify() }
export function getPrefs() { return prefs }
export function setPrefs(p: Prefs) { prefs = p; notify() }
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
