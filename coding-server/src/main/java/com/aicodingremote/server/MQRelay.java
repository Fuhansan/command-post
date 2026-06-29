package com.aicodingremote.server;

import com.aicodingremote.server.mq.RedisMQ;
import io.netty.handler.codec.http.websocketx.TextWebSocketFrame;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * 把 Redis MQ 接进 WS 这条线(取代 Hub 对「手机→电脑」指令的实时直推):
 * 手机指令(action/input)先入队(to_agent),再投递给同账号在线电脑;
 * 电脑离线 → 留在队列,电脑(重)连上线 → 补齐离线期间积压 —— 指令不丢。
 *
 * <p>投递放到单独守护线程,Redis 阻塞调用不卡 Netty 事件循环。「电脑→手机」的 UI 帧
 * 仍走原来的实时转发 + 快照(快照本就能让晚连的手机补全状态),这次不动。
 */
@Component
public class MQRelay {

    private static final Logger log = LoggerFactory.getLogger(MQRelay.class);

    private final RedisMQ mq;
    private final Hub hub;
    private final ExecutorService exec = Executors.newSingleThreadExecutor(r -> {
        Thread t = new Thread(r, "mq-deliver");
        t.setDaemon(true);
        return t;
    });

    public MQRelay(RedisMQ mq, Hub hub) {
        this.mq = mq;
        this.hub = hub;
    }

    /** 手机指令 → 入队 + 触发投递给同账号在线电脑。 */
    public void clientToAgent(String account, String frame) {
        mq.publish(account, "client", frame);
        deliverToAgents(account);
    }

    /** 某台电脑(重)连上线 → 把它离线期间积压的指令补齐(消费组按设备记位点,续读即可)。 */
    public void onAgentOnline(String account) {
        deliverToAgents(account);
    }

    private void deliverToAgents(String account) {
        exec.submit(() -> {
            try {
                for (Connection a : hub.agentsOf(account)) drainAgent(account, a);
            } catch (Exception e) {
                log.warn("mq 投递失败 account={}: {}", account, e.toString());
            }
        });
    }

    private void drainAgent(String account, Connection a) {
        for (int batch = 0; batch < 50; batch++) {   // 一次最多 50 批,防极端积压占死线程
            if (!a.channel.isActive()) return;
            List<RedisMQ.Msg> msgs = mq.poll(account, "agent", a.deviceId, 0);   // 非阻塞
            if (msgs.isEmpty()) return;
            List<String> ids = new ArrayList<>(msgs.size());
            for (RedisMQ.Msg m : msgs) {
                if (!a.channel.isActive()) break;
                a.channel.writeAndFlush(new TextWebSocketFrame(m.data()));
                ids.add(m.id());
            }
            // 写出 WS 即确认(TCP 可靠);没投出去的不 ack,设备重连后重投。
            mq.ack(account, "agent", a.deviceId, ids);
        }
    }
}
