package com.aicodingremote.server;

import io.netty.channel.Channel;

/**
 * 一条已鉴权的 WebSocket 连接（PROTOCOL §0：Client 或 Agent）。
 * 由 {@link FrameHandler} 在收到 auth 后创建，挂到 Channel 的 attribute 上。
 */
final class Connection {

    enum Role { CLIENT, AGENT }

    final Channel channel;
    final String account;     // 配对键：同一 account 下的 client 与 agent 互相投递
    final Role role;
    final String deviceId;    // agent 用作 agents[].id；client 可空
    final String deviceName;  // 展示名（"工作 Mac" / "我的 iPhone"）

    Connection(Channel channel, String account, Role role, String deviceId, String deviceName) {
        this.channel = channel;
        this.account = account;
        this.role = role;
        this.deviceId = deviceId;
        this.deviceName = deviceName;
    }

    boolean isAgent() { return role == Role.AGENT; }
    boolean isClient() { return role == Role.CLIENT; }

    @Override public String toString() {
        return role + "(" + deviceName + "@" + account + ")";
    }
}
