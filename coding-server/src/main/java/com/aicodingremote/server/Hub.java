package com.aicodingremote.server;

import io.netty.channel.ChannelId;
import org.springframework.stereotype.Component;

import java.util.ArrayList;
import java.util.Collection;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

/**
 * 中转核心：按 account 把 Client 与 Agent 配对，提供「该发给谁」的查询。
 * 纯内存、线程安全。是 Spring Bean —— 未来业务（鉴权、在线统计、推送）可直接注入它。
 *
 * <p>最小可跑通版本不做离线缓冲 / seq 回放（PROTOCOL §7、§8.4），只做实时双向投递。
 */
@Component
public class Hub {

    /** 一个账号下当前在线的两类连接。 */
    private static final class Account {
        final Map<ChannelId, Connection> clients = new ConcurrentHashMap<>();
        final Map<ChannelId, Connection> agents = new ConcurrentHashMap<>();
    }

    private final Map<String, Account> accounts = new ConcurrentHashMap<>();

    /** 手机挂起的电脑(account → deviceId → 设备名)。挂起期间该 Agent 的鉴权被拒。 */
    private final Map<String, Map<String, String>> suspended = new ConcurrentHashMap<>();

    /** 一条快照:来自哪台 Agent + 帧原文(reset 时按设备作用域清理,多电脑互不影响)。 */
    private record Snap(String agentId, String frame) {}

    /** 每账号、每**消息 id** 的最后一帧 ui 快照(LinkedHashMap 保留首次出现顺序,补发时按序还原对话)。 */
    private final Map<String, Map<String, Snap>> snapshots = new ConcurrentHashMap<>();

    private Account acc(String account) {
        return accounts.computeIfAbsent(account, k -> new Account());
    }

    /** 该账号当前**在线**的所有设备(client + agent)。「登录设备列表」只展示在线的,离线不留。 */
    public java.util.List<Connection> onlineDevices(String account) {
        Account a = accounts.get(account);
        if (a == null) return java.util.List.of();
        java.util.List<Connection> out = new java.util.ArrayList<>(a.clients.values());
        out.addAll(a.agents.values());
        return out;
    }

    private Map<String, Snap> snaps(String account) {
        return snapshots.computeIfAbsent(account, k -> Collections.synchronizedMap(new LinkedHashMap<>()));
    }

    /** Agent 推来一帧 ui 时,按消息 id 记下快照(同 id 后到的覆盖,位置不变)。 */
    public void snapshot(String account, String msgId, String frame, String agentId) {
        snaps(account).put(msgId, new Snap(agentId, frame));
    }

    /** 某账号当前所有消息的最后一帧,按首次出现顺序(补发用)。 */
    public List<String> snapshotsOf(String account) {
        Map<String, Snap> m = snapshots.get(account);
        if (m == null) return List.of();
        synchronized (m) { return m.values().stream().map(Snap::frame).toList(); }
    }

    /** 删除某条消息的快照。 */
    public void removeSnapshot(String account, String msgId) {
        Map<String, Snap> m = snapshots.get(account);
        if (m != null) m.remove(msgId);
    }

    /** 会话整体关闭时,删掉该会话所有消息快照(按 id 前缀)。 */
    public void removeSnapshotsWithPrefix(String account, String prefix) {
        Map<String, Snap> m = snapshots.get(account);
        if (m == null) return;
        synchronized (m) { m.keySet().removeIf(k -> k.startsWith(prefix)); }
    }

    /** 清掉该账号下**某台 Agent** 的全部快照(该机 reset/退出配对时;其他电脑的会话不受影响)。 */
    public void clearSnapshots(String account, String agentId) {
        Map<String, Snap> m = snapshots.get(account);
        if (m == null) return;
        synchronized (m) { m.values().removeIf(v -> agentId == null || agentId.equals(v.agentId())); }
    }

    public void suspendAgent(String account, String deviceId, String name) {
        suspended.computeIfAbsent(account, k -> new ConcurrentHashMap<>())
                 .put(deviceId, name == null ? deviceId : name);
    }

    public void resumeAgent(String account, String deviceId) {
        Map<String, String> m = suspended.get(account);
        if (m != null) m.remove(deviceId);
    }

    public boolean isSuspended(String account, String deviceId) {
        Map<String, String> m = suspended.get(account);
        return m != null && m.containsKey(deviceId);
    }

    /** 该账号被挂起的设备(deviceId → 名称),auth_ok 时带给手机展示。 */
    public Map<String, String> suspendedOf(String account) {
        return suspended.getOrDefault(account, Map.of());
    }

    public void register(Connection c) {
        Account a = acc(c.account);
        if (c.isAgent() && c.deviceId != null && !c.deviceId.isEmpty()) {
            // 同一台电脑(deviceId)只保留一条连接:踢掉同设备的旧连接(僵尸/重连残留),
            // 避免 authOk 把同一台 Mac 报成多个。
            a.agents.values().removeIf(old -> {
                if (c.deviceId.equals(old.deviceId) && old.channel != c.channel) {
                    if (old.channel.isActive()) old.channel.close();
                    return true;
                }
                return false;
            });
        }
        (c.isAgent() ? a.agents : a.clients).put(c.channel.id(), c);
    }

    public void unregister(Connection c) {
        Account a = accounts.get(c.account);
        if (a == null) return;
        (c.isAgent() ? a.agents : a.clients).remove(c.channel.id());
    }

    /** 下行：Agent 的 ui/patch 投给同账号所有 Client。 */
    public Collection<Connection> clientsOf(String account) {
        Account a = accounts.get(account);
        return a == null ? List.of() : a.clients.values();
    }

    /** 上行：Client 的 action/input 投给同账号所有 Agent。 */
    public Collection<Connection> agentsOf(String account) {
        Account a = accounts.get(account);
        return a == null ? List.of() : a.agents.values();
    }
}
