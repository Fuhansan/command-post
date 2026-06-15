package com.aicodingremote.server.auth;

import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.security.SecureRandom;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

/**
 * 桌面 Agent 配对(手机授权电脑,类微信桌面端):
 *   1. Agent  POST /start          → 得到 6 位配对码(10 分钟有效)
 *   2. 手机   POST /claim          → 用自己的登录 token 认领该码(绑定到账号)
 *   3. Agent  GET  /poll?code=     → 轮询;认领后签发 Agent 自己的 token
 * Agent 此后用该 token 走 WS 鉴权,与手机同账号配对。
 */
@RestController
@RequestMapping("/api/pair")
public class PairController {

    private static final Logger log = LoggerFactory.getLogger(PairController.class);
    private static final long TTL_MS = 10 * 60 * 1000;

    private static final class Pending {
        final long expiresAt = System.currentTimeMillis() + TTL_MS;
        volatile String account;   // null = 未认领
    }

    private final Map<String, Pending> codes = new ConcurrentHashMap<>();
    private final SecureRandom random = new SecureRandom();
    private final UserStore store;

    public PairController(UserStore store) {
        this.store = store;
    }

    @PostMapping("/start")
    public Map<String, String> start() {
        sweep();
        String code;
        do {
            code = String.format("%06d", random.nextInt(1_000_000));
        } while (codes.putIfAbsent(code, new Pending()) != null);
        log.info("pair start: code={}", code);
        return Map.of("code", code);
    }

    public record Claim(String code, String token) {}

    @PostMapping("/claim")
    public ResponseEntity<Map<String, String>> claim(@RequestBody Claim c) {
        sweep();
        String account = store.accountOf(c.token());
        if (account == null) {
            return ResponseEntity.status(HttpStatus.UNAUTHORIZED).body(Map.of("error", "请先在手机上登录"));
        }
        Pending p = c.code() == null ? null : codes.get(c.code().trim());
        if (p == null) {
            return ResponseEntity.status(HttpStatus.NOT_FOUND).body(Map.of("error", "配对码不存在或已过期"));
        }
        p.account = account;
        log.info("pair claim: code={} account={}", c.code(), account);
        return ResponseEntity.ok(Map.of("account", account));
    }

    @GetMapping("/poll")
    public ResponseEntity<Map<String, String>> poll(@RequestParam String code) {
        Pending p = codes.get(code);
        if (p == null || System.currentTimeMillis() > p.expiresAt) {
            codes.remove(code);
            return ResponseEntity.status(HttpStatus.NOT_FOUND).body(Map.of("error", "expired"));
        }
        if (p.account == null) {
            return ResponseEntity.ok(Map.of("status", "pending"));
        }
        codes.remove(code);
        String token = store.issueToken(p.account);
        log.info("pair done: account={}", p.account);
        return ResponseEntity.ok(Map.of("status", "ok", "account", p.account, "token", token));
    }

    private void sweep() {
        long now = System.currentTimeMillis();
        codes.entrySet().removeIf(e -> now > e.getValue().expiresAt);
    }
}
