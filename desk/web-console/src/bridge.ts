import { setState, upsertSession, removeSession, upsertManual, removeManual, setProjects, setTranscript, setDir, setFile, setUsage, setConn, setImgReady } from './store'

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
        case 'sessionUpsert':
          upsertSession(msg.payload)
          break
        case 'sessionRemove':
          removeSession(msg.payload.id)
          break
        case 'manualUpsert':
          upsertManual(msg.payload)
          break
        case 'manualRemove':
          removeManual(msg.payload.id)
          break
        case 'projects':
          setProjects(msg.payload.projects, msg.payload.hidden)
          break
        case 'transcript':
          setTranscript(msg.payload.id, msg.payload.messages,
            { earliest: msg.payload.earliest ?? 0, hasEarlier: !!msg.payload.hasEarlier })
          break
        case 'dirList':
          setDir(msg.payload.path, msg.payload.entries)
          break
        case 'fileContent':
          setFile(msg.payload.path, { text: msg.payload.text, truncated: msg.payload.truncated })
          break
        case 'usage':
          setUsage(msg.payload)
          break
        case 'conn':
          setConn(msg.payload)
          break
        case 'imageReady':
          setImgReady(msg.payload)
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
export type AgentId = 'claude' | 'codex'

export const cmd = {
  openProject: () => send({ action: 'openProject' }),
  newSession: (workdir: string, agent: AgentId) => send({ action: 'newSession', workdir, agent }),
  continueLast: (workdir: string, agent: AgentId) => send({ action: 'newSession', workdir, agent, continueLast: true }),
  resume: (workdir: string, id: string, agent: AgentId = 'claude') => send({ action: 'newSession', workdir, agent, resume: id }),
  closeSession: (sid: string) => send({ action: 'closeSession', sid }),
  switchModel: (sid: string, model: string) => send({ action: 'switchModel', sid, model }),
  renameSession: (key: string, title: string) => send({ action: 'renameSession', key, title }),
  hideSession: (key: string) => send({ action: 'hideSession', key }),
  unhideSession: (key: string) => send({ action: 'unhideSession', key }),
  sendInput: (sid: string, text: string, images?: Array<{ name?: string; data?: string; id?: string; ext?: string }>) =>
    send({ action: 'send', sid, text, ...(images && images.length ? { images } : {}) }),
  // 粘贴/添加图片那一刻就上传(由桥代传服务器);完成后桥回推 imageReady
  prepareImage: (attachId: string, name: string, data: string) =>
    send({ action: 'prepareImage', attachId, name, data }),
  // 停止当前回合(Claude 写 {type:interrupt} 控制帧 / Codex turn/interrupt),会话仍在
  interrupt: (sid: string) => send({ action: 'interrupt', sid }),
  respond: (sid: string, reqId: string, choose: string[]) =>
    send({ action: 'respond', sid, reqId, choose }),
  raiseWindow: (id: string) => send({ action: 'raiseWindow', id }),
  // beforeByte 省略=取末尾一窗;传值=加载该字节偏移之前的一窗(更早消息)。
  loadTranscript: (kind: 'manual' | 'history', id: string, workdir?: string, beforeByte?: number) =>
    send({ action: 'loadTranscript', kind, id, workdir, beforeByte }),
  listDir: (path: string) => send({ action: 'listDir', path }),
  loadFile: (path: string) => send({ action: 'loadFile', path }),
  loadUsage: (days: number) => send({ action: 'loadUsage', days }),
  setTheme: (dark: boolean) => send({ action: 'theme', dark }),
  setHost: (host: string) => send({ action: 'setHost', host }),
  pairStart: () => send({ action: 'pairStart' }),
  pairCancel: () => send({ action: 'pairCancel' }),
  unpair: () => send({ action: 'unpair' }),
}
