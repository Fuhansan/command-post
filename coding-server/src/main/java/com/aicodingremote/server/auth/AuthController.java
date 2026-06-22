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
    public record AccountReq(String account) {}
    public record CodeLoginReq(String account, String code) {}

    private final UserStore store;
    private final VerificationService codes;

    public AuthController(UserStore store, VerificationService codes) {
        this.store = store;
        this.codes = codes;
    }

    /** 查邮箱是否已注册、是否设了密码 —— 统一登录入口据此分流(注册 / 密码登录 / 验证码登录)。 */
    @PostMapping("/check")
    public ResponseEntity<Map<String, Object>> check(@RequestBody AccountReq req) {
        String account = norm(req.account());
        if (account.isEmpty() || !account.contains("@")) {
            return ResponseEntity.badRequest().body(Map.of("error", "请输入有效邮箱"));
        }
        boolean exists = store.exists(account);
        return ResponseEntity.ok(Map.of(
                "exists", exists,
                "hasPassword", exists && store.hasPassword(account)));
    }

    /** 验证码登录 - 发码(账号须已存在)。 */
    @PostMapping("/login/code")
    public ResponseEntity<Map<String, String>> loginCode(@RequestBody AccountReq req) {
        String account = norm(req.account());
        if (!codes.isMailReady()) {
            return ResponseEntity.status(HttpStatus.SERVICE_UNAVAILABLE).body(Map.of("error", "服务器未配置邮件发送"));
        }
        if (!store.exists(account)) {
            return ResponseEntity.status(HttpStatus.NOT_FOUND).body(Map.of("error", "该邮箱未注册"));
        }
        return switch (codes.send(account, "登录")) {
            case SENT          -> ResponseEntity.ok(Map.of("message", "验证码已发送"));
            case RATE_LIMITED  -> ResponseEntity.status(HttpStatus.TOO_MANY_REQUESTS).body(Map.of("error", "验证码已发送,请稍后再试"));
            case NO_MAIL       -> ResponseEntity.status(HttpStatus.SERVICE_UNAVAILABLE).body(Map.of("error", "服务器未配置邮件发送"));
            case SEND_FAILED   -> ResponseEntity.status(HttpStatus.BAD_GATEWAY).body(Map.of("error", "邮件发送失败,请稍后重试"));
        };
    }

    /** 验证码登录 - 验码并签发令牌。 */
    @PostMapping("/login/verify")
    public ResponseEntity<Map<String, String>> loginVerify(@RequestBody CodeLoginReq req) {
        String account = norm(req.account());
        if (!store.exists(account)) {
            return ResponseEntity.status(HttpStatus.NOT_FOUND).body(Map.of("error", "该邮箱未注册"));
        }
        return switch (codes.check(account, req.code())) {
            case OK -> ResponseEntity.ok(Map.of("account", account, "token", store.issueToken(account)));
            case WRONG    -> ResponseEntity.status(HttpStatus.UNAUTHORIZED).body(Map.of("error", "验证码错误"));
            case TOO_MANY -> ResponseEntity.status(HttpStatus.TOO_MANY_REQUESTS).body(Map.of("error", "尝试次数过多,请重新获取验证码"));
            default       -> ResponseEntity.status(HttpStatus.UNAUTHORIZED).body(Map.of("error", "验证码已过期,请重新获取"));
        };
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
