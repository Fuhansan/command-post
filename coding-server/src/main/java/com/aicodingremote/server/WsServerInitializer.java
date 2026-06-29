package com.aicodingremote.server;

import com.aicodingremote.server.auth.UserStore;
import io.netty.channel.ChannelInitializer;
import io.netty.channel.ChannelPipeline;
import io.netty.channel.socket.SocketChannel;
import io.netty.handler.codec.http.HttpObjectAggregator;
import io.netty.handler.codec.http.HttpServerCodec;
import io.netty.handler.codec.http.websocketx.WebSocketServerProtocolHandler;
import io.netty.handler.timeout.IdleStateHandler;

/**
 * 每条连接的 Netty 处理链：HTTP 编解码 → 聚合 → WS 握手升级 → 业务 FrameHandler。
 */
final class WsServerInitializer extends ChannelInitializer<SocketChannel> {

    private static final int MAX_FRAME = 8 << 20; // 8MB 单帧上限(手机上行图片走 WS base64,需放宽)

    private final Hub hub;
    private final String path;
    private final UserStore users;
    private final MQRelay mqRelay;

    WsServerInitializer(Hub hub, String path, UserStore users, MQRelay mqRelay) {
        this.hub = hub;
        this.path = path;
        this.users = users;
        this.mqRelay = mqRelay;
    }

    @Override
    protected void initChannel(SocketChannel ch) {
        ChannelPipeline p = ch.pipeline();
        // 75s 收不到任何帧(两端心跳间隔 25s)→ READER_IDLE → FrameHandler 关连接,
        // 清理半开的僵尸连接(手机锁屏/切网后 TCP 黑洞)。
        p.addLast(new IdleStateHandler(75, 0, 0));
        p.addLast(new HttpServerCodec());
        p.addLast(new HttpObjectAggregator(MAX_FRAME));
        // 第三参 true = 处理关闭帧；WS 协议层 ping/pong 由它处理,应用层 ping/pong 走 JSON 文本帧。
        // 第四参:WS 单帧上限(默认 64KB,不够装图片)。
        p.addLast(new WebSocketServerProtocolHandler(path, null, true, MAX_FRAME));
        p.addLast(new FrameHandler(hub, users, mqRelay));
    }
}
