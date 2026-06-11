# coding-server

AI Coding Remote 的**公网中转服务器**。按账号把 iOS Client 与电脑 Agent 配对，双向搬运
协议消息。三端通信契约见 `../cli-ios/PROTOCOL.md`。

## 架构

- **Spring Boot (Tomcat, `:8080`)** —— 预留给业务 REST（账号、设备授权、上传换 URL 等）。目前无端点。
- **Netty 中转 WebSocket (`:8090/ws`)** —— Client / Agent 的实时通道。作为 Spring 生命周期 Bean
  (`RelayServer`) 随应用启停。

```
[iOS Client] ⇄ WS ⇄ [coding-server :8090/ws] ⇄ WS ⇄ [Agent]
```

服务器是**哑管道**：内容类 frame（`ui`/`patch`/`action`/`input`）原文透传，绝不改 body。
只处理控制类：`auth` 配对、`ping`→`pong`、`presence` 上下线广播。

### 关键类
- `RelayServer` —— Netty 启停（SmartLifecycle）。
- `WsServerInitializer` —— 连接处理链（HTTP→聚合→WS 升级→FrameHandler）。
- `FrameHandler` —— 按 `t` 路由（PROTOCOL §4）。
- `Hub` —— account → {clients, agents} 注册表与转发查询（Spring Bean，业务可注入）。
- `Frames` —— 服务端下发的控制帧构造（auth_ok / presence / pong / error）。

> 最小可跑通版本**不做**离线缓冲与 `resume` 回放（PROTOCOL §7、§8.4），只做实时投递。

## 配置 (`application.properties`)
```
server.port=8080     # Spring MVC
relay.port=8090      # Netty 中转 WS
relay.path=/ws
```

## 运行

构建用 IDEA 自带 Maven（无需本地装 mvn），或项目自带的 `./mvnw`。

```bash
# 1) 启动服务器
./run.sh server

# 2) 另开一个终端，跑端到端模拟（Agent 推帧 → 服务器 → 手机端 Client 接收 + action 回传）
./run.sh sim
```

`sim` 用 JDK 自带 WebSocket 客户端，开 Agent + Client 两条连接，复刻 iOS 详情页的下发，
跑通即证明配对与双向转发正确。真机 iOS 用**同一 account**连 `ws://<本机IP>:8090/ws` 即可收到同样下发。

## 配对说明（最小版）
握手 `auth.body` 里：
- `account`（或回退用 `token`）作为配对键 —— 同一 account 下 Client 与 Agent 互通。
- 角色由 `from`（`client`/`agent`）决定，缺省时按 `device.platform == "ios"` 判为 Client。
