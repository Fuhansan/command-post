# AI Coding Remote — Android 客户端

手机端「协议驱动 UI 渲染器」(Android 版本)。本质是 IM:收发消息,UI 全部由 [PROTOCOL.md](./PROTOCOL.md) 下发的组件树决定。
终端的脏活在电脑代理那边,Android 端不碰终端/PTY。

> 与 [cli-ios](../cli-ios) 严格对称: 一套协议、一致 UI、相同功能集。

```
[Android 客户端] ⇄ WebSocket ⇄ [中转服务器] ⇄ [电脑代理] ⇄ 终端/claude
```

## 技术栈

- **Jetpack Compose** + Material 3 / Android 7.0 (API 24) 起步 / Kotlin 1.9
- 网络:`OkHttp WebSocket`  ·  存储:`EncryptedSharedPreferences`  ·  原生:Coil(图片加载)
- 序列化:`kotlinx.serialization`(`JsonElement` 作为协议里 `props/body` 的载体)
- 构建:Gradle 8.x(`gradle/libs.versions.toml` 集中管理版本)

## 构建运行

依赖 JDK 17 + Android SDK(平台 34、构建工具 34.0.0)。首次需要在仓库根目录跑一次 Gradle Wrapper 同步:

```bash
gradle wrapper                                   # 首次生成 gradlew (本仓库未携带二进制 jar)
./gradlew :app:assembleDebug                     # 直接出包
./gradlew :app:installDebug                      # 装到当前 adb 设备 / 模拟器
```

或直接用 Android Studio 打开 `cli-anr/`,等 Gradle 同步完点 Run。

> 默认连 `ws://127.0.0.1:8090/ws`。真机推荐先跑 `adb reverse tcp:8090 tcp:8090`,手机的 127.0.0.1:8090 会直通 Mac 的 8090;不用 adb reverse 时,在 App 登录页改成电脑的局域网 / Tailscale IP。

## 目录结构(对着 PROTOCOL.md,与 cli-ios 一一对应)

```
cli-anr/
├── PROTOCOL.md                  与 cli-ios 同源,三端唯一通信契约
└── app/src/main/
    ├── AndroidManifest.xml
    ├── res/                     主题、字符串、launcher icon
    └── java/com/aicodingremote/app/
        ├── MainActivity.kt
        ├── RemoteCodingApp.kt   Application(持久化 SecureStore)
        ├── app/                 RootScreen / MainScreen / AppState / CompositionLocals
        ├── auth/                SecureStore(EncryptedSharedPreferences,Keychain 对位)
        ├── designsystem/        Theme(深色令牌)+ Components(Avatar、Modifier.cardStyle)
        ├── models/              JsonValueExt / Frame / Component / TaskModels(协议层,未知类型兜底)
        ├── networking/          WebSocketClient(OkHttp + 退避重连) / RelayClient(单源真状态)
        ├── rendering/           ComponentView(注册表)+ renderers/
        │   └── renderers/       Container / Content / Interactive / Chat / Unknown
        └── features/            Auth(登录)· Tasks(会话列表 + 详情)· Notifications · More(设备/设置)
```

## 加新组件类型的方法(只增不改)

1. `PROTOCOL.md §5.2` 登记类型 + props + 示例;
2. 在 `rendering/renderers/` 加一个 Composable 渲染器;
3. `ComponentView.kt` 里加一个 `when` 分支;
4. 旧代码不用动;旧版 App 遇到它自动降级显示 `fallbackText`。

## 与 iOS 端的对应表

| 模块                       | iOS (SwiftUI)                            | Android (Compose)                                   |
| -------------------------- | ---------------------------------------- | --------------------------------------------------- |
| 入口                       | `RemoteCodingApp` (`@main App`)          | `MainActivity` + `RemoteCodingApp : Application`    |
| 全局状态                   | `AppState : ObservableObject`            | `AppState : ViewModel`                              |
| 中转单例                   | `RelayClient : ObservableObject`         | `RelayClient : ViewModel`                           |
| Token 存储                 | Keychain                                 | EncryptedSharedPreferences                          |
| WebSocket                  | `URLSessionWebSocketTask`                | OkHttp `WebSocket`                                  |
| JSON 不定结构              | `JSONValue` 枚举                         | `kotlinx.serialization.JsonElement` + 扩展取值      |
| 主题令牌                   | `Theme` enum + `cardStyle()` modifier    | `Theme` object + `Modifier.cardStyle()`             |
| 渲染器注册表               | `ComponentView` switch                   | `ComponentView` when 分支                           |
| 4 Tab 框架                 | `TabView`                                | `Scaffold + NavigationBar + NavHost`                |
| Markdown                   | `MarkdownUI`                             | 内置轻量解析(粗体 / 行内 code / 标题 / 列表)       |
| 图片                       | `AsyncImage`                             | Coil `AsyncImage`                                   |

## 现状 / TODO

- ✅ 协议解码链路(JSON→Frame→UIMessage,未知类型不崩)
- ✅ 组件渲染器注册表 + 核心 18 个组件 + 兜底
- ✅ 任务列表(会话列表)+ 会话详情(对话流 + 输入栏)
- ✅ 账号密码登录 + Google 注册/设密码 + Token 安全存储
- ✅ WebSocket 连接 / 自动重连 / 主动 `auth` 握手 / 可靠上行 `action` `input` / `patch` replace/remove
- ✅ 图文输入 / 拍照与相册 / 结束任务 / 手机端新建会话
- ✅ 跨会话待办中心 / 权限批量审批 / 选择题作答
- ✅ 多电脑在线状态 / 断开与重连 / 版本检查与强制更新
- ⬜ `patch` 流式 `append/update`(逐字、进度条)
- ⬜ 推送(FCM)叫醒
- ⬜ 端到端加密策略(见 PROTOCOL.md §12)
- ⬜ Markdown 表格 / 引用块的完整渲染
