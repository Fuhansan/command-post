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
 * 邮箱验证码注册(替代 Google:国内 VPS 连不上 Google,没法用 Google 验证邮箱建号)。
 *   POST /api/auth/register/code {account}                 → 给该邮箱发注册验证码(已注册则报错)
 *   POST /api/auth/register      {account, code, password} → 验码 + 创建账号 + 返回 {account, token}
 * 验证码逻辑见 {@link VerificationService}。
 */
@RestController
@RequestMapping("/api/auth")
public class RegistrationController {

    private static final Logger log = LoggerFactory.getLogger(RegistrationController.class);

    public record CodeReq(String account) {}
    public record RegisterReq(String account, String code, String password) {}

    private final UserStore store;
    private final VerificationService codes;

    public RegistrationController(UserStore store, VerificationService codes) {
        this.store = store;
        this.codes = codes;
    }

    /** 请求注册验证码。 */
    @PostMapping("/register/code")
    public ResponseEntity<Map<String, String>> sendCode(@RequestBody CodeReq req) {
        String account = norm(req.account());
        if (account.isEmpty() || !account.contains("@")) {
            return ResponseEntity.badRequest().body(Map.of("error", "请输入有效邮箱"));
        }
        if (!codes.isMailReady()) {
            return ResponseEntity.status(HttpStatus.SERVICE_UNAVAILABLE).body(Map.of("error", "服务器未配置邮件发送"));
        }
        if (store.exists(account)) {
            return ResponseEntity.status(HttpStatus.CONFLICT).body(Map.of("error", "该邮箱已注册,请直接登录或用「忘记密码」"));
        }
        return switch (codes.send(account, "注册")) {
            case SENT          -> ResponseEntity.ok(Map.of("message", "验证码已发送"));
            case RATE_LIMITED  -> ResponseEntity.status(HttpStatus.TOO_MANY_REQUESTS).body(Map.of("error", "验证码已发送,请稍后再试"));
            case NO_MAIL       -> ResponseEntity.status(HttpStatus.SERVICE_UNAVAILABLE).body(Map.of("error", "服务器未配置邮件发送"));
            case SEND_FAILED   -> ResponseEntity.status(HttpStatus.BAD_GATEWAY).body(Map.of("error", "邮件发送失败,请稍后重试"));
        };
    }

    /** 验码并创建账号,直接返回登录令牌。 */
    @PostMapping("/register")
    public ResponseEntity<Map<String, String>> register(@RequestBody RegisterReq req) {
        String account = norm(req.account());
        String password = req.password() == null ? "" : req.password();
        if (password.length() < 4) {
            return ResponseEntity.badRequest().body(Map.of("error", "密码至少 4 位"));
        }
        if (store.exists(account)) {
            return ResponseEntity.status(HttpStatus.CONFLICT).body(Map.of("error", "该邮箱已注册"));
        }
        return switch (codes.check(account, req.code())) {
            case OK -> {
                store.createWithPassword(account, password, null);
                String token = store.issueClientToken(account);
                log.info("register: 新账号已创建 {}", account);
                yield ResponseEntity.ok(Map.of("account", account, "token", token));
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
