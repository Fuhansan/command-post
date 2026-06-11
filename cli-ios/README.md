# AI Coding Remote — iOS 客户端

手机端「协议驱动 UI 渲染器」。本质是 IM:收发消息,UI 全部由 [PROTOCOL.md](./PROTOCOL.md) 下发的组件树决定。
终端的脏活在电脑代理那边,iOS 端不碰终端/PTY。

```
[iOS 客户端] ⇄ WebSocket ⇄ [中转服务器] ⇄ [电脑代理] ⇄ 终端/claude
```

## 技术栈

- **SwiftUI**(纯,无第三方依赖)/ iOS 17+ / Swift(语言模式 5)
- 网络:`URLSessionWebSocketTask`  ·  存储:Keychain  ·  原生:PhotosUI(相册/相机)
- 工程由 **XcodeGen** 从 `project.yml` 生成

## 构建运行

```bash
xcodegen generate                       # 生成 RemoteCoding.xcodeproj
open RemoteCoding.xcodeproj             # Xcode 里跑,或:
xcodebuild -scheme RemoteCoding -destination 'generic/platform=iOS Simulator' build
```

App 默认加载 `SampleData` 离线演示(登录页随便填 → 选「工作 Mac」→ 看渲染效果),
未接服务端也能直接跑,验证组件渲染。

## 目录结构(对着 PROTOCOL.md)

```
RemoteCoding/
├── App/            入口、RootView、AppState
├── Models/         协议层:JSONValue / Frame / Component(带 .unknown 兜底)
├── Networking/     WebSocketClient(连接状态机/心跳/退避重连)
├── Rendering/      组件渲染器注册表(ComponentView)+ 各 Renderer
│   └── Renderers/  Container / Content / Interactive / Unknown
├── Auth/           KeychainStore
└── Features/       Auth(登录)· Sessions(会话列表)· Chat(聊天+输入栏+示例数据)
```

## 加新组件类型的方法(只增不改)

1. `PROTOCOL.md §5.2` 登记类型 + props + 示例;
2. 在 `Rendering/Renderers/` 加一个 Renderer;
3. `ComponentView` 里加一个 `case`;
4. 旧代码不用动;旧版 App 遇到它自动降级显示 `fallbackText`。

## 现状 / TODO

- ✅ 协议解码链路(JSON→Frame→UIMessage,未知类型不崩)
- ✅ 组件渲染器注册表 + 14 个核心组件 + 兜底
- ✅ 离线示例(含权限确认卡、diff、未知组件兜底)
- ⬜ 接通 WebSocket(`auth` 握手、上行 `action`/`input`、`resume` 回放)
- ⬜ `patch` 的流式 append/update(逐字、进度条)
- ⬜ APNs 推送叫醒
- ⬜ 鉴权 / 端到端加密策略(见 PROTOCOL.md §12)
```
