import { useSyncExternalStore, useState, useMemo, useRef, useEffect } from 'react'
import { subscribe, getState, getTranscripts } from './store'
import { cmd } from './bridge'
import type { Session, Msg, Manual, History, Project } from './types'

function useAgent() { return useSyncExternalStore(subscribe, getState, getState) }
function useTranscripts() { return useSyncExternalStore(subscribe, getTranscripts, getTranscripts) }

const STATUS: Record<string, { label: string; cls: string }> = {
  starting: { label: '启动中', cls: 'text-amber-600 bg-amber-50' },
  idle: { label: '就绪', cls: 'text-brand bg-blue-50' },
  working: { label: '运行中', cls: 'text-green-600 bg-green-50' },
  waitingInput: { label: '挂起', cls: 'text-gray-500 bg-gray-100' },
  needsResponse: { label: '待响应', cls: 'text-amber-600 bg-amber-50' },
  done: { label: '完成', cls: 'text-green-600 bg-green-50' },
  error: { label: '错误', cls: 'text-red-600 bg-red-50' },
}
function Pill({ text, cls }: { text: string; cls: string }) {
  return <span className={`px-2 py-[1px] rounded-full text-[10.5px] font-medium ${cls}`}>{text}</span>
}
function StatusPill({ status }: { status: string }) {
  const s = STATUS[status] ?? { label: status, cls: 'text-gray-500 bg-gray-100' }
  return <Pill text={s.label} cls={s.cls} />
}
function IconBox({ tint, glyph, size = 32 }: { tint: string; glyph: string; size?: number }) {
  return (
    <div className="rounded-lg flex items-center justify-center font-semibold shrink-0"
      style={{ width: size, height: size, fontSize: size * 0.4, background: tint + '1F', color: tint }}>
      {glyph}
    </div>
  )
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

function Card({ active, tint, glyph, title, time, pill, sub, onClick }: {
  active: boolean; tint: string; glyph: string; title: string; time?: string
  pill?: React.ReactNode; sub?: string; onClick: () => void
}) {
  return (
    <button onClick={onClick}
      className={`w-full text-left flex gap-3 items-start p-3 rounded-[10px] border transition
        ${active ? 'bg-selbg border-selborder' : 'bg-white border-line hover:bg-gray-50'}`}>
      <IconBox tint={tint} glyph={glyph} />
      <div className="min-w-0 flex-1">
        <div className="flex items-center gap-2">
          <div className="font-semibold text-[13.5px] text-ink truncate flex-1">{title || '新会话'}</div>
          {time && <div className="text-[11px] text-faint shrink-0">{time}</div>}
        </div>
        <div className="mt-1 flex items-center gap-2">
          {pill}
          {sub && <span className="text-[11px] text-sub truncate">{sub}</span>}
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
        className="text-[12px] text-brand px-2 py-0.5 rounded-md hover:bg-blue-50">+ 新建</button>
      {open && (
        <>
          <div className="fixed inset-0 z-10" onClick={() => setOpen(false)} />
          <div className="absolute right-0 mt-1 z-20 bg-white border border-line rounded-lg shadow-lg py-1 w-32">
            <button onClick={() => { cmd.continueLast(workdir); setOpen(false) }}
              className="w-full text-left px-3 py-1.5 text-[12px] hover:bg-gray-50">继续最近</button>
            <button onClick={() => { cmd.newSession(workdir); setOpen(false) }}
              className="w-full text-left px-3 py-1.5 text-[12px] hover:bg-gray-50">全新会话</button>
          </div>
        </>
      )}
    </div>
  )
}

// —— 消息渲染 ——
function UserBubble({ text }: { text: string }) {
  return (
    <div className="flex justify-end">
      <div className="max-w-[80%] px-3 py-2 rounded-xl bg-[#EAF1FE] text-[13px] text-ink whitespace-pre-wrap break-words select-text">{text}</div>
    </div>
  )
}
function MessageRow({ m, onRespond }: { m: Msg; onRespond?: (reqId: string, choose: string[]) => void }) {
  if (m.kind === 'text' && m.role === 'user') return <UserBubble text={m.text} />
  if (m.kind === 'text') {
    return (
      <div className="flex gap-2.5">
        <div className="w-6 h-6 rounded-md bg-blue-50 text-brand flex items-center justify-center text-[11px] shrink-0">✦</div>
        <div className="text-[13px] text-ink whitespace-pre-wrap break-words select-text leading-relaxed">{m.text}</div>
      </div>
    )
  }
  if (m.kind === 'tool') {
    const i = m.text.indexOf(':')
    const name = i > 0 ? m.text.slice(0, i) : m.text
    const arg = i > 0 ? m.text.slice(i + 1).trim() : ''
    return (
      <div className="flex gap-2.5">
        <div className="w-6 h-6 rounded-md bg-gray-100 text-sub flex items-center justify-center text-[11px] shrink-0">⌘</div>
        <div className="flex-1 rounded-[10px] border border-line p-2.5">
          <div className="text-[12px] font-semibold text-ink mb-1.5">{name}</div>
          {arg && <pre className="text-[12px] font-mono bg-panel rounded-lg p-2.5 whitespace-pre-wrap break-words select-text">{arg}</pre>}
        </div>
      </div>
    )
  }
  if (m.kind === 'permission') {
    const r = m.permState
    const tone = r == null ? 'border-amber-200 bg-amber-50' : r === 'allow' ? 'border-green-200 bg-green-50' : 'border-red-200 bg-red-50'
    return (
      <div className={`rounded-[10px] border p-3 ${tone}`}>
        <div className="text-[12px] font-semibold mb-1.5">{r == null ? '需要你处理' : r === 'allow' ? '✓ 已允许' : '✕ 已拒绝'}</div>
        <pre className="text-[12px] font-mono bg-white/70 rounded-lg p-2.5 whitespace-pre-wrap break-words select-text">{m.text}</pre>
        {r == null && onRespond && (
          <div className="mt-2 flex gap-2">
            <button onClick={() => onRespond(m.permReqId ?? '', ['deny'])} className="px-3 py-1 rounded-lg text-[12px] border border-line bg-white">拒绝</button>
            <button onClick={() => onRespond(m.permReqId ?? '', ['allow'])} className="px-3 py-1 rounded-lg text-[12px] text-white bg-brand">允许</button>
          </div>
        )}
      </div>
    )
  }
  return null
}

function MsgList({ msgs, onRespond }: { msgs: Msg[]; onRespond?: (r: string, c: string[]) => void }) {
  const ref = useRef<HTMLDivElement>(null)
  const ordered = useMemo(() => [...msgs].sort((a, b) => a.ord - b.ord), [msgs])
  useEffect(() => { const el = ref.current; if (el) el.scrollTop = el.scrollHeight }, [ordered.length])
  return (
    <div ref={ref} className="flex-1 overflow-auto px-4 py-4 space-y-3.5">
      {ordered.map((m) => <MessageRow key={m.id} m={m} onRespond={onRespond} />)}
    </div>
  )
}

function Header({ title, sub, right }: { title: string; sub?: string; right?: React.ReactNode }) {
  return (
    <div className="titlebar-pad px-4 pb-2.5 flex items-center gap-2 border-b border-line">
      <div className="font-semibold text-[14px] text-ink truncate">{title}</div>
      {sub && <div className="text-[11px] text-faint truncate flex-1">{sub}</div>}
      <div className="ml-auto flex items-center gap-2">{right}</div>
    </div>
  )
}

function Conversation({ s }: { s: Session }) {
  const [draft, setDraft] = useState('')
  const submit = () => { const t = draft.trim(); if (!t) return; cmd.sendInput(s.id, t); setDraft('') }
  return (
    <div className="flex flex-col h-full">
      <Header title={s.title || '会话'} sub={s.workdir}
        right={<button onClick={() => cmd.closeSession(s.id)} className="text-[12px] text-sub px-2 py-1 rounded-md hover:bg-gray-100">结束会话</button>} />
      <MsgList msgs={s.messages} onRespond={(r, c) => cmd.respond(s.id, r, c)} />
      <div className="px-3 py-3 border-t border-line flex gap-2 items-end">
        <textarea value={draft} onChange={(e) => setDraft(e.target.value)}
          onKeyDown={(e) => { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); submit() } }}
          rows={1} placeholder="输入指令…(Enter 发送,Shift+Enter 换行)"
          className="flex-1 resize-none text-[13px] px-3 py-2 rounded-[10px] bg-panel border border-line focus:outline-none focus:border-brand select-text" />
        <button onClick={submit} disabled={!draft.trim()}
          className="w-9 h-9 rounded-[9px] bg-brand text-white disabled:bg-faint flex items-center justify-center">↑</button>
      </div>
    </div>
  )
}

function ManualView({ m, msgs }: { m: Manual; msgs: Msg[] }) {
  return (
    <div className="flex flex-col h-full">
      <Header title={m.title} sub={m.cwd} right={
        <>
          <Pill text="手动" cls="text-orange-600 bg-orange-50" />
          <button onClick={() => cmd.raiseWindow(m.id)}
            className="text-[12px] text-white bg-brand px-2.5 py-1 rounded-md">唤起 {m.terminal}</button>
        </>
      } />
      <MsgList msgs={msgs} />
      <div className="px-4 py-2 border-t border-line text-[11px] text-sub">手动会话:在 {m.terminal} 里输入,这里只读。</div>
    </div>
  )
}

function HistoryView({ h, workdir, msgs }: { h: History; workdir: string; msgs: Msg[] }) {
  return (
    <div className="flex flex-col h-full relative">
      <Header title={h.label} sub="历史会话 · 只读" right={<Pill text="只读" cls="text-gray-500 bg-gray-100" />} />
      <div className="flex-1 relative bg-panel/40" onClick={() => cmd.resume(workdir, h.id)}>
        <MsgList msgs={msgs} />
        <button onClick={(e) => { e.stopPropagation(); cmd.resume(workdir, h.id) }}
          className="absolute bottom-4 left-1/2 -translate-x-1/2 px-3.5 py-2 rounded-full bg-brand text-white text-[12px] font-medium shadow-lg">
          🔓 点击恢复会话
        </button>
      </div>
    </div>
  )
}

export default function App() {
  const state = useAgent()
  const transcripts = useTranscripts()
  const [sel, setSel] = useState<Sel>(null)

  // 选中历史/手动 → 拉转录(只读浏览)
  useEffect(() => {
    if (sel?.kind === 'history' && !transcripts[sel.id]) cmd.loadTranscript('history', sel.id, sel.workdir)
    if (sel?.kind === 'manual' && !transcripts[sel.id]) cmd.loadTranscript('manual', sel.id)
  }, [sel, transcripts])

  // 选中失效则清空
  useEffect(() => {
    if (sel?.kind === 'session' && !state.sessions.some((s) => s.id === sel.id)) setSel(null)
    if (sel?.kind === 'manual' && !state.manual.some((m) => m.id === sel.id)) setSel(null)
  }, [state, sel])

  const inProject = (cwd: string, wd: string) => cwd === wd || cwd.startsWith(wd + '/')

  const right = useMemo(() => {
    if (!sel) return null
    if (sel.kind === 'session') { const s = state.sessions.find((x) => x.id === sel.id); return s ? <Conversation s={s} /> : null }
    if (sel.kind === 'manual') { const m = state.manual.find((x) => x.id === sel.id); return m ? <ManualView m={m} msgs={transcripts[m.id] ?? []} /> : null }
    if (sel.kind === 'history') {
      const h = state.projects.flatMap((p) => p.history).find((x) => x.id === sel.id)
      return h ? <HistoryView h={h} workdir={sel.workdir} msgs={transcripts[h.id] ?? []} /> : null
    }
    return null
  }, [sel, state, transcripts])

  return (
    <div className="flex h-full">
      <div className="w-[300px] shrink-0 bg-panel border-r border-line flex flex-col">
        <div className="titlebar-pad px-4 pb-2 text-[11px] font-semibold text-faint tracking-wide">项目</div>
        <div className="flex-1 overflow-auto px-2.5 pb-3 space-y-3">
          {state.projects.length === 0 && (
            <div className="text-[12px] text-sub px-2 py-4">在电脑 VibeNotch「打开项目」后,这里会出现项目与会话。</div>
          )}
          {state.projects.map((p) => (
            <ProjectGroup key={p.workdir} p={p} state={state} sel={sel} setSel={setSel} inProject={inProject} />
          ))}
        </div>
      </div>
      <div className="flex-1 min-w-0">
        {right ?? <div className="h-full flex items-center justify-center text-sub text-[13px]">选择或新建一个会话</div>}
      </div>
    </div>
  )
}

function ProjectGroup({ p, state, sel, setSel, inProject }: {
  p: Project; state: ReturnType<typeof getState>; sel: Sel
  setSel: (s: Sel) => void; inProject: (cwd: string, wd: string) => boolean
}) {
  const consoleSessions = state.sessions.filter((s) => s.workdir === p.workdir)
  const manual = state.manual.filter((m) => inProject(m.cwd, p.workdir))
  const liveIds = new Set<string>([
    ...consoleSessions.map((s) => s.agentSessionId).filter(Boolean) as string[],
    ...manual.map((m) => m.id),
  ])
  const history = p.history.filter((h) => !liveIds.has(h.id))
  const empty = consoleSessions.length === 0 && manual.length === 0 && history.length === 0

  return (
    <div>
      <div className="flex items-center justify-between px-1 mb-1.5">
        <div className="text-[12px] font-semibold text-ink truncate">{p.name}</div>
        <NewMenu workdir={p.workdir} />
      </div>
      <div className="space-y-1.5">
        {consoleSessions.map((s) => (
          <Card key={s.id} active={sel?.kind === 'session' && sel.id === s.id}
            tint={s.agent === 'codex' ? '#7C5CD6' : '#2563EB'} glyph={s.agent === 'codex' ? 'Cx' : 'CC'}
            title={s.title} time={relTime(s.startedAt)} pill={<StatusPill status={s.status} />}
            onClick={() => setSel({ kind: 'session', id: s.id })} />
        ))}
        {manual.map((m) => (
          <Card key={m.id} active={sel?.kind === 'manual' && sel.id === m.id}
            tint="#E8810C" glyph="✋" title={m.title} time={relTime(m.lastActivityAt)}
            pill={<Pill text="手动" cls="text-orange-600 bg-orange-50" />} sub={m.terminal}
            onClick={() => setSel({ kind: 'manual', id: m.id })} />
        ))}
        {history.map((h) => (
          <Card key={h.id} active={sel?.kind === 'history' && sel.id === h.id}
            tint="#9CA3AF" glyph="◷" title={h.label} time={relTime(h.mtime)}
            pill={<Pill text="历史" cls="text-gray-500 bg-gray-100" />} sub="已结束"
            onClick={() => setSel({ kind: 'history', id: h.id, workdir: p.workdir })} />
        ))}
        {empty && <div className="text-[11px] text-faint px-1 pb-1">未打开会话</div>}
      </div>
    </div>
  )
}
