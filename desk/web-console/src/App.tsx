import { useSyncExternalStore, useState, useMemo, useRef, useEffect, useLayoutEffect } from 'react'
import hljs from 'highlight.js'
import { marked } from 'marked'
import {
  Folder, ChevronRight, ChevronDown, ChevronsUpDown, ArrowUp,
  RotateCcw, AppWindow, Plus, X, Paperclip, Sun, Moon, SlidersHorizontal,
  BarChart3, PanelsTopLeft, Copy, FileText, Check, Server, MoreHorizontal, Pencil, EyeOff,
  Activity, DollarSign, Boxes, Database,
} from 'lucide-react'
import { subscribe, getState, getTranscripts, getTranscriptMeta, getDirs, getFiles, getUsage, getConn } from './store'
import { cmd } from './bridge'
import type { Session, Msg, Manual, History, Project, Entry, UsageData } from './types'

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
function useConn() { return useSyncExternalStore(subscribe, getConn, getConn) }

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

// 助手文本走 Markdown 渲染(粗体/列表/代码/标题/表格等)
function Markdown({ text }: { text: string }) {
  const html = useMemo(() => marked.parse(text, { gfm: true, breaks: true, async: false }) as string, [text])
  return <div className="md flex-1 text-[13.5px] leading-[1.72] text-ink select-text min-w-0" dangerouslySetInnerHTML={{ __html: html }} />
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
        <Markdown text={m.text} />
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

function WorkHeader({ title, meta, model, sub, renameKey, right }: { title: string; meta?: DotMeta; model?: string; sub?: string; renameKey?: string; right?: React.ReactNode }) {
  const [menu, setMenu] = useState(false)
  const [editing, setEditing] = useState(false)
  const [val, setVal] = useState(title)
  useEffect(() => { if (!editing) setVal(title) }, [title, editing])
  const commit = () => { setEditing(false); if (renameKey) cmd.renameSession(renameKey, val.trim()) }
  return (
    <div className="flex-none flex items-center gap-3 px-5 py-3 border-b border-line">
      <div className="flex-1 min-w-0">
        {editing
          ? <input autoFocus value={val} onChange={(e) => setVal(e.target.value)}
              onKeyDown={(e) => { if (e.key === 'Enter') { e.preventDefault(); commit() } else if (e.key === 'Escape') setEditing(false) }}
              onBlur={commit} placeholder="会话名…(留空恢复默认)"
              className="w-full text-[15px] font-semibold text-ink bg-transparent outline-none border-b border-strong pb-0.5 select-text placeholder:text-faint placeholder:font-normal" />
          : <div className="text-[15px] font-semibold text-ink truncate">{title}</div>}
        <div className="flex items-center gap-2 mt-1">
          {meta && <Dot meta={meta} size={8} />}
          {meta && <span className="text-[11.5px] text-dim">{meta.text}</span>}
          {model && <><span className="text-[11.5px] text-faint">·</span><span className="font-mono text-[11px] text-faint">{model}</span></>}
          {sub && <><span className="text-[11.5px] text-faint">·</span><span className="text-[11.5px] text-faint truncate">{sub}</span></>}
        </div>
      </div>
      <div className="flex items-center gap-1">
        {renameKey && (
          <div className="relative">
            <IconBtn title="更多" onClick={() => setMenu((o) => !o)}><MoreHorizontal size={16} /></IconBtn>
            {menu && (
              <>
                <div className="fixed inset-0 z-30" onClick={() => setMenu(false)} />
                <div className="absolute right-0 mt-1.5 z-40 w-32 p-1.5 rounded-[11px] bg-elev border border-strong shadow-pop animate-pop">
                  <button onClick={() => { setMenu(false); setVal(title); setEditing(true) }}
                    className="w-full flex items-center gap-2 px-2.5 py-1.5 text-[12.5px] text-ink rounded-lg hover:bg-sunken"><Pencil size={13} />重命名</button>
                  <button onClick={() => { setMenu(false); cmd.hideSession(renameKey) }}
                    className="w-full flex items-center gap-2 px-2.5 py-1.5 text-[12.5px] rounded-lg hover:bg-sunken" style={{ color: 'var(--red)' }}><EyeOff size={13} />隐藏</button>
                </div>
              </>
            )}
          </div>
        )}
        {right}
      </div>
    </div>
  )
}

// 可切换的模型(alias 给 --model;label 是带版本的展示名)
const MODELS: { alias: 'opus' | 'sonnet' | 'haiku'; label: string }[] = [
  { alias: 'opus', label: 'Opus 4.8' }, { alias: 'sonnet', label: 'Sonnet 4.6' }, { alias: 'haiku', label: 'Haiku 4.5' },
]
function modelFamily(m?: string): 'opus' | 'sonnet' | 'haiku' | null {
  if (!m) return null
  const s = m.toLowerCase()
  return s.includes('opus') ? 'opus' : s.includes('sonnet') ? 'sonnet' : s.includes('haiku') ? 'haiku' : null
}
// claude-opus-4-8 → "Opus 4.8";别名 sonnet → 用 MODELS 里的带版本名
function modelLabel(m?: string): string {
  if (!m) return '默认'
  const fam = modelFamily(m)
  if (!fam) return m
  const ver = m.toLowerCase().match(/(\d+)-(\d+)/)   // claude-opus-4-8 → 4-8
  if (ver) return `${fam.charAt(0).toUpperCase() + fam.slice(1)} ${ver[1]}.${ver[2]}`
  return MODELS.find((x) => x.alias === fam)?.label ?? (fam.charAt(0).toUpperCase() + fam.slice(1))
}

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
                      <span className="font-mono flex-1 text-left">{m.label}</span>
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
        renameKey={s.key || s.agentSessionId || s.id}
        right={<IconBtn title="结束会话" onClick={() => cmd.closeSession(s.id)}><X size={16} /></IconBtn>} />
      <MsgList msgs={s.messages} onRespond={(r, c) => cmd.respond(s.id, r, c)} working={s.status === 'working'} />
      <Composer sid={s.id} model={s.model} onSend={(t) => cmd.sendInput(s.id, t)} />
    </div>
  )
}

function ManualView({ m, msgs, hasEarlier, onLoadEarlier }: { m: Manual; msgs: Msg[]; hasEarlier?: boolean; onLoadEarlier?: () => void }) {
  return (
    <div className="flex flex-col h-full bg-bg">
      <WorkHeader title={m.title} meta={manualMeta(m.state)} sub={m.cwd} renameKey={m.key || m.id}
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
      <WorkHeader title={h.label} meta={{ text: '历史 · 只读', color: 'var(--text-faint)', hollow: true }} renameKey={h.key || h.id}
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
function ConsolePage() {
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

  const fSessions = consoleSessions.filter((s) => filter === 'all' || (filter === 'running' ? isRunning.session(s) : !isRunning.session(s)))
  const fManual = manualList.filter((m) => filter === 'all' || (filter === 'running' ? isRunning.manual(m) : !isRunning.manual(m)))
  const fHistory = historyList.filter(() => filter !== 'running')

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
const fmtTok = (n: number) => n >= 1e6 ? `${(n / 1e6).toFixed(2)}M` : n >= 1e3 ? `${(n / 1e3).toFixed(1)}k` : `${Math.round(n)}`
const fmtUsd = (c: number) => `$${c < 10 ? c.toFixed(2) : c.toFixed(1)}`
const fmtNum = (n: number) => Math.round(n).toLocaleString()
const USAGE_COLORS = ['#5562c9', '#2fae79', '#e8943a', '#a574d8', '#5b8def', '#e0609a', '#2fb6c8']
type Measure = 'cost' | 'token' | 'req'
const MEASURES: { k: Measure; label: string }[] = [{ k: 'cost', label: '成本' }, { k: 'token', label: 'Token' }, { k: 'req', label: '请求数' }]
const fmtMeasure = (m: Measure, v: number) => m === 'cost' ? fmtUsd(v) : m === 'token' ? fmtTok(v) : fmtNum(v)

function Seg<T extends string | number>({ value, onPick, options, width }: {
  value: T; onPick: (v: T) => void; options: { k: T; label: string }[]; width?: number
}) {
  return (
    <div className="flex gap-[3px] p-[3px] rounded-[9px]" style={{ background: 'var(--bg-sunken)', width }}>
      {options.map((o) => {
        const on = o.k === value
        return (
          <button key={String(o.k)} onClick={() => onPick(o.k)} className="flex-1 px-3 py-1.5 rounded-[7px] text-[12px] whitespace-nowrap transition"
            style={on ? { background: 'var(--bg-elev)', fontWeight: 500, boxShadow: '0 1px 2px rgba(0,0,0,.08)' } : { color: 'var(--text-dim)' }}>
            {o.label}
          </button>
        )
      })}
    </div>
  )
}

function UsageCard({ icon, tint, label, value, sub }: { icon: React.ReactNode; tint: string; label: string; value: string; sub?: React.ReactNode }) {
  return (
    <div className="p-4 rounded-[13px] border border-line bg-elev">
      <div className="flex items-center justify-between">
        <span className="text-[12px] text-dim">{label}</span>
        <span className="w-[26px] h-[26px] rounded-[7px] flex items-center justify-center" style={{ background: tint + '22', color: tint }}>{icon}</span>
      </div>
      <div className="text-[25px] font-semibold mt-2.5 text-ink tracking-tight">{value}</div>
      {sub && <div className="flex gap-4 mt-2 text-[11px] text-faint">{sub}</div>}
    </div>
  )
}

function UsageChart({ usage, measure, group }: { usage: UsageData; measure: Measure; group: 'model' | 'total' }) {
  const [hidden, setHidden] = useState<Set<string>>(new Set())
  const [hover, setHover] = useState<number | null>(null)
  const N = usage.days.length
  const allSeries = useMemo(() => {
    if (group === 'total') {
      const vals = usage.days.map((_, i) => usage.series.reduce((s, se) => s + se[measure][i], 0))
      return [{ key: 'total', label: '总计', color: USAGE_COLORS[0], vals }]
    }
    return [...usage.series]
      .map((se, i) => ({ key: se.name, label: modelLabel(se.name), color: USAGE_COLORS[i % USAGE_COLORS.length], vals: se[measure] }))
      .sort((a, b) => b.vals.reduce((s, v) => s + v, 0) - a.vals.reduce((s, v) => s + v, 0))
  }, [usage, measure, group])
  const visible = allSeries.filter((s) => !hidden.has(s.key))
  const maxY = Math.max(1, ...visible.flatMap((s) => s.vals))
  const W = 1000, H = 230, padT = 12, padB = 6
  const X = (i: number) => N <= 1 ? W / 2 : (i / (N - 1)) * W
  const Y = (v: number) => padT + (1 - v / maxY) * (H - padT - padB)
  const yTicks = Array.from({ length: 5 }, (_, i) => maxY * (1 - i / 4))
  const tickIdx = Array.from({ length: Math.min(7, N) }, (_, i) => Math.round(i * (N - 1) / Math.max(1, Math.min(7, N) - 1)))

  return (
    <div>
      <div className="relative" style={{ height: H + 22 }}
        onMouseMove={(e) => { const r = e.currentTarget.getBoundingClientRect(); setHover(Math.max(0, Math.min(N - 1, Math.round(((e.clientX - r.left) / r.width) * (N - 1))))) }}
        onMouseLeave={() => setHover(null)}>
        {/* Y 轴标签 */}
        {yTicks.map((v, i) => (
          <span key={i} className="absolute left-0 font-mono text-[9.5px] text-faint -translate-y-1/2 pr-1 z-[2]" style={{ top: `${(i / 4) * (H / (H + 22)) * 100}%`, background: 'var(--bg-elev)' }}>{fmtMeasure(measure, v)}</span>
        ))}
        <svg viewBox={`0 0 ${W} ${H}`} preserveAspectRatio="none" style={{ width: '100%', height: H }}>
          {/* 网格 */}
          {[0, 1, 2, 3, 4].map((i) => (
            <line key={i} x1={0} x2={W} y1={padT + (i / 4) * (H - padT - padB)} y2={padT + (i / 4) * (H - padT - padB)} stroke="var(--border)" strokeWidth={1} vectorEffect="non-scaling-stroke" />
          ))}
          {visible.map((s) => (
            <polyline key={s.key} points={s.vals.map((v, i) => `${X(i)},${Y(v)}`).join(' ')}
              fill="none" stroke={s.color} strokeWidth={1.8} strokeLinejoin="round" strokeLinecap="round" vectorEffect="non-scaling-stroke" />
          ))}
          {hover != null && <line x1={X(hover)} x2={X(hover)} y1={padT} y2={H - padB} stroke="var(--border-strong)" strokeWidth={1} vectorEffect="non-scaling-stroke" />}
        </svg>
        {/* hover 点(用百分比定位,避免 svg 非等比拉伸变形)*/}
        {hover != null && visible.map((s) => (
          <span key={s.key} className="absolute w-2 h-2 rounded-full -translate-x-1/2 -translate-y-1/2 pointer-events-none border-2"
            style={{ left: `${(N <= 1 ? 0.5 : hover / (N - 1)) * 100}%`, top: `${(Y(s.vals[hover]) / (H + 22)) * 100}%`, background: s.color, borderColor: 'var(--bg-elev)' }} />
        ))}
        {/* tooltip */}
        {hover != null && (
          <div className="absolute top-1.5 z-[5] pointer-events-none" style={{ left: `${(N <= 1 ? 0.5 : hover / (N - 1)) * 100}%`, transform: hover > N / 2 ? 'translateX(-100%)' : 'none' }}>
            <div className="rounded-[10px] border border-strong bg-elev shadow-pop p-2.5 min-w-[150px]">
              <div className="font-mono text-[10.5px] text-faint mb-1.5">{usage.days[hover]}</div>
              {visible.map((s) => (
                <div key={s.key} className="flex items-center gap-2 mb-1">
                  <span className="w-2 h-2 rounded-full shrink-0" style={{ background: s.color }} />
                  <span className="text-[11px] text-dim flex-1 truncate">{s.label}</span>
                  <span className="font-mono text-[11px] font-semibold text-ink">{fmtMeasure(measure, s.vals[hover])}</span>
                </div>
              ))}
            </div>
          </div>
        )}
      </div>
      {/* X 刻度 */}
      <div className="flex justify-between mt-1.5 px-0.5">
        {tickIdx.map((i) => <span key={i} className="font-mono text-[10px] text-faint">{usage.days[i]}</span>)}
      </div>
      {/* 图例 */}
      <div className="flex flex-wrap justify-center gap-1 mt-3.5 pt-3.5 border-t border-line">
        {allSeries.map((s) => {
          const off = hidden.has(s.key)
          return (
            <button key={s.key} onClick={() => setHidden((p) => { const n = new Set(p); n.has(s.key) ? n.delete(s.key) : n.add(s.key); return n })}
              className="flex items-center gap-1.5 px-2 py-1 rounded-md hover:bg-sunken transition-colors">
              <span className="w-2.5 h-2.5 rounded-full" style={{ background: off ? 'var(--text-faint)' : s.color, opacity: off ? 0.4 : 1 }} />
              <span className="text-[11.5px]" style={{ color: off ? 'var(--text-faint)' : 'var(--text-dim)', textDecoration: off ? 'line-through' : 'none' }}>{s.label}</span>
            </button>
          )
        })}
      </div>
    </div>
  )
}

function UsagePage() {
  const usage = useUsage()
  const [days, setDays] = useState(14)
  const [measure, setMeasure] = useState<Measure>('cost')
  const [group, setGroup] = useState<'model' | 'total'>('model')
  useEffect(() => { cmd.loadUsage(days) }, [days])
  const t = usage?.totals
  const RANGES = [{ k: 7, label: '7 天' }, { k: 14, label: '14 天' }, { k: 30, label: '30 天' }, { k: 90, label: '90 天' }, { k: 0, label: '全部' }]
  const measureLabel = MEASURES.find((m) => m.k === measure)!.label

  // 排行(按当前 measure)
  const rank = useMemo(() => {
    if (!usage) return []
    return usage.series.map((s) => ({ name: s.name, total: s[measure].reduce((a, b) => a + b, 0) }))
      .sort((a, b) => b.total - a.total)
  }, [usage, measure])
  const rankSum = Math.max(1, rank.reduce((a, b) => a + b.total, 0))
  const rankMax = Math.max(1, ...rank.map((r) => r.total))

  return (
    <div className="flex-1 overflow-y-auto bg-bg">
      <div className="max-w-[1000px] mx-auto px-8 pt-8 pb-12">
        <div className="flex items-end justify-between mb-5 gap-4">
          <div>
            <div className="text-[20px] font-semibold text-ink">使用统计</div>
            <div className="text-[12.5px] text-dim mt-1">按日期范围查看请求、Token、缓存与成本(花费为单价表估算)</div>
          </div>
          <Seg value={days} onPick={setDays} options={RANGES} />
        </div>

        {!usage ? <div className="text-[13px] text-faint py-16 text-center">统计中…</div> : (
          <>
            <div className="grid grid-cols-4 gap-3.5">
              <UsageCard icon={<Activity size={14} />} tint="#5b8def" label="总请求数" value={fmtNum(t!.requests)} />
              <UsageCard icon={<DollarSign size={14} />} tint="#a574d8" label="总成本" value={fmtUsd(t!.cost)} />
              <UsageCard icon={<Boxes size={14} />} tint="#2fae79" label="总 Token 数" value={fmtTok(t!.tokens)}
                sub={<><span>Input <b className="text-dim font-semibold">{fmtTok(t!.input)}</b></span><span>Output <b className="text-dim font-semibold">{fmtTok(t!.output)}</b></span></>} />
              <UsageCard icon={<Database size={14} />} tint="#e8943a" label="缓存 Token" value={fmtTok(t!.cacheTokens)}
                sub={<><span>Write <b className="text-dim font-semibold">{fmtTok(t!.cacheWrite)}</b></span><span>Read <b className="text-dim font-semibold">{fmtTok(t!.cacheRead)}</b></span></>} />
            </div>

            <div className="mt-4.5 p-6 rounded-[13px] border border-line bg-elev">
              <div className="flex items-center gap-3.5 flex-wrap mb-4">
                <div className="text-[13px] font-semibold text-ink">使用趋势</div>
                <span className="flex-1" />
                <div className="flex items-center gap-1.5"><span className="text-[11px] text-faint">指标</span><Seg value={measure} onPick={setMeasure} options={MEASURES} /></div>
                <div className="flex items-center gap-1.5"><span className="text-[11px] text-faint">维度</span><Seg value={group} onPick={setGroup} options={[{ k: 'model', label: '模型' }, { k: 'total', label: '总计' }]} /></div>
              </div>
              <UsageChart usage={usage} measure={measure} group={group} />
            </div>

            <div className="mt-4.5 p-6 rounded-[13px] border border-line bg-elev">
              <div className="flex items-center justify-between mb-1">
                <div className="text-[13px] font-semibold text-ink">消耗排行</div>
                <div className="text-[11.5px] text-faint">按{measureLabel}</div>
              </div>
              {rank.length === 0 && <div className="text-[12px] text-faint mt-3">本范围无数据。</div>}
              {rank.length > 0 && (
                <>
                  <div className="text-[11.5px] text-dim mb-4">{modelLabel(rank[0].name)} 占用最多,约 {Math.round((rank[0].total / rankSum) * 100)}% 的{measureLabel}消耗</div>
                  <div className="flex flex-col gap-3">
                    {rank.map((r, i) => (
                      <div key={r.name} className="flex items-center gap-3">
                        <span className="font-mono text-[11px] text-faint w-3.5 shrink-0">{i + 1}</span>
                        <span className="w-2 h-2 rounded-full shrink-0" style={{ background: USAGE_COLORS[i % USAGE_COLORS.length] }} />
                        <span className="text-[12px] w-[130px] shrink-0 truncate">{modelLabel(r.name)}</span>
                        <div className="flex-1 h-2 rounded-full overflow-hidden" style={{ background: 'var(--bg-sunken)' }}>
                          <div className="h-full rounded-full" style={{ width: `${(r.total / rankMax) * 100}%`, background: USAGE_COLORS[i % USAGE_COLORS.length] }} />
                        </div>
                        <span className="font-mono text-[11.5px] font-semibold text-ink w-[84px] text-right shrink-0">{fmtMeasure(measure, r.total)}</span>
                        <span className="font-mono text-[11px] text-faint w-12 text-right shrink-0">{Math.round((r.total / rankSum) * 100)}%</span>
                      </div>
                    ))}
                  </div>
                </>
              )}
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

const CONN_DOT: Record<string, string> = {
  online: 'var(--green)', connecting: 'var(--amber)', offline: 'var(--text-faint)',
  unpaired: 'var(--text-faint)', suspended: 'var(--amber)', rejected: 'var(--red)',
}
function ConnSection() {
  const conn = useConn()
  const [host, setHost] = useState('')
  const [editing, setEditing] = useState(false)
  useEffect(() => { if (!editing && conn) setHost(conn.host) }, [conn?.host, editing])
  if (!conn) return null
  const p = conn.pair
  const pairing = p.phase === 'fetching' || p.phase === 'waiting'
  const dot = CONN_DOT[conn.state] ?? 'var(--text-faint)'
  return (
    <>
      <div className="text-[11px] font-semibold tracking-[0.05em] uppercase text-faint mb-2.5">连接手机</div>
      <div className="border border-line rounded-[13px] bg-elev mb-6">
        {/* 服务器地址 */}
        <div className="flex items-center px-4 py-4 border-b border-line">
          <div className="flex-1 min-w-0">
            <div className="text-[13px] font-medium text-ink">中转服务器地址</div>
            <div className="text-[11.5px] text-dim mt-0.5">手机和电脑连同一台服务器(WS 8090 / HTTP 8080)</div>
          </div>
          <input value={host} onFocus={() => setEditing(true)} onChange={(e) => setHost(e.target.value)}
            onBlur={() => setEditing(false)} placeholder="如 8.159.151.118"
            className="w-[170px] text-[12.5px] font-mono px-2.5 py-1.5 rounded-lg bg-sunken text-ink outline-none select-text mr-2" />
          <button onClick={() => { cmd.setHost(host.trim()); setEditing(false) }}
            className="text-[12.5px] px-3 py-1.5 rounded-lg text-accentfg hover:brightness-110" style={{ background: 'var(--accent)' }}>保存</button>
        </div>
        {/* 连接状态 */}
        <div className="flex items-center gap-2.5 px-4 py-3.5 border-b border-line">
          <span className="w-2 h-2 rounded-full shrink-0" style={{ background: dot }} />
          <span className="text-[12.5px] text-dim flex-1">{conn.text}</span>
          {conn.paired && conn.account && <span className="font-mono text-[11px] text-faint truncate max-w-[180px]">{conn.account}</span>}
        </div>
        {/* 配对区 */}
        <div className="px-4 py-4">
          {p.phase === 'waiting' ? (
            <div className="flex flex-col items-center gap-3 py-2">
              <div className="text-[11.5px] text-dim">在手机 App「设备」页输入此配对码(10 分钟内有效)</div>
              <div className="font-mono text-[34px] font-semibold tracking-[0.25em] text-ink" style={{ paddingLeft: '0.25em' }}>{p.code}</div>
              <button onClick={() => cmd.pairCancel()} className="text-[12.5px] text-dim px-3 py-1.5 rounded-lg border border-strong hover:bg-sunken">取消</button>
            </div>
          ) : p.phase === 'fetching' ? (
            <div className="text-[12.5px] text-dim py-1">正在获取配对码…</div>
          ) : (
            <div className="flex items-center gap-2.5">
              <div className="flex-1 min-w-0">
                {conn.paired
                  ? <><div className="text-[13px] font-medium text-ink">已配对</div><div className="text-[11.5px] text-dim mt-0.5">手机已绑定到 {conn.account}</div></>
                  : <><div className="text-[13px] font-medium text-ink">未配对</div><div className="text-[11.5px] text-dim mt-0.5">点「配对手机」生成配对码,在手机上输入完成绑定</div></>}
                {p.phase === 'failed' && p.error && <div className="text-[11.5px] mt-1" style={{ color: 'var(--red)' }}>{p.error}</div>}
              </div>
              {conn.paired && <button onClick={() => cmd.unpair()} className="text-[12.5px] px-3 py-1.5 rounded-lg hover:bg-sunken" style={{ color: 'var(--red)' }}>退出登录</button>}
              <button onClick={() => cmd.pairStart()} disabled={pairing}
                className="text-[12.5px] px-3.5 py-1.5 rounded-lg text-accentfg hover:brightness-110 disabled:opacity-60" style={{ background: 'var(--accent)' }}>
                {conn.paired ? '重新配对' : '配对手机'}
              </button>
            </div>
          )}
        </div>
      </div>
    </>
  )
}

function SettingsPage({ theme, setTheme }: { theme: string; setTheme: (t: 'light' | 'dark') => void }) {
  const state = useAgent()
  return (
    <div className="flex-1 overflow-y-auto bg-bg">
      <div className="max-w-[640px] mx-auto px-8 pt-8 pb-12">
        <div className="text-[20px] font-semibold text-ink mb-6">设置</div>
        <ConnSection />
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

        <div className="text-[11px] font-semibold tracking-[0.05em] uppercase text-faint mt-7 mb-2.5">已隐藏会话 · {state.hidden.length}</div>
        <div className="border border-line rounded-[13px] bg-elev overflow-hidden">
          {state.hidden.length === 0
            ? <div className="px-4 py-4 text-[12px] text-dim">没有隐藏的会话。隐藏只是不在列表展示,转录不会被删除。</div>
            : state.hidden.map((h) => (
              <div key={h.key} className="flex items-center px-4 py-3 border-b last:border-b-0 border-line">
                <span className="flex-1 text-[13px] text-ink truncate">{h.title}</span>
                <button onClick={() => cmd.unhideSession(h.key)}
                  className="text-[12px] px-2.5 py-1 rounded-lg hover:bg-sunken transition-colors" style={{ color: 'var(--accent)' }}>恢复</button>
              </div>
            ))}
        </div>
      </div>
    </div>
  )
}

// ===== 顶栏 =====
function TitleBar({ theme, toggleTheme }: { theme: string; toggleTheme: () => void }) {
  return (
    <div className="flex-none h-10 flex items-center gap-3 px-3.5 border-b border-line bg-elev">
      <div className="flex-1" />
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
      <TitleBar theme={theme} toggleTheme={toggleTheme} />
      <div className="flex flex-1 min-h-0">
        <NavRail page={page} setPage={setPage} />
        {/* 控制台常驻不卸载,切页面回来仍记得选中的项目/文件/树展开 */}
        <div className="flex flex-1 min-w-0" style={{ display: page === 'console' ? 'flex' : 'none' }}>
          <ConsolePage />
        </div>
        {page === 'usage' && <UsagePage />}
        {page === 'providers' && <ProvidersPage />}
        {page === 'settings' && <SettingsPage theme={theme} setTheme={setTheme} />}
      </div>
    </div>
  )
}
