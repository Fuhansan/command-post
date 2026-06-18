import { useSyncExternalStore, useState, useMemo, useRef, useEffect } from 'react'
import hljs from 'highlight.js'
import {
  Folder, FolderOpen, File as FileIcon, ChevronRight, ChevronDown, ArrowUp, FolderPlus,
  RotateCcw, AppWindow, Plus, X, Paperclip, Sun, Moon, SlidersHorizontal,
  BarChart3, PanelsTopLeft, Search,
} from 'lucide-react'
import { subscribe, getState, getTranscripts, getDirs, getFiles } from './store'
import { cmd } from './bridge'
import type { Session, Msg, Manual, History, Project, Entry } from './types'

const HLJS_EXT: Record<string, string> = {
  ts: 'typescript', tsx: 'typescript', js: 'javascript', jsx: 'javascript', mjs: 'javascript',
  swift: 'swift', py: 'python', rb: 'ruby', go: 'go', rs: 'rust', java: 'java', kt: 'kotlin',
  json: 'json', md: 'markdown', html: 'xml', css: 'css', scss: 'scss', sh: 'bash', bash: 'bash',
  yml: 'yaml', yaml: 'yaml', xml: 'xml', sql: 'sql', c: 'c', cpp: 'cpp', cc: 'cpp', h: 'cpp',
  hpp: 'cpp', php: 'php', toml: 'ini', ini: 'ini',
}
const hljsLang = (path: string) => HLJS_EXT[path.split('.').pop()?.toLowerCase() ?? '']

function useAgent() { return useSyncExternalStore(subscribe, getState, getState) }
function useTranscripts() { return useSyncExternalStore(subscribe, getTranscripts, getTranscripts) }
function useDirs() { return useSyncExternalStore(subscribe, getDirs, getDirs) }
function useFiles() { return useSyncExternalStore(subscribe, getFiles, getFiles) }

// ===== 状态 → 圆点 + 文案(对齐设计稿)=====
type DotMeta = { text: string; color: string; pulse?: boolean; hollow?: boolean }
function sessionMeta(status: string): DotMeta {
  switch (status) {
    case 'working': return { text: '运行中', color: 'var(--accent)', pulse: true }
    case 'starting': return { text: '启动中', color: 'var(--amber)', pulse: true }
    case 'needsResponse': return { text: '待响应', color: 'var(--amber)', hollow: true }
    case 'waitingInput': return { text: '挂起', color: 'var(--text-faint)', hollow: true }
    case 'idle': return { text: '就绪', color: 'var(--accent)' }
    case 'error': return { text: '错误', color: 'var(--red)' }
    default: return { text: '已完成', color: 'var(--green)' }
  }
}
function manualMeta(state: string): DotMeta {
  if (state === 'working') return { text: '运行中', color: 'var(--accent)', pulse: true }
  if (state === 'waiting') return { text: '待确认', color: 'var(--amber)', hollow: true }
  return { text: '空闲', color: 'var(--text-faint)', hollow: true }
}
function Dot({ meta, size = 7 }: { meta: DotMeta; size?: number }) {
  const base: React.CSSProperties = {
    width: size, height: size, borderRadius: '50%', flex: 'none', display: 'inline-block',
  }
  if (meta.hollow) return <span style={{ ...base, background: 'transparent', border: `1.5px solid ${meta.color}` }} />
  return <span className={meta.pulse ? 'dot-live' : ''} style={{ ...base, background: meta.color }} />
}

function relTime(ms?: number): string {
  if (!ms) return ''
  const d = new Date(ms), now = new Date()
  if (d.toDateString() === now.toDateString()) return d.toTimeString().slice(0, 5)
  const y = new Date(now); y.setDate(now.getDate() - 1)
  if (d.toDateString() === y.toDateString()) return '昨天'
  const days = Math.floor((new Date(now).setHours(0, 0, 0, 0) - new Date(ms).setHours(0, 0, 0, 0)) / 86400000)
  if (days < 7) return `${days} 天前`
  return `${d.getMonth() + 1}/${d.getDate()}`
}

type Sel =
  | { kind: 'session'; id: string }
  | { kind: 'manual'; id: string }
  | { kind: 'history'; id: string; workdir: string }
  | null

// ===== 会话行(列表)=====
function Row({ title, badge, meta, model, time, active, onClick }: {
  title: string; badge?: { text: string; color: string }; meta: DotMeta
  model?: string; time?: string; active: boolean; onClick: () => void
}) {
  return (
    <button onClick={onClick}
      className="relative w-full text-left flex gap-2.5 rounded-[10px] mb-0.5 px-3 py-2.5 pl-3.5
        transition-colors hover:bg-sunken"
      style={active ? { background: 'var(--accent-soft)' } : undefined}>
      {active && <span className="absolute left-[3px] top-3 bottom-3 w-[3px] rounded-full" style={{ background: 'var(--accent)' }} />}
      <div className="min-w-0 flex-1">
        <div className="flex items-center gap-1.5">
          <span className="font-medium text-[13px] text-ink truncate">{title || '新会话'}</span>
          {badge && (
            <span className="text-[10px] font-medium px-1.5 py-px rounded shrink-0"
              style={{ color: badge.color, background: 'var(--bg-sunken)' }}>{badge.text}</span>
          )}
        </div>
        <div className="mt-[5px] flex items-center gap-[7px]">
          <Dot meta={meta} />
          <span className="text-[11px] text-dim">{meta.text}</span>
          {model && <>
            <span className="text-[11px] text-faint">·</span>
            <span className="font-mono text-[10.5px] text-faint truncate">{model}</span>
          </>}
          <span className="flex-1" />
          {time && <span className="text-[10.5px] text-faint shrink-0">{time}</span>}
        </div>
      </div>
    </button>
  )
}

function NewMenu({ workdir }: { workdir: string }) {
  const [open, setOpen] = useState(false)
  return (
    <div className="relative">
      <button onClick={() => setOpen((o) => !o)}
        className="flex items-center gap-1 pl-1.5 pr-2.5 py-1 rounded-[7px] text-[12px] font-medium text-accentfg transition hover:brightness-110"
        style={{ background: 'var(--accent)' }}>
        <Plus size={13} strokeWidth={2.4} />新建
      </button>
      {open && (
        <>
          <div className="fixed inset-0 z-30" onClick={() => setOpen(false)} />
          <div className="absolute right-0 mt-1.5 z-40 w-36 p-1.5 rounded-[11px] bg-elev border border-strong shadow-pop animate-pop">
            <button onClick={() => { cmd.continueLast(workdir); setOpen(false) }}
              className="w-full text-left px-2.5 py-1.5 text-[12.5px] text-ink rounded-lg hover:bg-sunken">继续最近</button>
            <button onClick={() => { cmd.newSession(workdir); setOpen(false) }}
              className="w-full text-left px-2.5 py-1.5 text-[12.5px] text-ink rounded-lg hover:bg-sunken">全新会话</button>
          </div>
        </>
      )}
    </div>
  )
}

// ===== 消息渲染 =====
function MessageRow({ m, onRespond }: { m: Msg; onRespond?: (reqId: string, choose: string[]) => void }) {
  if (m.kind === 'text' && m.role === 'user') {
    return (
      <div className="flex justify-end">
        <div className="max-w-[80%] px-3.5 py-2.5 text-[13px] leading-[1.6] whitespace-pre-wrap break-words select-text text-accentfg"
          style={{ background: 'var(--accent)', borderRadius: '14px 14px 4px 14px' }}>{m.text}</div>
      </div>
    )
  }
  if (m.kind === 'text') {
    return (
      <div className="flex gap-2.5">
        <div className="w-[22px] h-[22px] rounded-[7px] flex items-center justify-center text-[12px] shrink-0 mt-0.5"
          style={{ background: 'var(--accent-soft)', color: 'var(--accent)' }}>✦</div>
        <div className="flex-1 text-[13.5px] leading-[1.72] text-ink whitespace-pre-wrap break-words select-text">{m.text}</div>
      </div>
    )
  }
  if (m.kind === 'tool') {
    const i = m.text.indexOf(':')
    const name = i > 0 ? m.text.slice(0, i) : m.text
    const arg = i > 0 ? m.text.slice(i + 1).trim() : ''
    const isBash = name === 'Bash'
    if (isBash) {
      return (
        <div className="rounded-[11px] overflow-hidden border" style={{ background: 'var(--term-bg)', borderColor: 'var(--term-border)' }}>
          <div className="flex items-center gap-2 px-3.5 py-2.5 border-b" style={{ borderColor: 'var(--term-border)' }}>
            <span className="w-2 h-2 rounded-full shrink-0" style={{ background: 'var(--term-green)' }} />
            <span className="text-[12px] font-medium" style={{ color: 'var(--term-text)' }}>{name}</span>
          </div>
          {arg && (
            <pre className="px-4 py-3 font-mono text-[12px] leading-[1.75] overflow-x-auto whitespace-pre-wrap break-words select-text"
              style={{ color: 'var(--term-text)' }}>
              <span style={{ color: 'var(--term-dim)' }} className="select-none">$ </span>{arg}
            </pre>
          )}
        </div>
      )
    }
    return (
      <div className="rounded-[11px] overflow-hidden border border-line bg-elev">
        <div className="flex items-center gap-2 px-3.5 py-2.5">
          <span className="text-[12.5px] font-semibold text-ink">{name}</span>
        </div>
        {arg && <pre className="px-4 py-2.5 font-mono text-[12px] leading-relaxed bg-sunken text-dim whitespace-pre-wrap break-words select-text border-t border-line">{arg}</pre>}
      </div>
    )
  }
  if (m.kind === 'permission') {
    const r = m.permState
    const tone = r == null ? 'var(--amber)' : r === 'allow' ? 'var(--green)' : 'var(--red)'
    const label = r == null ? '需要你处理' : r === 'allow' ? '✓ 已允许' : '✕ 已拒绝'
    return (
      <div className="rounded-[11px] border p-3.5 animate-pop" style={{ borderColor: tone, background: 'var(--bg-elev2)' }}>
        <div className="text-[12px] font-semibold mb-2" style={{ color: tone }}>{label}</div>
        <pre className="font-mono text-[12px] rounded-lg p-2.5 bg-sunken text-ink whitespace-pre-wrap break-words select-text">{m.text}</pre>
        {r == null && onRespond && (
          <div className="mt-2.5 flex gap-2">
            <button onClick={() => onRespond(m.permReqId ?? '', ['deny'])}
              className="px-3.5 py-1.5 rounded-[9px] text-[12px] border border-strong text-dim hover:bg-sunken">拒绝</button>
            <button onClick={() => onRespond(m.permReqId ?? '', ['allow'])}
              className="px-4 py-1.5 rounded-[9px] text-[12px] font-medium text-accentfg hover:brightness-110"
              style={{ background: 'var(--accent)' }}>允许</button>
          </div>
        )}
      </div>
    )
  }
  return null
}

function MsgList({ msgs, onRespond, working }: {
  msgs: Msg[]; onRespond?: (r: string, c: string[]) => void; working?: boolean
}) {
  const ref = useRef<HTMLDivElement>(null)
  const ordered = useMemo(() => [...msgs].sort((a, b) => a.ord - b.ord), [msgs])
  useEffect(() => { const el = ref.current; if (el) el.scrollTop = el.scrollHeight }, [ordered.length, working])
  return (
    <div ref={ref} className="flex-1 overflow-y-auto overflow-x-hidden">
      <div className="max-w-[780px] mx-auto px-7 py-5 space-y-4">
        {ordered.map((m) => <div key={m.id} className="animate-msg"><MessageRow m={m} onRespond={onRespond} /></div>)}
        {working && (
          <div className="flex gap-2.5 animate-msg">
            <div className="w-[22px] h-[22px] rounded-[7px] flex items-center justify-center text-[12px] shrink-0"
              style={{ background: 'var(--accent-soft)', color: 'var(--accent)' }}>✦</div>
            <div className="flex items-center gap-1 py-1.5">
              <span className="w-1.5 h-1.5 rounded-full bg-faint typing-dot" />
              <span className="w-1.5 h-1.5 rounded-full bg-faint typing-dot" style={{ animationDelay: '.15s' }} />
              <span className="w-1.5 h-1.5 rounded-full bg-faint typing-dot" style={{ animationDelay: '.3s' }} />
            </div>
          </div>
        )}
      </div>
    </div>
  )
}

function WorkHeader({ title, meta, model, sub, right }: {
  title: string; meta?: DotMeta; model?: string; sub?: string; right?: React.ReactNode
}) {
  return (
    <div className="flex-none flex items-center gap-3 px-5 py-3 border-b border-line">
      <div className="flex-1 min-w-0">
        <div className="text-[15px] font-semibold text-ink truncate">{title}</div>
        <div className="flex items-center gap-2 mt-1">
          {meta && <Dot meta={meta} size={8} />}
          {meta && <span className="text-[11.5px] text-dim">{meta.text}</span>}
          {model && <><span className="text-[11.5px] text-faint">·</span><span className="font-mono text-[11px] text-faint">{model}</span></>}
          {sub && <><span className="text-[11.5px] text-faint">·</span><span className="text-[11.5px] text-faint truncate">{sub}</span></>}
        </div>
      </div>
      <div className="flex items-center gap-1.5">{right}</div>
    </div>
  )
}

function IconBtn({ title, onClick, children }: { title: string; onClick?: () => void; children: React.ReactNode }) {
  return (
    <button title={title} onClick={onClick}
      className="w-[30px] h-[30px] rounded-lg flex items-center justify-center text-dim hover:text-ink hover:bg-sunken transition-colors">
      {children}
    </button>
  )
}

// ===== 文件树 / 文件查看 / Tab =====
function TreeRow({ entry, depth, expanded, toggle, openFile }: {
  entry: Entry; depth: number; expanded: Set<string>
  toggle: (p: string) => void; openFile: (p: string) => void
}) {
  const dirs = useDirs()
  const isOpen = expanded.has(entry.path)
  const children = dirs[entry.path]
  return (
    <div>
      <button onClick={() => (entry.isDir ? toggle(entry.path) : openFile(entry.path))}
        className="w-full text-left flex items-center gap-1.5 py-[3px] pr-1 rounded-md hover:bg-sunken transition-colors"
        style={{ paddingLeft: depth * 12 + 4 }}>
        <span className="w-3 flex justify-center text-faint">
          {entry.isDir ? (isOpen ? <ChevronDown size={11} /> : <ChevronRight size={11} />) : null}
        </span>
        {entry.isDir
          ? (isOpen ? <FolderOpen size={13} className="shrink-0" style={{ color: 'var(--accent)' }} /> : <Folder size={13} className="text-faint shrink-0" />)
          : <FileIcon size={13} className="text-faint shrink-0" />}
        <span className="text-[12px] text-dim truncate">{entry.name}</span>
      </button>
      {entry.isDir && isOpen && (children ?? []).map((c) => (
        <TreeRow key={c.path} entry={c} depth={depth + 1} expanded={expanded} toggle={toggle} openFile={openFile} />
      ))}
    </div>
  )
}

function FileTree({ root, openFile }: { root: string; openFile: (p: string) => void }) {
  const dirs = useDirs()
  const [expanded, setExpanded] = useState<Set<string>>(new Set())
  useEffect(() => { if (!dirs[root]) cmd.listDir(root) }, [root, dirs])
  const toggle = (p: string) => {
    setExpanded((prev) => {
      const next = new Set(prev)
      if (next.has(p)) next.delete(p)
      else { next.add(p); if (!dirs[p]) cmd.listDir(p) }
      return next
    })
  }
  return (
    <div>
      {(dirs[root] ?? []).map((e) => (
        <TreeRow key={e.path} entry={e} depth={0} expanded={expanded} toggle={toggle} openFile={openFile} />
      ))}
    </div>
  )
}

function FileViewer({ path }: { path: string }) {
  const files = useFiles()
  const body = files[path]
  useEffect(() => { if (!body) cmd.loadFile(path) }, [path, body])
  const html = useMemo(() => {
    if (!body || body.text.length > 200_000) return null
    try {
      const lang = hljsLang(path)
      return lang && hljs.getLanguage(lang)
        ? hljs.highlight(body.text, { language: lang, ignoreIllegals: true }).value
        : hljs.highlightAuto(body.text).value
    } catch { return null }
  }, [body, path])
  return (
    <div className="h-full flex flex-col">
      <div className="px-5 py-2.5 border-b border-line flex items-center gap-2">
        <FileIcon size={13} className="text-faint" />
        <span className="text-[13px] font-semibold text-ink truncate">{path.split('/').pop()}</span>
        {body?.truncated && <span className="text-[11px]" style={{ color: 'var(--amber)' }}>已截断(仅前 2MB)</span>}
      </div>
      <div className="flex-1 min-h-0 overflow-auto">
        <pre className="text-[12px] font-mono leading-relaxed p-4 m-0 select-text">
          {html != null
            ? <code className="hljs" dangerouslySetInnerHTML={{ __html: html }} />
            : <code className="hljs">{body?.text ?? '加载中…'}</code>}
        </pre>
      </div>
    </div>
  )
}

function Tab({ label, active, closable, onTap, onClose }: {
  label: string; active: boolean; closable?: boolean; onTap: () => void; onClose?: () => void
}) {
  return (
    <div onClick={onTap}
      className={`flex items-center gap-1.5 px-3 py-1.5 rounded-lg cursor-pointer text-[12px] transition-colors
        ${active ? 'text-ink font-medium' : 'text-dim hover:bg-sunken'}`}
      style={active ? { background: 'var(--accent-soft)', color: 'var(--accent)' } : undefined}>
      <span className="truncate max-w-[140px]">{label}</span>
      {closable && (
        <span onClick={(e) => { e.stopPropagation(); onClose?.() }} className="text-faint hover:text-ink rounded p-0.5 hover:bg-sunken"><X size={11} /></span>
      )}
    </div>
  )
}

// ===== 输入框 =====
function Composer({ modelLabel, onSend }: { modelLabel: string; onSend: (t: string) => void }) {
  const [draft, setDraft] = useState('')
  const submit = () => { const t = draft.trim(); if (!t) return; onSend(t); setDraft('') }
  return (
    <div className="flex-none px-7 pb-4 pt-1">
      <div className="max-w-[780px] mx-auto rounded-[14px] border border-strong bg-elev shadow-card overflow-hidden">
        <textarea value={draft} onChange={(e) => setDraft(e.target.value)}
          onKeyDown={(e) => { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); submit() } }}
          rows={1} placeholder="描述你的需求…(Enter 发送,Shift+Enter 换行)"
          className="w-full resize-none bg-transparent outline-none px-4 pt-3.5 pb-1.5 text-[13px] text-ink select-text placeholder:text-faint" />
        <div className="flex items-center gap-1.5 px-2.5 pb-2.5 pt-0.5">
          <div className="w-7 h-7 rounded-[7px] flex items-center justify-center text-faint"><Paperclip size={15} /></div>
          <span className="flex-1" />
          <div className="flex items-center gap-1.5 px-2.5 py-1 rounded-lg border border-line text-[11.5px] text-dim">
            <span className="w-[7px] h-[7px] rounded-full" style={{ background: 'var(--accent)' }} />
            <span className="font-mono">{modelLabel}</span>
          </div>
          <button onClick={submit} disabled={!draft.trim()}
            className="w-8 h-8 rounded-[9px] flex items-center justify-center text-accentfg disabled:opacity-40 transition hover:brightness-110"
            style={{ background: 'var(--accent)' }}>
            <ArrowUp size={16} strokeWidth={2} />
          </button>
        </div>
      </div>
    </div>
  )
}

function Conversation({ s }: { s: Session }) {
  const model = s.agent === 'codex' ? 'Codex' : 'Claude'
  return (
    <div className="flex flex-col h-full bg-bg">
      <WorkHeader title={s.title || '会话'} meta={sessionMeta(s.status)} model={model} sub={s.workdir}
        right={<IconBtn title="结束会话" onClick={() => cmd.closeSession(s.id)}><X size={16} /></IconBtn>} />
      <MsgList msgs={s.messages} onRespond={(r, c) => cmd.respond(s.id, r, c)} working={s.status === 'working'} />
      <Composer modelLabel={model} onSend={(t) => cmd.sendInput(s.id, t)} />
    </div>
  )
}

function ManualView({ m, msgs }: { m: Manual; msgs: Msg[] }) {
  return (
    <div className="flex flex-col h-full bg-bg">
      <WorkHeader title={m.title} meta={manualMeta(m.state)} sub={m.cwd}
        right={
          <button onClick={() => cmd.raiseWindow(m.id)}
            className="flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-[12px] font-medium text-accentfg hover:brightness-110"
            style={{ background: 'var(--accent)' }}>
            <AppWindow size={13} /> 唤起 {m.terminal}
          </button>
        } />
      <MsgList msgs={msgs} />
      <div className="flex-none px-7 py-2.5 border-t border-line text-[11px] text-faint">手动会话:在 {m.terminal} 里输入,这里只读。</div>
    </div>
  )
}

function HistoryView({ h, msgs, onResume, resuming }: {
  h: History; msgs: Msg[]; onResume: () => void; resuming: boolean
}) {
  return (
    <div className="flex flex-col h-full bg-bg">
      <WorkHeader title={h.label} meta={{ text: '历史 · 只读', color: 'var(--text-faint)', hollow: true }}
        right={
          <button onClick={onResume} disabled={resuming}
            className="flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-[12px] font-medium text-accentfg hover:brightness-110 disabled:opacity-60"
            style={{ background: 'var(--accent)' }}>
            <RotateCcw size={13} className={resuming ? 'animate-spin' : ''} />{resuming ? '恢复中…' : 'Resume'}
          </button>
        } />
      <MsgList msgs={msgs} />
    </div>
  )
}

// ===== 工作区(控制台)=====
function ConsolePage() {
  const state = useAgent()
  const transcripts = useTranscripts()
  const [selectedProject, setSelectedProject] = useState<string | null>(null)
  const [sel, setSel] = useState<Sel>(null)
  const [openFiles, setOpenFiles] = useState<string[]>([])
  const [activeFile, setActiveFile] = useState<string | null>(null)
  const [pendingResume, setPendingResume] = useState<string | null>(null)
  const [query, setQuery] = useState('')
  const [filter, setFilter] = useState<'all' | 'running' | 'done'>('all')

  const doResume = (workdir: string, id: string) => {
    if (pendingResume) return
    setPendingResume(id); cmd.resume(workdir, id)
  }
  useEffect(() => {
    if (!pendingResume) return
    const s = state.sessions.find((x) => x.agentSessionId === pendingResume)
    if (s) { setSel({ kind: 'session', id: s.id }); setActiveFile(null); setPendingResume(null) }
  }, [state.sessions, pendingResume])

  useEffect(() => {
    if ((!selectedProject || !state.projects.some((p) => p.workdir === selectedProject)) && state.projects.length)
      setSelectedProject(state.projects[0].workdir)
  }, [state.projects, selectedProject])

  useEffect(() => {
    if (sel?.kind === 'history' && !transcripts[sel.id]) cmd.loadTranscript('history', sel.id, sel.workdir)
    if (sel?.kind === 'manual' && !transcripts[sel.id]) cmd.loadTranscript('manual', sel.id)
  }, [sel, transcripts])
  useEffect(() => {
    if (sel?.kind === 'session' && !state.sessions.some((s) => s.id === sel.id)) setSel(null)
    if (sel?.kind === 'manual' && !state.manual.some((m) => m.id === sel.id)) setSel(null)
  }, [state, sel])

  const inProject = (cwd: string, wd: string) => cwd === wd || cwd.startsWith(wd + '/')
  const project = state.projects.find((p) => p.workdir === selectedProject) ?? null

  // 当前项目的三类会话
  const consoleSessions = project ? state.sessions.filter((s) => s.workdir === project.workdir) : []
  const manualList = project ? state.manual.filter((m) => inProject(m.cwd, project.workdir)) : []
  const liveIds = new Set<string>([
    ...consoleSessions.map((s) => s.agentSessionId).filter(Boolean) as string[],
    ...manualList.map((m) => m.id),
  ])
  const historyList = project ? project.history.filter((h) => !liveIds.has(h.id)) : []

  const isRunning = {
    session: (s: Session) => !['done', 'error'].includes(s.status),
    manual: (m: Manual) => m.state === 'working' || m.state === 'waiting',
  }
  const counts = {
    all: consoleSessions.length + manualList.length + historyList.length,
    running: consoleSessions.filter(isRunning.session).length + manualList.filter(isRunning.manual).length,
    done: 0,
  }
  counts.done = counts.all - counts.running

  const q = query.trim().toLowerCase()
  const match = (t: string) => !q || t.toLowerCase().includes(q)
  const fSessions = consoleSessions.filter((s) => match(s.title)
    && (filter === 'all' || (filter === 'running' ? isRunning.session(s) : !isRunning.session(s))))
  const fManual = manualList.filter((m) => match(m.title)
    && (filter === 'all' || (filter === 'running' ? isRunning.manual(m) : !isRunning.manual(m))))
  const fHistory = historyList.filter((h) => match(h.label) && filter !== 'running')

  const openFile = (p: string) => { setOpenFiles((prev) => (prev.includes(p) ? prev : [...prev, p])); setActiveFile(p) }
  const closeFile = (p: string) => {
    setOpenFiles((prev) => prev.filter((x) => x !== p))
    setActiveFile((cur) => (cur === p ? null : cur))
  }
  const pick = (s: Sel) => { setSel(s); setActiveFile(null) }

  const sessionView = useMemo(() => {
    if (!sel) return (
      <div className="h-full flex flex-col items-center justify-center text-faint gap-3">
        <div className="w-12 h-12 rounded-2xl flex items-center justify-center" style={{ background: 'var(--accent-soft)', color: 'var(--accent)' }}><PanelsTopLeft size={22} /></div>
        <div className="text-[13px]">选择左侧会话,或点「新建」</div>
      </div>
    )
    if (sel.kind === 'session') { const s = state.sessions.find((x) => x.id === sel.id); return s ? <Conversation s={s} /> : null }
    if (sel.kind === 'manual') { const m = state.manual.find((x) => x.id === sel.id); return m ? <ManualView m={m} msgs={transcripts[m.id] ?? []} /> : null }
    const h = state.projects.flatMap((p) => p.history).find((x) => x.id === sel.id)
    const wd = (sel as any).workdir
    return h ? <HistoryView h={h} msgs={transcripts[h.id] ?? []} onResume={() => doResume(wd, h.id)} resuming={pendingResume === h.id} /> : null
  }, [sel, state, transcripts, pendingResume])

  const FILTERS: { k: typeof filter; label: string }[] = [
    { k: 'all', label: '全部' }, { k: 'running', label: '进行中' }, { k: 'done', label: '已完成' },
  ]

  return (
    <div className="flex h-full flex-1 min-w-0">
      {/* 列1:项目 + 嵌套文件树 */}
      <div className="w-[230px] shrink-0 bg-elev border-r border-line flex flex-col">
        <div className="titlebar-pad px-3 pb-2 flex items-center justify-between">
          <span className="text-[11px] font-semibold text-faint tracking-[0.05em] uppercase">项目</span>
          <IconBtn title="打开项目" onClick={() => cmd.openProject()}><FolderPlus size={15} /></IconBtn>
        </div>
        <div className="flex-1 overflow-auto px-2 pb-3">
          {state.projects.length === 0 && <div className="text-[11px] text-dim px-1 py-3 leading-relaxed">点右上角打开一个项目。</div>}
          {state.projects.map((p) => {
            const cnt = state.sessions.filter((s) => s.workdir === p.workdir).length
            const active = p.workdir === selectedProject
            return (
              <div key={p.workdir}>
                <button onClick={() => { setSelectedProject(p.workdir); setSel(null); setActiveFile(null) }}
                  className="w-full text-left flex items-center gap-2.5 px-2.5 py-2 rounded-[10px] transition-colors hover:bg-sunken"
                  style={active ? { background: 'var(--accent-soft)' } : undefined}>
                  <div className="w-7 h-7 shrink-0 rounded-lg flex items-center justify-center"
                    style={active ? { background: 'var(--accent-soft)', color: 'var(--accent)' } : { background: 'var(--bg-sunken)', color: 'var(--text-faint)' }}>
                    {active ? <FolderOpen size={15} /> : <Folder size={15} />}
                  </div>
                  <div className="min-w-0 flex-1">
                    <div className="text-[12.5px] font-medium text-ink truncate">{p.name}</div>
                    <div className="font-mono text-[10px] text-faint truncate">{cnt ? `${cnt} 个会话` : p.workdir.replace(/^.*\//, '~/…/')}</div>
                  </div>
                </button>
                {active && (
                  <div className="ml-3.5 mt-0.5 pl-1 border-l border-line">
                    <FileTree root={p.workdir} openFile={openFile} />
                  </div>
                )}
              </div>
            )
          })}
        </div>
      </div>

      {/* 列2:会话 */}
      <div className="w-[300px] shrink-0 bg-elev border-r border-line flex flex-col">
        {project ? (
          <>
            <div className="titlebar-pad px-3 pb-2 flex items-center justify-between gap-2">
              <span className="text-[13px] font-semibold text-ink truncate">{project.name}</span>
              <NewMenu workdir={project.workdir} />
            </div>
            {/* 搜索 */}
            <div className="px-3 pb-2">
              <div className="flex items-center gap-2 px-2.5 py-1.5 rounded-lg" style={{ background: 'var(--bg-sunken)' }}>
                <Search size={13} className="text-faint shrink-0" />
                <input value={query} onChange={(e) => setQuery(e.target.value)} placeholder="搜索会话…"
                  className="flex-1 bg-transparent outline-none text-[12px] text-ink select-text placeholder:text-faint min-w-0" />
              </div>
            </div>
            {/* 过滤 */}
            <div className="px-3 pb-2 flex gap-1.5">
              {FILTERS.map((f) => {
                const on = filter === f.k
                return (
                  <button key={f.k} onClick={() => setFilter(f.k)}
                    className="px-2.5 py-1 rounded-lg text-[12px] transition-colors"
                    style={on ? { background: 'var(--accent-soft)', color: 'var(--accent)', fontWeight: 500 }
                      : { background: 'var(--bg-sunken)', color: 'var(--text-dim)' }}>
                    {f.label}<span className="ml-1.5 opacity-55">{counts[f.k]}</span>
                  </button>
                )
              })}
            </div>
            <div className="flex-1 overflow-auto px-2 pb-3">
              <SessionList sessions={fSessions} manual={fManual} history={fHistory}
                empty={counts.all === 0} workdir={project.workdir} sel={sel} setSel={pick} />
            </div>
          </>
        ) : <div className="titlebar-pad px-3 text-[12px] text-dim">选择左侧项目</div>}
      </div>

      {/* 列3:tab + 内容 */}
      <div className="flex-1 min-w-0 flex flex-col bg-bg">
        <div className="titlebar-pad px-2 pb-1.5 flex items-center gap-1 overflow-x-auto border-b border-line bg-elev">
          <Tab label="会话" active={activeFile === null} onTap={() => setActiveFile(null)} />
          {openFiles.map((p) => (
            <Tab key={p} label={p.split('/').pop() ?? p} active={activeFile === p} closable
              onTap={() => setActiveFile(p)} onClose={() => closeFile(p)} />
          ))}
        </div>
        <div className="flex-1 min-h-0">
          <div key={activeFile ?? (sel ? sel.kind + sel.id : 'empty')} className="h-full animate-conv">
            {activeFile ? <FileViewer path={activeFile} /> : sessionView}
          </div>
        </div>
      </div>
    </div>
  )
}

function SessionList({ sessions, manual, history, empty, workdir, sel, setSel }: {
  sessions: Session[]; manual: Manual[]; history: History[]; empty: boolean
  workdir: string; sel: Sel; setSel: (s: Sel) => void
}) {
  const [histOpen, setHistOpen] = useState(true)
  return (
    <>
      {sessions.map((s) => (
        <Row key={s.id} active={sel?.kind === 'session' && sel.id === s.id}
          title={s.title} meta={sessionMeta(s.status)} model={s.agent === 'codex' ? 'Codex' : 'Claude'}
          time={relTime(s.startedAt)} onClick={() => setSel({ kind: 'session', id: s.id })} />
      ))}
      {manual.map((m) => (
        <Row key={m.id} active={sel?.kind === 'manual' && sel.id === m.id}
          title={m.title} badge={{ text: '手动', color: 'var(--amber)' }} meta={manualMeta(m.state)}
          model={m.terminal} time={relTime(m.lastActivityAt)} onClick={() => setSel({ kind: 'manual', id: m.id })} />
      ))}
      {history.length > 0 && (
        <div className="pt-1.5">
          <button onClick={() => setHistOpen((o) => !o)}
            className="w-full flex items-center gap-1 px-1 py-1 text-[10.5px] font-semibold text-faint tracking-[0.05em] uppercase hover:text-dim transition-colors">
            {histOpen ? <ChevronDown size={11} /> : <ChevronRight size={11} />}历史会话 · {history.length}
          </button>
          {histOpen && history.map((h) => (
            <Row key={h.id} active={sel?.kind === 'history' && sel.id === h.id}
              title={h.label} badge={{ text: '历史', color: 'var(--text-faint)' }}
              meta={{ text: '已结束', color: 'var(--text-faint)', hollow: true }}
              time={relTime(h.mtime)} onClick={() => setSel({ kind: 'history', id: h.id, workdir })} />
          ))}
        </div>
      )}
      {empty && <div className="text-[11px] text-faint px-1 pb-1">未打开会话</div>}
    </>
  )
}

// ===== 使用统计(占位,沿用设计语言)=====
function UsagePage() {
  return (
    <div className="flex-1 overflow-y-auto bg-bg">
      <div className="max-w-[920px] mx-auto px-8 pt-8 pb-12">
        <div className="text-[20px] font-semibold text-ink">使用统计</div>
        <div className="text-[12.5px] text-dim mt-1">这个页面之后接入真实数据。</div>
        <div className="grid grid-cols-4 gap-3.5 mt-6">
          {[['总 Token', '—'], ['花费', '—'], ['缓存命中', '—'], ['请求数', '—']].map(([l, v]) => (
            <div key={l} className="p-4 rounded-[13px] border border-line bg-elev">
              <div className="text-[11.5px] text-dim">{l}</div>
              <div className="text-[24px] font-semibold mt-2 text-faint">{v}</div>
            </div>
          ))}
        </div>
      </div>
    </div>
  )
}

function SettingsPage({ theme, setTheme }: { theme: string; setTheme: (t: 'light' | 'dark') => void }) {
  return (
    <div className="flex-1 overflow-y-auto bg-bg">
      <div className="max-w-[640px] mx-auto px-8 pt-8 pb-12">
        <div className="text-[20px] font-semibold text-ink mb-6">设置</div>
        <div className="text-[11px] font-semibold tracking-[0.05em] uppercase text-faint mb-2.5">外观</div>
        <div className="border border-line rounded-[13px] bg-elev">
          <div className="flex items-center px-4 py-4">
            <div className="flex-1">
              <div className="text-[13px] font-medium text-ink">主题</div>
              <div className="text-[11.5px] text-dim mt-0.5">浅色 / 深色外观</div>
            </div>
            <div className="flex gap-1 p-[3px] rounded-[9px]" style={{ background: 'var(--bg-sunken)' }}>
              {(['light', 'dark'] as const).map((t) => (
                <button key={t} onClick={() => setTheme(t)}
                  className="px-3.5 py-1.5 rounded-[7px] text-[12px] transition"
                  style={theme === t ? { background: 'var(--bg-elev)', fontWeight: 500, boxShadow: '0 1px 2px rgba(0,0,0,.1)' } : { color: 'var(--text-dim)' }}>
                  {t === 'light' ? '浅色' : '深色'}
                </button>
              ))}
            </div>
          </div>
        </div>
      </div>
    </div>
  )
}

// ===== 左侧导航 =====
function NavRail({ page, setPage, theme, toggleTheme }: {
  page: string; setPage: (p: string) => void; theme: string; toggleTheme: () => void
}) {
  const items = [
    { id: 'console', icon: <PanelsTopLeft size={19} />, label: '工作区' },
    { id: 'usage', icon: <BarChart3 size={19} />, label: '使用统计' },
    { id: 'settings', icon: <SlidersHorizontal size={19} />, label: '设置' },
  ]
  const btn = (on: boolean) => ({
    width: 38, height: 38, ...(on ? { background: 'var(--accent-soft)', color: 'var(--accent)' } : {}),
  } as React.CSSProperties)
  return (
    <div className="w-[56px] shrink-0 bg-elev border-r border-line flex flex-col items-center pt-3 gap-1">
      {items.map((it) => {
        const on = page === it.id
        return (
          <button key={it.id} onClick={() => setPage(it.id)} title={it.label}
            className={`rounded-[10px] flex items-center justify-center transition-colors ${on ? '' : 'text-dim hover:bg-sunken'}`}
            style={btn(on)}>{it.icon}</button>
        )
      })}
      <div className="flex-1" />
      <button title="切换主题" onClick={toggleTheme}
        className="w-[38px] h-[38px] rounded-[10px] flex items-center justify-center text-dim hover:bg-sunken hover:text-ink transition-colors mb-3">
        {theme === 'dark' ? <Sun size={18} /> : <Moon size={16} />}
      </button>
    </div>
  )
}

export default function App() {
  const [page, setPage] = useState('console')
  const [theme, setThemeState] = useState<'light' | 'dark'>(() =>
    (localStorage.getItem('theme') as 'light' | 'dark') || 'light')
  useEffect(() => {
    document.documentElement.setAttribute('data-theme', theme)
    localStorage.setItem('theme', theme)
    cmd.setTheme(theme === 'dark')
  }, [theme])
  const setTheme = (t: 'light' | 'dark') => setThemeState(t)
  const toggleTheme = () => setThemeState((t) => (t === 'dark' ? 'light' : 'dark'))
  return (
    <div className="flex h-full">
      <NavRail page={page} setPage={setPage} theme={theme} toggleTheme={toggleTheme} />
      {page === 'console' ? <ConsolePage />
        : page === 'usage' ? <UsagePage />
        : <SettingsPage theme={theme} setTheme={setTheme} />}
    </div>
  )
}
