package com.aicodingremote.server.mq;

import com.aicodingremote.server.auth.UserStore;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.util.List;
import java.util.Map;

/**
 * 设备间消息队列的 HTTP 端点(取代实时 WS)。三端都走 HTTP(8080):
 * 走 URLSession.direct/直连,能绕开系统代理(ClashX),不再被代理吃掉连接。
 *
 * <p>鉴权:每个请求带登录/配对签发的 token,服务端据此解析账号;角色(agent/client)
 * 由设备自报(同账号内部,信任)。
 */
@RestController
@RequestMapping("/api/mq")
@CrossOrigin
public class MQController {

    private final RedisMQ mq;
    private final UserStore users;

    public MQController(RedisMQ mq, UserStore users) {
        this.mq = mq;
        this.users = users;
    }

    private String accountOf(String token) {
        return users.accountOf(token);
    }

    /** 发布一帧。body: {token, from:"agent"|"client", frame:"<json>"}。 */
    @PostMapping("/publish")
    public ResponseEntity<?> publish(@RequestBody PublishReq req) {
        String account = accountOf(req.token());
        if (account == null) return ResponseEntity.status(HttpStatus.UNAUTHORIZED).body(Map.of("error", "未登录"));
        if (req.frame() == null || req.frame().isEmpty()) return ResponseEntity.badRequest().body(Map.of("error", "空帧"));
        String from = "agent".equals(req.from()) ? "agent" : "client";
        String id = mq.publish(account, from, req.frame());
        return ResponseEntity.ok(Map.of("id", id == null ? "" : id));
    }

    /**
     * 长轮询消费。params: token, role(agent/client), consumer(设备id), block(ms,默认 25000)。
     * 返回 {msgs:[{id,data}]};无新消息阻塞到超时返回空数组。
     */
    @GetMapping("/poll")
    public ResponseEntity<?> poll(@RequestParam String token,
                                  @RequestParam String role,
                                  @RequestParam(required = false, defaultValue = "") String consumer,
                                  @RequestParam(required = false, defaultValue = "25000") long block) {
        String account = accountOf(token);
        if (account == null) return ResponseEntity.status(HttpStatus.UNAUTHORIZED).body(Map.of("error", "未登录"));
        long blockMs = Math.max(0, Math.min(block, 55000));   // 上限 55s,低于常见网关 60s 超时
        List<RedisMQ.Msg> msgs = mq.poll(account, role, consumer, blockMs);
        return ResponseEntity.ok(Map.of("msgs", msgs));
    }

    /** 确认收妥。body: {token, role, ids:[...]}。 */
    @PostMapping("/ack")
    public ResponseEntity<?> ack(@RequestBody AckReq req) {
        String account = accountOf(req.token());
        if (account == null) return ResponseEntity.status(HttpStatus.UNAUTHORIZED).body(Map.of("error", "未登录"));
        mq.ack(account, req.role(), req.consumer(), req.ids());
        return ResponseEntity.ok(Map.of("ok", true));
    }

    public record PublishReq(String token, String from, String frame) {}
    public record AckReq(String token, String role, String consumer, List<String> ids) {}
}
