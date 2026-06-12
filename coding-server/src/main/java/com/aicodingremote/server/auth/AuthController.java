package com.aicodingremote.server.auth;

import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;

/**
 * 登录/注册 REST(8080)。成功后发 token,手机端 WS auth 时携带,
 * FrameHandler 据 token 解析真实账号(不再信任客户端自报的 account)。
 */
@RestController
@RequestMapping("/api/auth")
public class AuthController {

    public record Credentials(String account, String password) {}

    private final UserStore store;

    public AuthController(UserStore store) {
        this.store = store;
    }

    @PostMapping("/register")
    public ResponseEntity<Map<String, String>> register(@RequestBody Credentials c) {
        String account = norm(c.account());
        if (account.isEmpty() || c.password() == null || c.password().length() < 4) {
            return ResponseEntity.badRequest().body(Map.of("error", "账号或密码格式不对(密码至少 4 位)"));
        }
        if (!store.register(account, c.password())) {
            return ResponseEntity.status(HttpStatus.CONFLICT).body(Map.of("error", "账号已存在"));
        }
        return ResponseEntity.ok(Map.of("account", account, "token", store.issueToken(account)));
    }

    @PostMapping("/login")
    public ResponseEntity<Map<String, String>> login(@RequestBody Credentials c) {
        String account = norm(c.account());
        if (!store.verify(account, c.password() == null ? "" : c.password())) {
            return ResponseEntity.status(HttpStatus.UNAUTHORIZED).body(Map.of("error", "账号或密码错误"));
        }
        return ResponseEntity.ok(Map.of("account", account, "token", store.issueToken(account)));
    }

    private static String norm(String s) {
        return s == null ? "" : s.trim().toLowerCase();
    }
}
