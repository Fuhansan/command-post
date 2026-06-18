import { useSyncExternalStore, useState, useMemo, useRef, useEffect, useLayoutEffect } from 'react'
import hljs from 'highlight.js'
import {
  Folder, ChevronRight, ChevronDown, ChevronsUpDown, ArrowUp,
  RotateCcw, AppWindow, Plus, X, Paperclip, Sun, Moon, SlidersHorizontal,
  BarChart3, PanelsTopLeft, Search, Copy, FileText, Check, Server, MoreHorizontal,
} from 'lucide-react'
import { subscribe, getState, getTranscripts, getTranscriptMeta, getDirs, getFiles, getUsage } from './store'
import { cmd } from './bridge'
import type { Session, Msg, Manual, History, Project, Entry } from './types'

const HLJS_EXT: Record<string, string> = {
  ts: 'typescript', tsx: 'typescript', js: 'javascript', jsx: 'javascript', mjs: 'javascript',
  swift: 'swift', py: 'python', rb: 'ruby', go: 'go', rs: 'rust', java: 'java', kt: 'kotlin',
  json: 'json', md: 'markdown', html: 'xml', css: 'css', scss: 'scss', sh: 'bash', bash: 'bash',
  yml: 'yaml', yaml: 'yaml', xml: 'xml', sql: 'sql', c: 'c', cpp: 'cpp', cc: 'cpp', h: 'cpp',
  hpp: 'cpp', php: 'php', toml: 'ini', ini: 'ini',
}
const fileExt = (p: string) => p.split('.').pop()?.toLowerCase() ?? ''
const hljsLang = (p: string) => HLJS_EXT[fileExt(p)]

function useAgent() { return useSyncExternalStore(subscribe, getState, getState) }
function useTranscripts() { return useSyncExternalStore(subscribe, getTranscripts, getTranscripts) }
function useTranscriptMeta() { return useSyncExternalStore(subscribe, getTranscriptMeta, getTranscriptMeta) }
function useDirs() { return useSyncExternalStore(subscribe, getDirs, getDirs) }
function useFiles() { return useSyncExternalStore(subscribe, getFiles, getFiles) }
function useUsage() { return useSyncExternalStore(subscribe, getUsage, getUsage) }

// ===== 状态 → 圆点 + 文案 =====
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
  const base: React.CSSProperties = { width: size, height: size, borderRadius: '50%', flex: 'none', display: 'inline-block' }
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

// ===== 会话行 =====
function Row({ title, badge, meta, model, time, active, onClick }: {
  title: string; badge?: { text: string; color: string }; meta: DotMeta
  model?: string; time?: string; active: boolean; onClick: () => void
}) {
  return (
    <button onClick={onClick}
      className="relative w-full text-left flex gap-2.5 rounded-[10px] mb-0.5 px-3 py-2.5 pl-3.5 transition-colors hover:bg-sunken"
      style={active ? { background: 'var(--accent-soft)' } : undefined}>
      {active && <span className="absolute left-[3px] top-3 bottom-3 w-[3px] rounded-full" style={{ background: 'var(--accent)' }} />}
      <div className="min-w-0 flex-1">
        <div className="flex items-center gap-1.5">
          <span className="font-medium text-[13px] text-ink truncate">{title || '新会话'}</span>
          {badge && <span className="text-[10px] font-medium px-1.5 py-px rounded shrink-0" style={{ color: badge.color, background: 'var(--bg-sunken)' }}>{badge.text}</span>}
        </div>
        <div className="mt-[5px] flex items-center gap-[7px]">
          <Dot meta={meta} />
          <span className="text-[11px] text-dim">{meta.text}</span>
          {model && <><span className="text-[11px] text-faint">·</span><span className="font-mono text-[10.5px] text-faint truncate">{model}</span></>}
          <span className="flex-1" />
          {time && <span className="text-[10.5px] text-faint shrink-0">{time}</span>}
        </div>
      </div>
    </button>
  )
}

// ===== 消息渲染 =====
function MessageRow({ m, onRespond }: { m: Msg; onRespond?: (reqId: string, choose: string[]) => void }) {
  if (m.kind === 'text' && m.role === 'user') {
    return (
      <div className="flex justify-end">
        <div className="max-w-[78%] px-3.5 py-2.5 text-[13px] leading-[1.6] whitespace-pre-wrap break-words select-text text-accentfg"
          style={{ background: 'var(--accent)', borderRadius: '14px 14px 4px 14px' }}>{m.text}</div>
      </div>
    )
  }
  if (m.kind === 'text') {
    return (
      <div className="flex gap-2.5">
        <div className="w-[22px] h-[22px] rounded-[7px] flex items-center justify-center text-[12px] shrink-0 mt-0.5" style={{ background: 'var(--accent-soft)', color: 'var(--accent)' }}>✦</div>
        <div className="flex-1 text-[13.5px] leading-[1.72] text-ink whitespace-pre-wrap break-words select-text">{m.text}</div>
      </div>
    )
  }
  if (m.kind === 'tool') {
    const i = m.text.indexOf(':')
    const name = i > 0 ? m.text.slice(0, i) : m.text
    const arg = i > 0 ? m.text.slice(i + 1).trim() : ''
    if (name === 'Bash') {
      return (
        <div className="rounded-[11px] overflow-hidden border" style={{ background: 'var(--term-bg)', borderColor: 'var(--term-border)' }}>
          <div className="flex items-center gap-2 px-3.5 py-2.5 border-b" style={{ borderColor: 'var(--term-border)' }}>
            <span className="w-2 h-2 rounded-full shrink-0" style={{ background: 'var(--term-green)' }} />
            <span className="text-[12px] font-medium" style={{ color: 'var(--term-text)' }}>{name}</span>
          </div>
          {arg && (
            <pre className="px-4 py-3 font-mono text-[12px] leading-[1.75] overflow-x-auto whitespace-pre-wrap break-words select-text" style={{ color: 'var(--term-text)' }}>
              <span style={{ color: 'var(--term-dim)' }} className="select-none">$ </span>{arg}
            </pre>
          )}
        </div>
      )
    }
    return (
      <div className="rounded-[11px] overflow-hidden border border-line bg-elev">
        <div className="flex items-center gap-2 px-3.5 py-2.5"><span className="text-[12.5px] font-semibold text-ink">{name}</span></div>
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
            <button onClick={() => onRespond(m.permReqId ?? '', ['deny'])} className="px-3.5 py-1.5 rounded-[9px] text-[12px] border border-strong text-dim hover:bg-sunken">拒绝</button>
            <button onClick={() => onRespond(m.permReqId ?? '', ['allow'])} className="px-4 py-1.5 rounded-[9px] text-[12px] font-medium text-accentfg hover:brightness-110" style={{ background: 'var(--accent)' }}>允许</button>
          </div>
        )}
      </div>
    )
  }
  return null
}

function MsgList({ msgs, onRespond, working, animate = true, hasEarlier, onLoadEarlier }: {
  msgs: Msg[]; onRespond?: (r: string, c: string[]) => void; working?: boolean
  animate?: boolean; hasEarlier?: boolean; onLoadEarlier?: () => void
}) {
  const ref = useRef<HTMLDivElement>(null)
  const ordered = useMemo(() => [...msgs].sort((a, b) => a.ord - b.ord), [msgs])
  const prevFirst = useRef<number | undefined>(undefined)
  const prevH = useRef(0)
  const [loading, setLoading] = useState(false)
  // 末尾新消息/首次:滚到底;顶部插入「更早」消息:保持当前可视位置不跳。
  useLayoutEffect(() => {
    const el = ref.current; if (!el) return
    const firstOrd = ordered[0]?.ord
    if (prevFirst.current !== undefined && firstOrd !== undefined && firstOrd < prevFirst.current)
      el.scrollTop = el.scrollTop + (el.scrollHeight - prevH.current)
    else
      el.scrollTop = el.scrollHeight
    prevFirst.current = firstOrd
    prevH.current = el.scrollHeight
  }, [ordered, working])
  useEffect(() => { setLoading(false) }, [ordered.length, hasEarlier])
  return (
    <div ref={ref} className="flex-1 overflow-y-auto overflow-x-hidden">
      <div className="max-w-[780px] mx-auto px-7 py-5 space-y-4">
        {hasEarlier && (
          <div className="flex justify-center pb-1">
            <button onClick={() => { if (onLoadEarlier && !loading) { setLoading(true); onLoadEarlier() } }} disabled={loading}
              className="px-3.5 py-1.5 rounded-lg text-[12px] text-dim border border-line hover:bg-sunken disabled:opacity-60 transition-colors">
              {loading ? '加载中…' : '加载更早'}
            </button>
          </div>
        )}
        {ordered.map((m) => <div key={m.id} className={animate ? 'animate-msg' : undefined}><MessageRow m={m} onRespond={onRespond} /></div>)}
        {working && (
          <div className="flex gap-2.5 animate-msg">
            <div className="w-[22px] h-[22px] rounded-[7px] flex items-center justify-center text-[12px] shrink-0" style={{ background: 'var(--accent-soft)', color: 'var(--accent)' }}>✦</div>
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

function IconBtn({ title, onClick, children }: { title: string; onClick?: () => void; children: React.ReactNode }) {
  return (
    <button title={title} onClick={onClick} className="w-[30px] h-[30px] rounded-lg flex items-center justify-center text-dim hover:text-ink hover:bg-sunken transition-colors">{children}</button>
  )
}

function WorkHeader({ title, meta, model, sub, right }: { title: string; meta?: DotMeta; model?: string; sub?: string; right?: React.ReactNode }) {
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
      <div className="flex items-center gap-1">{right}</div>
    </div>
  )
}

// claude-opus-4-8 → "Opus 4.8";opus → "Opus"
function modelFamily(m?: string): 'opus' | 'sonnet' | 'haiku' | null {
  if (!m) return null
  const s = m.toLowerCase()
  return s.includes('opus') ? 'opus' : s.includes('sonnet') ? 'sonnet' : s.includes('haiku') ? 'haiku' : null
}
function modelLabel(m?: string): string {
  if (!m) return '默认'
  const fam = modelFamily(m)
  if (!fam) return m
  const name = fam.charAt(0).toUpperCase() + fam.slice(1)
  const ver = m.toLowerCase().match(/(\d+)-(\d+)/)   // claude-opus-4-8 → 4-8
  return ver ? `${name} ${ver[1]}.${ver[2]}` : name
}
const MODELS: { alias: string; label: string }[] = [
  { alias: 'opus', label: 'Opus' }, { alias: 'sonnet', label: 'Sonnet' }, { alias: 'haiku', label: 'Haiku' },
]

// ===== 输入框 =====
function Composer({ sid, model, onSend }: { sid: string; model?: string; onSend: (t: string) => void }) {
  const [draft, setDraft] = useState('')
  const [menu, setMenu] = useState(false)
  const cur = modelLabel(model)
  const submit = () => { const t = draft.trim(); if (!t) return; onSend(t); setDraft('') }
  return (
    <div className="flex-none px-7 pb-[18px] pt-1">
      <div className="max-w-[780px] mx-auto rounded-[14px] border border-strong bg-elev shadow-card relative">
        <textarea value={draft} onChange={(e) => setDraft(e.target.value)}
          onKeyDown={(e) => { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); submit() } }}
          rows={1} placeholder="描述你的需求,或输入 / 调用快捷命令…"
          className="w-full resize-none bg-transparent outline-none px-4 pt-3.5 pb-1.5 text-[13px] text-ink select-text placeholder:text-faint" />
        <div className="flex items-center gap-1.5 px-2.5 pb-2.5 pt-0.5">
          <div className="w-7 h-7 rounded-[7px] flex items-center justify-center text-faint"><Paperclip size={15} /></div>
          <div className="w-7 h-7 rounded-[7px] flex items-center justify-center text-faint font-mono text-[14px]">/</div>
          <span className="flex-1" />
          {/* 模型切换 */}
          <button onClick={() => setMenu((o) => !o)}
            className="flex items-center gap-1.5 px-2.5 py-1 rounded-lg border border-line text-[11.5px] text-dim hover:bg-sunken transition-colors">
            <span className="w-[7px] h-[7px] rounded-full" style={{ background: 'var(--accent)' }} />
            <span className="font-mono">{cur}</span>
            <ChevronDown size={12} />
          </button>
          {menu && (
            <>
              <div className="fixed inset-0 z-30" onClick={() => setMenu(false)} />
              <div className="absolute right-12 bottom-12 z-40 min-w-[150px] p-1.5 rounded-[11px] bg-elev border border-strong shadow-pop animate-pop">
                {MODELS.map((m) => {
                  const on = modelFamily(model) === m.alias
                  return (
                    <button key={m.alias} onClick={() => { setMenu(false); if (!on) cmd.switchModel(sid, m.alias) }}
                      className="w-full flex items-center gap-2 px-2.5 py-1.5 rounded-lg text-[12.5px] text-ink hover:bg-sunken"
                      style={on ? { background: 'var(--bg-sunken)' } : undefined}>
                      <span className="font-mono flex-1 text-left">{on ? cur : m.label}</span>
                      {on && <Check size={14} style={{ color: 'var(--accent)' }} />}
                    </button>
                  )
                })}
                <div className="text-[10px] text-faint px-2.5 pt-1 pb-0.5 leading-snug">切换=用新模型 resume,会短暂重连</div>
              </div>
            </>
          )}
          <button onClick={submit} disabled={!draft.trim()}
            className="w-8 h-8 rounded-[9px] flex items-center justify-center text-accentfg disabled:opacity-40 transition hover:brightness-110" style={{ background: 'var(--accent)' }}>
            <ArrowUp size={16} strokeWidth={2} />
          </button>
        </div>
      </div>
    </div>
  )
}

function Conversation({ s }: { s: Session }) {
  return (
    <div className="flex flex-col h-full bg-bg">
      <WorkHeader title={s.title || '会话'} meta={sessionMeta(s.status)} model={modelLabel(s.model)} sub={s.workdir}
        right={<>
          <IconBtn title="更多"><MoreHorizontal size={16} /></IconBtn>
          <IconBtn title="结束会话" onClick={() => cmd.closeSession(s.id)}><X size={16} /></IconBtn>
        </>} />
      <MsgList msgs={s.messages} onRespond={(r, c) => cmd.respond(s.id, r, c)} working={s.status === 'working'} />
      <Composer sid={s.id} model={s.model} onSend={(t) => cmd.sendInput(s.id, t)} />
    </div>
  )
}

function ManualView({ m, msgs, hasEarlier, onLoadEarlier }: { m: Manual; msgs: Msg[]; hasEarlier?: boolean; onLoadEarlier?: () => void }) {
  return (
    <div className="flex flex-col h-full bg-bg">
      <WorkHeader title={m.title} meta={manualMeta(m.state)} sub={m.cwd}
        right={<button onClick={() => cmd.raiseWindow(m.id)} className="flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-[12px] font-medium text-accentfg hover:brightness-110" style={{ background: 'var(--accent)' }}><AppWindow size={13} /> 唤起 {m.terminal}</button>} />
      <MsgList msgs={msgs} animate={false} hasEarlier={hasEarlier} onLoadEarlier={onLoadEarlier} />
      <div className="flex-none px-7 py-2.5 border-t border-line text-[11px] text-faint">手动会话:在 {m.terminal} 里输入,这里只读。</div>
    </div>
  )
}

function HistoryView({ h, msgs, onResume, resuming, hasEarlier, onLoadEarlier }: {
  h: History; msgs: Msg[]; onResume: () => void; resuming: boolean; hasEarlier?: boolean; onLoadEarlier?: () => void
}) {
  return (
    <div className="flex flex-col h-full bg-bg">
      <WorkHeader title={h.label} meta={{ text: '历史 · 只读', color: 'var(--text-faint)', hollow: true }}
        right={<button onClick={onResume} disabled={resuming} className="flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-[12px] font-medium text-accentfg hover:brightness-110 disabled:opacity-60" style={{ background: 'var(--accent)' }}><RotateCcw size={13} className={resuming ? 'animate-spin' : ''} />{resuming ? '恢复中…' : 'Resume'}</button>} />
      <MsgList msgs={msgs} animate={false} hasEarlier={hasEarlier} onLoadEarlier={onLoadEarlier} />
    </div>
  )
}

// ===== 文件树(文件 tab)=====
function TreeRow({ entry, depth, expanded, toggle, openFile, active }: {
  entry: Entry; depth: number; expanded: Set<string>
  toggle: (p: string) => void; openFile: (p: string) => void; active: string | null
}) {
  const dirs = useDirs()
  const isOpen = expanded.has(entry.path)
  const children = dirs[entry.path]
  const isActive = active === entry.path
  return (
    <div>
      <button onClick={() => (entry.isDir ? toggle(entry.path) : openFile(entry.path))}
        className="w-full text-left flex items-center gap-1.5 py-[5px] pr-2 rounded-[7px] hover:bg-sunken transition-colors"
        style={{ paddingLeft: depth * 13 + 8, ...(isActive ? { background: 'var(--accent-soft)' } : {}) }}>
        {entry.isDir
          ? <ChevronRight size={12} strokeWidth={2.4} className="text-faint shrink-0 transition-transform" style={{ transform: isOpen ? 'rotate(90deg)' : 'none' }} />
          : <span className="w-3 shrink-0" />}
        {entry.isDir
          ? <Folder size={15} className="shrink-0" style={{ color: 'var(--accent)' }} />
          : <FileText size={15} className="text-faint shrink-0" />}
        <span className="text-[12.5px] truncate" style={{ color: isActive ? 'var(--accent)' : 'var(--text)', fontFamily: entry.isDir ? undefined : '"Geist Mono Variable", monospace' }}>{entry.name}</span>
      </button>
      {entry.isDir && isOpen && (children ?? []).map((c) => (
        <TreeRow key={c.path} entry={c} depth={depth + 1} expanded={expanded} toggle={toggle} openFile={openFile} active={active} />
      ))}
    </div>
  )
}

function FileTree({ root, openFile, active }: { root: string; openFile: (p: string) => void; active: string | null }) {
  const dirs = useDirs()
  const [expanded, setExpanded] = useState<Set<string>>(new Set())
  useEffect(() => { if (!dirs[root]) cmd.listDir(root) }, [root, dirs])
  const toggle = (p: string) => setExpanded((prev) => {
    const next = new Set(prev)
    if (next.has(p)) next.delete(p); else { next.add(p); if (!dirs[p]) cmd.listDir(p) }
    return next
  })
  return (
    <div>
      {(dirs[root] ?? []).map((e) => <TreeRow key={e.path} entry={e} depth={0} expanded={expanded} toggle={toggle} openFile={openFile} active={active} />)}
      {!dirs[root] && <div className="text-[11px] text-faint px-2 py-2">加载中…</div>}
    </div>
  )
}

// ===== 文件查看器(在工作区,带行号)=====
function FileViewer({ path, onClose }: { path: string; onClose: () => void }) {
  const files = useFiles()
  const body = files[path]
  const [copied, setCopied] = useState(false)
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
  const lineCount = body ? body.text.split('\n').length : 0
  const gutter = useMemo(() => Array.from({ length: lineCount }, (_, i) => i + 1).join('\n'), [lineCount])
  const copy = () => { if (body) { navigator.clipboard?.writeText(body.text); setCopied(true); setTimeout(() => setCopied(false), 1200) } }
  return (
    <div className="flex flex-col h-full bg-elev">
      <div className="flex-none flex items-center gap-2.5 px-5 py-3 border-b border-line">
        <FileText size={16} className="text-dim shrink-0" />
        <span className="font-mono text-[13px] font-medium text-ink flex-1 min-w-0 truncate">{path.split('/').pop()}</span>
        <span className="text-[10.5px] px-2 py-0.5 rounded font-mono" style={{ background: 'var(--bg-sunken)', color: 'var(--text-dim)' }}>{hljsLang(path) ?? fileExt(path) ?? 'txt'}</span>
        {body?.truncated && <span className="text-[11px]" style={{ color: 'var(--amber)' }}>已截断</span>}
        <IconBtn title={copied ? '已复制' : '复制'} onClick={copy}>{copied ? <Check size={15} style={{ color: 'var(--green)' }} /> : <Copy size={15} />}</IconBtn>
        <IconBtn title="关闭" onClick={onClose}><X size={16} /></IconBtn>
      </div>
      <div className="flex-1 overflow-auto">
        <div className="flex font-mono text-[12.5px] leading-[1.7] py-3.5 min-h-full">
          <pre className="flex-none px-3.5 text-right m-0 select-none" style={{ color: 'var(--text-faint)' }}>{gutter || '1'}</pre>
          <pre className="flex-1 px-4 m-0 overflow-x-auto border-l border-line select-text">
            {html != null
              ? <code className="hljs" dangerouslySetInnerHTML={{ __html: html }} />
              : <code className="hljs">{body?.text ?? '加载中…'}</code>}
          </pre>
        </div>
      </div>
    </div>
  )
}

// ===== 项目切换下拉 =====
function ProjectSwitcher({ projects, active, onPick, sessionCount }: {
  projects: Project[]; active: Project | null; onPick: (wd: string) => void; sessionCount: (wd: string) => number
}) {
  const [open, setOpen] = useState(false)
  return (
    <div className="px-3 pt-3 pb-2.5 relative">
      <div onClick={() => setOpen((o) => !o)}
        className="flex items-center gap-2.5 px-2.5 py-2 rounded-[10px] cursor-pointer border border-line bg-elev2 hover:border-strong transition-colors">
        <div className="w-7 h-7 shrink-0 rounded-lg flex items-center justify-center" style={{ background: 'var(--accent-soft)', color: 'var(--accent)' }}><Folder size={15} /></div>
        <div className="flex-1 min-w-0">
          <div className="font-semibold text-[13px] text-ink truncate">{active?.name ?? '未选择项目'}</div>
          <div className="font-mono text-[10.5px] text-faint truncate">{active?.workdir ?? '点右上 + 打开项目'}</div>
        </div>
        <ChevronsUpDown size={14} className="text-faint shrink-0" />
      </div>
      {open && (
        <>
          <div className="fixed inset-0 z-30" onClick={() => setOpen(false)} />
          <div className="absolute left-3 right-3 top-[60px] z-40 p-1.5 rounded-xl bg-elev border border-strong shadow-pop animate-pop">
            <div className="text-[10.5px] font-semibold tracking-[0.04em] text-faint px-2 pt-1.5 pb-1">切换项目</div>
            {projects.map((p) => {
              const on = p.workdir === active?.workdir
              return (
                <div key={p.workdir} onClick={() => { onPick(p.workdir); setOpen(false) }}
                  className="flex items-center gap-2 px-2 py-2 rounded-lg cursor-pointer hover:bg-sunken"
                  style={on ? { background: 'var(--bg-sunken)' } : undefined}>
                  <div className="flex-1 min-w-0">
                    <div className="font-medium text-[12.5px] text-ink truncate">{p.name}</div>
                    <div className="font-mono text-[10px] text-faint truncate">{p.workdir}</div>
                  </div>
                  <span className="text-[10.5px] text-faint shrink-0">{sessionCount(p.workdir)} 会话</span>
                </div>
              )
            })}
            <div className="h-px bg-line my-1.5 mx-1" />
            <div onClick={() => { cmd.openProject(); setOpen(false) }} className="flex items-center gap-2 px-2 py-2 rounded-lg cursor-pointer text-dim hover:bg-sunken">
              <Plus size={14} strokeWidth={1.8} /><span className="text-[12.5px]">添加项目目录</span>
            </div>
          </div>
        </>
      )}
    </div>
  )
}

// ===== 新建会话(轻量菜单)=====
function NewBtn({ workdir }: { workdir: string }) {
  const [open, setOpen] = useState(false)
  return (
    <div className="relative">
      <button onClick={() => setOpen((o) => !o)}
        className="flex items-center gap-1 pl-1.5 pr-2.5 py-1 rounded-[7px] text-[12px] font-medium text-accentfg transition hover:brightness-110" style={{ background: 'var(--accent)' }}>
        <Plus size={13} strokeWidth={2.4} />新建
      </button>
      {open && (
        <>
          <div className="fixed inset-0 z-30" onClick={() => setOpen(false)} />
          <div className="absolute right-0 mt-1.5 z-40 w-36 p-1.5 rounded-[11px] bg-elev border border-strong shadow-pop animate-pop">
            <button onClick={() => { cmd.continueLast(workdir); setOpen(false) }} className="w-full text-left px-2.5 py-1.5 text-[12.5px] text-ink rounded-lg hover:bg-sunken">继续最近</button>
            <button onClick={() => { cmd.newSession(workdir); setOpen(false) }} className="w-full text-left px-2.5 py-1.5 text-[12.5px] text-ink rounded-lg hover:bg-sunken">全新会话</button>
          </div>
        </>
      )}
    </div>
  )
}

// ===== 工作区 =====
function ConsolePage({ query }: { query: string }) {
  const state = useAgent()
  const transcripts = useTranscripts()
  const tmeta = useTranscriptMeta()
  const [selectedProject, setSelectedProject] = useState<string | null>(() => localStorage.getItem('console.project'))
  const [sel, setSel] = useState<Sel>(null)
  const [openFile, setOpenFile] = useState<string | null>(() => localStorage.getItem('console.file'))
  const [listTab, setListTab] = useState<'sessions' | 'files'>(() => (localStorage.getItem('console.tab') as 'sessions' | 'files') || 'sessions')
  const [filter, setFilter] = useState<'all' | 'running' | 'done'>('all')
  const [pendingResume, setPendingResume] = useState<string | null>(null)

  const doResume = (workdir: string, id: string) => { if (pendingResume) return; setPendingResume(id); cmd.resume(workdir, id) }
  useEffect(() => {
    if (!pendingResume) return
    const s = state.sessions.find((x) => x.agentSessionId === pendingResume)
    if (s) { setSel({ kind: 'session', id: s.id }); setOpenFile(null); setPendingResume(null) }
  }, [state.sessions, pendingResume])

  useEffect(() => {
    if ((!selectedProject || !state.projects.some((p) => p.workdir === selectedProject)) && state.projects.length)
      setSelectedProject(state.projects[0].workdir)
  }, [state.projects, selectedProject])

  // 记住上次选择(切页面/重启都不丢)
  useEffect(() => { if (selectedProject) localStorage.setItem('console.project', selectedProject) }, [selectedProject])
  useEffect(() => { if (openFile) localStorage.setItem('console.file', openFile); else localStorage.removeItem('console.file') }, [openFile])
  useEffect(() => { localStorage.setItem('console.tab', listTab) }, [listTab])

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

  const consoleSessions = project ? state.sessions.filter((s) => s.workdir === project.workdir) : []
  const manualList = project ? state.manual.filter((m) => inProject(m.cwd, project.workdir)) : []
  const liveIds = new Set<string>([...consoleSessions.map((s) => s.agentSessionId).filter(Boolean) as string[], ...manualList.map((m) => m.id)])
  const historyList = project ? project.history.filter((h) => !liveIds.has(h.id)) : []

  const isRunning = { session: (s: Session) => !['done', 'error'].includes(s.status), manual: (m: Manual) => m.state === 'working' || m.state === 'waiting' }
  const counts = { all: consoleSessions.length + manualList.length + historyList.length, running: consoleSessions.filter(isRunning.session).length + manualList.filter(isRunning.manual).length, done: 0 }
  counts.done = counts.all - counts.running

  const q = query.trim().toLowerCase()
  const match = (t: string) => !q || t.toLowerCase().includes(q)
  const fSessions = consoleSessions.filter((s) => match(s.title) && (filter === 'all' || (filter === 'running' ? isRunning.session(s) : !isRunning.session(s))))
  const fManual = manualList.filter((m) => match(m.title) && (filter === 'all' || (filter === 'running' ? isRunning.manual(m) : !isRunning.manual(m))))
  const fHistory = historyList.filter((h) => match(h.label) && filter !== 'running')

  const pick = (s: Sel) => { setSel(s); setOpenFile(null) }

  const sessionView = useMemo(() => {
    if (!sel) return (
      <div className="h-full flex flex-col items-center justify-center text-faint gap-3 bg-bg">
        <div className="w-12 h-12 rounded-2xl flex items-center justify-center" style={{ background: 'var(--accent-soft)', color: 'var(--accent)' }}><PanelsTopLeft size={22} /></div>
        <div className="text-[13px]">选择左侧会话,或点「新建」</div>
      </div>
    )
    if (sel.kind === 'session') { const s = state.sessions.find((x) => x.id === sel.id); return s ? <Conversation s={s} /> : null }
    if (sel.kind === 'manual') {
      const m = state.manual.find((x) => x.id === sel.id); if (!m) return null
      const mm = tmeta[m.id]
      return <ManualView m={m} msgs={transcripts[m.id] ?? []} hasEarlier={mm?.hasEarlier}
        onLoadEarlier={() => mm && cmd.loadTranscript('manual', m.id, undefined, mm.earliest)} />
    }
    const h = state.projects.flatMap((p) => p.history).find((x) => x.id === sel.id)
    const wd = (sel as any).workdir
    if (!h) return null
    const hm = tmeta[h.id]
    return <HistoryView h={h} msgs={transcripts[h.id] ?? []} onResume={() => doResume(wd, h.id)} resuming={pendingResume === h.id}
      hasEarlier={hm?.hasEarlier} onLoadEarlier={() => hm && cmd.loadTranscript('history', h.id, wd, hm.earliest)} />
  }, [sel, state, transcripts, tmeta, pendingResume])

  const FILTERS: { k: typeof filter; label: string }[] = [{ k: 'all', label: '全部' }, { k: 'running', label: '进行中' }, { k: 'done', label: '已完成' }]
  const [histOpen, setHistOpen] = useState(true)
  const tabStyle = (on: boolean): React.CSSProperties => on
    ? { background: 'var(--bg-elev)', color: 'var(--text)', fontWeight: 500, boxShadow: '0 1px 2px rgba(0,0,0,.08)' }
    : { color: 'var(--text-dim)' }

  return (
    <div className="flex h-full flex-1 min-w-0">
      {/* 左列:项目切换 + 会话/文件 */}
      <div className="w-[312px] shrink-0 bg-elev border-r border-line flex flex-col min-h-0">
        <ProjectSwitcher projects={state.projects} active={project} sessionCount={(wd) => state.sessions.filter((s) => s.workdir === wd).length}
          onPick={(wd) => { setSelectedProject(wd); setSel(null); setOpenFile(null) }} />

        {/* 会话 / 文件 分段 */}
        <div className="px-3 pb-2">
          <div className="flex gap-[3px] p-[3px] rounded-[9px]" style={{ background: 'var(--bg-sunken)' }}>
            <button onClick={() => setListTab('sessions')} className="flex-1 py-1.5 rounded-[7px] text-[12.5px] transition" style={tabStyle(listTab === 'sessions')}>会话</button>
            <button onClick={() => setListTab('files')} className="flex-1 py-1.5 rounded-[7px] text-[12.5px] transition" style={tabStyle(listTab === 'files')}>文件</button>
          </div>
        </div>

        {!project ? <div className="px-4 text-[12px] text-dim">点上方切换器右侧 + 打开一个项目。</div>
          : listTab === 'sessions' ? (
            <div className="flex-1 flex flex-col min-h-0">
              <div className="px-3 pb-2">
                <div className="flex items-center justify-between mb-2.5">
                  <span className="text-[11px] font-semibold tracking-[0.05em] uppercase text-faint">全部会话</span>
                  <NewBtn workdir={project.workdir} />
                </div>
                <div className="flex gap-1.5">
                  {FILTERS.map((f) => {
                    const on = filter === f.k
                    return (
                      <button key={f.k} onClick={() => setFilter(f.k)} className="px-2.5 py-1 rounded-lg text-[12px] transition-colors"
                        style={on ? { background: 'var(--accent-soft)', color: 'var(--accent)', fontWeight: 500 } : { background: 'var(--bg-sunken)', color: 'var(--text-dim)' }}>
                        {f.label}<span className="ml-1.5 opacity-55">{counts[f.k]}</span>
                      </button>
                    )
                  })}
                </div>
              </div>
              <div className="flex-1 overflow-auto px-2 pb-3">
                {fSessions.map((s) => <Row key={s.id} active={sel?.kind === 'session' && sel.id === s.id} title={s.title} meta={sessionMeta(s.status)} model={s.agent === 'codex' ? 'Codex' : 'Claude'} time={relTime(s.startedAt)} onClick={() => pick({ kind: 'session', id: s.id })} />)}
                {fManual.map((m) => <Row key={m.id} active={sel?.kind === 'manual' && sel.id === m.id} title={m.title} badge={{ text: '手动', color: 'var(--amber)' }} meta={manualMeta(m.state)} model={`${m.agent === 'codex' ? 'Codex' : 'Claude'} · ${m.terminal}`} time={relTime(m.lastActivityAt)} onClick={() => pick({ kind: 'manual', id: m.id })} />)}
                {fHistory.length > 0 && (
                  <div className="pt-1.5">
                    <button onClick={() => setHistOpen((o) => !o)} className="w-full flex items-center gap-1 px-1 py-1 text-[10.5px] font-semibold text-faint tracking-[0.05em] uppercase hover:text-dim transition-colors">
                      {histOpen ? <ChevronDown size={11} /> : <ChevronRight size={11} />}历史会话 · {fHistory.length}
                    </button>
                    {histOpen && fHistory.map((h) => <Row key={h.id} active={sel?.kind === 'history' && sel.id === h.id} title={h.label} badge={{ text: '历史', color: 'var(--text-faint)' }} meta={{ text: '已结束', color: 'var(--text-faint)', hollow: true }} model="Claude" time={relTime(h.mtime)} onClick={() => pick({ kind: 'history', id: h.id, workdir: project.workdir })} />)}
                  </div>
                )}
                {counts.all === 0 && <div className="text-[11px] text-faint px-1 pb-1">未打开会话</div>}
              </div>
            </div>
          ) : (
            <div className="flex-1 flex flex-col min-h-0">
              <div className="px-3.5 pb-2"><span className="text-[11px] font-semibold tracking-[0.05em] uppercase text-faint">工作区文件</span></div>
              <div className="flex-1 overflow-auto px-1.5 pb-3">
                <FileTree root={project.workdir} active={openFile} openFile={(p) => setOpenFile(p)} />
              </div>
            </div>
          )}
      </div>

      {/* 工作区 */}
      <div className="flex-1 min-w-0 flex flex-col bg-bg">
        <div key={openFile ?? (sel ? sel.kind + sel.id : 'empty')} className="h-full animate-conv">
          {openFile ? <FileViewer path={openFile} onClose={() => setOpenFile(null)} /> : sessionView}
        </div>
      </div>
    </div>
  )
}

// ===== 使用统计(扫本地 .jsonl,花费按内置单价表估算)=====
const fmtTok = (n: number) => n >= 1e6 ? `${(n / 1e6).toFixed(2)}M` : n >= 1e3 ? `${(n / 1e3).toFixed(1)}k` : `${n}`
const fmtUsd = (c: number) => `$${c.toFixed(c < 10 ? 2 : 1)}`
const MODEL_COLORS = ['var(--accent)', '#7d9bd4', '#b9c0e8', '#9aa0ad']

function UsagePage() {
  const usage = useUsage()
  const [days, setDays] = useState(14)
  useEffect(() => { cmd.loadUsage(days) }, [days])
  const t = usage?.totals
  const maxBar = Math.max(1, ...(usage?.daily ?? []).map((d) => d.tokens))
  const totalTok = Math.max(1, t?.tokens ?? 1)
  const RANGES: { d: number; label: string }[] = [{ d: 14, label: '14 天' }, { d: 30, label: '30 天' }, { d: 0, label: '全部' }]
  return (
    <div className="flex-1 overflow-y-auto bg-bg">
      <div className="max-w-[920px] mx-auto px-8 pt-8 pb-12">
        <div className="flex items-end justify-between mb-5">
          <div>
            <div className="text-[20px] font-semibold text-ink">使用统计</div>
            <div className="text-[12.5px] text-dim mt-1">扫描本地 Claude 转录 · 花费为单价表估算</div>
          </div>
          <div className="flex gap-1 p-[3px] rounded-[9px]" style={{ background: 'var(--bg-sunken)' }}>
            {RANGES.map((r) => (
              <button key={r.d} onClick={() => setDays(r.d)} className="px-3 py-1.5 rounded-[7px] text-[12px] transition"
                style={days === r.d ? { background: 'var(--bg-elev)', fontWeight: 500, boxShadow: '0 1px 2px rgba(0,0,0,.08)' } : { color: 'var(--text-dim)' }}>
                {r.label}
              </button>
            ))}
          </div>
        </div>

        {!usage ? <div className="text-[13px] text-faint py-16 text-center">统计中…</div> : (
          <>
            <div className="grid grid-cols-4 gap-3.5">
              {[
                { l: '总 Token', v: fmtTok(t!.tokens), s: `输入 ${fmtTok(t!.input)} · 输出 ${fmtTok(t!.output)}` },
                { l: '花费(估算)', v: fmtUsd(t!.cost), s: '按内置单价表' },
                { l: '缓存命中', v: `${(t!.cacheHit * 100).toFixed(0)}%`, s: `读取 ${fmtTok(t!.cacheRead)}` },
                { l: '请求数', v: t!.requests.toLocaleString(), s: days > 0 ? `近 ${days} 天` : '全部' },
              ].map((c) => (
                <div key={c.l} className="p-4 rounded-[13px] border border-line bg-elev">
                  <div className="text-[11.5px] text-dim">{c.l}</div>
                  <div className="text-[24px] font-semibold mt-2 text-ink tracking-tight">{c.v}</div>
                  <div className="text-[11px] text-faint mt-1 truncate">{c.s}</div>
                </div>
              ))}
            </div>

            <div className="mt-4 p-5 rounded-[13px] border border-line bg-elev">
              <div className="text-[13px] font-semibold text-ink mb-4">每日 Token 消耗</div>
              <div className="flex items-end gap-1.5 h-[150px]">
                {usage.daily.map((b, i) => (
                  <div key={i} className="flex-1 flex flex-col items-center gap-1.5 h-full justify-end" title={`${b.day}: ${fmtTok(b.tokens)}`}>
                    <div className="w-full rounded-t-[5px] transition-all" style={{ height: `${Math.max(2, (b.tokens / maxBar) * 100)}%`, background: i === usage.daily.length - 1 ? 'var(--accent)' : 'var(--accent-soft)' }} />
                    <span className="text-[9px] text-faint">{b.day}</span>
                  </div>
                ))}
              </div>
            </div>

            <div className="mt-4 p-5 rounded-[13px] border border-line bg-elev">
              <div className="text-[13px] font-semibold text-ink mb-4">按模型分布</div>
              {usage.models.length === 0 && <div className="text-[12px] text-faint">本范围无数据。</div>}
              {usage.models.map((m, i) => (
                <div key={m.name} className="flex items-center gap-3.5 py-2">
                  <span className="w-2.5 h-2.5 rounded-full shrink-0" style={{ background: MODEL_COLORS[i] ?? 'var(--text-faint)' }} />
                  <span className="font-mono text-[12px] w-[150px] shrink-0 truncate">{modelLabel(m.name)}</span>
                  <div className="flex-1 h-2 rounded-full overflow-hidden" style={{ background: 'var(--bg-sunken)' }}>
                    <div className="h-full rounded-full" style={{ width: `${(m.tokens / totalTok) * 100}%`, background: MODEL_COLORS[i] ?? 'var(--text-faint)' }} />
                  </div>
                  <span className="text-[12px] text-dim w-[80px] text-right shrink-0">{fmtTok(m.tokens)}</span>
                  <span className="text-[12px] text-faint w-[64px] text-right shrink-0">{fmtUsd(m.cost)}</span>
                </div>
              ))}
              <div className="flex items-center gap-3.5 pt-3 mt-1 border-t border-line">
                <span className="w-2.5 h-2.5 shrink-0" />
                <span className="text-[12px] font-semibold text-ink w-[150px] shrink-0">汇总</span>
                <span className="flex-1" />
                <span className="text-[12px] font-semibold text-ink w-[80px] text-right shrink-0">{fmtTok(t!.tokens)}</span>
                <span className="text-[12px] font-semibold text-ink w-[64px] text-right shrink-0">{fmtUsd(t!.cost)}</span>
              </div>
            </div>
          </>
        )}
      </div>
    </div>
  )
}

// ===== Provider 管理(VibeNotch 当前单 Claude)=====
function ProvidersPage() {
  return (
    <div className="flex-1 overflow-y-auto bg-bg">
      <div className="max-w-[820px] mx-auto px-8 pt-8 pb-12">
        <div className="text-[20px] font-semibold text-ink">Provider 管理</div>
        <div className="text-[12.5px] text-dim mt-1">当前由 VibeNotch 托管,经 stream-json 驱动 Claude。</div>
        <div className="mt-6 p-[18px] rounded-[13px] border border-line bg-elev">
          <div className="flex items-center gap-3.5">
            <div className="w-10 h-10 shrink-0 rounded-[11px] flex items-center justify-center font-semibold text-[15px]" style={{ background: '#ece6dd', color: '#b8612d' }}>C</div>
            <div className="flex-1 min-w-0">
              <div className="flex items-center gap-2.5">
                <span className="text-[14px] font-semibold text-ink">Claude</span>
                <span className="text-[10px] font-medium px-1.5 py-0.5 rounded" style={{ background: 'var(--accent-soft)', color: 'var(--accent)' }}>默认</span>
              </div>
              <div className="text-[11.5px] text-faint mt-0.5">Anthropic · 经 VibeNotch</div>
            </div>
            <div className="flex items-center gap-1.5"><span className="w-2 h-2 rounded-full" style={{ background: 'var(--green)' }} /><span className="text-[11.5px] text-dim">在线</span></div>
          </div>
        </div>
        <div className="mt-3 p-[18px] rounded-[13px] border border-line bg-elev opacity-70">
          <div className="flex items-center gap-3.5">
            <div className="w-10 h-10 shrink-0 rounded-[11px] flex items-center justify-center" style={{ background: 'var(--bg-sunken)', color: 'var(--text-faint)' }}><Server size={17} /></div>
            <div className="flex-1"><div className="text-[14px] font-semibold text-ink">Codex</div><div className="text-[11.5px] text-faint mt-0.5">OpenAI · 计划中</div></div>
            <span className="text-[11.5px] text-faint">未启用</span>
          </div>
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
            <div className="flex-1"><div className="text-[13px] font-medium text-ink">主题</div><div className="text-[11.5px] text-dim mt-0.5">浅色 / 深色外观</div></div>
            <div className="flex gap-1 p-[3px] rounded-[9px]" style={{ background: 'var(--bg-sunken)' }}>
              {(['light', 'dark'] as const).map((t) => (
                <button key={t} onClick={() => setTheme(t)} className="px-3.5 py-1.5 rounded-[7px] text-[12px] transition"
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

// ===== 顶栏 =====
function TitleBar({ query, setQuery, theme, toggleTheme }: { query: string; setQuery: (s: string) => void; theme: string; toggleTheme: () => void }) {
  return (
    <div className="flex-none h-10 flex items-center gap-3 px-3.5 border-b border-line bg-elev">
      <div className="flex-1 flex justify-center">
        <div className="flex items-center gap-2 px-3 py-1.5 rounded-lg w-[280px] max-w-full" style={{ background: 'var(--bg-sunken)' }}>
          <Search size={13} className="text-faint shrink-0" />
          <input value={query} onChange={(e) => setQuery(e.target.value)} placeholder="搜索会话…"
            className="flex-1 bg-transparent outline-none text-[12px] text-ink select-text placeholder:text-faint min-w-0" />
          <span className="font-mono text-[10.5px] px-1.5 py-px rounded border border-line text-faint">⌘K</span>
        </div>
      </div>
      <div className="flex items-center gap-1.5 shrink-0">
        <button title="切换主题" onClick={toggleTheme} className="w-[30px] h-[30px] rounded-lg flex items-center justify-center text-dim hover:text-ink hover:bg-sunken transition-colors">
          {theme === 'dark' ? <Sun size={16} /> : <Moon size={15} />}
        </button>
        <div className="relative w-[26px] h-[26px] rounded-full flex items-center justify-center text-[11px] font-semibold text-dim" style={{ background: 'var(--bg-sunken)', border: '1px solid var(--border-strong)' }}>
          Z<span className="absolute -right-px -bottom-px w-2 h-2 rounded-full" style={{ background: 'var(--green)', border: '2px solid var(--bg-elev)' }} />
        </div>
      </div>
    </div>
  )
}

function NavRail({ page, setPage }: { page: string; setPage: (p: string) => void }) {
  const items = [
    { id: 'console', icon: <PanelsTopLeft size={19} />, label: '工作区' },
    { id: 'usage', icon: <BarChart3 size={19} />, label: '使用统计' },
    { id: 'providers', icon: <Server size={19} />, label: 'Provider 管理' },
  ]
  return (
    <div className="w-[56px] shrink-0 bg-elev border-r border-line flex flex-col items-center pt-2.5 gap-1">
      {items.map((it) => {
        const on = page === it.id
        return (
          <button key={it.id} onClick={() => setPage(it.id)} title={it.label}
            className={`w-[38px] h-[38px] rounded-[10px] flex items-center justify-center transition-colors ${on ? '' : 'text-dim hover:bg-sunken'}`}
            style={on ? { background: 'var(--accent-soft)', color: 'var(--accent)' } : undefined}>{it.icon}</button>
        )
      })}
      <div className="flex-1" />
      <button onClick={() => setPage('settings')} title="设置"
        className={`w-[38px] h-[38px] rounded-[10px] flex items-center justify-center transition-colors mb-2.5 ${page === 'settings' ? '' : 'text-dim hover:bg-sunken'}`}
        style={page === 'settings' ? { background: 'var(--accent-soft)', color: 'var(--accent)' } : undefined}><SlidersHorizontal size={19} /></button>
    </div>
  )
}

export default function App() {
  const [page, setPage] = useState('console')
  const [query, setQuery] = useState('')
  const [theme, setThemeState] = useState<'light' | 'dark'>(() => (localStorage.getItem('theme') as 'light' | 'dark') || 'light')
  useEffect(() => {
    document.documentElement.setAttribute('data-theme', theme)
    localStorage.setItem('theme', theme)
    cmd.setTheme(theme === 'dark')
  }, [theme])
  const setTheme = (t: 'light' | 'dark') => setThemeState(t)
  const toggleTheme = () => setThemeState((t) => (t === 'dark' ? 'light' : 'dark'))
  return (
    <div className="flex flex-col h-full">
      <TitleBar query={query} setQuery={setQuery} theme={theme} toggleTheme={toggleTheme} />
      <div className="flex flex-1 min-h-0">
        <NavRail page={page} setPage={setPage} />
        {/* 控制台常驻不卸载,切页面回来仍记得选中的项目/文件/树展开 */}
        <div className="flex flex-1 min-w-0" style={{ display: page === 'console' ? 'flex' : 'none' }}>
          <ConsolePage query={query} />
        </div>
        {page === 'usage' && <UsagePage />}
        {page === 'providers' && <ProvidersPage />}
        {page === 'settings' && <SettingsPage theme={theme} setTheme={setTheme} />}
      </div>
    </div>
  )
}
