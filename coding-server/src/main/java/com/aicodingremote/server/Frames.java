package com.aicodingremote.server;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;

import java.util.Collection;

/**
 * 服务端主动下发的控制类 Frame 构造器（PROTOCOL §8）。
 * 内容类 frame（ui/patch/action/input）服务端只做透明转发，不在这里构造。
 */
final class Frames {

    private static final ObjectMapper M = new ObjectMapper();

    private Frames() {}

    /** PROTOCOL §8.1 —— 握手成功，回带账号下在线 Agent + 被挂起的 Agent 列表 + 全量登录设备列表。 */
    static String authOk(String account, Collection<Connection> agents,
                         java.util.Map<String, String> suspendedAgents,
                         java.util.List<java.util.Map<String, Object>> devices) {
        ObjectNode f = M.createObjectNode();
        f.put("v", 1).put("t", "auth_ok").put("from", "server");
        ObjectNode body = f.putObject("body");
        body.put("user_id", account);
        body.put("last_seq", 0);
        // 全量登录设备(client + agent,含离线),供「登录设备列表」展示、区分是哪台。
        ArrayNode darr = body.putArray("devices");
        for (var d : devices) {
            ObjectNode o = darr.addObject();
            o.put("id", String.valueOf(d.get("id")));
            o.put("name", String.valueOf(d.get("name")));
            o.put("role", String.valueOf(d.get("role")));
            o.put("online", Boolean.TRUE.equals(d.get("online")));
        }
        ArrayNode arr = body.putArray("agents");
        // 软暂停:被暂停的电脑通常仍在线(保持连接)。在线列表里直接标 suspended,
        // 避免与下面的「离线暂停」列表重复(否则同一台电脑出现两条)。
        java.util.Set<String> onlineIds = new java.util.HashSet<>();
        for (Connection a : agents) {
            onlineIds.add(a.deviceId);
            ObjectNode o = arr.addObject();
            o.put("id", a.deviceId);
            o.put("name", a.deviceName);
            o.put("online", true);
            o.put("suspended", suspendedAgents.containsKey(a.deviceId));
        }
        suspendedAgents.forEach((id, name) -> {
            if (onlineIds.contains(id)) return;   // 已在在线列表里标过暂停
            ObjectNode o = arr.addObject();
            o.put("id", id);
            o.put("name", name);
            o.put("online", false);
            o.put("suspended", true);
        });
        return f.toString();
    }

    /** PROTOCOL §8.2 —— Agent 上线 / 下线广播给 Client（附带展示名,只增字段）。 */
    static String presence(String agentId, String name, boolean online) {
        return presence(agentId, name, online, false);
    }

    /** 同上,附带「是否被手机暂停」。软暂停下电脑可 online=true 且 paused=true。 */
    static String presence(String agentId, String name, boolean online, boolean paused) {
        ObjectNode f = M.createObjectNode();
        f.put("v", 1).put("t", "presence").put("from", "server");
        ObjectNode body = f.putObject("body");
        body.put("agent_id", agentId);
        body.put("name", name);
        body.put("online", online);
        body.put("paused", paused);
        return f.toString();
    }

    /** 服务器 → Agent 的软暂停控制:op=pause 暂停推送/忽略输入(不断开),op=resume 恢复。 */
    static String agentCtl(String op) {
        ObjectNode f = M.createObjectNode();
        f.put("v", 1).put("t", "ctl").put("from", "server");
        f.putObject("body").put("op", op);
        return f.toString();
    }

    /** 手机(Client）上线 → 通知同账号的 Agent,促其把当前所有任务全量重推,补齐快照缺漏。 */
    static String clientPresence(boolean online) {
        ObjectNode f = M.createObjectNode();
        f.put("v", 1).put("t", "presence").put("from", "server");
        ObjectNode body = f.putObject("body");
        body.put("role", "client");
        body.put("online", online);
        return f.toString();
    }

    /** Agent 断开时服务器代发的设备级 reset:手机据此清掉该电脑的会话。 */
    static String agentReset(String agentId) {
        ObjectNode f = M.createObjectNode();
        f.put("v", 1).put("t", "patch").put("id", "reset").put("from", "server");
        ObjectNode body = f.putObject("body");
        body.put("op", "reset");
        body.put("agent", agentId);
        return f.toString();
    }

    /** 上行确认:stage=server(已到服务器)。delivered 级由 Agent 发出、服务器透传。 */
    static String ack(String ackId, String stage) {
        ObjectNode f = M.createObjectNode();
        f.put("v", 1).put("t", "ack").put("from", "server");
        ObjectNode body = f.putObject("body");
        body.put("ack_id", ackId);
        body.put("stage", stage);
        return f.toString();
    }

    /** PROTOCOL §8.3 —— 心跳回应，回显 id / ts。 */
    static String pong(String id, long ts) {
        ObjectNode f = M.createObjectNode();
        f.put("v", 1).put("t", "pong");
        if (id != null) f.put("id", id);
        f.put("ts", ts);
        return f.toString();
    }

    /** PROTOCOL §8.5 —— 错误通知。 */
    static String error(String code, String message, boolean fatal) {
        ObjectNode f = M.createObjectNode();
        f.put("v", 1).put("t", "error").put("from", "server");
        ObjectNode body = f.putObject("body");
        body.put("code", code);
        body.put("message", message);
        body.put("fatal", fatal);
        return f.toString();
    }
}
