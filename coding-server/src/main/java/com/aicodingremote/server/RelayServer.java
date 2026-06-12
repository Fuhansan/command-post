package com.aicodingremote.server;

import com.aicodingremote.server.auth.UserStore;
import io.netty.bootstrap.ServerBootstrap;
import io.netty.channel.Channel;
import io.netty.channel.EventLoopGroup;
import io.netty.channel.nio.NioEventLoopGroup;
import io.netty.channel.socket.nio.NioServerSocketChannel;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.context.SmartLifecycle;
import org.springframework.stereotype.Component;

/**
 * 把 Netty 中转 WS 服务做成 Spring 生命周期 Bean：
 * Spring Boot 启动时 {@link #start()} 绑定端口，关闭时 {@link #stop()} 优雅释放。
 * 与 Spring MVC（Tomcat, server.port）并存，业务后续可走 MVC，实时通道走这里。
 */
@Component
public class RelayServer implements SmartLifecycle {

    private static final Logger log = LoggerFactory.getLogger(RelayServer.class);

    private final Hub hub;
    private final RelayProperties props;
    private final UserStore users;

    private EventLoopGroup boss;
    private EventLoopGroup worker;
    private Channel serverChannel;
    private volatile boolean running;

    public RelayServer(Hub hub, RelayProperties props, UserStore users) {
        this.hub = hub;
        this.props = props;
        this.users = users;
    }

    @Override
    public void start() {
        boss = new NioEventLoopGroup(1);
        worker = new NioEventLoopGroup();
        try {
            ServerBootstrap b = new ServerBootstrap();
            b.group(boss, worker)
                    .channel(NioServerSocketChannel.class)
                    .childHandler(new WsServerInitializer(hub, props.getPath(), users));
            serverChannel = b.bind(props.getPort()).syncUninterruptibly().channel();
            running = true;
            log.info("中转 WS 已启动: ws://0.0.0.0:{}{}", props.getPort(), props.getPath());
        } catch (Exception e) {
            log.error("中转 WS 启动失败", e);
            stop();
            throw new IllegalStateException(e);
        }
    }

    @Override
    public void stop() {
        running = false;
        if (serverChannel != null) serverChannel.close();
        if (boss != null) boss.shutdownGracefully();
        if (worker != null) worker.shutdownGracefully();
        log.info("中转 WS 已停止");
    }

    @Override
    public boolean isRunning() {
        return running;
    }
}
