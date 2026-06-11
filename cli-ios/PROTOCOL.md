# AI Coding Remote — 通信协议 (PROTOCOL)

> 状态: **Draft v0.1**
> 这是 **iOS 客户端 ↔ 中转服务器 ↔ 电脑代理** 三端的唯一通信契约。
> 三端各自独立实现,但必须严格遵守本文档。任何端要新增/修改消息,先改这里。

---

## 0. 名词

| 名词 | 含义 |
|---|---|
| **iOS 端 / Client** | 手机 App。纯粹的「协议驱动 UI 渲染器」,自己几乎不决定 UI,只把下发的组件树渲染出来,并把用户交互回传。 |
| **Server** | 公网中转服务器。按账号配对两端,双向搬运消息,负责离线缓冲、回放、推送。 |
| **Agent** | 电脑代理。持有并驱动本机 claude code / 终端,把 claude 的输出**翻译成本协议的组件**,把客户端回传的动作执行到终端。 |
| **Frame** | 一条协议消息(JSON)。 |
| **Component / Block** | UI 组件。Frame 携带的组件树的节点。 |

数据走向:

```
[iOS Client] ⇄ WebSocket ⇄ [Server] ⇄ WebSocket ⇄ [Agent] ⇄ 终端/claude
```

iOS 端不认识 claude,只认识「组件」。所有 UI 形态都由 Agent 决定、经协议下发。

---

## 1. 核心原则(先读这一节)

1. **Server-Driven UI**:屏幕上的一切(卡片、按钮、列表、输入框)由下发的组件描述决定。客户端是渲染器,不是 UI 设计者。
2. **永不崩溃 / 优雅降级**:遇到不认识的组件类型或字段,**渲染兜底文本,绝不抛异常、绝不白屏**。
3. **强制兜底文本**:每条富消息都必须带 `fallbackText`(纯文本/markdown)。旧版客户端不认识新组件时,显示它。**这一条是协议能长期演进而不出灾难的根本。**
4. **只增不改**:同一大版本(`v`)内,只允许「新增组件类型 / 新增可选字段」,**禁止改已有字段语义或删字段**。破坏性变更必须升 `v`。
5. **能力协商**:握手时客户端声明支持的协议版本与组件清单,Server/Agent 按需降级。
6. **传输用 JSON**:可读、易扩展、加字段零成本。二进制(图片/文件)走单独上传换 URL,不塞进 JSON。

---

## 2. 传输层

- **协议**:WebSocket(`wss://`,TLS 必须)。
- **编码**:文本帧,UTF-8 JSON。一帧 = 一个 Frame。
- **二进制**:图片/文件**不走** WS 文本帧。先通过 HTTP 上传接口拿到 `url`,组件里只引用 `url`。
- **心跳**:应用层 `ping`/`pong`(见 §7),不依赖 WS 自带 ping,便于穿透代理。
- **顺序与去重**:同一会话内 `seq` 单调递增,客户端按 `seq` 排序、按 `id` 去重。

---

## 3. Frame 信封(所有消息共有的外层)

```jsonc
{
  "v": 1,                    // 协议大版本 (int, 必填)
  "t": "ui",                 // frame 类型 (string, 必填) —— 见 §4
  "id": "msg_a1b2",          // 本条消息稳定 ID (string, 必填) —— 流式更新/去重/交互回指都靠它
  "sid": "sess_123",         // 会话 ID (string, ui/patch/action 必填)
  "seq": 42,                 // 会话内单调递增序号 (int, 内容类 frame 必填)
  "ts": 1718000000000,       // 服务端毫秒时间戳 (int)
  "from": "agent",           // 发送方: "agent" | "client" | "server"
  "fallbackText": "运行命令: npm test",  // 富消息必填,见原则 3
  "body": { /* t 决定结构 */ }
}
```

> 内容类 frame = `ui` / `patch`。控制类 frame(`ping`、`auth` 等)可省略 `sid` / `seq` / `fallbackText`。

---

## 4. Frame 类型 (`t`)

| `t` | 方向 | 说明 |
|---|---|---|
| `auth` | Client→Server | 登录握手,带 token + 能力声明 |
| `auth_ok` / `auth_err` | Server→Client | 握手结果 |
| `presence` | Server→Client | 对端(Agent/设备)上线/下线 |
| `ui` | Agent→Client | **一条富消息**,body 携带组件树 |
| `patch` | Agent→Client | **更新已存在的 ui 消息**(流式追加、改状态) |
| `action` | Client→Agent | 用户交互结果(点按钮、选选项、提交输入) |
| `input` | Client→Agent | 用户主动发的内容(文本/图片消息) |
| `ack` | 双向 | 送达确认(可选,按 `id`) |
| `ping` / `pong` | 双向 | 心跳 |
| `resume` | Client→Server | 重连后请求回放(带 last_seq) |
| `error` | 任意 | 错误通知 |

---

## 5. 组件模型(`t: "ui"` 的核心)

`ui` frame 的 `body` 是一棵**组件树**:

```jsonc
{
  "t": "ui",
  "id": "msg_77",
  "sid": "sess_123",
  "seq": 108,
  "fallbackText": "Claude 想运行 `rm -rf build/`,需要你确认",
  "body": {
    "role": "agent",          // 消息归属: agent | user | system —— 决定气泡方向/样式
    "session": {              // 可选: 任务/会话元信息(只增字段),客户端首页任务行用
      "title": "工作 Mac",     //   终端/IDE 名
      "subtitle": "重构支付模块",//   prompt 摘要 / 当前活动
      "status": "working",     //   idle | working | waiting | done | ended
      "needsAction": false     //   是否有待批准命令(首页高亮)
    },
    "root": { /* 根组件 */ }
  }
}
```

> **会话即任务**:`sid` 唯一标识一个会话(如一个终端里的一次 claude 会话)。同一 `sid` 的多条
> `ui`/`patch` 属于同一任务;客户端按 `sid` 分组成多个任务,首页一任务一行(用 `body.session`)。
> 服务端按 `sid` 保留每会话最后一帧快照,新 Client 连上时补发,使其立刻看到全部任务。

### 5.1 组件通用结构

每个组件节点统一长这样:

```jsonc
{
  "type": "card",          // 组件类型 (必填) —— 决定渲染器
  "cid": "c1",             // 组件在本消息内的稳定 ID (可选,patch 定位用)
  "props": { /* 类型专属属性 */ },
  "children": [ /* 子组件,仅容器类有 */ ]
}
```

- **容器型**组件用 `children` 嵌套子组件(可递归)。
- **叶子型**组件只有 `props`。
- 客户端用「`type` → SwiftUI 渲染器」注册表递归渲染;`type` 不认识 → 渲染兜底卡。

### 5.2 核心组件目录 (v1)

> 这是 v1 的**核心集**,刻意保持精简。新组件随时可加(遵循只增不改)。

**布局 / 容器**

| type | props | children | 渲染 |
|---|---|---|---|
| `stack` | `spacing`, `padding` | ✅ | 纵向排列 |
| `row` | `spacing`, `align` | ✅ | 横向排列 |
| `card` | `title?`, `style?`, `collapsible?`, `collapsed?` | ✅ | 卡片容器 |
| `divider` | — | — | 分隔线 |

**内容 / 叶子**

| type | props | 渲染 |
|---|---|---|
| `text` | `text`, `markdown:bool`, `style:(body\|caption\|heading)`, `color?` | 文本/Markdown |
| `code` | `code`, `language?`, `copyable:bool` | 代码块 + 复制 |
| `image` | `url`, `thumbUrl?`, `alt?`, `w?`, `h?` | 图片 |
| `file` | `url`, `name`, `size?`, `mime?` | 附件 |
| `badge` | `text`, `color?` | 状态标签 |
| `bubble` | `text`, `role:(user\|agent)`, `markdown?` | 聊天气泡(user 右对齐,agent 左对齐) |
| `keyvalue` | `items:[{k,v}]` | 键值表 |
| `progress` | `value:0..1\|null`, `label?` | 进度条(null=无限转圈) |
| `diff` | `filename?`, `hunks:[{op:(add\|del\|ctx), text}]` | 文件 diff |

**交互**(均带 `action`,见 §6)

| type | props | 渲染 |
|---|---|---|
| `button` | `label`, `style:(primary\|danger\|default)`, `icon?` | 按钮 |
| `button_group` | `buttons:[button]` | 一排按钮(如 允许/拒绝/总是允许) |
| `select` | `options:[{label,value}]`, `placeholder?` | 下拉/选择 |
| `text_input` | `placeholder?`, `multiline:bool`, `submitLabel?` | 输入框 |
| `toggle` | `label`, `value:bool` | 开关 |

---

## 6. 交互回路(用户操作怎么回传)

交互组件携带 `action`:

```jsonc
{
  "type": "button",
  "props": { "label": "允许", "style": "primary" },
  "action": { "id": "act_allow", "value": "allow" }
}
```

用户点击后,客户端发**上行** `action` frame:

```jsonc
{
  "v": 1, "t": "action",
  "id": "act_evt_5", "sid": "sess_123",
  "body": {
    "msg_id": "msg_77",     // 哪条消息上的交互
    "action_id": "act_allow",
    "value": "allow",        // text_input 时是输入内容; select 时是选中 value
    "cid": "c1"              // 可选: 哪个组件
  }
}
```

Server 按 `sid` 转给 Agent,Agent 按 `action_id` 对上号 → 执行到终端(例如替你按下 claude 的「允许」)。

> 这是「手机控制电脑」的最终落点。所有 yes/no、计划审批、选项选择都走这一条上行通道。

---

## 7. 流式与更新(`t: "patch"`)

claude 边跑边吐,所以一条消息会被多次更新。`patch` 通过 `id`(+ 可选 `cid`)定位已有消息/组件:

```jsonc
{
  "v": 1, "t": "patch",
  "id": "msg_77", "sid": "sess_123", "seq": 109,
  "body": {
    "op": "append",          // new | append | replace | update | remove
    "cid": "c_text_1",       // 目标组件 (省略=整条消息)
    "value": { "text": "继续输出的下一段…" }   // op 相关的增量/新值
  }
}
```

**op 语义**

| op | 作用 |
|---|---|
| `append` | 往目标(通常 `text`/`code`)尾部追加 `value`(流式打字) |
| `replace` | 用 `value`(一个完整组件)替换目标组件 |
| `update` | 合并更新目标 `props`(如改 `progress.value`、`badge.text`) |
| `remove` | 删除目标组件(如收起「思考中…」);**省略 `cid` 时删除整个会话(任务关闭)** —— 客户端从任务列表移除该 `sid`,服务端同时丢弃其快照 |

> 一条消息的生命周期典型是:`ui(new)` → 多次 `patch(append/update)` → `patch(update)` 标记完成态。客户端始终用 `id` 找到那条气泡原地更新。

---

## 8. 控制类 Frame

### 8.1 握手 `auth`

```jsonc
// Client → Server
{ "v": 1, "t": "auth", "id": "h1",
  "body": {
    "token": "<jwt/session token>",
    "device": { "platform": "ios", "name": "我的 iPhone" },
    "caps": { "protocol": 1, "components": ["stack","row","card","text","code","button","button_group","select","text_input","image","diff","progress","todo"] }
  }
}
// Server → Client
{ "v": 1, "t": "auth_ok", "id": "h1",
  "body": { "user_id": "u_1", "last_seq": 108, "agents": [ {"id":"agent_mac","name":"工作 Mac","online":true} ] }
}
```

- 登录是会合机制:谁先登不重要,Server 记录账号下在线的 Agent/设备,配对投递。
- `caps.components` 让 Agent 知道这个客户端支持哪些组件 → 不支持的可降级。

### 8.2 在线状态 `presence`

```jsonc
{ "v": 1, "t": "presence", "body": { "agent_id": "agent_mac", "online": false } }
```

### 8.3 心跳 `ping` / `pong`

```jsonc
{ "v": 1, "t": "ping", "id": "p_12", "ts": 1718000000000 }
{ "v": 1, "t": "pong", "id": "p_12", "ts": 1718000000050 }
```

### 8.4 重连回放 `resume`

```jsonc
// Client 重连后 → Server
{ "v": 1, "t": "resume", "sid": "sess_123", "body": { "last_seq": 108 } }
// Server 把 seq > 108 的消息按序补发
```

### 8.5 错误 `error`

```jsonc
{ "v": 1, "t": "error", "body": { "code": "session_gone", "message": "会话已结束", "fatal": false } }
```

---

## 9. 客户端主动发消息 `input`

用户在输入框打字 / 发图,走 `input`:

```jsonc
{
  "v": 1, "t": "input", "id": "in_9", "sid": "sess_123",
  "body": {
    "kind": "text",                 // text | image | file
    "text": "帮我跑一下测试",
    "attachments": [ { "url": "https://.../img.jpg", "mime": "image/jpeg" } ]
  }
}
```

Agent 收到后,把它喂给 claude / 终端。

---

## 10. iOS 实现契约(关键约束)

> 这几条不是建议,是为了不出灾难的**硬约束**:

1. **解码用带兜底的枚举**:组件 `type` 解析必须有 `.unknown(raw)` 分支,解码任何未知类型不得抛错。Frame `t` 同理。
2. **渲染器注册表**:`type → some View` 的注册表 + 递归渲染 `children`。新增组件 = 只加一个渲染器文件,不碰旧代码。
3. **未知即兜底**:未知 `type` / 未知 `t` → 渲染 `fallbackText`(消息级)或一张「需更新 App」占位卡。
4. **幂等更新**:`ui`/`patch` 按 `id` 定位,重复收到同 `seq` 直接丢弃。
5. **缺字段不崩**:所有 `props` 字段按「可选 + 合理默认」处理。

---

## 11. 完整示例:一次权限确认

Agent 下发(claude 想删目录):

```jsonc
{
  "v": 1, "t": "ui", "id": "msg_77", "sid": "sess_123", "seq": 108, "from": "agent",
  "fallbackText": "Claude 想运行 `rm -rf build/`,允许吗?[允许 / 拒绝 / 总是允许]",
  "body": {
    "role": "agent",
    "root": {
      "type": "card",
      "props": { "title": "需要确认", "style": "warning" },
      "children": [
        { "type": "text", "props": { "text": "Claude 想执行命令:", "style": "body" } },
        { "type": "code", "props": { "code": "rm -rf build/", "language": "bash", "copyable": true } },
        { "type": "button_group", "props": {
            "buttons": [
              { "type": "button", "props": { "label": "允许", "style": "primary" },  "action": { "id": "perm_allow",  "value": "allow" } },
              { "type": "button", "props": { "label": "拒绝", "style": "danger" },   "action": { "id": "perm_deny",   "value": "deny" } },
              { "type": "button", "props": { "label": "总是允许", "style": "default" }, "action": { "id": "perm_always", "value": "always" } }
            ]
        } }
      ]
    }
  }
}
```

用户点「允许」,客户端回:

```jsonc
{ "v": 1, "t": "action", "id": "act_5", "sid": "sess_123",
  "body": { "msg_id": "msg_77", "action_id": "perm_allow", "value": "allow" } }
```

Agent 替你按下 claude 的允许,随后用 `patch` 把那张卡更新成「已允许 ✅」:

```jsonc
{ "v": 1, "t": "patch", "id": "msg_77", "sid": "sess_123", "seq": 110,
  "body": { "op": "replace", "value": {
    "type": "card", "props": { "title": "已允许 ✅", "style": "success" },
    "children": [ { "type": "text", "props": { "text": "已执行 rm -rf build/" } } ]
  } } }
```

---

## 12. 待定 / TODO

- [ ] 鉴权细节(token 续期、设备授权)与端到端加密策略(信任服务器 vs 每设备一次性授权)。
- [ ] 图片/文件 HTTP 上传接口规格(独立于本 WS 协议)。
- [ ] `todo` / `table` 等更复杂组件的 props 细化。
- [ ] 多 Agent / 多会话切换的会话列表协议。
- [ ] 错误码全集(`code` 枚举)。

> 本文档为活文档。新增组件类型时:① 在 §5.2 登记 ② 给出 props ③ 补一个示例 ④ 确认带 `fallbackText`。
