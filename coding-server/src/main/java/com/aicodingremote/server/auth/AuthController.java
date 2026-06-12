package com.aicodingremote.server.auth;

import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;

/**
 * 邮箱密码登录 + 设置密码 REST(8080)。
 * 账号只能经 Google 验证邮箱后创建(见 GoogleAuthController),无自由注册;
 * 首次 Google 登录后设密码,之后即可邮箱密码登录(国内无需再用 Google)。
 */
@RestController
@RequestMapping("/api/auth")
public class AuthController {

    public record Credentials(String account, String password) {}
    public record SetPassword(String token, String password) {}

    private final UserStore store;

    public AuthController(UserStore store) {
        this.store = store;
    }

    @PostMapping("/login")
    public ResponseEntity<Map<String, String>> login(@RequestBody Credentials c) {
        String account = norm(c.account());
        if (!store.verify(account, c.password() == null ? "" : c.password())) {
            // 账号存在但只走过 Google(还没设密码)时,给出更明确的提示
            if (store.exists(account) && !store.hasPassword(account)) {
                return ResponseEntity.status(HttpStatus.UNAUTHORIZED)
                        .body(Map.of("error", "该账号尚未设置密码,请先用 Google 登录并设置密码"));
            }
            return ResponseEntity.status(HttpStatus.UNAUTHORIZED).body(Map.of("error", "账号或密码错误"));
        }
        return ResponseEntity.ok(Map.of("account", account, "token", store.issueToken(account)));
    }

    /** 设置密码:用 Google 登录拿到的 token 鉴权,给当前账号设密码。 */
    @PostMapping("/set-password")
    public ResponseEntity<Map<String, String>> setPassword(@RequestBody SetPassword b) {
        String account = store.accountOf(b.token());
        if (account == null) {
            return ResponseEntity.status(HttpStatus.UNAUTHORIZED).body(Map.of("error", "请先用 Google 登录"));
        }
        if (b.password() == null || b.password().length() < 4) {
            return ResponseEntity.badRequest().body(Map.of("error", "密码至少 4 位"));
        }
        store.setPassword(account, b.password());
        return ResponseEntity.ok(Map.of("account", account));
    }

    private static String norm(String s) {
        return s == null ? "" : s.trim().toLowerCase();
    }
}
