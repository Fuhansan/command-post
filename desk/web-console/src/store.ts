import type { AppState, Msg } from './types'

let state: AppState = { projects: [], sessions: [], manual: [] }
let transcripts: Record<string, Msg[]> = {}
const listeners = new Set<() => void>()

export function getState(): AppState { return state }
export function setState(s: AppState) {
  state = { projects: s.projects ?? [], sessions: s.sessions ?? [], manual: s.manual ?? [] }
  listeners.forEach((l) => l())
}
export function getTranscripts() { return transcripts }
export function setTranscript(id: string, messages: Msg[]) {
  transcripts = { ...transcripts, [id]: messages }
  listeners.forEach((l) => l())
}
export function subscribe(l: () => void): () => void {
  listeners.add(l)
  return () => { listeners.delete(l) }
}
