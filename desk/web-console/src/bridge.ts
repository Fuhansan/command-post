import { setState, upsertSession, removeSession, upsertManual, removeManual, setProjects, setTranscript, setDir, setFile, setUsage, setConn, setPrefs, setImgReady } from './store'

// JS → Swift:发命令。WKWebView 里走 messageHandlers;浏览器 dev 模式只打印。
export function send(cmd: Record<string, unknown>) {
  const w = window as any
  const h = w.webkit?.messageHandlers?.agent
  if (h) h.postMessage(JSON.stringify(cmd))
  else console.log('[cmd]', cmd)
}

// 登录类请求:reqId → Promise,Swift 经 "authResult" push 回带同一 reqId 解决/拒绝。
let authSeq = 0
const authPending = new Map<string, { resolve: (v: any) => void; reject: (e: Error) => void }>()
function authCall(action: string, params: Record<string, unknown> = {}): Promise<any> {
  const reqId = `auth${++authSeq}`
  return new Promise((resolve, reject) => {
    authPending.set(reqId, { resolve, reject })
    send({ action, reqId, ...params })
    setTimeout(() => {
      if (authPending.has(reqId)) { authPending.delete(reqId); reject(new Error('请求超时,检查网络')) }
    }, 20000)
  })
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
          setProjects(msg.payload.projects, msg.payload.hidden, msg.payload.defaultWorkdir, msg.payload.defaultRoots, msg.payload.defaultSessionDirs)
          break
        case 'transcript':
          setTranscript(msg.payload.id, msg.payload.messages,
            { earliest: msg.payload.earliest ?? 0, hasEarlier: !!msg.payload.hasEarlier, queued: msg.payload.queued ?? [],
              contextTokens: msg.payload.contextTokens, contextWindow: msg.payload.contextWindow })
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
        case 'prefs':
          setPrefs(msg.payload)
          break
        case 'imageReady':
          setImgReady(msg.payload)
          break
        case 'authResult': {
          const { reqId, ok, error, ...rest } = msg.payload || {}
          const p = authPending.get(reqId)
          if (p) { authPending.delete(reqId); ok ? p.resolve(rest) : p.reject(new Error(error || '请求失败')) }
          break
        }
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
  removeProject: (workdir: string) => send({ action: 'removeProject', workdir }),
  pickDefaultWorkdir: () => send({ action: 'pickDefaultWorkdir' }),
  addDefaultSessionDir: () => send({ action: 'addDefaultSessionDir' }),
  removeDefaultSessionDir: (dir: string) => send({ action: 'removeDefaultSessionDir', dir }),
  newSession: (workdir: string, agent: AgentId) => send({ action: 'newSession', workdir, agent }),
  continueLast: (workdir: string, agent: AgentId) => send({ action: 'newSession', workdir, agent, continueLast: true }),
  resume: (workdir: string, id: string, agent: AgentId = 'claude') => send({ action: 'newSession', workdir, agent, resume: id }),
  closeSession: (sid: string) => send({ action: 'closeSession', sid }),
  loadSessionHistory: (sid: string, beforeByte?: number) =>
    send({ action: 'loadSessionHistory', sid, beforeByte }),
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
  // 终端会话审批应答(允许/拒绝)→ 回写被 hook 扣住的连接(如 git push)
  termPermission: (sid: string, allow: boolean) => send({ action: 'termPermission', sid, allow }),
  respond: (sid: string, reqId: string, choose: string[]) =>
    send({ action: 'respond', sid, reqId, choose }),
  raiseWindow: (id: string) => send({ action: 'raiseWindow', id }),
  // beforeByte 省略=取末尾一窗;传值=加载该字节偏移之前的一窗(更早消息)。
  loadTranscript: (kind: 'manual' | 'history', id: string, workdir?: string, beforeByte?: number) =>
    send({ action: 'loadTranscript', kind, id, workdir, beforeByte }),
  // 告诉桥当前打开的是哪个(终端)会话:只给它读转录推实时正文,其余不加载。null = 没开/控制台会话。
  focusSession: (id: string | null) => send({ action: 'focusSession', id }),
  listDir: (path: string) => send({ action: 'listDir', path }),
  loadFile: (path: string) => send({ action: 'loadFile', path }),
  loadUsage: (days: number) => send({ action: 'loadUsage', days }),
  setTheme: (dark: boolean) => send({ action: 'theme', dark }),
  setHost: (host: string) => send({ action: 'setHost', host }),
  setLaunchAtLogin: (value: boolean) => send({ action: 'setLaunchAtLogin', value }),
  setMute: (value: boolean) => send({ action: 'setMute', value }),
  logout: () => send({ action: 'logout' }),
}

// 账号登录:调用走桥接(原生帮发请求,和会话/项目同一套),结果经 authResult push await 回来。
// 流程与手机端一致:邮箱 → check 分流 → 密码 / 验证码 / 注册;另有忘记密码。
export const auth = {
  check: (account: string) =>
    authCall('checkAccount', { account }) as Promise<{ exists: boolean; hasPassword: boolean }>,
  login: (account: string, password: string) =>
    authCall('login', { account, password }) as Promise<{ account: string }>,
  sendCode: (account: string) => authCall('sendCode', { account }) as Promise<{}>,
  loginWithCode: (account: string, code: string) =>
    authCall('loginWithCode', { account, code }) as Promise<{ account: string }>,
  sendRegisterCode: (account: string) => authCall('sendRegisterCode', { account }) as Promise<{}>,
  register: (account: string, code: string, password: string) =>
    authCall('register', { account, code, password }) as Promise<{ account: string }>,
  sendForgotCode: (account: string) => authCall('sendForgotCode', { account }) as Promise<{}>,
  resetPassword: (account: string, code: string, password: string) =>
    authCall('resetPassword', { account, code, password }) as Promise<{}>,
}
