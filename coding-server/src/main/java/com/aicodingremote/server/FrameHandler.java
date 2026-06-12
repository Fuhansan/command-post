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
            case "resume" -> { /* 最小版无缓冲,忽略回放请求(PROTOCOL §8.4 待实现) */ }
            default -> log.debug("忽略未知/未处理 frame t={}", t);
        }
    }

    /** PROTOCOL §8.1 —— 握手:解析账号与角色,登记,回 auth_ok,并广播 Agent 上线。 */
    private void handleAuth(ChannelHandlerContext ctx, JsonNode root) {
        JsonNode body = root.path("body");
        String token = body.path("token").asText("");
        // 配对键:优先用登录令牌解析真实账号(不信任客户端自报);
        // 解析不到则回退「显式 account / token 当账号」的旧会合机制(Agent 仍走这条)。
        String resolved = users.accountOf(token);
        String account = resolved != null ? resolved
                : (body.hasNonNull("account") ? body.path("account").asText() : token);
        if (account.isEmpty()) {
            send(ctx.channel(), Frames.error("no_account", "缺少 token/account", true));
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

        Connection conn = new Connection(ctx.channel(), account, role, deviceId, deviceName);
        ctx.channel().attr(CONN).set(conn);
        hub.register(conn);
        log.info("auth: {} 上线 (account={})", conn, account);

        // 回 auth_ok:带上该账号当前在线的 Agent 列表
        send(ctx.channel(), Frames.authOk(account, hub.agentsOf(account)));

        if (role == Connection.Role.AGENT) {
            // Agent 上线 → 通知同账号的 Client
            String presence = Frames.presence(deviceId, deviceName, true);
            for (Connection c : hub.clientsOf(account)) send(c.channel, presence);
        } else {
            // Client 上线 → 补发该账号现有所有会话的最后一帧,使其立刻看到全部任务
            for (String snap : hub.snapshotsOf(account)) send(ctx.channel(), snap);
        }
    }

    /** 记录这帧 ui 的快照(按消息 id),供后来连上的 Client 按序补发。 */
    private void snapshotUi(ChannelHandlerContext ctx, JsonNode root, String text) {
        Connection conn = ctx.channel().attr(CONN).get();
        if (conn == null) return;
        String msgId = root.path("id").asText("");
        if (!msgId.isEmpty()) hub.snapshot(conn.account, msgId, text);
    }

    /** patch 路由:op=reset 清空账号全部快照并转发(让手机清空);否则正常转发 + 处理删除快照。 */
    private void handlePatch(ChannelHandlerContext ctx, JsonNode root, String text) {
        Connection conn = ctx.channel().attr(CONN).get();
        if (conn != null && "reset".equals(root.path("body").path("op").asText(""))) {
            hub.clearSnapshots(conn.account);
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
                String presence = Frames.presence(conn.deviceId, conn.deviceName, false);
                for (Connection c : hub.clientsOf(conn.account)) send(c.channel, presence);
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
