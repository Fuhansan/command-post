package com.aicodingremote.server.auth;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;

/**
 * 忘记密码:验证码发到账号绑定邮箱(账号本身就是邮箱),验码后重设密码。
 *   POST /api/auth/forgot {account}                  → 发验证码(账号不存在也回 200,防探测)
 *   POST /api/auth/reset  {account, code, password}  → 验码 + 改密
 * 验证码逻辑见 {@link VerificationService}。
 */
@RestController
@RequestMapping("/api/auth")
public class PasswordResetController {

    private static final Logger log = LoggerFactory.getLogger(PasswordResetController.class);

    public record ForgotReq(String account) {}
    public record ResetReq(String account, String code, String password) {}

    private final UserStore store;
    private final VerificationService codes;

    public PasswordResetController(UserStore store, VerificationService codes) {
        this.store = store;
        this.codes = codes;
    }

    @PostMapping("/forgot")
    public ResponseEntity<Map<String, String>> forgot(@RequestBody ForgotReq req) {
        String account = norm(req.account());
        if (account.isEmpty() || !account.contains("@")) {
            return ResponseEntity.badRequest().body(Map.of("error", "请输入有效邮箱"));
        }
        if (!codes.isMailReady()) {
            return ResponseEntity.status(HttpStatus.SERVICE_UNAVAILABLE).body(Map.of("error", "服务器未配置邮件发送"));
        }
        // 账号不存在:静默返回成功(防探测),不发信
        if (!store.exists(account)) {
            log.info("forgot: 账号不存在,静默忽略 {}", account);
            return ResponseEntity.ok(Map.of("message", "若该邮箱已注册,验证码已发送"));
        }
        return switch (codes.send(account, "重置密码")) {
            case SENT          -> ResponseEntity.ok(Map.of("message", "验证码已发送"));
            case RATE_LIMITED  -> ResponseEntity.status(HttpStatus.TOO_MANY_REQUESTS).body(Map.of("error", "验证码已发送,请稍后再试"));
            case NO_MAIL       -> ResponseEntity.status(HttpStatus.SERVICE_UNAVAILABLE).body(Map.of("error", "服务器未配置邮件发送"));
            case SEND_FAILED   -> ResponseEntity.status(HttpStatus.BAD_GATEWAY).body(Map.of("error", "邮件发送失败,请稍后重试"));
        };
    }

    @PostMapping("/reset")
    public ResponseEntity<Map<String, String>> reset(@RequestBody ResetReq req) {
        String account = norm(req.account());
        String password = req.password() == null ? "" : req.password();
        if (password.length() < 4) {
            return ResponseEntity.badRequest().body(Map.of("error", "密码至少 4 位"));
        }
        return switch (codes.check(account, req.code())) {
            case OK -> {
                store.setPassword(account, password);
                log.info("reset: 密码已重置 {}", account);
                yield ResponseEntity.ok(Map.of("account", account, "message", "密码已重置,请用新密码登录"));
            }
            case WRONG     -> ResponseEntity.status(HttpStatus.UNAUTHORIZED).body(Map.of("error", "验证码错误"));
            case TOO_MANY  -> ResponseEntity.status(HttpStatus.TOO_MANY_REQUESTS).body(Map.of("error", "尝试次数过多,请重新获取验证码"));
            default        -> ResponseEntity.status(HttpStatus.UNAUTHORIZED).body(Map.of("error", "验证码已过期,请重新获取"));
        };
    }

    private static String norm(String s) {
        return s == null ? "" : s.trim().toLowerCase();
    }
}
