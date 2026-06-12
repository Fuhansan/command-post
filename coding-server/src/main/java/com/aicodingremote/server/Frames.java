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

    /** PROTOCOL §8.1 —— 握手成功，回带账号下在线 Agent 列表。 */
    static String authOk(String account, Collection<Connection> agents) {
        ObjectNode f = M.createObjectNode();
        f.put("v", 1).put("t", "auth_ok").put("from", "server");
        ObjectNode body = f.putObject("body");
        body.put("user_id", account);
        body.put("last_seq", 0);
        ArrayNode arr = body.putArray("agents");
        for (Connection a : agents) {
            ObjectNode o = arr.addObject();
            o.put("id", a.deviceId);
            o.put("name", a.deviceName);
            o.put("online", true);
        }
        return f.toString();
    }

    /** PROTOCOL §8.2 —— Agent 上线 / 下线广播给 Client（附带展示名,只增字段）。 */
    static String presence(String agentId, String name, boolean online) {
        ObjectNode f = M.createObjectNode();
        f.put("v", 1).put("t", "presence").put("from", "server");
        ObjectNode body = f.putObject("body");
        body.put("agent_id", agentId);
        body.put("name", name);
        body.put("online", online);
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
