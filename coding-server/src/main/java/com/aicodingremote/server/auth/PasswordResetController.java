package com.aicodingremote.server.auth;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.mail.SimpleMailMessage;
import org.springframework.mail.javamail.JavaMailSender;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.security.SecureRandom;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

/**
 * 忘记密码:验证码发到账号绑定的邮箱(账号本身就是邮箱),验码后重设密码。
 *
 *  POST /api/auth/forgot  {account}                  → 生成验证码、发邮件(无论账号是否存在都回 200,防探测)
 *  POST /api/auth/reset   {account, code, password}  → 验码 + 改密
 *
 * 验证码:6 位、10 分钟有效、最多验 5 次,内存存储(重启即失效,够用)。
 * 发邮件用 JavaMailSender;未配置 SMTP(spring.mail.host 为空)时 forgot 返回 503。
 */
@RestController
@RequestMapping("/api/auth")
public class PasswordResetController {

    private static final Logger log = LoggerFactory.getLogger(PasswordResetController.class);
    private static final long TTL_MS = 10 * 60 * 1000;   // 验证码 10 分钟有效
    private static final int MAX_VERIFY = 5;             // 最多验 5 次,防爆破
    private static final long RESEND_GAP_MS = 60 * 1000; // 同一账号 60s 内不重复发

    public record ForgotReq(String account) {}
    public record ResetReq(String account, String code, String password) {}

    private static final class Entry {
        final String code;
        final long expireAt;
        int tries;
        long sentAt;
        Entry(String code, long expireAt, long sentAt) {
            this.code = code; this.expireAt = expireAt; this.sentAt = sentAt;
        }
    }

    private final Map<String, Entry> codes = new ConcurrentHashMap<>();
    private final SecureRandom rnd = new SecureRandom();

    private final UserStore store;
    private final ObjectProvider<JavaMailSender> mailProvider;
    @Value("${spring.mail.username:}")
    private String mailFrom;

    public PasswordResetController(UserStore store, ObjectProvider<JavaMailSender> mailProvider) {
        this.store = store;
        this.mailProvider = mailProvider;
    }

    /** 请求验证码:发到账号(邮箱)。账号不存在也回 200(不泄露账号是否注册)。 */
    @PostMapping("/forgot")
    public ResponseEntity<Map<String, String>> forgot(@RequestBody ForgotReq req) {
        String account = norm(req.account());
        if (account.isEmpty() || !account.contains("@")) {
            return ResponseEntity.badRequest().body(Map.of("error", "请输入有效邮箱"));
        }
        JavaMailSender mail = mailProvider.getIfAvailable();
        if (mail == null) {
            log.warn("forgot 被调用但未配置 SMTP(spring.mail.host 为空)");
            return ResponseEntity.status(HttpStatus.SERVICE_UNAVAILABLE)
                    .body(Map.of("error", "服务器未配置邮件发送"));
        }
        // 账号不存在:静默返回成功(防探测),但不发信
        if (!store.exists(account)) {
            log.info("forgot: 账号不存在,静默忽略 {}", account);
            return ResponseEntity.ok(Map.of("message", "若该邮箱已注册,验证码已发送"));
        }
        // 限频:60s 内不重复发
        Entry old = codes.get(account);
        long now = System.currentTimeMillis();
        if (old != null && now - old.sentAt < RESEND_GAP_MS) {
            return ResponseEntity.status(HttpStatus.TOO_MANY_REQUESTS)
                    .body(Map.of("error", "验证码已发送,请稍后再试"));
        }
        String code = String.format("%06d", rnd.nextInt(1_000_000));
        codes.put(account, new Entry(code, now + TTL_MS, now));
        try {
            SimpleMailMessage msg = new SimpleMailMessage();
            if (mailFrom != null && !mailFrom.isBlank()) msg.setFrom(mailFrom);
            msg.setTo(account);
            msg.setSubject("AI Coding Remote 密码重置验证码");
            msg.setText("你正在重置 AI Coding Remote 的登录密码。\n\n"
                    + "验证码:" + code + "\n\n"
                    + "10 分钟内有效。若非本人操作,请忽略此邮件。");
            mail.send(msg);
            log.info("forgot: 验证码已发往 {}", account);
        } catch (Exception e) {
            codes.remove(account);
            log.warn("forgot: 发送失败 {} - {}", account, e.toString());
            return ResponseEntity.status(HttpStatus.BAD_GATEWAY)
                    .body(Map.of("error", "邮件发送失败,请稍后重试"));
        }
        return ResponseEntity.ok(Map.of("message", "验证码已发送"));
    }

    /** 用验证码重设密码。 */
    @PostMapping("/reset")
    public ResponseEntity<Map<String, String>> reset(@RequestBody ResetReq req) {
        String account = norm(req.account());
        String code = req.code() == null ? "" : req.code().trim();
        String password = req.password() == null ? "" : req.password();
        if (password.length() < 4) {
            return ResponseEntity.badRequest().body(Map.of("error", "密码至少 4 位"));
        }
        Entry e = codes.get(account);
        long now = System.currentTimeMillis();
        if (e == null || now > e.expireAt) {
            codes.remove(account);
            return ResponseEntity.status(HttpStatus.UNAUTHORIZED).body(Map.of("error", "验证码已过期,请重新获取"));
        }
        if (e.tries >= MAX_VERIFY) {
            codes.remove(account);
            return ResponseEntity.status(HttpStatus.TOO_MANY_REQUESTS).body(Map.of("error", "尝试次数过多,请重新获取验证码"));
        }
        e.tries++;
        if (!e.code.equals(code)) {
            return ResponseEntity.status(HttpStatus.UNAUTHORIZED).body(Map.of("error", "验证码错误"));
        }
        store.setPassword(account, password);
        codes.remove(account);
        log.info("reset: 密码已重置 {}", account);
        return ResponseEntity.ok(Map.of("account", account, "message", "密码已重置,请用新密码登录"));
    }

    private static String norm(String s) {
        return s == null ? "" : s.trim().toLowerCase();
    }
}
