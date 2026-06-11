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

    /** 每账号、每**消息 id** 的最后一帧 ui 快照(LinkedHashMap 保留首次出现顺序,补发时按序还原对话)。 */
    private final Map<String, Map<String, String>> snapshots = new ConcurrentHashMap<>();

    private Account acc(String account) {
        return accounts.computeIfAbsent(account, k -> new Account());
    }

    private Map<String, String> snaps(String account) {
        return snapshots.computeIfAbsent(account, k -> Collections.synchronizedMap(new LinkedHashMap<>()));
    }

    /** Agent 推来一帧 ui 时,按消息 id 记下快照(同 id 后到的覆盖,位置不变)。 */
    public void snapshot(String account, String msgId, String frame) {
        snaps(account).put(msgId, frame);
    }

    /** 某账号当前所有消息的最后一帧,按首次出现顺序(补发用)。 */
    public List<String> snapshotsOf(String account) {
        Map<String, String> m = snapshots.get(account);
        if (m == null) return List.of();
        synchronized (m) { return new ArrayList<>(m.values()); }
    }

    /** 删除某条消息的快照。 */
    public void removeSnapshot(String account, String msgId) {
        Map<String, String> m = snapshots.get(account);
        if (m != null) m.remove(msgId);
    }

    /** 会话整体关闭时,删掉该会话所有消息快照(按 id 前缀)。 */
    public void removeSnapshotsWithPrefix(String account, String prefix) {
        Map<String, String> m = snapshots.get(account);
        if (m == null) return;
        synchronized (m) { m.keySet().removeIf(k -> k.startsWith(prefix)); }
    }

    /** 清空该账号全部快照(agent 进程重启 reset 时)。 */
    public void clearSnapshots(String account) {
        Map<String, String> m = snapshots.get(account);
        if (m != null) m.clear();
    }

    public void register(Connection c) {
        Account a = acc(c.account);
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
