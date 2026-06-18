import { setState, setTranscript, setDir, setFile } from './store'

// JS → Swift:发命令。WKWebView 里走 messageHandlers;浏览器 dev 模式只打印。
export function send(cmd: Record<string, unknown>) {
  const w = window as any
  const h = w.webkit?.messageHandlers?.agent
  if (h) h.postMessage(JSON.stringify(cmd))
  else console.log('[cmd]', cmd)
}

// Swift → JS:推事件。Swift 用 evaluateJavaScript("window.__agent.push(...)") 调。
function installReceiver() {
  const w = window as any
  w.__agent = {
    push(msg: { type: string; payload: any }) {
      switch (msg.type) {
        case 'state':
          setState(msg.payload)
          break
        case 'transcript':
          setTranscript(msg.payload.id, msg.payload.messages)
          break
        case 'dirList':
          setDir(msg.payload.path, msg.payload.entries)
          break
        case 'fileContent':
          setFile(msg.payload.path, { text: msg.payload.text, truncated: msg.payload.truncated })
          break
        default:
          console.warn('未知推送', msg.type)
      }
    },
  }
}
installReceiver()

// 启动后告诉 Swift「我准备好了,给我全量」。
export function ready() { send({ action: 'ready' }) }

// —— 命令封装 ——
export const cmd = {
  openProject: () => send({ action: 'openProject' }),
  newSession: (workdir: string) => send({ action: 'newSession', workdir }),
  continueLast: (workdir: string) => send({ action: 'newSession', workdir, continueLast: true }),
  resume: (workdir: string, id: string) => send({ action: 'newSession', workdir, resume: id }),
  closeSession: (sid: string) => send({ action: 'closeSession', sid }),
  sendInput: (sid: string, text: string) => send({ action: 'send', sid, text }),
  respond: (sid: string, reqId: string, choose: string[]) =>
    send({ action: 'respond', sid, reqId, choose }),
  raiseWindow: (id: string) => send({ action: 'raiseWindow', id }),
  loadTranscript: (kind: 'manual' | 'history', id: string, workdir?: string) =>
    send({ action: 'loadTranscript', kind, id, workdir }),
  listDir: (path: string) => send({ action: 'listDir', path }),
  loadFile: (path: string) => send({ action: 'loadFile', path }),
  setTheme: (dark: boolean) => send({ action: 'theme', dark }),
}
