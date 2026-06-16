package com.aicodingremote.server;

import com.aicodingremote.server.auth.UserStore;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.netty.channel.Channel;
import io.netty.channel.ChannelHandlerContext;
import io.netty.channel.SimpleChannelInboundHandler;
import io.netty.handler.codec.http.websocketx.TextWebSocketFrame;
import io.netty.util.AttributeKey;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * 业务层：解析每一条文本帧的信封，按 PROTOCOL §4 的 `t` 路由。
 * 服务端是「哑管道」——内容类 frame（ui/patch/action/input）原文透传，绝不改 body。
 */
final class FrameHandler extends SimpleChannelInboundHandler<TextWebSocketFrame> {

    private static final Logger log = LoggerFactory.getLogger(FrameHandler.class);
    private static final ObjectMapper M = new ObjectMapper();
    /** 鉴权后把 Connection 挂到 channel 上，后续帧据此判断身份与账号。 */
    static final AttributeKey<Connection> CONN = AttributeKey.valueOf("aicr.conn");

    private final Hub hub;
    private final UserStore users;

    FrameHandler(Hub hub, UserStore users) {
        this.hub = hub;
        this.users = users;
    }

    @Override
    protected void channelRead0(ChannelHandlerContext ctx, TextWebSocketFrame frame) {
        String text = frame.text();
        JsonNode root;
        try {
            root = M.readTree(text);
        } catch (Exception e) {
            send(ctx.channel(), Frames.error("bad_json", "JSON 解析失败", false));
            return;
        }

        String t = root.path("t").asText("");
        switch (t) {
            case "auth"   -> handleAuth(ctx, root);
            case "ping"   -> send(ctx.channel(),
                    Frames.pong(root.path("id").isMissingNode() ? null : root.path("id").asText(),
                                root.path("ts").asLong(System.currentTimeMillis())));
            case "ui"     -> { forward(ctx, text, /*fromAgent=*/true); snapshotUi(ctx, root, text); }
            case "patch"  -> handlePatch(ctx, root, text);
            // 上行指令:先回 server 级 ack(已到服务器),再转发给 Agent;
            // Agent 处理后回 delivered 级 ack,经下面的 "ack" 分支透传回 Client。
            case "action", "input" -> { ackToSender(ctx, root); forward(ctx, text, /*fromAgent=*/false); }
            case "ack"    -> {
                Connection c = ctx.channel().attr(CONN).get();
                forward(ctx, text, /*fromAgent=*/c != null && c.isAgent());
            }
            case "ctl"    -> handleCtl(ctx, root);
            case "resume" -> { /* 最小版无缓冲,忽略回放请求(PROTOCOL §8.4 待实现) */ }
            default -> log.debug("忽略未知/未处理 frame t={}", t);
        }
    }

    /** PROTOCOL §8.1 —— 握手:解析账号与角色,登记,回 auth_ok,并广播 Agent 上线。 */
    private void handleAuth(ChannelHandlerContext ctx, JsonNode root) {
        JsonNode body = root.path("body");
        String token = body.path("token").asText("");
        // 第二道防线:必须持有效令牌(手机=登录签发,Agent=配对签发),
        // 令牌解析出账号才放行;不再信任客户端自报的 account。
        String account = users.accountOf(token);
        if (account == null || account.isEmpty()) {
            log.info("auth 拒绝: 无效令牌 from={}", root.path("from").asText("?"));
            send(ctx.channel(), Frames.error("auth_failed",
                    "未登录/未配对:手机请先登录,电脑请先在 VibeNotch 设置里配对手机", true));
            ctx.close();
            return;
        }

        JsonNode device = body.path("device");
        String from = root.path("from").asText("");
        String platform = device.path("platform").asText("");
        Connection.Role role = switch (from) {
            case "agent" -> Connection.Role.AGENT;
            case "client" -> Connection.Role.CLIENT;
            default -> "ios".equals(platform) ? Connection.Role.CLIENT : Connection.Role.AGENT;
        };

        String deviceName = device.path("name").asText(role == Connection.Role.AGENT ? "Agent" : "Device");
        String deviceId = device.hasNonNull("id") ? device.path("id").asText() : deviceName;

        // 被手机挂起的电脑:拒绝接入,直到手机点「重连」解除
        if (role == Connection.Role.AGENT && hub.isSuspended(account, deviceId)) {
            log.info("auth 拒绝: 设备已被手机挂起 {}@{}", deviceId, account);
            send(ctx.channel(), Frames.error("suspended", "该电脑已被手机端断开,在手机「设备」页点重连恢复", true));
            ctx.close();
            return;
        }

        Connection conn = new Connection(ctx.channel(), account, role, deviceId, deviceName);
        ctx.channel().attr(CONN).set(conn);
        hub.register(conn);
        log.info("auth: {} 上线 (account={})", conn, account);

        // 回 auth_ok:带上该账号当前在线的 Agent 列表
        send(ctx.channel(), Frames.authOk(account, hub.agentsOf(account), hub.suspendedOf(account)));

        if (role == Connection.Role.AGENT) {
            // Agent 上线 → 通知同账号的 Client
            String presence = Frames.presence(deviceId, deviceName, true);
            for (Connection c : hub.clientsOf(account)) send(c.channel, presence);
        } else {
            // Client 上线 → 补发该账号现有所有会话的最后一帧,使其立刻看到全部任务
            for (String snap : hub.snapshotsOf(account)) send(ctx.channel(), snap);
            // 并通知同账号的 Agent「手机上线了」→ Agent 主动全量重推,补齐服务端快照缺漏
            // (服务端重启丢内存 / Agent 早期断网漏同步且之后无变化的场景)。
            String clientUp = Frames.clientPresence(true);
            for (Connection a : hub.agentsOf(account)) send(a.channel, clientUp);
        }
    }

    /** 记录这帧 ui 的快照(按消息 id),供后来连上的 Client 按序补发。 */
    private void snapshotUi(ChannelHandlerContext ctx, JsonNode root, String text) {
        Connection conn = ctx.channel().attr(CONN).get();
        if (conn == null) return;
        String msgId = root.path("id").asText("");
        if (!msgId.isEmpty()) hub.snapshot(conn.account, msgId, text, conn.deviceId);
    }

    /** patch 路由:op=reset 清空账号全部快照并转发(让手机清空);否则正常转发 + 处理删除快照。 */
    private void handlePatch(ChannelHandlerContext ctx, JsonNode root, String text) {
        Connection conn = ctx.channel().attr(CONN).get();
        if (conn != null && "reset".equals(root.path("body").path("op").asText(""))) {
            // 只清这台 Agent 的快照与会话(多电脑同账号时互不影响)
            hub.clearSnapshots(conn.account, conn.deviceId);
            for (Connection c : hub.clientsOf(conn.account)) send(c.channel, text);
            return;
        }
        forward(ctx, text, /*fromAgent=*/true);
        maybeDropSnapshot(ctx, root);
    }

    /** patch(op=remove):scope=session 删整会话快照;否则删单条消息快照。 */
    private void maybeDropSnapshot(ChannelHandlerContext ctx, JsonNode root) {
        Connection conn = ctx.channel().attr(CONN).get();
        if (conn == null) return;
        JsonNode body = root.path("body");
        if (!"remove".equals(body.path("op").asText(""))) return;
        if ("session".equals(body.path("scope").asText(""))) {
            String sid = root.path("sid").asText("");
            if (!sid.isEmpty()) hub.removeSnapshotsWithPrefix(conn.account, "m:" + sid + ":");
        } else {
            String msgId = root.path("id").asText("");
            if (!msgId.isEmpty()) hub.removeSnapshot(conn.account, msgId);
        }
    }

    /** 手机的设备控制:挂起(断开某台电脑)/ 恢复。服务端自己消费,不转发。 */
    private void handleCtl(ChannelHandlerContext ctx, JsonNode root) {
        Connection conn = ctx.channel().attr(CONN).get();
        if (conn == null || conn.isAgent()) return;
        JsonNode body = root.path("body");
        String op = body.path("op").asText("");
        String agentId = body.path("agent").asText("");
        if (agentId.isEmpty()) return;
        switch (op) {
            case "agent_suspend" -> {
                String name = body.path("name").asText(agentId);
                hub.suspendAgent(conn.account, agentId, name);
                // 踢掉该设备当前的连接(channelInactive 会清快照 + 广播 reset/离线)
                for (Connection a : hub.agentsOf(conn.account)) {
                    if (agentId.equals(a.deviceId)) a.channel.close();
                }
                log.info("ctl: 挂起设备 {}@{}", agentId, conn.account);
            }
            case "agent_resume" -> {
                hub.resumeAgent(conn.account, agentId);
                log.info("ctl: 恢复设备 {}@{} (等待其重连)", agentId, conn.account);
            }
            default -> { }
        }
        ackToSender(ctx, root);
    }

    /** 上行帧到达即回 server 级 ack 给发送方(发送方据此把消息标为「已发送 ✓」)。 */
    private void ackToSender(ChannelHandlerContext ctx, JsonNode root) {
        String id = root.path("id").asText("");
        if (!id.isEmpty()) send(ctx.channel(), Frames.ack(id, "server"));
    }

    /** 透传内容类 frame:Agent→所有 Client,或 Client→所有 Agent。原文不改。 */
    private void forward(ChannelHandlerContext ctx, String text, boolean fromAgent) {
        Connection conn = ctx.channel().attr(CONN).get();
        if (conn == null) {
            send(ctx.channel(), Frames.error("not_authed", "请先 auth", false));
            return;
        }
        var targets = fromAgent ? hub.clientsOf(conn.account) : hub.agentsOf(conn.account);
        for (Connection target : targets) send(target.channel, text);
    }

    @Override
    public void channelInactive(ChannelHandlerContext ctx) {
        Connection conn = ctx.channel().attr(CONN).get();
        if (conn != null) {
            hub.unregister(conn);
            log.info("断开: {}", conn);
            if (conn.isAgent()) {
                // 服务端隔离:离线电脑的数据不再保留/回放 —— 清掉它的快照,
                // 并代发设备级 reset + presence 离线,手机立刻移除该电脑的会话。
                // Agent 重连后会全量重推,数据不会丢。
                hub.clearSnapshots(conn.account, conn.deviceId);
                String reset = Frames.agentReset(conn.deviceId);
                String presence = Frames.presence(conn.deviceId, conn.deviceName, false);
                for (Connection c : hub.clientsOf(conn.account)) {
                    send(c.channel, reset);
                    send(c.channel, presence);
                }
            }
        }
    }

    @Override
    public void userEventTriggered(ChannelHandlerContext ctx, Object evt) {
        if (evt instanceof io.netty.handler.timeout.IdleStateEvent e
                && e.state() == io.netty.handler.timeout.IdleState.READER_IDLE) {
            Connection conn = ctx.channel().attr(CONN).get();
            log.info("空闲超时,踢除: {}", conn != null ? conn : ctx.channel());
            ctx.close();
        }
    }

    @Override
    public void exceptionCaught(ChannelHandlerContext ctx, Throwable cause) {
        log.warn("连接异常,关闭: {}", cause.toString());
        ctx.close();
    }

    private static void send(Channel ch, String json) {
        if (ch.isActive()) ch.writeAndFlush(new TextWebSocketFrame(json));
    }
}
