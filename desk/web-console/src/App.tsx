import { useSyncExternalStore, useState, useMemo, useRef, useEffect } from 'react'
import { subscribe, getState } from './store'
import { cmd } from './bridge'
import type { Session, Msg } from './types'

function useAgent() {
  return useSyncExternalStore(subscribe, getState, getState)
}

const STATUS: Record<string, { label: string; cls: string }> = {
  starting: { label: '启动中', cls: 'text-amber-600 bg-amber-50' },
  idle: { label: '就绪', cls: 'text-brand bg-blue-50' },
  working: { label: '运行中', cls: 'text-green-600 bg-green-50' },
  waitingInput: { label: '挂起', cls: 'text-gray-500 bg-gray-100' },
  needsResponse: { label: '待响应', cls: 'text-amber-600 bg-amber-50' },
  done: { label: '完成', cls: 'text-green-600 bg-green-50' },
  error: { label: '错误', cls: 'text-red-600 bg-red-50' },
}

function StatusPill({ status }: { status: string }) {
  const s = STATUS[status] ?? { label: status, cls: 'text-gray-500 bg-gray-100' }
  return <span className={`px-2 py-[1px] rounded-full text-[10.5px] font-medium ${s.cls}`}>{s.label}</span>
}

function IconBox({ tint, glyph }: { tint: string; glyph: string }) {
  return (
    <div className="w-8 h-8 rounded-lg flex items-center justify-center text-[13px] font-semibold shrink-0"
         style={{ background: tint + '1F', color: tint }}>
      {glyph}
    </div>
  )
}

function SessionCard({ s, active, onClick }: { s: Session; active: boolean; onClick: () => void }) {
  const tint = s.agent === 'codex' ? '#7C5CD6' : '#2563EB'
  return (
    <button onClick={onClick}
      className={`w-full text-left flex gap-3 items-start p-3 rounded-[10px] border transition
        ${active ? 'bg-selbg border-selborder' : 'bg-white border-line hover:bg-gray-50'}`}>
      <IconBox tint={tint} glyph={s.agent === 'codex' ? 'Cx' : 'CC'} />
      <div className="min-w-0 flex-1">
        <div className="flex items-center gap-2">
          <div className="font-semibold text-[13.5px] text-ink truncate flex-1">{s.title || '新会话'}</div>
        </div>
        <div className="mt-1 flex items-center gap-2">
          <StatusPill status={s.status} />
        </div>
      </div>
    </button>
  )
}

function UserBubble({ text }: { text: string }) {
  return (
    <div className="flex justify-end">
      <div className="max-w-[80%] px-3 py-2 rounded-xl bg-[#EAF1FE] text-[13px] text-ink whitespace-pre-wrap break-words select-text">
        {text}
      </div>
    </div>
  )
}

function MessageRow({ m, onRespond }: { m: Msg; onRespond: (reqId: string, choose: string[]) => void }) {
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
    const resolved = m.permState
    const tone = resolved == null ? 'amber' : resolved === 'allow' ? 'green' : 'red'
    return (
      <div className={`rounded-[10px] border p-3 ${tone === 'amber' ? 'border-amber-200 bg-amber-50' : tone === 'green' ? 'border-green-200 bg-green-50' : 'border-red-200 bg-red-50'}`}>
        <div className="text-[12px] font-semibold mb-1.5">{resolved == null ? '需要你处理' : resolved === 'allow' ? '✓ 已允许' : '✕ 已拒绝'}</div>
        <pre className="text-[12px] font-mono bg-white/70 rounded-lg p-2.5 whitespace-pre-wrap break-words select-text">{m.text}</pre>
        {resolved == null && (
          <div className="mt-2 flex gap-2">
            <button onClick={() => onRespond(m.permReqId ?? '', ['deny'])}
              className="px-3 py-1 rounded-lg text-[12px] border border-line bg-white">拒绝</button>
            <button onClick={() => onRespond(m.permReqId ?? '', ['allow'])}
              className="px-3 py-1 rounded-lg text-[12px] text-white bg-brand">允许</button>
          </div>
        )}
      </div>
    )
  }
  return null
}

function Conversation({ s }: { s: Session }) {
  const [draft, setDraft] = useState('')
  const scrollRef = useRef<HTMLDivElement>(null)
  const ordered = useMemo(
    () => [...s.messages].sort((a, b) => (a.ord !== b.ord ? a.ord - b.ord : 0)),
    [s.messages],
  )
  useEffect(() => {
    const el = scrollRef.current
    if (el) el.scrollTop = el.scrollHeight
  }, [ordered.length, s.id])

  const submit = () => {
    const t = draft.trim()
    if (!t) return
    cmd.sendInput(s.id, t)
    setDraft('')
  }

  return (
    <div className="flex flex-col h-full">
      <div className="titlebar-pad px-4 pb-2.5 flex items-center gap-2 border-b border-line">
        <div className="font-semibold text-[14px] text-ink truncate">{s.title || '会话'}</div>
        <div className="text-[11px] text-faint truncate flex-1">{s.workdir}</div>
        <button onClick={() => cmd.closeSession(s.id)}
          className="text-[12px] text-sub px-2 py-1 rounded-md hover:bg-gray-100">结束会话</button>
      </div>
      <div ref={scrollRef} className="flex-1 overflow-auto px-4 py-4 space-y-3.5">
        {ordered.map((m) => (
          <MessageRow key={m.id} m={m} onRespond={(reqId, choose) => cmd.respond(s.id, reqId, choose)} />
        ))}
      </div>
      <div className="px-3 py-3 border-t border-line flex gap-2 items-end">
        <textarea
          value={draft}
          onChange={(e) => setDraft(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); submit() }
          }}
          rows={1}
          placeholder="输入指令…(Enter 发送,Shift+Enter 换行)"
          className="flex-1 resize-none text-[13px] px-3 py-2 rounded-[10px] bg-panel border border-line focus:outline-none focus:border-brand select-text"
        />
        <button onClick={submit} disabled={!draft.trim()}
          className="w-9 h-9 rounded-[9px] bg-brand text-white disabled:bg-faint flex items-center justify-center">↑</button>
      </div>
    </div>
  )
}

export default function App() {
  const state = useAgent()
  const [selected, setSelected] = useState<string | null>(null)

  const active = state.sessions.find((s) => s.id === selected) ?? null
  // 切换/移除会话时保持选中有效
  useEffect(() => {
    if (selected && !state.sessions.some((s) => s.id === selected)) setSelected(null)
    if (!selected && state.sessions.length) setSelected(state.sessions[0].id)
  }, [state.sessions, selected])

  const byProject = useMemo(() => {
    const map = new Map<string, Session[]>()
    for (const s of state.sessions) {
      const arr = map.get(s.workdir) ?? []
      arr.push(s); map.set(s.workdir, arr)
    }
    return map
  }, [state.sessions])

  return (
    <div className="flex h-full">
      {/* 左:项目 + 会话 */}
      <div className="w-[300px] shrink-0 bg-panel border-r border-line flex flex-col">
        <div className="titlebar-pad px-4 pb-2 text-[11px] font-semibold text-faint tracking-wide">项目</div>
        <div className="flex-1 overflow-auto px-2.5 pb-3 space-y-3">
          {state.projects.length === 0 && (
            <div className="text-[12px] text-sub px-2 py-4">在电脑 VibeNotch「打开项目」后,这里会出现项目与会话。</div>
          )}
          {state.projects.map((p) => {
            const ss = byProject.get(p.workdir) ?? []
            return (
              <div key={p.workdir}>
                <div className="flex items-center justify-between px-1 mb-1.5">
                  <div className="text-[12px] font-semibold text-ink truncate">{p.name}</div>
                  <button onClick={() => cmd.newSession(p.workdir)}
                    className="text-[12px] text-brand px-2 py-0.5 rounded-md hover:bg-blue-50">+ 新建</button>
                </div>
                <div className="space-y-1.5">
                  {ss.map((s) => (
                    <SessionCard key={s.id} s={s} active={s.id === selected} onClick={() => setSelected(s.id)} />
                  ))}
                  {ss.length === 0 && <div className="text-[11px] text-faint px-1 pb-1">未打开会话</div>}
                </div>
              </div>
            )
          })}
        </div>
      </div>
      {/* 右:对话 */}
      <div className="flex-1 min-w-0">
        {active ? <Conversation s={active} /> : (
          <div className="h-full flex items-center justify-center text-sub text-[13px]">选择或新建一个会话</div>
        )}
      </div>
    </div>
  )
}
