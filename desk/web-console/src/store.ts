import type { AppState, Msg, Entry, FileBody } from './types'

let state: AppState = { projects: [], sessions: [], manual: [] }
let transcripts: Record<string, Msg[]> = {}
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
export function setTranscript(id: string, messages: Msg[]) {
  transcripts = { ...transcripts, [id]: messages }; notify()
}
export function getDirs() { return dirs }
export function setDir(path: string, entries: Entry[]) { dirs = { ...dirs, [path]: entries }; notify() }
export function getFiles() { return files }
export function setFile(path: string, body: FileBody) { files = { ...files, [path]: body }; notify() }
export function subscribe(l: () => void): () => void {
  listeners.add(l)
  return () => { listeners.delete(l) }
}
