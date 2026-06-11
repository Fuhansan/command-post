package com.aicodingremote.server;

import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.stereotype.Component;

/**
 * 中转 WS 的配置（application.properties 里的 relay.*）。
 */
@Component
@ConfigurationProperties(prefix = "relay")
public class RelayProperties {

    /** Netty 监听端口（与 Spring MVC 的 server.port 分开）。 */
    private int port = 8090;

    /** WebSocket 路径。 */
    private String path = "/ws";

    public int getPort() { return port; }
    public void setPort(int port) { this.port = port; }

    public String getPath() { return path; }
    public void setPath(String path) { this.path = path; }
}
