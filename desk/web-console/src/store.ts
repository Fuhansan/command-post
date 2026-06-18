import type { AppState } from './types'

let state: AppState = { projects: [], sessions: [] }
const listeners = new Set<() => void>()

export function getState(): AppState { return state }
export function setState(s: AppState) {
  state = { projects: s.projects ?? [], sessions: s.sessions ?? [] }
  listeners.forEach((l) => l())
}
export function subscribe(l: () => void): () => void {
  listeners.add(l)
  return () => { listeners.delete(l) }
}
