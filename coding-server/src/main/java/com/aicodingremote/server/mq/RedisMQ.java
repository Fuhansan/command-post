package com.aicodingremote.server.mq;

import org.springframework.data.redis.connection.stream.*;
import org.springframework.data.redis.core.RedisCallback;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.stereotype.Service;

import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.*;

/**
 * 设备间消息队列(Redis Stream + 消费组)。取代旧的实时 WS 直推:
 * 发送方入队、接收方消费 + ack;接收设备离线时消息留在 Stream 里,重连后补齐 —— 不丢。
 *
 * <p>每账号两条方向流:
 * <ul>
 *   <li>{@code mq:{account}:to_agent} —— 手机→电脑 的指令(action/input/ctl)</li>
 *   <li>{@code mq:{account}:to_client} —— 电脑→手机 的 UI(ui/patch/ack/presence)</li>
 * </ul>
 * 消费侧按角色用消费组({@code g_agent}/{@code g_client}),每台设备是组里一个具名 consumer;
 * 每次 poll 先重投本 consumer 的 pending(上次没 ack 的),没有再阻塞读新消息 → at-least-once。
 */
@Service
public class RedisMQ {

    public record Msg(String id, String data) {}

    private static final String FIELD = "d";
    private static final long MAX_LEN = 3000;   // 每条流保留上限,防无限增长

    private final StringRedisTemplate redis;

    public RedisMQ(StringRedisTemplate redis) {
        this.redis = redis;
    }

    private String streamKey(String account, String dir) {
        return "mq:" + account + ":" + dir;
    }

    /** 发布一帧。fromRole=agent → 写 to_client;fromRole=client → 写 to_agent。返回流内 id。 */
    public String publish(String account, String fromRole, String frame) {
        String dir = "agent".equals(fromRole) ? "to_client" : "to_agent";
        String key = streamKey(account, dir);
        RecordId id = redis.opsForStream().add(
                StreamRecords.newRecord().in(key).ofMap(Map.of(FIELD, frame)));
        try { redis.opsForStream().trim(key, MAX_LEN, true); } catch (Exception ignored) {}
        return id != null ? id.getValue() : null;
    }

    /**
     * 消费。role=agent 读 to_agent,role=client 读 to_client。
     * 先重投本 consumer 的 pending(未 ack),没有再阻塞 blockMs 读新消息。
     */
    /** 每台设备一个独立消费组(dev:{设备id}),互不影响 —— 同一条流广播给同账号所有同向设备,
     *  各自记自己的消费位点;某设备离线时位点不前进,重连后从位点续读 = 补齐离线积压。 */
    private String groupOf(String consumer) {
        return "dev:" + (consumer == null || consumer.isEmpty() ? "c1" : consumer);
    }

    public List<Msg> poll(String account, String role, String consumer, long blockMs) {
        String dir = "agent".equals(role) ? "to_agent" : "to_client";
        String key = streamKey(account, dir);
        String group = groupOf(consumer);
        ensureGroup(key, group);
        Consumer c = Consumer.from(group, consumer == null || consumer.isEmpty() ? "c1" : consumer);

        // 1) pending:本 consumer 上次取过但没 ack 的,重新发(从 0 读 = 该 consumer 的待确认列表)
        List<Msg> pending = read(c, key, ReadOffset.from("0"), 200, 0);
        if (!pending.isEmpty()) return pending;

        // 2) 没有 pending → 阻塞读「未投递过」的新消息
        return read(c, key, ReadOffset.lastConsumed(), 200, blockMs);
    }

    /** 确认收妥:从该 consumer 的 pending 列表移除。 */
    public void ack(String account, String role, String consumer, List<String> ids) {
        if (ids == null || ids.isEmpty()) return;
        String dir = "agent".equals(role) ? "to_agent" : "to_client";
        String key = streamKey(account, dir);
        String group = groupOf(consumer);
        RecordId[] rids = ids.stream().map(RecordId::of).toArray(RecordId[]::new);
        try { redis.opsForStream().acknowledge(key, group, rids); } catch (Exception ignored) {}
    }

    private List<Msg> read(Consumer c, String key, ReadOffset offset, int count, long blockMs) {
        try {
            StreamReadOptions opt = StreamReadOptions.empty().count(count);
            if (blockMs > 0) opt = opt.block(Duration.ofMillis(blockMs));
            List<MapRecord<String, Object, Object>> recs =
                    redis.opsForStream().read(c, opt, StreamOffset.create(key, offset));
            if (recs == null || recs.isEmpty()) return List.of();
            List<Msg> out = new ArrayList<>(recs.size());
            for (MapRecord<String, Object, Object> r : recs) {
                Object v = r.getValue().get(FIELD);
                if (v != null) out.add(new Msg(r.getId().getValue(), v.toString()));
            }
            return out;
        } catch (Exception e) {
            return List.of();
        }
    }

    /** 懒建消费组,从「当前最新」起读(ReadOffset.latest = "$"):新组只收建组之后的消息,
     *  避免设备首次连接时把流里的历史指令全量重放(重复执行)。建组后离线积压靠位点续读补齐。 */
    private void ensureGroup(String key, String group) {
        // 用 MKSTREAM 建组:流不存在也顺手建空流,保证组从此刻起捕获所有后续消息
        // (Spring 的 createGroup 不带 MKSTREAM,流不存在会抛 + 漏掉建组前后那条)。
        try {
            redis.execute((RedisCallback<Object>) conn -> {
                try {
                    conn.streamCommands().xGroupCreate(
                            key.getBytes(StandardCharsets.UTF_8), group, ReadOffset.latest(), true);
                } catch (Exception ignored) {
                    // BUSYGROUP:组已存在 —— 正常
                }
                return null;
            });
        } catch (Exception ignored) {
        }
    }
}
