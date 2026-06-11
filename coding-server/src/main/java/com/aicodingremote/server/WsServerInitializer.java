package com.aicodingremote.server;

import io.netty.channel.ChannelInitializer;
import io.netty.channel.ChannelPipeline;
import io.netty.channel.socket.SocketChannel;
import io.netty.handler.codec.http.HttpObjectAggregator;
import io.netty.handler.codec.http.HttpServerCodec;
import io.netty.handler.codec.http.websocketx.WebSocketServerProtocolHandler;

/**
 * 每条连接的 Netty 处理链：HTTP 编解码 → 聚合 → WS 握手升级 → 业务 FrameHandler。
 */
final class WsServerInitializer extends ChannelInitializer<SocketChannel> {

    private static final int MAX_FRAME = 1 << 20; // 1MB 单帧上限（图片/文件不走 WS，见 PROTOCOL §2）

    private final Hub hub;
    private final String path;

    WsServerInitializer(Hub hub, String path) {
        this.hub = hub;
        this.path = path;
    }

    @Override
    protected void initChannel(SocketChannel ch) {
        ChannelPipeline p = ch.pipeline();
        p.addLast(new HttpServerCodec());
        p.addLast(new HttpObjectAggregator(MAX_FRAME));
        // 第三参 true = 处理关闭帧；WS 协议层 ping/pong 由它处理,应用层 ping/pong 走 JSON 文本帧。
        p.addLast(new WebSocketServerProtocolHandler(path, null, true));
        p.addLast(new FrameHandler(hub));
    }
}
