import { useSyncExternalStore, useState, useMemo, useRef, useEffect, useLayoutEffect, useCallback, memo } from 'react'
import { createPortal } from 'react-dom'
import hljs from 'highlight.js'
import { marked } from 'marked'
import {
  Folder, ChevronRight, ChevronDown, ChevronsUpDown, ArrowUp,
  RotateCcw, AppWindow, Plus, X, Paperclip, Sun, Moon, SlidersHorizontal,
  BarChart3, PanelsTopLeft, Copy, FileText, Check, Server, MoreHorizontal, Pencil, EyeOff, Trash2,
  Activity, DollarSign, Boxes, Database, GitBranch, MessageSquare, Clipboard, Code2, User,
} from 'lucide-react'
import { subscribe, getState, getTranscripts, getTranscriptMeta, getDirs, getFiles, getUsage, getConn, getPrefs, getImgUpload } from './store'
import { cmd, auth, type AgentId } from './bridge'
import type { Session, Msg, Manual, History, Project, Entry, UsageData, MsgImage, Pending } from './types'
import { mockGit, PROVIDERS } from './mock'
import type { GitStatus } from './mock'

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
function usePrefs() { return useSyncExternalStore(subscribe, getPrefs, getPrefs) }

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
  // manual 会话只要还在列表里 = 进程还活着(SessionEnd 才会移出)。done/suspended/idle
  // 都是「回完一轮、在等你输入」,而非结束 → 显示绿色「在线」,不要画成灰色「空闲」让人误以为已结束。
  return { text: '在线', color: 'var(--green)' }
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
const Markdown = memo(function Markdown({ text }: { text: string }) {
  const html = useMemo(() => marked.parse(text, { gfm: true, breaks: true, async: false }) as string, [text])
  return <div className="md flex-1 text-[13.5px] leading-[1.72] text-ink select-text min-w-0" dangerouslySetInnerHTML={{ __html: html }} />
})

// 用户消息里的图片:缩略图栅格 + 点击看全图(lightbox)
function UserImages({ images }: { images: MsgImage[] }) {
  const [zoom, setZoom] = useState<string | null>(null)
  // 通道只给 id,字节由 VibeNotch 经 app:// 按 id 代取(本地缓存命中或回源)
  const srcOf = (im: MsgImage) => `app://local/__img/${im.id}.${im.ext || 'png'}`
  return (
    <>
      <div className="flex flex-wrap gap-1.5 justify-end max-w-[78%]">
        {images.map((im, i) => (
          <img key={i} src={srcOf(im)} alt="" onClick={() => setZoom(srcOf(im))}
            className="max-w-[180px] max-h-[220px] rounded-[12px] object-cover border border-line cursor-zoom-in transition hover:brightness-90" />
        ))}
      </div>
      {zoom && createPortal(
        <div onClick={() => setZoom(null)} className="fixed inset-0 z-[1000] flex items-center justify-center p-6 cursor-zoom-out animate-fade" style={{ background: 'rgba(0,0,0,.85)' }}>
          <img src={zoom} alt="" className="max-w-full max-h-full rounded-lg object-contain shadow-pop" />
        </div>,
        document.body,
      )}
    </>
  )
}

// 排队消息弹幕:一条条暗色行(图标+透明文字、无背景),图片显示小缩略图、可点预览。
function QueueDanmaku({ items }: { items: { text: string; images?: { id: string; ext: string }[] }[] }) {
  const [zoom, setZoom] = useState<string | null>(null)
  const srcOf = (im: { id: string; ext: string }) => `app://local/__img/${im.id}.${im.ext || 'png'}`
  return (
    <>
      {items.slice(-6).map((q, i) => (
        <div key={i} className="flex items-start gap-2 text-[13px] leading-[1.5] animate-msg" style={{ opacity: 0.55 }}>
          <User size={13} className="mt-[3px] shrink-0" style={{ color: 'var(--text-faint)' }} />
          <div className="flex flex-col gap-1 min-w-0 pointer-events-auto">
            {q.images && q.images.length > 0 && (
              <div className="flex flex-wrap gap-1.5">
                {q.images.map((im, k) => (
                  <img key={k} src={srcOf(im)} alt="" onClick={() => setZoom(srcOf(im))}
                    className="h-[60px] w-auto max-w-[160px] rounded-lg object-cover border border-line cursor-zoom-in" />
                ))}
              </div>
            )}
            {q.text && <span className="whitespace-nowrap" style={{ color: 'var(--text-dim)', textShadow: '0 1px 4px var(--bg), 0 0 4px var(--bg)' }} title={q.text}>{q.text}</span>}
          </div>
        </div>
      ))}
      {zoom && createPortal(
        <div onClick={() => setZoom(null)} className="fixed inset-0 z-[1000] flex items-center justify-center p-6 cursor-zoom-out animate-fade" style={{ background: 'rgba(0,0,0,.85)' }}>
          <img src={zoom} alt="" className="max-w-full max-h-full rounded-lg object-contain shadow-pop" />
        </div>, document.body)}
    </>
  )
}

// ===== 消息渲染:助手回合 = 思考文本 + 动作时间线(读取/编辑/新建/命令)=====
// verb / 配色 / 节点(对齐设计稿 opMeta）
type OpKindT = 'read' | 'edit' | 'write' | 'bash' | 'other'
const OP_META: Record<OpKindT, { label: string; c: string; bg: string; node: string; icon: string }> = {
  read: { label: '读取', c: 'var(--text-dim)', bg: 'var(--bg-sunken)', node: 'var(--bg-sunken)', icon: 'var(--text-dim)' },
  edit: { label: '编辑', c: 'var(--amber)', bg: 'color-mix(in srgb,var(--amber) 15%,transparent)', node: 'color-mix(in srgb,var(--amber) 15%,transparent)', icon: 'var(--amber)' },
  write: { label: '新建', c: 'var(--green)', bg: 'color-mix(in srgb,var(--green) 15%,transparent)', node: 'color-mix(in srgb,var(--green) 15%,transparent)', icon: 'var(--green)' },
  bash: { label: '命令', c: 'var(--accent)', bg: 'var(--accent-soft)', node: 'var(--term-bg)', icon: 'var(--term-green)' },
  other: { label: '工具', c: 'var(--text-dim)', bg: 'var(--bg-sunken)', node: 'var(--bg-sunken)', icon: 'var(--text-dim)' },
}
// 节点图标(SVG path,对齐设计稿 TOOL_ICON)
const TOOL_ICON: Record<OpKindT, string> = {
  read: 'M14 3v4a1 1 0 0 0 1 1h4 M6 3h8l5 5v11a1 1 0 0 1-1 1H6a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1z',
  edit: 'M12 20h9 M16.5 3.5a2.12 2.12 0 0 1 3 3L7 19l-4 1 1-4z',
  write: 'M14 3v4a1 1 0 0 0 1 1h4 M6 3h8l5 5v11a1 1 0 0 1-1 1H6a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1z M12 11v6 M9 14h6',
  bash: 'M4 17l6-6-6-6 M12 19h8',
  other: 'M11 19a8 8 0 1 0 0-16 8 8 0 0 0 0 16z M21 21l-4.35-4.35',
}
const NAME_KIND: Record<string, OpKindT> = {
  Read: 'read', NotebookRead: 'read', Edit: 'edit', MultiEdit: 'edit', NotebookEdit: 'edit',
  Write: 'write', Create: 'write', Bash: 'bash', Shell: 'bash',
}

// 一条标准化动作:有 m.op 用之,否则从 m.text(旧式 "Name: arg" / 文件路径)兜底合成
type NormOp = {
  kind: OpKindT; verb: string; file: string; dir: string; path: string
  add?: number; del?: number; sameFile?: boolean; command?: string
  diff?: { k: string; t: string }[]; output?: string[]
}
function opOf(m: Msg): NormOp {
  const raw = m.kind === 'file' ? m.text
    : m.text.includes(':') ? m.text.slice(m.text.indexOf(':') + 1).trim() : m.text
  if (m.op) {
    const o = m.op
    return {
      kind: o.kind, verb: o.label || OP_META[o.kind]?.label || '工具',
      file: o.file || (raw.split('/').pop() || raw), dir: o.dir, path: raw,
      add: o.add, del: o.del, sameFile: o.sameFile, command: o.command, diff: o.diff, output: o.output,
    }
  }
  // 兜底:kind:file(无 op,如 codex)→ 当编辑;kind:tool 旧式 "Name: arg"
  if (m.kind === 'file') {
    return { kind: 'edit', verb: '编辑', file: raw.split('/').pop() || raw, dir: raw.split('/').slice(-3, -1).join('/'), path: raw }
  }
  const name = m.text.includes(':') ? m.text.slice(0, m.text.indexOf(':')) : m.text
  const kind = NAME_KIND[name] || 'other'
  return {
    kind, verb: kind === 'other' ? name : OP_META[kind].label,
    file: kind === 'bash' ? (raw.split(' ')[0] || 'bash') : (raw.split('/').pop() || raw),
    dir: kind === 'bash' ? '' : raw.split('/').slice(-3, -1).join('/'),
    path: raw, command: kind === 'bash' ? raw : undefined,
  }
}

// 时间线里一行动作:
//  · edit → 点行展开 diff;点文件名直接跳到 Files 打开
//  · bash → 点行展开终端(始终显示完整 $ 命令 + 输出)
//  · read/write/other → 点行/点文件名跳到 Files 打开
function OpRow({ op, first, last, root, onOpenFile }: { op: NormOp; first: boolean; last: boolean; root?: string; onOpenFile?: (p: string) => void }) {
  const meta = OP_META[op.kind]
  const isBash = op.kind === 'bash'
  const hasDiff = op.kind === 'edit' && !!op.diff?.length
  const expandable = hasDiff || (isBash && !!op.command)            // bash 始终可展开看全命令
  const [open, setOpen] = useState(expandable)   // edit(改文件)/ bash 默认展开:用户要直接看改了啥 / 命令
  // 只有「项目内的文件操作」才允许跳转打开:other(Monitor 等命令)/bash/项目外路径一律不可点
  const inProj = !!root && !!op.path && (op.path === root || op.path.startsWith(root.endsWith('/') ? root : root + '/'))
  const openable = (op.kind === 'read' || op.kind === 'edit' || op.kind === 'write') && !!op.path && !!onOpenFile && inProj
  // 点整行:可展开的(edit/bash)→ 切换展开;否则可打开 → 跳转
  const rowClick = expandable ? () => setOpen(v => !v) : openable ? () => onOpenFile!(op.path) : undefined
  // 文件名单独点:始终优先「打开文件」(edit 行点文件名也能直接跳转)
  const fileClick = openable ? (e: React.MouseEvent) => { e.stopPropagation(); onOpenFile!(op.path) } : undefined
  const action = isBash ? (open ? '收起' : '终端') : hasDiff ? (open ? '收起' : 'diff') : '打开'
  return (
    <div className="relative flex gap-[13px]">
      <div className="w-[24px] flex-none flex justify-center relative">
        <span className="absolute top-0 h-[15px] w-[1.5px]" style={{ background: first ? 'transparent' : 'var(--border-strong)' }} />
        <span className="absolute top-[15px] bottom-0 w-[1.5px]" style={{ background: last ? 'transparent' : 'var(--border-strong)' }} />
        <span className="absolute top-[5px] w-[21px] h-[21px] rounded-[6px] flex items-center justify-center" style={{ background: meta.node, boxShadow: '0 0 0 3px var(--bg-elev)' }}>
          <svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke={meta.icon} strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
            {TOOL_ICON[op.kind].split(' M').map((d, i) => <path key={i} d={i === 0 ? d : 'M' + d} />)}
          </svg>
        </span>
      </div>
      <div className="flex-1 min-w-0" style={{ paddingBottom: last ? 0 : '3px' }}>
        <div onClick={rowClick} className="group flex items-center gap-[9px] px-[11px] py-[7px] rounded-[9px] transition-colors hover:bg-sunken min-w-0"
          style={{ cursor: rowClick ? 'pointer' : 'default' }}>
          <span className="text-[10.5px] font-semibold flex-none" style={{ color: meta.c, background: meta.bg, padding: '2px 7px', borderRadius: 5, letterSpacing: '.02em' }}>{op.verb}</span>
          <span onClick={fileClick} title={fileClick ? '在 Files 里打开' : op.file}
            className={'font-mono text-[12.5px] font-semibold text-ink truncate flex-none' + (fileClick ? ' hover:underline cursor-pointer' : '')}
            style={{ maxWidth: op.dir || op.sameFile ? '52%' : '88%' }}>{op.file}</span>
          {op.sameFile
            ? <span className="text-[10.5px] text-faint flex-1 min-w-0">同一文件</span>
            : op.dir && <span className="font-mono text-[11px] text-faint whitespace-nowrap overflow-hidden text-ellipsis min-w-0 flex-1" style={{ direction: 'rtl', textAlign: 'left' }}>{op.dir}</span>}
          <span className="flex-1 min-w-[8px]" />
          {op.add != null && op.add > 0 && <span className="font-mono text-[11px] flex-none" style={{ color: 'var(--green)' }}>+{op.add}</span>}
          {op.del != null && op.del > 0 && <span className="font-mono text-[11px] flex-none" style={{ color: 'var(--red)' }}>−{op.del}</span>}
          {(expandable || openable) && (
            <span className="flex items-center gap-[3px] text-[11px] text-faint flex-none opacity-0 group-hover:opacity-100 transition-opacity whitespace-nowrap">
              {action}<ChevronRight size={12} style={{ transform: open ? 'rotate(90deg)' : 'none', transition: 'transform .18s' }} />
            </span>
          )}
        </div>
        {isBash && open && (
          <div className="mt-[7px] rounded-[10px] overflow-hidden" style={{ background: 'var(--term-bg)', border: '1px solid var(--term-border)' }}>
            <div className="px-3 py-2 flex items-start gap-2" style={{ borderBottom: op.output?.length ? '1px solid var(--term-border)' : 'none' }}>
              <span className="font-mono text-[12px] mt-px" style={{ color: 'var(--term-green)' }}>$</span>
              <span className="font-mono text-[11.5px] flex-1 break-all select-text" style={{ color: 'var(--term-text)' }}>{op.command}</span>
            </div>
            {!!op.output?.length && (
              <div className="px-3 py-2.5 font-mono text-[11.5px] leading-[1.7] max-h-[280px] overflow-auto select-text">
                {op.output!.map((l, i) => <div key={i} className="whitespace-pre" style={{ color: 'var(--term-text)' }}>{l}</div>)}
              </div>
            )}
          </div>
        )}
        {hasDiff && open && (
          <div className="mt-[7px] border border-line rounded-[10px] bg-elev font-mono text-[11.5px] leading-[1.65] max-h-[320px] overflow-auto select-text">
            {op.diff!.map((d, i) => {
              const st: React.CSSProperties = d.k === 'add' ? { background: 'color-mix(in srgb,var(--green) 12%,transparent)', color: 'var(--green)' }
                : d.k === 'del' ? { background: 'color-mix(in srgb,var(--red) 12%,transparent)', color: 'var(--red)' } : { color: 'var(--text-dim)' }
              return <div key={i} className="whitespace-pre px-3 py-[2px]" style={st}>{(d.k === 'add' ? '+ ' : d.k === 'del' ? '− ' : '  ') + d.t}</div>
            })}
          </div>
        )}
      </div>
    </div>
  )
}

// 一段连续工具/文件 → 时间线(共用左侧轨道)
const OpsTimeline = memo(function OpsTimeline({ ops, root, onOpenFile }: { ops: { id: string; op: NormOp }[]; root?: string; onOpenFile?: (p: string) => void }) {
  return (
    <div className="relative my-[2px]">
      {ops.map((x, i) => <OpRow key={x.id} op={x.op} first={i === 0} last={i === ops.length - 1} root={root} onOpenFile={onOpenFile} />)}
    </div>
  )
}, (a, b) => a.onOpenFile === b.onOpenFile && a.root === b.root && a.ops.length === b.ops.length &&
  a.ops.every((x, i) => x.id === b.ops[i].id && (x.op.output?.length ?? 0) === (b.ops[i].op.output?.length ?? 0) &&
    x.op.add === b.ops[i].op.add && x.op.del === b.ops[i].op.del))

// 审批/权限卡(Bash 等就地审批)
function PermissionCard({ m, onRespond }: { m: Msg; onRespond?: (reqId: string, choose: string[]) => void }) {
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

// 待办/任务编排类工具在终端里不作为动作行出现,时间线里也隐藏,避免噪音
const HIDE_TOOLS = new Set(['TodoWrite', 'TaskCreate', 'TaskUpdate', 'TaskList', 'TaskGet', 'TaskOutput', 'TaskStop'])
function isHiddenTool(m: Msg): boolean {
  if (m.kind !== 'tool') return false
  const name = m.text.includes(':') ? m.text.slice(0, m.text.indexOf(':')) : m.text
  return HIDE_TOOLS.has(name.trim())
}

// claude 模型 id → 友好名(忠实展示实际模型):claude-3-5-sonnet-… → "Claude 3.5 Sonnet";claude-opus-4-8 → "Claude Opus 4.8"
function prettyModelName(id?: string): string {
  if (!id) return ''
  const m = id.toLowerCase()
  const fam = m.includes('opus') ? 'Opus' : m.includes('sonnet') ? 'Sonnet' : m.includes('haiku') ? 'Haiku' : ''
  if (!fam) return id
  const vm = m.match(/(\d+)-(\d+)/)
  if (!vm) return `Claude ${fam}`
  const ver = `${vm[1]}.${vm[2]}`
  const famIdx = m.search(/opus|sonnet|haiku/)
  const verIdx = vm.index ?? -1
  return verIdx >= 0 && verIdx < famIdx ? `Claude ${ver} ${fam}` : `Claude ${fam} ${ver}`
}
// 聊天头的相对时间:刚刚 / N 分钟前 / HH:MM / M-D HH:MM(比列表的 relTime 更细)
function chatTime(ms?: number): string {
  if (!ms) return ''
  const diff = Date.now() - ms
  if (diff < 0) return ''
  if (diff < 60_000) return '刚刚'
  if (diff < 3_600_000) return `${Math.floor(diff / 60_000)} 分钟前`
  const d = new Date(ms)
  const hh = String(d.getHours()).padStart(2, '0'), mm = String(d.getMinutes()).padStart(2, '0')
  if (diff < 86_400_000) return `${hh}:${mm}`
  return `${d.getMonth() + 1}-${d.getDate()} ${hh}:${mm}`
}

// 一个助手回合:头(✦+模型+时间) + 按文档顺序铺开 思考文本 / 动作时间线 / 审批卡
function AssistantTurn({ items, model, root, onRespond, onOpenFile }: { items: Msg[]; model?: string; root?: string; onRespond?: (r: string, c: string[]) => void; onOpenFile?: (p: string) => void }) {
  const blocks: React.ReactNode[] = []
  let seg: { id: string; op: NormOp }[] = []
  const flush = (key: string) => { if (seg.length) { const s = seg; blocks.push(<OpsTimeline key={'ops' + key} ops={s} root={root} onOpenFile={onOpenFile} />); seg = [] } }
  for (const m of items) {
    if (m.kind === 'text') { flush(m.id); if (m.text) blocks.push(<Markdown key={m.id} text={m.text} />) }
    else if (m.kind === 'permission') { flush(m.id); blocks.push(<PermissionCard key={m.id} m={m} onRespond={onRespond} />) }
    else if (!isHiddenTool(m)) seg.push({ id: m.id, op: opOf(m) })   // tool / file(隐藏待办/任务编排)
  }
  flush('end')
  if (blocks.length === 0) return null   // 整回合只剩被隐藏的工具 → 不渲染空头
  // 模型/时间:优先用该回合消息上真实记录的(转录里 jsonl 的 model + timestamp),没有再回退会话当前模型
  const head = items.find((m) => m.model || m.ts)
  const turnModel = head?.model || model
  const turnTime = head?.ts
  return (
    <div className="flex flex-col gap-3">
      <div className="flex items-center gap-2">
        <div className="w-[22px] h-[22px] rounded-[7px] flex items-center justify-center text-[12px]" style={{ background: 'var(--accent-soft)', color: 'var(--accent)' }}>✦</div>
        {turnModel && <span className="text-[11.5px] font-medium text-dim">{prettyModelName(turnModel)}</span>}
        {turnTime ? <span className="text-[11px] text-faint">{chatTime(turnTime)}</span> : null}
      </div>
      {blocks}
    </div>
  )
}

// 待处理请求(审批 / 多选 / 计划确认)——之前桌面 web 没渲染,只到手机。点选项即应答。
function PendingCard({ p, onRespond }: { p: Pending; onRespond?: (reqId: string, choose: string[]) => void }) {
  return (
    <div className="rounded-[11px] border p-3.5 animate-pop" style={{ borderColor: 'var(--amber)', background: 'var(--bg-elev2)' }}>
      <div className="flex items-center gap-2 mb-2">
        <span className="w-2 h-2 rounded-full" style={{ background: 'var(--amber)' }} />
        <span className="text-[12.5px] font-semibold" style={{ color: 'var(--amber)' }}>{p.title || '需要你处理'}</span>
      </div>
      {p.detail && <pre className="font-mono text-[12px] rounded-lg p-2.5 bg-sunken text-ink whitespace-pre-wrap break-words select-text mb-2.5">{p.detail}</pre>}
      <div className="flex flex-wrap gap-2">
        {p.options.map((o, i) => {
          const primary = i === p.options.length - 1   // 末项一般是肯定项(允许/确认),高亮
          return (
            <button key={o.id} onClick={() => onRespond?.(p.id, [o.id])}
              className={`px-3.5 py-1.5 rounded-[9px] text-[12px] font-medium transition-colors ${primary ? 'text-accentfg hover:brightness-110' : 'border border-strong text-dim hover:bg-sunken'}`}
              style={primary ? { background: 'var(--accent)' } : undefined}>
              {o.label}
            </button>
          )
        })}
      </div>
    </div>
  )
}

type Block = { type: 'user'; m: Msg } | { type: 'system'; m: Msg } | { type: 'assistant'; items: Msg[]; key: string }
const MsgList = memo(function MsgList({ msgs, pending, onRespond, onOpenFile, working, model, root, animate = true, hasEarlier, onLoadEarlier }: {
  msgs: Msg[]; pending?: Pending[]; onRespond?: (r: string, c: string[]) => void; onOpenFile?: (path: string) => void; working?: boolean
  model?: string; root?: string; animate?: boolean; hasEarlier?: boolean; onLoadEarlier?: () => void
}) {
  const ref = useRef<HTMLDivElement>(null)
  const ordered = useMemo(() => [...msgs].sort((a, b) => a.ord - b.ord), [msgs])
  // 按助手回合分组:user/system 独立成块;连续助手消息(文本/工具/文件/审批)并成一个回合
  const blocks = useMemo(() => {
    const out: Block[] = []
    for (const m of ordered) {
      if (m.kind === 'text' && m.role === 'user') { out.push({ type: 'user', m }); continue }
      if (m.role === 'system') { out.push({ type: 'system', m }); continue }
      const last = out[out.length - 1]
      if (last && last.type === 'assistant') last.items.push(m)
      else out.push({ type: 'assistant', items: [m], key: m.id })
    }
    return out
  }, [ordered])
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
  }, [ordered, working, pending?.length])
  useEffect(() => { setLoading(false) }, [ordered.length, hasEarlier])
  // 微信式:上滑到接近顶部(滚动范围前 25%)就静默预载更早消息,不用点按钮。
  const onScroll = () => {
    const el = ref.current; if (!el || !hasEarlier || loading) return
    const range = el.scrollHeight - el.clientHeight
    if (range > 0 && el.scrollTop < range * 0.25) { setLoading(true); onLoadEarlier?.() }
  }
  return (
    <div ref={ref} onScroll={onScroll} className="flex-1 overflow-y-auto overflow-x-hidden">
      <div className="max-w-[780px] mx-auto px-7 py-5 space-y-4">
        {/* 预载静默进行;只有还没载完你就滑到顶,才看到这个「加载中」。 */}
        {hasEarlier && loading && (
          <div className="flex justify-center pb-1">
            <span className="flex items-center gap-1.5 px-3 py-1.5 text-[12px] text-faint">
              <span className="w-1.5 h-1.5 rounded-full bg-faint typing-dot" />加载更早消息…
            </span>
          </div>
        )}
        {blocks.map((b) => b.type === 'user' ? (
          <div key={b.m.id} className={animate ? 'animate-msg' : undefined}>
            <div className="flex flex-col items-end gap-1.5">
              {b.m.images && b.m.images.length > 0 && <UserImages images={b.m.images} />}
              {b.m.text && <div className="max-w-[78%] px-3.5 py-2.5 text-[13px] leading-[1.6] whitespace-pre-wrap break-words select-text text-accentfg" style={{ background: 'var(--accent)', borderRadius: '14px 14px 4px 14px' }}>{b.m.text}</div>}
            </div>
          </div>
        ) : b.type === 'system' ? (
          <div key={b.m.id} className={animate ? 'animate-msg' : undefined}>
            <div className="text-[12.5px] text-dim bg-sunken rounded-[11px] px-3.5 py-2.5 whitespace-pre-wrap break-words select-text">{b.m.text}</div>
          </div>
        ) : (
          <div key={b.key} className={animate ? 'animate-msg' : undefined}>
            <AssistantTurn items={b.items} model={model} root={root} onRespond={onRespond} onOpenFile={onOpenFile} />
          </div>
        ))}
        {pending?.map((p) => <div key={p.id} className="animate-msg"><PendingCard p={p} onRespond={onRespond} /></div>)}
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
}, (a, b) =>
  // 只比数据,忽略每次渲染都新建的回调:数据没变就不重渲染(背景会话在跑时不拖累当前列表)。
  a.msgs === b.msgs && a.pending === b.pending && a.working === b.working &&
  a.model === b.model && a.root === b.root && a.animate === b.animate && a.hasEarlier === b.hasEarlier )

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

type ModelOpt = { id: string; label: string }
// claude 兜底(availableModels 还没到的瞬间用):稳定别名,版本无关、永不过时。
const CLAUDE_FALLBACK: ModelOpt[] = [
  { id: 'opus', label: 'Opus' }, { id: 'sonnet', label: 'Sonnet' }, { id: 'haiku', label: 'Haiku' },
]
// 可切换模型:优先用 driver 动态下发的列表(claude 别名 / codex 真实 slug);
// 为空时 claude 用兜底别名,codex 留空(model/list 还在加载)。不再写死。
function modelOptions(agent?: string, models?: ModelOpt[]): ModelOpt[] {
  if (models && models.length) return models
  return agent === 'codex' ? [] : CLAUDE_FALLBACK
}
// 当前模型命中哪个选项:先精确(codex slug 完全相等),再包含(claude-opus-4-8 含 opus);
// 按 id 长度降序匹配,避免 gpt-5.4 误命中 gpt-5.4-mini。
function activeModelId(opts: ModelOpt[], model?: string): string | null {
  if (!model) return null
  const s = model.toLowerCase()
  const exact = opts.find((o) => o.id.toLowerCase() === s)
  if (exact) return exact.id
  const inc = [...opts].sort((a, b) => b.id.length - a.id.length).find((o) => s.includes(o.id.toLowerCase()))
  return inc?.id ?? null
}
// 切换按钮显示的当前模型名:claude 用动态解析的版本号(Opus 4.8);codex 用命中项的展示名。
function curModelLabel(agent: string | undefined, model: string | undefined, opts: ModelOpt[]): string {
  if (!model) return '默认'
  if (agent !== 'codex') return modelLabel(model)
  return opts.find((o) => o.id === activeModelId(opts, model))?.label ?? model
}

// ===== 附件(选中代码 / 粘贴长文本 / 图片 / 文件)=====
// 后端 send 只收纯文本 → 发送时把附件拼成文本前缀。代码引用真发,图片/文件仅本地展示并降级为说明。
type Attach =
  | { id: string; kind: 'code'; file: string; start: number; end: number; lang: string; snippet: string }
  | { id: string; kind: 'paste'; text: string }
  | { id: string; kind: 'file'; name: string; path: string; lang: string }
  | { id: string; kind: 'image'; name: string; dataUrl: string }

let _aid = 0
const newAid = () => `a${++_aid}`
type SetAttach = (fn: (prev: Attach[]) => Attach[]) => void
// 输入框草稿按会话 id 暂存(切会话工作区会重挂载 Composer,靠它保住未发送内容)
const draftStore: Record<string, string> = {}

function attachToText(a: Attach): string {
  if (a.kind === 'code') return `\`\`\`${a.lang}\n// ${a.file}:${a.start === a.end ? a.start : `${a.start}-${a.end}`}\n${a.snippet}\n\`\`\``
  if (a.kind === 'paste') return a.text
  if (a.kind === 'file') return `[附件文件: ${a.path}]`
  return `[附件图片: ${a.name}]`
}

function AttachChip({ a, onRemove }: { a: Attach; onRemove: () => void }) {
  return (
    <div className="flex items-center gap-2 pl-2 pr-1 py-1.5 rounded-[9px] border border-line bg-elev2 max-w-[230px]">
      {a.kind === 'image'
        ? <img src={a.dataUrl} alt="" className="w-[26px] h-[26px] rounded object-cover shrink-0" />
        : <span className="w-[22px] h-[22px] rounded-[6px] flex items-center justify-center shrink-0" style={{ background: 'var(--accent-soft)', color: 'var(--accent)' }}>
            {a.kind === 'code' ? <Code2 size={13} /> : a.kind === 'paste' ? <Clipboard size={13} /> : <FileText size={13} />}
          </span>}
      <div className="min-w-0 flex-1 leading-tight">
        {a.kind === 'code' && <><div className="text-[11.5px] text-ink truncate font-mono">{a.file}</div><div className="text-[10px] text-faint">{a.start === a.end ? `第 ${a.start} 行` : `${a.start}-${a.end} 行`}</div></>}
        {a.kind === 'paste' && <><div className="text-[11.5px] text-ink">已粘贴文本</div><div className="text-[10px] text-faint">{a.text.split('\n').length} 行 · {a.text.length} 字</div></>}
        {a.kind === 'file' && <><div className="text-[11.5px] text-ink truncate">{a.name}</div><div className="text-[10px] text-faint font-mono">{a.lang}</div></>}
        {a.kind === 'image' && <div className="text-[11.5px] text-ink truncate font-mono">{a.name}</div>}
      </div>
      <button onClick={onRemove} className="w-5 h-5 rounded-md flex items-center justify-center text-faint hover:text-ink hover:bg-sunken shrink-0"><X size={13} /></button>
    </div>
  )
}

// ===== 输入框(带附件)=====
const Composer = memo(function Composer({ sid, agent, model, models, working, attachments, setAttachments, onSend }: {
  sid: string; agent?: string; model?: string; models?: ModelOpt[]; working?: boolean; attachments: Attach[]; setAttachments: SetAttach
  onSend: (t: string, images?: Array<{ name?: string; data?: string; id?: string; ext?: string }>) => void
}) {
  const [draft, setDraft] = useState(() => draftStore[sid] ?? '')   // 草稿按会话持久化:切走再回来不丢
  const setDraftP = (v: string) => { setDraft(v); draftStore[sid] = v }
  const [menu, setMenu] = useState(false)
  const [drag, setDrag] = useState(false)
  const fileRef = useRef<HTMLInputElement>(null)
  // 输入法组字:WKWebView 里 compositionstart/isComposing 都不稳,叠加多重信号兜底,
  // 避免「回车选候选词(含英文候选)」被当成发送。
  const composingRef = useRef(false)
  const lastCompEnd = useRef(0)
  const opts = modelOptions(agent, models)
  const cur = curModelLabel(agent, model, opts)
  const activeId = activeModelId(opts, model)
  const addFiles = (files: FileList | File[]) => {
    for (const f of Array.from(files)) {
      if (f.type.startsWith('image/')) {
        // 图片读成 base64 dataUrl(发送时取字节给桥,由 VibeNotch 代传服务器)
        const id = newAid()
        setAttachments((p) => [...p, { id, kind: 'image', name: f.name, dataUrl: '' }])
        const r = new FileReader()
        r.onload = () => {
          const dataUrl = String(r.result)
          setAttachments((p) => p.map((a) => a.id === id ? { ...a, dataUrl } : a))
          cmd.prepareImage(id, f.name, dataUrl.split(',')[1] ?? '')   // 粘贴即上传,不等回车
        }
        r.readAsDataURL(f)
      } else {
        setAttachments((p) => [...p, { id: newAid(), kind: 'file', name: f.name, path: f.name, lang: hljsLang(f.name) ?? fileExt(f.name) ?? 'file' }])
      }
    }
  }
  const submit = () => {
    const t = draft.trim()
    if (!t && !attachments.length) return
    // 图片单独走二进制通道(只发字节,消息里不塞 base64);代码/粘贴/文件引用仍拼进文字
    const imgs = attachments.filter((a): a is Extract<Attach, { kind: 'image' }> => a.kind === 'image' && !!a.dataUrl)
    const textRefs = attachments.filter((a) => a.kind !== 'image').map(attachToText)
    // 粘贴时已预上传到就只发 id(秒发);没传完的兜底发 base64(现传)
    const images = imgs.map((a) => {
      const up = getImgUpload(a.id)
      return up ? { id: up.id, ext: up.ext } : { name: a.name, data: a.dataUrl.split(',')[1] ?? '' }
    })
    onSend([...textRefs, t].filter(Boolean).join('\n\n'), images)
    setDraftP(''); setAttachments(() => [])
  }
  const onPaste = (e: React.ClipboardEvent) => {
    if (e.clipboardData.files.length) { e.preventDefault(); addFiles(e.clipboardData.files); return }
    const txt = e.clipboardData.getData('text')
    if (txt && (txt.length > 320 || txt.split('\n').length > 8)) {
      e.preventDefault(); setAttachments((p) => [...p, { id: newAid(), kind: 'paste', text: txt }])
    }
  }
  return (
    <div className="flex-none px-7 pb-[18px] pt-1">
      <div onDragOver={(e) => { e.preventDefault(); setDrag(true) }} onDragLeave={() => setDrag(false)}
        onDrop={(e) => { e.preventDefault(); setDrag(false); if (e.dataTransfer.files.length) addFiles(e.dataTransfer.files) }}
        className="max-w-[780px] mx-auto rounded-[14px] border bg-elev shadow-card relative" style={{ borderColor: drag ? 'var(--accent)' : 'var(--border-strong)' }}>
        {drag && <div className="absolute inset-0 z-10 rounded-[14px] flex items-center justify-center text-[12.5px] font-medium" style={{ background: 'var(--accent-soft)', color: 'var(--accent)' }}>释放以添加图片或文件</div>}
        <input ref={fileRef} type="file" multiple className="hidden" onChange={(e) => { if (e.target.files) addFiles(e.target.files); e.target.value = '' }} />
        {attachments.length > 0 && <div className="flex flex-wrap gap-2 px-3 pt-3">{attachments.map((a) => <AttachChip key={a.id} a={a} onRemove={() => setAttachments((p) => p.filter((x) => x.id !== a.id))} />)}</div>}
        <textarea value={draft} onChange={(e) => setDraftP(e.target.value)} onPaste={onPaste}
          onCompositionStart={() => { composingRef.current = true }}
          onCompositionEnd={() => { composingRef.current = false; lastCompEnd.current = Date.now() }}
          onKeyDown={(e) => {
            if (e.key !== 'Enter' || e.shiftKey) return
            // 组字中 / isComposing / keyCode 229(输入法处理中)/ 刚确认候选词(150ms 内)→ 交给输入法,不发送
            if (composingRef.current || e.nativeEvent.isComposing || e.keyCode === 229 || Date.now() - lastCompEnd.current < 150) return
            e.preventDefault(); submit()
          }}
          rows={1} placeholder="描述需求…  选中代码可「加入对话」,拖拽 / 粘贴可加附件"
          className="w-full resize-none bg-transparent outline-none px-4 pt-3.5 pb-1.5 text-[13px] text-ink select-text placeholder:text-faint" />
        <div className="flex items-center gap-1.5 px-2.5 pb-2.5 pt-0.5">
          <button title="添加附件" onClick={() => fileRef.current?.click()} className="w-7 h-7 rounded-[7px] flex items-center justify-center text-faint hover:bg-sunken hover:text-dim transition-colors"><Paperclip size={15} /></button>
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
                {opts.length === 0 && <div className="text-[11.5px] text-faint px-2.5 py-1.5">模型列表加载中…</div>}
                {opts.map((m) => {
                  const on = activeId === m.id
                  return (
                    <button key={m.id} onClick={() => { setMenu(false); if (!on) cmd.switchModel(sid, m.id) }}
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
          {working
            ? <button onClick={() => cmd.interrupt(sid)} title="停止"
                className="w-8 h-8 rounded-[9px] flex items-center justify-center text-accentfg transition hover:brightness-110" style={{ background: 'var(--red)' }}>
                <span className="w-3 h-3 rounded-[2px] bg-white" />
              </button>
            : <button onClick={submit} disabled={!draft.trim() && !attachments.length}
                className="w-8 h-8 rounded-[9px] flex items-center justify-center text-accentfg disabled:opacity-40 transition hover:brightness-110" style={{ background: 'var(--accent)' }}>
                <ArrowUp size={16} strokeWidth={2} />
              </button>}
        </div>
      </div>
    </div>
  )
}, (a, b) =>
  // 只比会变的数据;onSend 每次渲染新建、setAttachments 是稳定 setter → 忽略。
  // 这样运行中会话的高频 store 更新不再重渲染输入框,打字不卡。
  a.sid === b.sid && a.model === b.model && a.models === b.models && a.working === b.working && a.attachments === b.attachments)

// ===== 工作区顶部三段切换:会话 / Git Tree / 文件 =====
function TriToggle({ navMode, viewMode, onConv, onGit, onFiles }: {
  navMode: 'sessions' | 'gittree'; viewMode: 'chat' | 'files'
  onConv: () => void; onGit: () => void; onFiles: () => void
}) {
  const idx = viewMode === 'files' ? 2 : navMode === 'gittree' ? 1 : 0
  const items = [
    { label: '会话', icon: <MessageSquare size={13} />, on: onConv },
    { label: 'Git Tree', icon: <GitBranch size={13} />, on: onGit },
    { label: '文件', icon: <Folder size={13} />, on: onFiles },
  ]
  return (
    <div className="relative flex w-[264px] p-[3px] rounded-[9px]" style={{ background: 'var(--bg-sunken)' }}>
      <div className="absolute top-[3px] bottom-[3px] rounded-[7px]" style={{ width: 'calc((100% - 6px) / 3)', left: `calc(3px + ${idx} * (100% - 6px) / 3)`, background: 'var(--bg-elev)', boxShadow: '0 1px 2px rgba(0,0,0,.08)', transition: 'left .24s cubic-bezier(.34,1.4,.45,1)' }} />
      {items.map((it, i) => (
        <button key={i} onClick={it.on} className="relative z-10 flex-1 flex items-center justify-center gap-1.5 py-1.5 rounded-[7px] text-[12px] transition-colors"
          style={{ color: idx === i ? 'var(--accent)' : 'var(--text-dim)', fontWeight: idx === i ? 600 : 400 }}>{it.icon}{it.label}</button>
      ))}
    </div>
  )
}

// ===== 会话工作区头(标题 + 状态 + 三段切换 + 重命名/隐藏/结束)=====
type BarSession = { title: string; meta: DotMeta; model?: string; sub?: string; renameKey?: string; manualId?: string }
// 常驻工作区顶栏(像任务栏一直存在):左=会话信息(无会话时留空,可拖动窗口),中=三段切换,右=操作
function WorkBar({ session, tri, right }: {
  session?: BarSession | null; tri: React.ReactNode; right?: React.ReactNode
}) {
  return (
    // 通栏会话头:标题左、三段切换中右、操作右,底部边线。重命名/隐藏/结束已挪到左侧会话列表
    //(双击改名、右键菜单、标签 ×),WorkBar 不再放「...」菜单与结束 X。
    <div className="flex-none flex items-center gap-3 px-5 py-[13px] border-b border-line">
      {/* 左:标题 + 状态(纯展示) */}
      <div className="flex-1 min-w-0">
        {session && (<>
          <div className="text-[15px] font-semibold text-ink truncate leading-tight">{session.title || '会话'}</div>
          <div className="flex items-center gap-2 mt-1">
            <Dot meta={session.meta} size={7} />
            <span className="text-[11.5px] text-dim whitespace-nowrap">{session.meta.text}</span>
            {session.model && <><span className="text-[11.5px] text-faint">·</span><span className="font-mono text-[11px] text-faint truncate">{session.model}</span></>}
            {session.sub && <><span className="text-[11.5px] text-faint">·</span><span className="text-[11.5px] text-faint truncate min-w-0">{session.sub}</span></>}
          </div>
        </>)}
      </div>
      {/* 中:三段切换 */}
      <div className="shrink-0">{tri}</div>
      {/* 右:操作(唤起 / Resume 等,在 barRight 里) */}
      <div className="flex items-center gap-1 shrink-0">{right}</div>
    </div>
  )
}

// 找最近的带 data-ln 的祖先 → 行号
function lineOf(node: Node | null): number | null {
  let el: Element | null = node instanceof Element ? node : node?.parentElement ?? null
  while (el && el !== document.body) {
    const ln = (el as HTMLElement).dataset?.ln
    if (ln) return parseInt(ln, 10)
    el = el.parentElement
  }
  return null
}

// ===== 文件模式的代码预览(纯等宽 + 行号 + 选中「加入对话」)=====
function FilesViewer({ path, onClose, onAddSel }: {
  path: string; onClose: () => void
  onAddSel?: (start: number, end: number, snippet: string, file: string, lang: string) => void
}) {
  const files = useFiles()
  const body = files[path]
  const scrollRef = useRef<HTMLDivElement>(null)
  const [sel, setSel] = useState<{ top: number; left: number; start: number; end: number; text: string } | null>(null)
  useEffect(() => { if (!body) cmd.loadFile(path) }, [path, body])
  useEffect(() => { setSel(null) }, [path])
  const lines = useMemo(() => (body?.text ?? '').split('\n'), [body])
  const lang = hljsLang(path) ?? fileExt(path) ?? 'txt'
  const fname = path.split('/').pop() ?? path
  const onMouseUp = () => {
    const s = window.getSelection()
    if (!s || s.isCollapsed || !s.toString().trim()) { setSel(null); return }
    const a = lineOf(s.anchorNode), f = lineOf(s.focusNode)
    if (a == null || f == null) { setSel(null); return }
    const rect = s.getRangeAt(0).getBoundingClientRect()
    const el = scrollRef.current!; const host = el.getBoundingClientRect()
    setSel({ start: Math.min(a, f), end: Math.max(a, f), text: s.toString(),
      top: rect.bottom - host.top + el.scrollTop + 6, left: Math.max(8, rect.left - host.left + el.scrollLeft) })
  }
  return (
    <div className="flex flex-col h-full bg-elev min-h-0">
      <div className="flex-none flex items-center gap-2.5 px-5 py-3 border-b border-line">
        <FileText size={16} className="text-dim shrink-0" />
        <span className="font-mono text-[13px] font-medium text-ink flex-1 min-w-0 truncate">{fname}</span>
        <span className="text-[10.5px] px-2 py-0.5 rounded font-mono" style={{ background: 'var(--bg-sunken)', color: 'var(--text-dim)' }}>{lang}</span>
        {body?.truncated && <span className="text-[11px]" style={{ color: 'var(--amber)' }}>已截断</span>}
        <IconBtn title="关闭预览" onClick={onClose}><X size={16} /></IconBtn>
      </div>
      <div ref={scrollRef} onMouseUp={onMouseUp} className="flex-1 overflow-auto relative">
        <div className="flex font-mono text-[12.5px] leading-[1.7] py-3.5 min-h-full">
          <div className="flex-none px-3.5 text-right select-none" style={{ color: 'var(--text-faint)' }}>
            {lines.map((_, i) => <div key={i}>{i + 1}</div>)}
          </div>
          <div className="flex-1 px-4 overflow-x-auto border-l border-line">
            {lines.map((t, i) => <div key={i} data-ln={i + 1} className="whitespace-pre select-text text-ink" style={{ cursor: 'text' }}>{t || '​'}</div>)}
          </div>
        </div>
        {!body && <div className="text-[11px] text-faint px-5 py-3 absolute top-0">加载中…</div>}
        {sel && onAddSel && (
          <div className="absolute z-20" style={{ top: sel.top, left: sel.left }}>
            <button onMouseDown={(e) => e.preventDefault()}
              onClick={() => { onAddSel(sel.start, sel.end, sel.text, fname, lang); window.getSelection()?.removeAllRanges(); setSel(null) }}
              className="flex items-center gap-1.5 px-3 py-1.5 rounded-[9px] text-accentfg text-[12px] font-semibold shadow-pop hover:brightness-110 whitespace-nowrap" style={{ background: 'var(--accent)' }}>
              <Plus size={13} strokeWidth={2.4} />加入对话 · {sel.start === sel.end ? `第 ${sel.start} 行` : `${sel.start}-${sel.end} 行`}
            </button>
          </div>
        )}
      </div>
    </div>
  )
}

// ===== 文件模式(文件树 + 预览)=====
function FilesMode({ project, openFile, fileTabs, onPickFile, onCloseFile, onAddSel, onAddFile }: {
  project: Project; openFile: string | null; fileTabs: string[]
  onPickFile: (p: string) => void; onCloseFile: (p: string) => void
  onAddSel?: (start: number, end: number, snippet: string, file: string, lang: string) => void
  onAddFile?: (path: string) => void
}) {
  return (
    <div className="flex-1 flex min-h-0">
      <div className="w-[268px] shrink-0 flex flex-col min-h-0 border-r border-line bg-elev">
        <div className="p-3 pb-2 flex-none">
          <div className="flex items-center gap-2.5 px-2.5 py-2 rounded-[9px] bg-elev2 border border-line">
            <div className="w-6 h-6 shrink-0 rounded-[7px] flex items-center justify-center" style={{ background: 'var(--accent-soft)', color: 'var(--accent)' }}><Folder size={13} /></div>
            <div className="min-w-0 flex-1">
              <div className="text-[12px] font-semibold text-ink truncate">{project.name}</div>
              <div className="font-mono text-[10px] text-faint truncate">{project.workdir}</div>
            </div>
          </div>
          {onAddFile && <div className="text-[10.5px] text-faint px-1 pt-2">右键 / ⌘+点击 文件可放入输入框</div>}
        </div>
        <div className="flex-1 overflow-auto px-2 pb-3">
          <FileTree root={project.workdir} active={openFile} openFile={onPickFile} onAddFile={onAddFile} />
        </div>
      </div>
      <div className="flex-1 min-w-0 flex flex-col min-h-0">
        {/* 文件多标签:打开过的文件像会话一样排开,可切换/关闭 */}
        {fileTabs.length > 0 && (
          <div className="flex-none flex items-stretch gap-1 px-2 pt-1.5 overflow-x-auto bg-elev border-b border-line">
            {fileTabs.map((f) => {
              const on = f === openFile
              return (
                <div key={f} onClick={() => onPickFile(f)} title={f}
                  className="group flex items-center gap-1.5 pl-2.5 pr-1 py-1.5 rounded-t-[8px] cursor-pointer max-w-[180px] shrink-0 border-b-2 transition-colors"
                  style={on ? { borderColor: 'var(--accent)', background: 'var(--bg)' } : { borderColor: 'transparent' }}>
                  <FileText size={12} className="shrink-0 text-faint" />
                  <span className="font-mono text-[12px] truncate" style={{ color: on ? 'var(--text)' : 'var(--text-dim)' }}>{f.split('/').pop()}</span>
                  <button onClick={(e) => { e.stopPropagation(); onCloseFile(f) }} title="关闭" className="shrink-0 opacity-0 group-hover:opacity-100 text-faint hover:text-ink rounded p-0.5"><X size={11} /></button>
                </div>
              )
            })}
          </div>
        )}
        {openFile
          ? <FilesViewer path={openFile} onClose={() => onCloseFile(openFile)} onAddSel={onAddSel} />
          : <div className="flex-1 flex flex-col items-center justify-center text-faint gap-3 bg-elev"><FileText size={22} /><div className="text-[13px]">从左侧选择文件预览</div></div>}
      </div>
    </div>
  )
}

// 工作区身体:文件模式 → 文件树+预览(可加文件/选中代码);否则渲染传入对话
function WorkBody({ viewMode, project, openFile, fileTabs, onPickFile, onCloseFile, onAddSel, onAddFile, chat }: {
  viewMode: 'chat' | 'files'; project: Project | null; openFile: string | null; fileTabs: string[]
  onPickFile: (p: string) => void; onCloseFile: (p: string) => void
  onAddSel?: (start: number, end: number, snippet: string, file: string, lang: string) => void
  onAddFile?: (path: string) => void; chat: React.ReactNode
}) {
  if (viewMode === 'files') {
    if (project) return <FilesMode project={project} openFile={openFile} fileTabs={fileTabs} onPickFile={onPickFile} onCloseFile={onCloseFile} onAddSel={onAddSel} onAddFile={onAddFile} />
    return <div className="flex-1 flex items-center justify-center text-faint text-[13px]">没有可浏览的项目目录</div>
  }
  return <>{chat}</>
}

// ===== 文件树(文件 tab)=====
function TreeRow({ entry, depth, expanded, toggle, openFile, active, onAddFile }: {
  entry: Entry; depth: number; expanded: Set<string>
  toggle: (p: string) => void; openFile: (p: string) => void; active: string | null
  onAddFile?: (path: string) => void   // 右键 / ⌘+点击 文件 → 放入输入框
}) {
  const dirs = useDirs()
  const isOpen = expanded.has(entry.path)
  const children = dirs[entry.path]
  const isActive = active === entry.path
  const onClick = (e: React.MouseEvent) => {
    if (entry.isDir) return toggle(entry.path)
    if ((e.metaKey || e.ctrlKey) && onAddFile) return onAddFile(entry.path)
    openFile(entry.path)
  }
  return (
    <div>
      <button onClick={onClick}
        onContextMenu={(e) => { if (!entry.isDir && onAddFile) { e.preventDefault(); onAddFile(entry.path) } }}
        title={entry.isDir ? undefined : '右键 / ⌘+点击 放入输入框'}
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
        <TreeRow key={c.path} entry={c} depth={depth + 1} expanded={expanded} toggle={toggle} openFile={openFile} active={active} onAddFile={onAddFile} />
      ))}
    </div>
  )
}

function FileTree({ root, openFile, active, onAddFile }: { root: string; openFile: (p: string) => void; active: string | null; onAddFile?: (path: string) => void }) {
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
      {(dirs[root] ?? []).map((e) => <TreeRow key={e.path} entry={e} depth={0} expanded={expanded} toggle={toggle} openFile={openFile} active={active} onAddFile={onAddFile} />)}
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

// ===== 新建会话(明确选择 Claude / Codex)=====
function AgentOption({ agent, onClick }: { agent: AgentId; onClick: () => void }) {
  const codex = agent === 'codex'
  const Icon = codex ? Code2 : MessageSquare
  return (
    <button onClick={onClick} className="w-full flex items-center gap-2 px-2.5 py-1.5 text-[12.5px] text-ink rounded-lg hover:bg-sunken">
      <span className="w-5 h-5 rounded-[6px] flex items-center justify-center shrink-0" style={{ background: codex ? '#dce9e3' : '#ece6dd', color: codex ? '#1a7d5a' : '#b8612d' }}>
        <Icon size={12.5} strokeWidth={2.1} />
      </span>
      <span className="flex-1 text-left">{codex ? 'Codex' : 'Claude'}</span>
    </button>
  )
}

function AgentActionMenu({ workdir, label = '新建', includeContinue = false, compact = false, align = 'right' }: {
  workdir: string; label?: string; includeContinue?: boolean; compact?: boolean; align?: 'left' | 'right'
}) {
  const [open, setOpen] = useState(false)
  const close = () => setOpen(false)
  const start = (agent: AgentId) => { cmd.newSession(workdir, agent); close() }
  const cont = (agent: AgentId) => { cmd.continueLast(workdir, agent); close() }
  return (
    <div className="relative">
      <button onClick={(e) => { e.stopPropagation(); setOpen((o) => !o) }}
        className={compact
          ? 'w-full flex items-center gap-1.5 px-2.5 py-1.5 rounded-[8px] text-[11.5px] text-faint hover:bg-sunken hover:text-accent transition-colors'
          : 'flex items-center gap-1 pl-1.5 pr-2.5 py-1 rounded-[7px] text-[12px] font-medium text-accentfg transition hover:brightness-110'}
        style={compact ? undefined : { background: 'var(--accent)' }}>
        <Plus size={compact ? 12 : 13} strokeWidth={2.4} />{label}
      </button>
      {open && createPortal(
        // 居中模态(portal 到 body):避免被侧栏 overflow / 定位祖先裁切。
        <div className="fixed inset-0 z-[100] flex items-center justify-center p-6" style={{ background: 'rgba(20,20,16,.28)' }}
          onClick={close}>
          <div className="w-[320px] p-3 rounded-[14px] bg-elev border border-strong shadow-pop animate-pop" onClick={(e) => e.stopPropagation()}>
            <div className="flex items-center justify-between px-1 pb-2">
              <div className="text-[13.5px] font-semibold text-ink">新建会话</div>
              <button onClick={close} className="w-6 h-6 rounded-md flex items-center justify-center text-faint hover:bg-sunken hover:text-ink transition-colors"><X size={15} /></button>
            </div>
            {includeContinue && (
              <>
                <div className="text-[10.5px] font-semibold tracking-[0.04em] text-faint px-2 pt-1 pb-1">继续最近</div>
                <AgentOption agent="claude" onClick={() => cont('claude')} />
                <AgentOption agent="codex" onClick={() => cont('codex')} />
                <div className="h-px bg-line my-1.5 mx-1" />
              </>
            )}
            <div className="text-[10.5px] font-semibold tracking-[0.04em] text-faint px-2 pt-1 pb-1">选择 Agent</div>
            <AgentOption agent="claude" onClick={() => start('claude')} />
            <AgentOption agent="codex" onClick={() => start('codex')} />
          </div>
        </div>,
        document.body,
      )}
    </div>
  )
}

// ===== 工作区 =====
// 分支会话状态点
function gitDot(status: GitStatus): DotMeta {
  if (status === 'running') return { text: '进行中', color: 'var(--green)', pulse: true }
  if (status === 'manual') return { text: '待确认', color: 'var(--amber)', hollow: true }
  return { text: '已完成', color: 'var(--text-faint)', hollow: true }
}

type RowItem = { key: string; sel: Sel; title: string; meta: DotMeta; model: string; time: string; running: boolean; path?: string; ts: number; renameKey?: string }
type Group = { p: Project; rows: RowItem[]; running: number; gitDirty: number }
const selEq = (a: Sel, b: Sel) => !!a && !!b && a.kind === b.kind && a.id === b.id

// 单条会话行(默认目录平铺 + 项目文件夹内 复用)。showPath:散会话标完整路径(左侧省略、末级目录必显)区分。
const SessionRow = memo(function SessionRow({ r, on, showPath, flipping, onClick }: { r: RowItem; on: boolean; showPath?: boolean; flipping?: boolean; onClick: () => void }) {
  const [editing, setEditing] = useState(false)
  const [val, setVal] = useState(r.title)
  const [menu, setMenu] = useState<{ x: number; y: number } | null>(null)
  useEffect(() => { if (!editing) setVal(r.title) }, [r.title, editing])
  const commitRename = () => { setEditing(false); if (r.renameKey) cmd.renameSession(r.renameKey, val.trim()) }
  const isConsole = r.sel?.kind === 'session'
  const startRename = () => { setMenu(null); setVal(r.title); setEditing(true) }
  const doDelete = () => {
    setMenu(null)
    if (isConsole) { cmd.closeSession(r.sel!.id); if (r.renameKey) cmd.hideSession(r.renameKey) }  // 结束进程 + 隐藏结果历史 = 一步彻底删除
    else if (r.renameKey) cmd.hideSession(r.renameKey)  // 手动/历史:从列表隐藏(转录不删)
  }
  return (
    <div onClick={editing ? undefined : onClick} onDoubleClick={() => { setVal(r.title); setEditing(true) }}
      onContextMenu={(e) => { e.preventDefault(); setMenu({ x: e.clientX, y: e.clientY }) }}
      className={`group relative w-full text-left flex gap-2.5 rounded-[9px] px-2.5 py-2 transition-colors hover:bg-sunken cursor-pointer ${flipping ? 'flip-sweep' : ''}`}
      style={on ? { background: 'var(--accent-soft)' } : undefined}>
      <span className="mt-[5px]"><Dot meta={r.meta} /></span>
      <div className="min-w-0 flex-1">
        {editing
          ? <input autoFocus value={val} onClick={(e) => e.stopPropagation()} onChange={(e) => setVal(e.target.value)}
              onKeyDown={(e) => { if (e.key === 'Enter') { e.preventDefault(); commitRename() } else if (e.key === 'Escape') setEditing(false) }}
              onBlur={commitRename} placeholder="会话名…(留空恢复默认)"
              className="w-full bg-sunken border border-strong rounded-md px-1.5 py-0.5 text-[13px] text-ink outline-none" />
          : <div className="font-medium text-[13px] text-ink truncate">{r.title || '新会话'}</div>}
        {showPath && r.path && (
          <div className="font-mono text-[10px] text-faint truncate mt-0.5" style={{ direction: 'rtl', textAlign: 'left' }} title={r.path}>{r.path}</div>
        )}
        <div className="mt-1 flex items-center gap-[7px]">
          <span className="text-[10.5px] font-medium shrink-0" style={{ color: r.meta.color }}>{r.meta.text}</span>
          <span className="text-[10.5px] text-faint shrink-0">·</span>
          <span className={`font-mono text-[10.5px] text-faint truncate flex-1 min-w-0 ${flipping ? 'badge-flip' : ''}`}>{r.model}</span>
          <span className="text-[10.5px] text-faint shrink-0">{r.time}</span>
        </div>
      </div>
      {menu && createPortal(
        <>
          <div className="fixed inset-0 z-[60]" onClick={() => setMenu(null)} onContextMenu={(e) => { e.preventDefault(); setMenu(null) }} />
          <div className="fixed z-[61] min-w-[156px] p-1 rounded-[10px] bg-elev border border-line shadow-pop animate-pop" style={{ left: menu.x, top: menu.y }}>
            <button onClick={startRename} className="w-full flex items-center gap-2.5 px-2.5 py-[7px] text-[12.5px] text-ink rounded-md hover:bg-sunken transition-colors">
              <Pencil size={14} className="text-dim shrink-0" />重命名
            </button>
            <div className="my-1 h-px bg-line" />
            <button onClick={doDelete} className="w-full flex items-center gap-2.5 px-2.5 py-[7px] text-[12.5px] rounded-md hover:bg-sunken transition-colors" style={{ color: 'var(--red)' }}>
              {isConsole ? <Trash2 size={14} className="shrink-0" /> : <EyeOff size={14} className="shrink-0" />}
              {isConsole ? '删除会话' : '从列表隐藏'}
            </button>
          </div>
        </>, document.body)}
    </div>
  )
}, (a, b) =>
  // 只比展示字段;onClick 每次渲染新建但行为相同 → 忽略。运行中会话每 token 更新 state.sessions
  // 时,标题/状态/时间没变的行直接跳过,会话列表不再整列重渲染。
  a.on === b.on && a.showPath === b.showPath && a.flipping === b.flipping &&
  a.r.key === b.r.key && a.r.title === b.r.title && a.r.time === b.r.time && a.r.model === b.r.model &&
  a.r.meta.text === b.r.meta.text && a.r.meta.color === b.r.meta.color && a.r.renameKey === b.r.renameKey)

// ===== 左列:默认目录(workplace)文件夹置顶+默认展开,散会话归入并标路径;其它项目文件夹可移除 =====
function SessionsNav({ groups, sel, activeWd, defaultWd, expanded, toggle, pick, onReorder, onRemove, flipping }: {
  groups: Group[]; sel: Sel; activeWd: string | null; defaultWd?: string
  expanded: Set<string>; toggle: (wd: string) => void; pick: (s: Sel, wd: string) => void
  onReorder: (fromWd: string, toWd: string) => void; onRemove: (wd: string) => void; flipping: Set<string>
}) {
  const [dragWd, setDragWd] = useState<string | null>(null)
  const [overWd, setOverWd] = useState<string | null>(null)
  const PAGE = 20
  const [limits, setLimits] = useState<Record<string, number>>({})   // 每个文件夹已展示条数(分页懒加载)
  const defaultGroup = defaultWd ? groups.find((g) => g.p.workdir === defaultWd) : undefined
  const others = groups.filter((g) => g.p.workdir !== defaultWd)
  const ordered = defaultGroup ? [defaultGroup, ...others] : others   // 默认文件夹永远置顶
  return (
    <div className="flex-1 flex flex-col min-h-0">
      <div className="flex-1 overflow-y-auto px-2 pt-2.5 pb-3">
        {ordered.map((g) => {
          const isDefault = !!defaultGroup && g.p.workdir === defaultGroup.p.workdir
          const open = expanded.has(g.p.workdir)   // 全部默认折叠(会话多时不一次性铺开)
          const active = g.p.workdir === activeWd
          const isOver = overWd === g.p.workdir && dragWd !== g.p.workdir
          const shown = limits[g.p.workdir] ?? (isDefault ? 5 : PAGE)   // 默认文件夹会话多,先只显示 5 条
          const visibleRows = g.rows.slice(0, shown)
          const moreCount = g.rows.length - visibleRows.length
          return (
            <div key={g.p.workdir}
              onDragOver={isDefault ? undefined : (e) => { if (dragWd) { e.preventDefault(); setOverWd(g.p.workdir) } }}
              onDrop={isDefault ? undefined : (e) => { e.preventDefault(); if (dragWd && dragWd !== g.p.workdir) onReorder(dragWd, g.p.workdir); setDragWd(null); setOverWd(null) }}
              style={isOver ? { boxShadow: 'inset 0 2px 0 var(--accent)' } : undefined}>
              {/* 外层 sticky 套不透明 bg-elev:盖住 mt 间隙,滚动时会话不再从头顶冒出 */}
              <div className="sticky top-0 z-[3] bg-elev">
                <div draggable={!isDefault} onDragStart={isDefault ? undefined : () => setDragWd(g.p.workdir)} onDragEnd={() => { setDragWd(null); setOverWd(null) }}
                  onClick={() => toggle(g.p.workdir)}
                  className="group flex items-center gap-[9px] px-2 py-[7px] mt-[10px] mb-1.5 rounded-[9px] cursor-pointer select-none hover:bg-sunken transition-colors"
                  style={{ boxShadow: '0 1px 0 var(--border)', opacity: dragWd === g.p.workdir ? 0.5 : 1 }}>
                  <span className="w-[22px] h-[22px] rounded-[6px] flex items-center justify-center shrink-0 transition-colors" style={(isDefault || active) ? { background: 'var(--accent-soft)', color: 'var(--accent)' } : { background: 'var(--bg-sunken)', color: 'var(--text-dim)' }}>{isDefault ? <Boxes size={13} /> : <Folder size={13} />}</span>
                  <span className="flex-1 min-w-0 font-semibold text-[12px] truncate text-left" style={{ color: isDefault ? 'var(--accent)' : active ? 'var(--text)' : 'var(--text-dim)' }}>{g.p.name || (isDefault ? 'workplace' : '')}</span>
                  {isDefault && <span className="text-[9.5px] font-semibold shrink-0 px-1.5 py-0.5 rounded" style={{ background: 'var(--accent-soft)', color: 'var(--accent)' }}>默认</span>}
                  {g.rows.length > 0 && <span className="text-[10.5px] font-mono text-faint shrink-0">{g.rows.length}</span>}
                  {g.running > 0 && <span title="进行中会话" className="inline-flex items-center gap-1 text-[10.5px] font-mono shrink-0" style={{ color: 'var(--green)' }}><span className="w-1.5 h-1.5 rounded-full dot-live" style={{ background: 'var(--green)' }} />{g.running}</span>}
                  {!isDefault && <button onClick={(e) => { e.stopPropagation(); onRemove(g.p.workdir) }} title="从项目栏移除(不动磁盘文件、不结束会话)"
                    className="opacity-0 group-hover:opacity-100 transition-opacity shrink-0 text-faint hover:text-[var(--red)] p-0.5 rounded"><X size={13} /></button>}
                  <ChevronRight size={13} strokeWidth={2.2} className="text-faint shrink-0 transition-transform" style={{ transform: open ? 'rotate(90deg)' : 'none' }} />
                </div>
              </div>
              {open && (
                <div className="pb-1.5" style={{ marginLeft: 19, marginBottom: 8, paddingLeft: 13, borderLeft: `2px solid ${active ? 'var(--accent-soft)' : 'var(--border-strong)'}` }}>
                  {visibleRows.map((r) => <SessionRow key={r.key} r={r} on={selEq(r.sel, sel)} showPath={isDefault} flipping={!!r.sel && flipping.has(r.sel.id)} onClick={() => pick(r.sel, g.p.workdir)} />)}
                  {moreCount > 0 && (
                    <button onClick={() => setLimits((m) => ({ ...m, [g.p.workdir]: shown + 30 }))}
                      className="w-full text-left text-[11.5px] text-dim hover:text-accent px-2.5 py-1.5 rounded-[9px] hover:bg-sunken transition-colors">显示更多 · 还有 {moreCount} 条</button>
                  )}
                  {g.rows.length === 0 && <div className="text-[11px] text-faint px-2.5 py-1.5">{isDefault ? '还没有散会话;新建、或在别处启动的会话会归到这里' : '还没有会话'}</div>}
                  <AgentActionMenu workdir={g.p.workdir} label="新建会话" compact align="left" />
                </div>
              )}
            </div>
          )
        })}
        {ordered.length === 0 && <div className="text-[12px] text-dim px-2 py-3">还没有项目,点下方「添加项目」打开一个目录。</div>}
      </div>
      <div className="flex-none p-2.5 border-t border-line">
        <button onClick={() => cmd.openProject()} className="w-full flex items-center justify-center gap-1.5 py-2 rounded-[9px] text-[12.5px] font-medium text-dim border border-dashed border-strong hover:bg-sunken hover:text-accent hover:border-accent transition-colors">
          <Folder size={14} />添加项目
        </button>
      </div>
    </div>
  )
}

// ===== 左列:Git Tree(分支 = worktree 会话)=====
function GitTreeNav({ projects, activeWd, branchSel, collapsed, toggle, inited, onInit, onBranch }: {
  projects: Project[]; activeWd: string | null; branchSel: { wd: string; branch: string } | null
  collapsed: Set<string>; toggle: (wd: string) => void; inited: Set<string>
  onInit: (wd: string) => void; onBranch: (wd: string, branch: string) => void
}) {
  return (
    <div className="flex-1 flex flex-col min-h-0">
      <div className="px-3 pt-3 pb-2.5 flex-none">
        <div className="font-semibold text-[13px] text-ink">分支会话</div>
        <div className="text-[10.5px] text-faint mt-0.5">每个分支 = 一个 worktree 会话</div>
      </div>
      <div className="flex-1 overflow-y-auto px-2 pb-3">
        {projects.map((p) => {
          const git = mockGit(p)
          const isInited = git.initialized || inited.has(p.workdir)
          const open = !collapsed.has(p.workdir)
          const active = p.workdir === activeWd
          return (
            <div key={p.workdir} className="mb-0.5">
              <button onClick={() => toggle(p.workdir)} className="w-full flex items-center gap-2 px-2 py-2 rounded-[9px] hover:bg-sunken transition-colors">
                <ChevronRight size={12} strokeWidth={2.4} className="text-faint shrink-0 transition-transform" style={{ transform: open ? 'rotate(90deg)' : 'none' }} />
                <span className="shrink-0" style={{ color: active ? 'var(--accent)' : 'var(--text-faint)' }}><Folder size={13} /></span>
                <span className="flex-1 min-w-0 font-semibold text-[12px] text-ink truncate text-left">{p.name}</span>
                {isInited
                  ? <span className="text-[10.5px] font-mono text-faint shrink-0">{git.branches.length}</span>
                  : <span className="text-[9.5px] shrink-0 px-1.5 py-px rounded-full" style={{ color: 'var(--amber)', background: 'color-mix(in srgb, var(--amber) 16%, transparent)' }}>无 Git</span>}
              </button>
              {open && !isInited && (
                <div className="mx-[10px] my-1.5 p-3 rounded-[10px] border border-dashed border-strong bg-sunken">
                  <div className="text-[11.5px] text-dim leading-relaxed mb-2.5">该目录未被 Git 管理,初始化后才能按分支建立会话。</div>
                  <button onClick={() => onInit(p.workdir)} className="w-full flex items-center justify-center gap-1.5 py-1.5 rounded-[8px] text-accentfg text-[12px] font-semibold hover:brightness-110" style={{ background: 'var(--accent)' }}><Plus size={13} strokeWidth={2.2} />git init</button>
                </div>
              )}
              {open && isInited && (
                <div className="ml-[10px] pl-1.5 border-l" style={{ borderColor: active ? 'var(--accent-soft)' : 'var(--border)' }}>
                  {git.branches.map((b) => {
                    const on = branchSel?.wd === p.workdir && branchSel.branch === b.name
                    const nodeColor = on || b.current ? 'var(--accent)' : 'var(--text-faint)'
                    return (
                      <button key={b.name} onClick={() => onBranch(p.workdir, b.name)} className="w-full text-left flex gap-2 px-2 py-1.5 rounded-[8px] hover:bg-sunken transition-colors" style={on ? { background: 'var(--accent-soft)' } : undefined}>
                        <span className="mt-[2px] shrink-0" style={{ color: nodeColor }}><GitBranch size={13} /></span>
                        <div className="flex-1 min-w-0">
                          <div className="flex items-center gap-1.5">
                            <span className="font-mono text-[12px] truncate" style={{ color: on ? 'var(--accent)' : 'var(--text)', fontWeight: on ? 600 : 400 }}>{b.name}</span>
                            {b.current && <span className="text-[9px] font-bold font-mono px-1.5 py-px rounded shrink-0" style={{ color: 'var(--accent)', background: 'var(--accent-soft)' }}>HEAD</span>}
                            <span className="flex-1" />
                            {b.ahead > 0 && <span className="text-[9.5px] font-mono text-faint shrink-0">↑{b.ahead}</span>}
                            {b.behind > 0 && <span className="text-[9.5px] font-mono text-faint shrink-0">↓{b.behind}</span>}
                          </div>
                          <div className="flex items-center gap-1.5 mt-1">
                            <Dot meta={gitDot(b.status)} size={6} />
                            <span className="text-[11.5px] text-dim truncate">{b.session}</span>
                          </div>
                        </div>
                      </button>
                    )
                  })}
                  <AgentActionMenu workdir={p.workdir} label="新分支会话" compact align="left" />
                </div>
              )}
            </div>
          )
        })}
        {projects.length === 0 && <div className="text-[12px] text-dim px-2 py-3">还没有项目。</div>}
      </div>
    </div>
  )
}

function ConsolePage() {
  const state = useAgent()
  const transcripts = useTranscripts()
  const tmeta = useTranscriptMeta()
  const [selectedProject, setSelectedProject] = useState<string | null>(() => localStorage.getItem('console.project'))
  const [sel, setSel] = useState<Sel>(null)
  const [openTabs, setOpenTabs] = useState<NonNullable<Sel>[]>([])   // 已打开会话(右侧多标签)
  // 控制台会话内部 id → claude session_id 映射;会话被终端抢占消失后,用它把选中/标签翻牌到同 id 的终端会话。
  const sidToAid = useRef<Map<string, string>>(new Map())
  // 真实翻牌动效(效果1):被终端抢占、控制台会话翻成终端会话的瞬间,给那张卡播一次过渡。
  const [flippedIds, setFlippedIds] = useState<Set<string>>(new Set())
  const prevConsoleAids = useRef<Set<string>>(new Set())
  const flipTimers = useRef<Record<string, number>>({})
  // 文件视图按会话记忆:每个会话各自的「打开的文件标签 / 当前文件 / chat-files 视图」——切走再切回不丢
  const [filesBySession, setFilesBySession] = useState<Record<string, string[]>>({})
  const [activeFileBySession, setActiveFileBySession] = useState<Record<string, string | null>>({})
  const [viewBySession, setViewBySession] = useState<Record<string, 'chat' | 'files'>>({})
  const [navMode, setNavMode] = useState<'sessions' | 'gittree'>(() => (localStorage.getItem('console.navMode') as 'sessions' | 'gittree') || 'sessions')
  const [attachments, setAttachments] = useState<Attach[]>([])
  // 当前会话 key + 按会话派生的文件/视图状态
  const sessionKey = sel ? sel.kind + ':' + sel.id : '_none'
  const fileTabs = filesBySession[sessionKey] ?? []
  const openFile = activeFileBySession[sessionKey] ?? null
  const viewMode = viewBySession[sessionKey] ?? 'chat'
  const setViewMode = (v: 'chat' | 'files') => setViewBySession((m) => ({ ...m, [sessionKey]: v }))
  const setActiveFile = (p: string | null) => setActiveFileBySession((m) => ({ ...m, [sessionKey]: p }))
  const closeFileTab = (p: string) => {
    const cur = filesBySession[sessionKey] ?? []
    const next = cur.filter((x) => x !== p)
    setFilesBySession((m) => ({ ...m, [sessionKey]: next }))
    if (openFile === p) { const fb = next[next.length - 1] ?? null; setActiveFile(fb); if (!fb) setViewMode('chat') }
  }
  // 项目分组:默认折叠、可拖拽排序,展开态与顺序都持久化(关闭后不变)
  const [expanded, setExpanded] = useState<Set<string>>(() => { try { return new Set(JSON.parse(localStorage.getItem('console.expanded') || '[]')) } catch { return new Set() } })
  const [projectOrder, setProjectOrder] = useState<string[]>(() => { try { return JSON.parse(localStorage.getItem('console.order') || '[]') } catch { return [] } })
  const [gitCollapsed, setGitCollapsed] = useState<Set<string>>(new Set())
  const [inited, setInited] = useState<Set<string>>(new Set())
  const [branchSel, setBranchSel] = useState<{ wd: string; branch: string } | null>(null)
  const [pendingResume, setPendingResume] = useState<string | null>(null)

  const doResume = (workdir: string, id: string, agent?: string) => { if (pendingResume) return; setPendingResume(id); cmd.resume(workdir, id, agent === 'codex' ? 'codex' : 'claude') }
  useEffect(() => {
    if (!pendingResume) return
    const s = state.sessions.find((x) => x.agentSessionId === pendingResume)
    if (s) {
      // 该历史会话已恢复成 live:把它的「历史」标签去掉,只留 live,避免同一会话开两个标签
      setOpenTabs((prev) => prev.filter((t) => !(t.kind === 'history' && t.id === pendingResume)))
      setSel({ kind: 'session', id: s.id }); setAttachments([]); setPendingResume(null)
    }
  }, [state.sessions, pendingResume])

  // 新建会话后自动跳到它:检测到新出现的 console 会话就选中(跳过初始加载,避免开机抢焦点)。
  const prevSessionIds = useRef<Set<string> | null>(null)
  useEffect(() => {
    const cur = new Set(state.sessions.map((s) => s.id))
    if (prevSessionIds.current !== null) {
      const fresh = state.sessions.find((s) => !prevSessionIds.current!.has(s.id))
      if (fresh) { setSel({ kind: 'session', id: fresh.id }); setAttachments([]) }
    }
    prevSessionIds.current = cur
  }, [state.sessions])

  useEffect(() => {
    if ((!selectedProject || !state.projects.some((p) => p.workdir === selectedProject)) && state.projects.length)
      setSelectedProject(state.projects[0].workdir)
  }, [state.projects, selectedProject])

  // 记住上次选择/项目顺序/展开态(切页面/重启都不丢)
  useEffect(() => { if (selectedProject) localStorage.setItem('console.project', selectedProject) }, [selectedProject])
  useEffect(() => { localStorage.setItem('console.navMode', navMode) }, [navMode])
  useEffect(() => { localStorage.setItem('console.expanded', JSON.stringify([...expanded])) }, [expanded])
  useEffect(() => { localStorage.setItem('console.order', JSON.stringify(projectOrder)) }, [projectOrder])

  useEffect(() => {
    // 只给当前打开的终端会话推实时正文;控制台会话走进程流、历史是静态,都不需要 → null。
    cmd.focusSession(sel?.kind === 'manual' ? sel.id : null)
    if (sel?.kind === 'history' && !transcripts[sel.id]) cmd.loadTranscript('history', sel.id, sel.workdir)
    if (sel?.kind === 'manual' && !transcripts[sel.id]) cmd.loadTranscript('manual', sel.id)
  }, [sel, transcripts])
  // 持续记录 控制台会话 id → claude session_id(供翻牌时把选中/标签改指到同 id 的终端会话)
  useEffect(() => { state.sessions.forEach((s) => { if (s.agentSessionId) sidToAid.current.set(s.id, s.agentSessionId) }) }, [state.sessions])
  // 翻牌检测:上一帧还是控制台会话、这一帧控制台没了、但同 session_id 的终端会话在 → 刚被抢占翻牌,标记播动效。
  useEffect(() => {
    const nowConsole = new Set(state.sessions.map((s) => s.agentSessionId).filter(Boolean) as string[])
    const manualIds = new Set(state.manual.map((m) => m.id))
    for (const aid of prevConsoleAids.current) {
      if (!nowConsole.has(aid) && manualIds.has(aid)) {
        setFlippedIds((prev) => (prev.has(aid) ? prev : new Set(prev).add(aid)))
        clearTimeout(flipTimers.current[aid])
        flipTimers.current[aid] = window.setTimeout(() => setFlippedIds((prev) => { const n = new Set(prev); n.delete(aid); return n }), 1400)
      }
    }
    prevConsoleAids.current = nowConsole
  }, [state.sessions, state.manual])
  useEffect(() => {
    if (sel?.kind === 'session' && !state.sessions.some((s) => s.id === sel.id)) {
      // 控制台会话消失:被终端抢占(同 session_id 的终端会话已接管)→ 选中平滑翻牌过去,否则清空
      const aid = sidToAid.current.get(sel.id)
      const m = aid ? state.manual.find((x) => x.id === aid) : undefined
      setSel(m ? { kind: 'manual', id: m.id } : null)
    }
    if (sel?.kind === 'manual' && !state.manual.some((m) => m.id === sel.id)) setSel(null)
    // 历史会话被隐藏/消失 → 清掉选中,否则顶部残留「历史会话」预览标签
    if (sel?.kind === 'history' && !state.projects.flatMap((p) => p.history).some((h) => h.id === sel.id)) setSel(null)
  }, [state, sel])
  // 选中即加入标签;但「历史(只读)」只预览、不固定 —— 只有 resume 成 live 才会进标签栏。
  // 会话消失(结束/移除)时从标签里剔除。
  useEffect(() => { if (sel && sel.kind !== 'history') setOpenTabs((prev) => prev.some((t) => t.kind === sel.kind && t.id === sel.id) ? prev : [...prev, sel]) }, [sel])
  useEffect(() => {
    setOpenTabs((prev) => prev.flatMap((t): NonNullable<Sel>[] => {
      if (t.kind === 'session') {
        if (state.sessions.some((s) => s.id === t.id)) return [t]
        // 控制台会话被终端抢占 → 标签翻牌成同 id 的终端会话(不丢标签)
        const aid = sidToAid.current.get(t.id)
        return aid && state.manual.some((m) => m.id === aid) ? [{ kind: 'manual', id: aid }] : []
      }
      if (t.kind === 'manual') return state.manual.some((m) => m.id === t.id) ? [t] : []
      return [t]
    }))
  }, [state.sessions, state.manual])

  const defWd = state.defaultWorkdir || ''
  const defaultRoots = state.defaultRoots && state.defaultRoots.length ? state.defaultRoots : (defWd ? [defWd] : [])
  const isRoot = (wd: string) => defaultRoots.includes(wd)
  const inProject = (cwd: string, wd: string) => cwd === wd || cwd.startsWith(wd.replace(/\/+$/, '') + '/')
  // 归属优先级:① 在某导入项目下(排除默认根/归属目录,最长前缀)→ 该项目(显式添加优先,carve-out);
  //            ② 否则在任一「归属目录/默认根」下 → 默认文件夹(捞散会话+历史);③ 都不是 → 不显示
  const importedBySpec = state.projects.filter((p) => p.workdir !== defWd && !isRoot(p.workdir)).sort((a, b) => b.workdir.length - a.workdir.length)
  const ownerWd = (cwd: string): string | null =>
    importedBySpec.find((p) => inProject(cwd, p.workdir))?.workdir
    ?? (defaultRoots.some((r) => inProject(cwd, r)) ? defWd : null)
  // 渲染的项目 = 默认文件夹 + 导入项目;归属目录不渲染成文件夹(它们的历史并进默认组)
  const visibleProjects = state.projects.filter((p) => p.workdir === defWd || !isRoot(p.workdir))
  const rootProjects = state.projects.filter((p) => isRoot(p.workdir))   // 默认根 + 归属目录(历史来源)

  // 每个可见项目 → 一个分组;默认文件夹收纳归属目录下的散会话 + 各归属目录的历史
  const groups: Group[] = visibleProjects.map((p) => {
    const isDefault = p.workdir === defWd
    const cs = state.sessions.filter((s) => ownerWd(s.workdir) === p.workdir)
    // 同一个 session_id 已在桌面端打开(console 会话),就不再把它的「手动/终端」会话重复列出
    const consoleSids = new Set<string>(cs.map((s) => s.agentSessionId).filter(Boolean) as string[])
    const ms = state.manual.filter((m) => ownerWd(m.cwd) === p.workdir && !consoleSids.has(m.id))
    const liveIds = new Set<string>([...consoleSids, ...ms.map((m) => m.id)])
    // 历史:默认组并入所有归属目录的历史(各按来源 workdir 取转录);普通组用自己的
    const histSources = isDefault ? rootProjects : [p]
    const hsRows = histSources.flatMap((src) => src.history.filter((h) => !liveIds.has(h.id)).map((h) => ({ h, wd: src.workdir })))   // h.agent 决定 Codex/Claude 标
    const rows: RowItem[] = [
      ...cs.map((s): RowItem => ({ key: 's' + s.id, sel: { kind: 'session', id: s.id }, title: s.title, meta: sessionMeta(s.status), model: s.agent === 'codex' ? 'Codex' : 'Claude', time: relTime(s.startedAt), running: !['done', 'error'].includes(s.status), path: s.workdir, ts: s.startedAt ?? 0, renameKey: s.key || s.agentSessionId || s.id })),
      ...ms.map((m): RowItem => ({ key: 'm' + m.id, sel: { kind: 'manual', id: m.id }, title: m.title, meta: manualMeta(m.state), model: `${m.agent === 'codex' ? 'Codex' : 'Claude'} · ${m.terminal}`, time: relTime(m.lastActivityAt), running: m.state === 'working' || m.state === 'waiting', path: m.cwd, ts: m.lastActivityAt, renameKey: m.key || m.id })),
      ...hsRows.map(({ h, wd }): RowItem => ({ key: 'h' + h.id, sel: { kind: 'history', id: h.id, workdir: wd }, title: h.label, meta: { text: '已结束', color: 'var(--text-faint)', hollow: true }, model: h.agent === 'codex' ? 'Codex' : 'Claude', time: relTime(h.mtime), running: false, path: wd, ts: h.mtime, renameKey: h.key || h.id })),
    ]
    // 运行中优先,其余按时间倒序(最近的在前)——配合分页,先看到的是最相关的
    rows.sort((a, b) => (b.running ? 1 : 0) - (a.running ? 1 : 0) || b.ts - a.ts)
    const git = mockGit(p)
    return { p, rows, running: rows.filter((r) => r.running).length, gitDirty: git.initialized ? git.dirty : 0 }
  })
  // 按持久化的顺序排;未排过的项目稳定排在后面(保持原始顺序)
  const orderIdx = (wd: string) => { const i = projectOrder.indexOf(wd); return i < 0 ? Number.MAX_SAFE_INTEGER : i }
  const orderedGroups = [...groups].sort((a, b) => orderIdx(a.p.workdir) - orderIdx(b.p.workdir))
  const reorder = (fromWd: string, toWd: string) => {
    const cur = orderedGroups.map((g) => g.p.workdir)
    const fi = cur.indexOf(fromWd), ti = cur.indexOf(toWd)
    if (fi < 0 || ti < 0 || fi === ti) return
    cur.splice(ti, 0, cur.splice(fi, 1)[0])
    setProjectOrder(cur)
  }

  const pick = (s: Sel, wd: string) => { setSel(s); setSelectedProject(wd); setAttachments([]) }
  // 会话标签页:已打开的会话在右侧顶部多标签展示,可切换/关闭
  const selKey = (s: NonNullable<Sel>) => s.kind + ':' + s.id
  const closeTab = (s: NonNullable<Sel>) => {
    // 标签 × = 收起这个标签。console 会话顺带结束进程(变成「已结束」,**仍留在项目列表**,不删除);
    // 手动/历史:只收起标签,完全不动会话(手动在终端还活着;历史保留)。
    // 想彻底删除请用会话行右键「删除会话」(那个才结束+隐藏)。
    if (s.kind === 'session') cmd.closeSession(s.id)
    const next = openTabs.filter((t) => selKey(t) !== selKey(s))
    setOpenTabs(next)
    if (sel && selKey(sel) === selKey(s)) setSel(next[next.length - 1] ?? null)
  }
  const tabMeta = (t: NonNullable<Sel>): { title: string; dot: DotMeta } => {
    if (t.kind === 'session') { const s = state.sessions.find((x) => x.id === t.id); return { title: s?.title || '新会话', dot: sessionMeta(s?.status || 'idle') } }
    if (t.kind === 'manual') { const m = state.manual.find((x) => x.id === t.id); return { title: m?.title || '会话', dot: manualMeta(m?.state || 'idle') } }
    const h = state.projects.flatMap((p) => p.history).find((x) => x.id === t.id)
    return { title: h?.label || '历史会话', dot: { text: '历史', color: 'var(--text-faint)', hollow: true } }
  }
  const toggleGroup = (wd: string) => setExpanded((prev) => { const n = new Set(prev); n.has(wd) ? n.delete(wd) : n.add(wd); return n })
  const toggleGit = (wd: string) => setGitCollapsed((prev) => { const n = new Set(prev); n.has(wd) ? n.delete(wd) : n.add(wd); return n })
  const onBranch = (wd: string, branch: string) => {
    setBranchSel({ wd, branch }); setSelectedProject(wd)
    const s = state.sessions.find((x) => x.workdir === wd)   // 该项目有真实会话就顺带选中
    if (s) { setSel({ kind: 'session', id: s.id }); setAttachments([]) }
  }
  const onConv = () => { setNavMode('sessions'); setViewMode('chat') }
  const onGit = () => { setNavMode('gittree'); setViewMode('chat') }
  const onFiles = () => setViewMode('files')

  const liveSession = sel?.kind === 'session' ? state.sessions.find((x) => x.id === sel.id) ?? null : null
  const liveSid = liveSession?.id
  // 稳定引用:否则 MessageRow 的 memo 比较器每次都失配,全部消息重渲染。
  const onLiveRespond = useCallback((r: string, c: string[]) => { if (liveSid) cmd.respond(liveSid, r, c) }, [liveSid])
  const manualSel = sel?.kind === 'manual' ? state.manual.find((x) => x.id === sel.id) ?? null : null
  const historySel = sel?.kind === 'history' ? state.projects.flatMap((p) => p.history).find((x) => x.id === sel.id) ?? null : null
  const histWd = sel?.kind === 'history' ? sel.workdir : ''
  const activeWd = liveSession?.workdir ?? (manualSel ? (state.projects.find((p) => inProject(manualSel.cwd, p.workdir))?.workdir ?? null) : null) ?? (sel?.kind === 'history' ? sel.workdir : null) ?? selectedProject
  const activeProject = state.projects.find((p) => p.workdir === activeWd) ?? null

  // 聊天里点文件/工具卡 → 在当前会话开一个文件标签并切到「文件」视图(相对路径补成绝对)
  const openFileInConsole = useCallback((path: string) => {
    const abs = path.startsWith('/') || path.startsWith('~') ? path : (activeWd ? `${activeWd}/${path}` : path)
    setFilesBySession((m) => { const cur = m[sessionKey] ?? []; return cur.includes(abs) ? m : { ...m, [sessionKey]: [...cur, abs] } })
    setActiveFileBySession((m) => ({ ...m, [sessionKey]: abs }))
    setViewBySession((m) => ({ ...m, [sessionKey]: 'files' }))
  }, [activeWd, sessionKey])

  // 选中代码 / 文件 → 放入输入框(仅活动会话有输入框)
  const addCode = (start: number, end: number, snippet: string, file: string, lang: string) =>
    setAttachments((p) => [...p, { id: newAid(), kind: 'code', file, start, end, lang, snippet }])
  const addFile = (path: string) =>
    setAttachments((p) => p.some((a) => a.kind === 'file' && a.path === path) ? p : [...p, { id: newAid(), kind: 'file', name: path.split('/').pop() ?? path, path, lang: hljsLang(path) ?? fileExt(path) ?? 'file' }])

  // 顶栏 + 身体 + 底部(随会话类型变,但顶栏三段切换一直在)
  let barSession: BarSession | null = null, barRight: React.ReactNode = null, footer: React.ReactNode = null, chat: React.ReactNode = null, queueOverlay: React.ReactNode = null
  let bodyAddSel: typeof addCode | undefined, bodyAddFile: typeof addFile | undefined
  if (liveSession) {
    barSession = { title: liveSession.title, meta: sessionMeta(liveSession.status), model: modelLabel(liveSession.model), renameKey: liveSession.key || liveSession.agentSessionId || liveSession.id }
    // 结束会话改由「标签 ×」/「会话行右键菜单」接管,WorkBar 不再放 X
    chat = <MsgList msgs={liveSession.messages} pending={liveSession.pending} onRespond={onLiveRespond} onOpenFile={openFileInConsole} working={liveSession.status === 'working'} model={liveSession.model} root={liveSession.workdir} />
    footer = <Composer sid={liveSession.id} agent={liveSession.agent} model={liveSession.model} models={liveSession.models} working={liveSession.status === 'working'} attachments={attachments} setAttachments={setAttachments} onSend={(t, imgs) => cmd.sendInput(liveSession.id, t, imgs)} />
    bodyAddSel = addCode; bodyAddFile = addFile
  } else if (manualSel) {
    const mm = tmeta[manualSel.id]
    barSession = { title: manualSel.title, meta: manualMeta(manualSel.state), sub: manualSel.cwd, renameKey: manualSel.key || manualSel.id, manualId: manualSel.id }
    // 终端未知(? = 无法识别的进程,如重启后存活的孤儿 console 进程)→ 没有窗口可顶,不显示唤起。
    barRight = (manualSel.terminal && manualSel.terminal !== '?')
      ? <button onClick={() => cmd.raiseWindow(manualSel.id)} className="flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-[12px] font-medium text-accentfg hover:brightness-110" style={{ background: 'var(--accent)' }}><AppWindow size={13} /> 唤起 {manualSel.terminal}</button>
      : null
    chat = <MsgList msgs={transcripts[manualSel.id] ?? []} animate={false} working={manualSel.state === 'working'} onOpenFile={openFileInConsole} root={manualSel.cwd} hasEarlier={mm?.hasEarlier} onLoadEarlier={() => mm && cmd.loadTranscript('manual', manualSel.id, undefined, mm.earliest)} />
    footer = viewMode === 'chat' ? <div className="flex-none px-7 py-2.5 border-t border-line text-[11px] text-faint">手动会话:在 {manualSel.terminal} 里输入,这里只读。</div> : null
    // 排队消息:独立浮层(不占对话空间、不打乱消息高度),浮在对话底部、输入区之上;干净样式:图标+透明文字、无背景。
    if (viewMode === 'chat' && (mm?.queued?.length ?? 0) > 0) {
      queueOverlay = (
        <div className="absolute left-5 bottom-4 z-30 pointer-events-none flex flex-col justify-end gap-1" style={{ maxHeight: '55%', maxWidth: 'calc(100% - 40px)' }}>
          <QueueDanmaku items={mm!.queued!} />
        </div>
      )
    }
  } else if (historySel) {
    const hm = tmeta[historySel.id]
    barSession = { title: historySel.label, meta: { text: '历史 · 只读', color: 'var(--text-faint)', hollow: true }, renameKey: historySel.key || historySel.id }
    barRight = <button onClick={() => doResume(histWd, historySel.id, historySel.agent)} disabled={pendingResume === historySel.id} className="flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-[12px] font-medium text-accentfg hover:brightness-110 disabled:opacity-60" style={{ background: 'var(--accent)' }}><RotateCcw size={13} className={pendingResume === historySel.id ? 'animate-spin' : ''} />{pendingResume === historySel.id ? '恢复中…' : 'Resume'}</button>
    chat = <MsgList msgs={transcripts[historySel.id] ?? []} animate={false} onOpenFile={openFileInConsole} root={histWd} hasEarlier={hm?.hasEarlier} onLoadEarlier={() => hm && cmd.loadTranscript('history', historySel.id, histWd, hm.earliest)} />
  }
  // 仅「无选中会话」(项目空视图)时给项目新建/继续菜单;选了 console 会话不冒它出来。
  if (!barRight && activeProject && !sel) {
    barRight = <AgentActionMenu workdir={activeProject.workdir} includeContinue />
  }
  // 当前选中但「未固定」的会话(= 正在预览的历史会话)作为一个临时标签露出;
  // 切到别的会话时它自动消失,不会越点越多。固定标签(live)仍常驻。
  const previewTab = sel && !openTabs.some((t) => selKey(t) === selKey(sel)) ? sel : null
  const tabList = previewTab ? [...openTabs, previewTab] : openTabs
  const emptyChat = (
    <div className="flex-1 flex flex-col items-center justify-center text-faint gap-3 bg-bg">
      <div className="w-12 h-12 rounded-2xl flex items-center justify-center" style={{ background: 'var(--accent-soft)', color: 'var(--accent)' }}><PanelsTopLeft size={22} /></div>
      <div className="text-[13px]">选择左侧会话开始</div>
    </div>
  )

  return (
    <div className="flex h-full flex-1 min-w-0">
      {/* 左列:会话分组 / Git Tree */}
      <div className="w-[312px] shrink-0 bg-elev border-r border-line flex flex-col min-h-0">
        {navMode === 'sessions'
          ? <SessionsNav groups={orderedGroups} sel={sel} activeWd={activeWd} defaultWd={state.defaultWorkdir} expanded={expanded} toggle={toggleGroup} pick={pick} onReorder={reorder} onRemove={(wd) => cmd.removeProject(wd)} flipping={flippedIds} />
          : <GitTreeNav projects={state.projects} activeWd={activeWd} branchSel={branchSel} collapsed={gitCollapsed} toggle={toggleGit} inited={inited} onInit={(wd) => setInited((p) => new Set(p).add(wd))} onBranch={onBranch} />}
      </div>

      {/* 工作区:已打开会话标签 + 通栏会话头(WorkBar)+ 身体 */}
      <div className="flex-1 min-w-0 flex flex-col bg-bg min-h-0">
        {tabList.length > 0 && (
          <div className="flex-none flex items-stretch gap-1 px-2 pt-1.5 overflow-x-auto bg-elev border-b border-line">
            {tabList.map((t) => {
              const on = !!sel && selKey(sel) === selKey(t)
              const info = tabMeta(t)
              const preview = !!previewTab && selKey(t) === selKey(previewTab)   // 预览标签:斜体提示「未固定」
              return (
                <div key={selKey(t)} onClick={() => setSel(t)}
                  className="group flex items-center gap-2 pl-2.5 pr-1 py-1.5 rounded-t-[8px] cursor-pointer max-w-[170px] shrink-0 border-b-2 transition-colors"
                  style={on ? { borderColor: 'var(--accent)', background: 'var(--bg)' } : { borderColor: 'transparent' }}>
                  <Dot meta={info.dot} size={6} />
                  <span className="text-[12px] truncate" style={{ color: on ? 'var(--text)' : 'var(--text-dim)', fontStyle: preview ? 'italic' : 'normal' }}>{info.title}</span>
                  <button onClick={(e) => { e.stopPropagation(); closeTab(t) }} title="关闭标签" className="shrink-0 opacity-0 group-hover:opacity-100 text-faint hover:text-ink rounded p-0.5"><X size={12} /></button>
                </div>
              )
            })}
          </div>
        )}
        {sel && (
          <WorkBar session={barSession}
            tri={<TriToggle navMode={navMode} viewMode={viewMode} onConv={onConv} onGit={onGit} onFiles={onFiles} />} right={barRight} />
        )}
        <div key={sel ? sel.kind + sel.id : 'empty'} className="flex-1 flex flex-col min-h-0 animate-conv">
          <div className="relative flex-1 min-h-0 flex flex-col">
            <WorkBody viewMode={viewMode} project={activeProject} openFile={openFile} fileTabs={fileTabs} onPickFile={openFileInConsole} onCloseFile={closeFileTab} onAddSel={bodyAddSel} onAddFile={bodyAddFile} chat={chat ?? emptyChat} />
            {queueOverlay}
          </div>
          {footer}
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

// ===== Provider 管理 =====
function ProvidersPage() {
  return (
    <div className="flex-1 overflow-y-auto bg-bg">
      <div className="max-w-[820px] mx-auto px-8 pt-8 pb-12">
        <div className="flex items-end justify-between gap-4">
          <div>
            <div className="text-[20px] font-semibold text-ink">Provider 管理</div>
            <div className="text-[12.5px] text-dim mt-1">配置 AI 服务商、密钥与可用模型。新建会话时手动选择使用 Claude 或 Codex。</div>
          </div>
          <button className="flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-[12.5px] font-medium text-accentfg hover:brightness-110 shrink-0" style={{ background: 'var(--accent)' }}><Plus size={14} strokeWidth={2.2} />添加 Provider</button>
        </div>
        <div className="mt-6 flex flex-col gap-3">
          {PROVIDERS.map((p, i) => (
            <div key={p.id} className="p-[18px] rounded-[13px] border border-line bg-elev" style={p.online ? undefined : { opacity: 0.72 }}>
              <div className="flex items-center gap-3.5">
                <div className="w-10 h-10 shrink-0 rounded-[11px] flex items-center justify-center font-semibold text-[15px]" style={{ background: p.iconBg, color: p.iconFg }}>{p.initial}</div>
                <div className="flex-1 min-w-0">
                  <div className="flex items-center gap-2.5">
                    <span className="text-[14px] font-semibold text-ink">{p.name}</span>
                    {(p.id === 'claude' || p.id === 'codex') && <span className="text-[10px] font-medium px-1.5 py-0.5 rounded" style={{ background: 'var(--accent-soft)', color: 'var(--accent)' }}>已接入</span>}
                  </div>
                  <div className="text-[11.5px] text-faint mt-0.5">{p.vendor}</div>
                </div>
                <div className="flex items-center gap-1.5">
                  <span className="w-2 h-2 rounded-full" style={{ background: p.online ? 'var(--green)' : 'var(--text-faint)' }} />
                  <span className="text-[11.5px]" style={{ color: p.online ? 'var(--text-dim)' : 'var(--text-faint)' }}>{p.online ? '在线' : '未连接'}</span>
                </div>
              </div>
              <div className="flex items-center gap-5 mt-3.5 pt-3.5 border-t border-line">
                <div className="min-w-0">
                  <div className="text-[10.5px] text-faint">API 密钥</div>
                  <div className="font-mono text-[12px] text-dim mt-0.5 truncate">{p.key}</div>
                </div>
                <div className="min-w-0">
                  <div className="text-[10.5px] text-faint">可用模型</div>
                  <div className="text-[12px] text-dim mt-0.5 truncate">{p.models.length} 个 · {p.models[0]}</div>
                </div>
                <span className="flex-1" />
                <button className="text-[12px] px-2.5 py-1 rounded-lg text-dim hover:bg-sunken transition-colors">管理</button>
              </div>
            </div>
          ))}
        </div>
      </div>
    </div>
  )
}

const CONN_DOT: Record<string, string> = {
  online: 'var(--green)', connecting: 'var(--amber)', offline: 'var(--text-faint)',
  unpaired: 'var(--text-faint)', paused: 'var(--amber)', rejected: 'var(--red)',
}
function ConnSection() {
  const conn = useConn()
  const [host, setHost] = useState('')
  const [editing, setEditing] = useState(false)
  useEffect(() => { if (!editing && conn) setHost(conn.host) }, [conn?.host, editing])
  if (!conn) return null
  const dot = CONN_DOT[conn.state] ?? 'var(--text-faint)'
  return (
    <>
      <div className="text-[11px] font-semibold tracking-[0.05em] uppercase text-faint mb-2.5">账号</div>
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
        </div>
        {/* 已登录账号 + 退出 */}
        <div className="flex items-center gap-2.5 px-4 py-4">
          <div className="flex-1 min-w-0">
            <div className="text-[13px] font-medium text-ink">已登录</div>
            <div className="text-[11.5px] text-dim mt-0.5 font-mono truncate">{conn.account || '—'}</div>
          </div>
          <button onClick={() => cmd.logout()} className="text-[12.5px] px-3 py-1.5 rounded-lg hover:bg-sunken" style={{ color: 'var(--red)' }}>退出登录</button>
        </div>
      </div>
    </>
  )
}

function SettingsPage({ theme, setTheme }: { theme: string; setTheme: (t: 'light' | 'dark') => void }) {
  const state = useAgent()
  const prefs = usePrefs()
  const [autosave, setAutosave] = useState(() => localStorage.getItem('console.autosave') !== '0')
  useEffect(() => { localStorage.setItem('console.autosave', autosave ? '1' : '0') }, [autosave])
  const [hostInput, setHostInput] = useState('')
  const [hostSaved, setHostSaved] = useState(false)
  useEffect(() => { if (prefs?.host != null) setHostInput(prefs.host) }, [prefs?.host])
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

        <div className="text-[11px] font-semibold tracking-[0.05em] uppercase text-faint mt-7 mb-2.5">系统</div>
        <div className="border border-line rounded-[13px] bg-elev divide-y divide-line">
          <div className="px-4 py-4">
            <div className="text-[13px] font-medium text-ink mb-1.5">中转服务器</div>
            <div className="flex items-center gap-2">
              <input value={hostInput} onChange={(e) => { setHostInput(e.target.value); setHostSaved(false) }}
                placeholder="服务器 IP / 域名" spellCheck={false}
                className="flex-1 min-w-0 px-3 py-1.5 rounded-lg bg-sunken border border-line text-[12.5px] font-mono text-ink outline-none focus:border-strong" />
              <button onClick={() => { cmd.setHost(hostInput.trim()); setHostSaved(true) }} disabled={!hostInput.trim()}
                className="shrink-0 text-[12.5px] px-3 py-1.5 rounded-lg text-accentfg disabled:opacity-50" style={{ background: 'var(--accent)' }}>
                {hostSaved ? '✓ 已保存' : '保存并重连'}
              </button>
            </div>
            <div className="text-[11px] text-faint mt-1.5">端口固定(WS 8090 / HTTP 8080),只填地址。改后手机端按新地址重连。</div>
          </div>
          <div className="flex items-center px-4 py-4">
            <div className="flex-1"><div className="text-[13px] font-medium text-ink">开机自动启动</div><div className="text-[11.5px] text-dim mt-0.5">登录系统时自动运行 VibeNotch</div></div>
            <button onClick={() => cmd.setLaunchAtLogin(!prefs?.launchAtLogin)} className="w-[42px] h-[24px] rounded-full p-[3px] transition-colors" style={{ background: prefs?.launchAtLogin ? 'var(--accent)' : 'var(--bg-sunken)' }}>
              <span className="block w-[18px] h-[18px] rounded-full bg-white transition-transform" style={{ transform: prefs?.launchAtLogin ? 'translateX(18px)' : 'none', boxShadow: '0 1px 2px rgba(0,0,0,.2)' }} />
            </button>
          </div>
          <div className="flex items-center px-4 py-4">
            <div className="flex-1"><div className="text-[13px] font-medium text-ink">静音提示音</div><div className="text-[11.5px] text-dim mt-0.5">关闭权限请求 / 完成等提示音</div></div>
            <button onClick={() => cmd.setMute(!prefs?.muted)} className="w-[42px] h-[24px] rounded-full p-[3px] transition-colors" style={{ background: prefs?.muted ? 'var(--accent)' : 'var(--bg-sunken)' }}>
              <span className="block w-[18px] h-[18px] rounded-full bg-white transition-transform" style={{ transform: prefs?.muted ? 'translateX(18px)' : 'none', boxShadow: '0 1px 2px rgba(0,0,0,.2)' }} />
            </button>
          </div>
        </div>

        <div className="text-[11px] font-semibold tracking-[0.05em] uppercase text-faint mt-7 mb-2.5">会话</div>
        <div className="border border-line rounded-[13px] bg-elev">
          <div className="flex items-center px-4 py-4 border-b border-line">
            <div className="flex-1"><div className="text-[13px] font-medium text-ink">新建会话 Agent</div><div className="text-[11.5px] text-dim mt-0.5">每次新建时手动选择,不使用默认 Provider</div></div>
            <div className="flex items-center gap-1.5 px-3 py-1.5 rounded-lg bg-sunken text-[12.5px] text-dim"><MessageSquare size={13} />Claude / Codex</div>
          </div>
          <div className="flex items-center px-4 py-4">
            <div className="flex-1"><div className="text-[13px] font-medium text-ink">会话草稿自动保存</div><div className="text-[11.5px] text-dim mt-0.5">输入框内容随变更本地保留</div></div>
            <button onClick={() => setAutosave((v) => !v)} className="w-[42px] h-[24px] rounded-full p-[3px] transition-colors" style={{ background: autosave ? 'var(--accent)' : 'var(--bg-sunken)' }}>
              <span className="block w-[18px] h-[18px] rounded-full bg-white transition-transform" style={{ transform: autosave ? 'translateX(18px)' : 'none', boxShadow: '0 1px 2px rgba(0,0,0,.2)' }} />
            </button>
          </div>
        </div>

        <div className="text-[11px] font-semibold tracking-[0.05em] uppercase text-faint mt-7 mb-2.5">工作目录</div>
        <div className="border border-line rounded-[13px] bg-elev divide-y divide-line">
          <div className="flex items-center px-4 py-4">
            <div className="flex-1 min-w-0">
              <div className="text-[13px] font-medium text-ink">默认工作目录</div>
              <div className="font-mono text-[11.5px] text-dim mt-0.5 truncate" title={state.defaultWorkdir}>{state.defaultWorkdir || '未设置 · 回退到 ~/.vibenotch/workplace'}</div>
              <div className="text-[11px] text-faint mt-1">没导入成项目的会话都归到这个目录下显示;顶层「新建会话」也建在这</div>
            </div>
            <button onClick={() => cmd.pickDefaultWorkdir()} className="text-[12.5px] px-3 py-1.5 rounded-lg border border-strong text-dim hover:bg-sunken transition-colors shrink-0">更改</button>
          </div>
          <div className="px-4 py-4">
            <div className="flex items-center">
              <div className="flex-1 min-w-0">
                <div className="text-[13px] font-medium text-ink">会话归属目录</div>
                <div className="text-[11.5px] text-dim mt-0.5">这些目录下手动建的会话,会读进默认文件夹显示(不会在项目栏单独成文件夹)</div>
              </div>
              <button onClick={() => cmd.addDefaultSessionDir()} className="text-[12.5px] px-3 py-1.5 rounded-lg border border-strong text-dim hover:bg-sunken transition-colors shrink-0">添加目录</button>
            </div>
            {(state.defaultSessionDirs?.length ?? 0) > 0
              ? <div className="mt-2.5 space-y-1">
                  {state.defaultSessionDirs!.map((d) => (
                    <div key={d} className="flex items-center gap-2 px-2.5 py-1.5 rounded-lg bg-sunken">
                      <span className="font-mono text-[11.5px] text-dim flex-1 min-w-0 truncate" title={d}>{d}</span>
                      <button onClick={() => cmd.removeDefaultSessionDir(d)} title="移除" className="shrink-0 text-faint hover:text-[var(--red)] p-0.5 rounded"><X size={13} /></button>
                    </div>
                  ))}
                </div>
              : <div className="mt-2.5 text-[11.5px] text-faint">还没登记。点「添加目录」选一个你常手动建会话、但不想导入成项目的目录。</div>}
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

function NavRail({ page, setPage }: { page: string; setPage: (p: string) => void }) {
  const items = [
    { id: 'console', icon: <PanelsTopLeft size={19} />, label: '工作区' },
    { id: 'usage', icon: <BarChart3 size={19} />, label: '使用统计' },
    { id: 'providers', icon: <Server size={19} />, label: 'Provider 管理' },
  ]
  return (
    <div className="w-[56px] shrink-0 bg-elev border-r border-line flex flex-col items-center gap-1 py-2.5">
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
        className={`w-[38px] h-[38px] rounded-[10px] flex items-center justify-center transition-colors ${page === 'settings' ? '' : 'text-dim hover:bg-sunken'}`}
        style={page === 'settings' ? { background: 'var(--accent-soft)', color: 'var(--accent)' } : undefined}><SlidersHorizontal size={19} /></button>
    </div>
  )
}

// 全局标题栏(对齐设计稿 line 34):左留原生红绿灯位,右=主题切换 + 账号头像状态点。
function TitleBar({ theme, toggleTheme }: { theme: string; toggleTheme: () => void }) {
  const conn = useConn()
  const dot = conn ? (CONN_DOT[conn.state] ?? 'var(--text-faint)') : 'var(--text-faint)'
  const initial = (conn?.account || 'A').trim().charAt(0).toUpperCase() || 'A'
  return (
    <div className="flex-none h-[40px] flex items-center pl-[72px] pr-3.5 border-b border-line bg-elev">
      <div className="flex-1" />
      <div className="flex items-center gap-1.5">
        <button onClick={toggleTheme} title="切换主题" className="w-[30px] h-[30px] rounded-[8px] flex items-center justify-center text-dim hover:bg-sunken hover:text-ink transition-colors">
          {theme === 'dark' ? <Sun size={16} /> : <Moon size={15} />}
        </button>
        <div title={conn ? `${conn.account || ''} · ${conn.text || conn.state}` : ''}
          className="relative w-[26px] h-[26px] rounded-full bg-sunken border border-strong flex items-center justify-center text-[11px] font-semibold text-dim select-none">
          {initial}
          <span className="absolute -right-px -bottom-px w-2 h-2 rounded-full" style={{ background: dot, border: '2px solid var(--bg-elev)' }} />
        </div>
      </div>
    </div>
  )
}

// —— 登录页 —— 打开控制台先判断是否登录;未登录走这里,登录成功(conn.loggedIn=true)自动进控制台。
// 流程与手机端一致:邮箱 → 分流(密码登录 / 验证码登录 / 注册)+ 忘记密码。调用走桥接(auth.*)。
function LoginPage() {
  type Step = 'email' | 'password' | 'code' | 'setpw'
  type Flow = 'login' | 'register' | 'reset'
  const [step, setStep] = useState<Step>('email')
  const [flow, setFlow] = useState<Flow>('login')
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [code, setCode] = useState('')
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState('')
  const [info, setInfo] = useState('')

  const acc = email.trim().toLowerCase()
  const emailOk = /\S+@\S+\.\S+/.test(acc)
  const errMsg = (e: any) => (e && e.message) || '出错了'
  const clear = () => { setErr(''); setInfo('') }

  function backToEmail() { clear(); setStep('email'); setFlow('login'); setPassword(''); setCode('') }

  async function run(fn: () => Promise<any>, after?: () => void) {
    if (busy) return
    setBusy(true); clear()
    try { await fn(); after?.() } catch (e) { setErr(errMsg(e)) } finally { setBusy(false) }
  }

  const proceedEmail = () => run(
    async () => {
      const r = await auth.check(acc)
      if (!r.exists) { setFlow('register'); setStep('setpw') }
      else if (r.hasPassword) { setStep('password') }
      else { await auth.sendCode(acc); setFlow('login'); setStep('code'); setInfo('验证码已发送到邮箱') }
    })

  const doPasswordLogin = () => run(() => auth.login(acc, password))
  const switchToCode = () => run(async () => { await auth.sendCode(acc) }, () => { setFlow('login'); setStep('code'); setCode(''); setInfo('验证码已发送') })
  const forgot = () => run(async () => { await auth.sendForgotCode(acc) }, () => { setFlow('reset'); setStep('code'); setCode(''); setPassword(''); setInfo('重置验证码已发送') })
  const proceedRegister = () => run(async () => { await auth.sendRegisterCode(acc) }, () => { setStep('code'); setCode(''); setInfo('注册验证码已发送') })
  const resend = () => run(
    () => flow === 'register' ? auth.sendRegisterCode(acc) : flow === 'reset' ? auth.sendForgotCode(acc) : auth.sendCode(acc),
    () => setInfo('验证码已重新发送'))
  const submitCode = () => {
    if (flow === 'login') run(() => auth.loginWithCode(acc, code))
    else if (flow === 'register') run(() => auth.register(acc, code, password))
    else run(async () => { await auth.resetPassword(acc, code, password) }, () => { setStep('password'); setFlow('login'); setCode(''); setInfo('密码已重置,请用新密码登录') })
  }

  const onEnter = (fn: () => void) => (e: React.KeyboardEvent) => { if (e.key === 'Enter') fn() }
  const inputCls = 'w-full px-3 py-2.5 rounded-[10px] bg-sunken border border-line text-[13px] text-text outline-none focus:border-accent transition-colors placeholder:text-faint'
  const btnCls = 'w-full px-3 py-2.5 rounded-[10px] bg-accent text-accent-fg text-[13px] font-medium transition-opacity hover:opacity-90 disabled:opacity-40'
  const linkCls = 'text-[12px] text-faint hover:text-dim transition-colors'

  const codeTitle = flow === 'register' ? '创建账号' : flow === 'reset' ? '重置密码' : '验证码登录'
  const codeBtn = flow === 'register' ? '注册并登录' : flow === 'reset' ? '重置密码' : '登录'

  return (
    <div className="flex flex-col h-full min-h-0">
      <TitleBar theme={(localStorage.getItem('theme') as any) || 'light'} toggleTheme={() => {}} />
      <div className="flex-1 min-h-0 flex items-center justify-center bg-bg px-6">
        <div className="w-full max-w-[340px] flex flex-col gap-5">
          {/* logo + 标题 */}
          <div className="flex flex-col items-center gap-3 mb-1">
            <div className="w-12 h-12 rounded-[14px] bg-accent flex items-center justify-center shadow-pop">
              <span className="text-accent-fg text-[22px] font-semibold leading-none">›_</span>
            </div>
            <div className="text-center">
              <div className="text-[17px] font-semibold text-text">AI Coding Remote</div>
              <div className="text-[12px] text-faint mt-0.5">
                {step === 'email' ? '登录后用手机遥控你的电脑' :
                 flow === 'register' ? '设置密码,创建新账号' :
                 flow === 'reset' ? '通过邮箱验证码重置密码' :
                 acc}
              </div>
            </div>
          </div>

          {/* 表单 */}
          <div className="flex flex-col gap-2.5">
            {step === 'email' && (
              <>
                <input className={inputCls} type="email" placeholder="邮箱" autoFocus value={email}
                  onChange={e => setEmail(e.target.value)} onKeyDown={onEnter(proceedEmail)} />
                <button className={btnCls} disabled={busy || !emailOk} onClick={proceedEmail}>{busy ? '请稍候…' : '继续'}</button>
              </>
            )}

            {step === 'password' && (
              <>
                <input className={inputCls} type="password" placeholder="密码" autoFocus value={password}
                  onChange={e => setPassword(e.target.value)} onKeyDown={onEnter(doPasswordLogin)} />
                <button className={btnCls} disabled={busy || !password} onClick={doPasswordLogin}>{busy ? '登录中…' : '登录'}</button>
                <div className="flex items-center justify-between pt-1">
                  <button className={linkCls} onClick={switchToCode} disabled={busy}>用验证码登录</button>
                  <button className={linkCls} onClick={forgot} disabled={busy}>忘记密码?</button>
                </div>
              </>
            )}

            {step === 'setpw' && (
              <>
                <input className={inputCls} type="password" placeholder="设置密码(至少 4 位)" autoFocus value={password}
                  onChange={e => setPassword(e.target.value)} onKeyDown={onEnter(proceedRegister)} />
                <button className={btnCls} disabled={busy || password.length < 4} onClick={proceedRegister}>{busy ? '请稍候…' : '继续'}</button>
                <div className="text-[11px] text-faint pt-0.5">该邮箱未注册,设置密码后用验证码完成注册。</div>
              </>
            )}

            {step === 'code' && (
              <>
                <div className="text-[12px] text-dim -mb-0.5">{codeTitle} · {acc}</div>
                <input className={`${inputCls} font-mono tracking-widest`} inputMode="numeric" placeholder="6 位验证码" autoFocus value={code}
                  onChange={e => setCode(e.target.value)} onKeyDown={onEnter(submitCode)} />
                {flow === 'reset' && (
                  <input className={inputCls} type="password" placeholder="新密码(至少 4 位)" value={password}
                    onChange={e => setPassword(e.target.value)} onKeyDown={onEnter(submitCode)} />
                )}
                <button className={btnCls}
                  disabled={busy || code.trim().length < 4 || (flow === 'reset' && password.length < 4)}
                  onClick={submitCode}>{busy ? '请稍候…' : codeBtn}</button>
                <div className="flex items-center justify-between pt-1">
                  <button className={linkCls} onClick={resend} disabled={busy}>重新发送验证码</button>
                </div>
              </>
            )}

            {/* 提示 */}
            {info && <div className="text-[12px] text-green">{info}</div>}
            {err && <div className="text-[12px] text-red">{err}</div>}

            {step !== 'email' && (
              <button className={`${linkCls} self-start pt-1`} onClick={backToEmail} disabled={busy}>← 换个邮箱</button>
            )}
          </div>
        </div>
      </div>
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

  // 门禁:首个 conn 推送前留白等待;未登录 → 登录页;登录成功后 conn.loggedIn 翻 true 自动进控制台。
  const conn = useConn()
  if (!conn) return <div className="h-full bg-bg" />
  if (!conn.loggedIn) return <LoginPage />

  return (
    <div className="flex flex-col h-full min-h-0">
      <TitleBar theme={theme} toggleTheme={toggleTheme} />
      <div className="flex flex-1 min-h-0">
        <NavRail page={page} setPage={setPage} />
        {/* 控制台常驻不卸载,切页面回来仍记得选中的项目/文件/树展开 */}
        <div className="flex flex-1 min-w-0 min-h-0" style={{ display: page === 'console' ? 'flex' : 'none' }}>
          <ConsolePage />
        </div>
        {page === 'usage' && <UsagePage />}
        {page === 'providers' && <ProvidersPage />}
        {page === 'settings' && <SettingsPage theme={theme} setTheme={setTheme} />}
      </div>
    </div>
  )
}
