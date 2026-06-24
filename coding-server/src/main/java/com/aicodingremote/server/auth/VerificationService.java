package com.aicodingremote.server.auth;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.mail.SimpleMailMessage;
import org.springframework.mail.javamail.JavaMailSender;
import org.springframework.stereotype.Service;

import java.security.SecureRandom;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

/**
 * 邮箱验证码:生成、发送、校验。注册和忘记密码共用。
 * 验证码 6 位 / 10 分钟有效 / 最多验 5 次 / 同邮箱 60s 限频,内存存储(重启失效)。
 * 发信用 JavaMailSender;未配置 SMTP(spring.mail.host 为空)时 isMailReady()=false。
 */
@Service
public class VerificationService {

    private static final Logger log = LoggerFactory.getLogger(VerificationService.class);
    private static final long TTL_MS = 10 * 60 * 1000;
    private static final int MAX_VERIFY = 5;
    private static final long RESEND_GAP_MS = 60 * 1000;

    public enum SendOutcome { SENT, NO_MAIL, RATE_LIMITED, SEND_FAILED }
    public enum CheckOutcome { OK, EXPIRED, WRONG, TOO_MANY, NONE }

    private static final class Entry {
        final String code; final long expireAt; int tries; final long sentAt;
        Entry(String code, long expireAt, long sentAt) {
            this.code = code; this.expireAt = expireAt; this.sentAt = sentAt;
        }
    }

    private final Map<String, Entry> codes = new ConcurrentHashMap<>();
    private final SecureRandom rnd = new SecureRandom();

    private final ObjectProvider<JavaMailSender> mailProvider;
    @Value("${spring.mail.username:}")
    private String mailFrom;

    public VerificationService(ObjectProvider<JavaMailSender> mailProvider) {
        this.mailProvider = mailProvider;
    }

    public boolean isMailReady() {
        return mailProvider.getIfAvailable() != null;
    }

    /** 生成验证码并发到 email。purpose 用于邮件文案(如「注册」「重置密码」)。 */
    public SendOutcome send(String email, String purpose) {
        JavaMailSender mail = mailProvider.getIfAvailable();
        if (mail == null) return SendOutcome.NO_MAIL;

        long now = System.currentTimeMillis();
        Entry old = codes.get(email);
        if (old != null && now - old.sentAt < RESEND_GAP_MS) return SendOutcome.RATE_LIMITED;

        String code = String.format("%06d", rnd.nextInt(1_000_000));
        codes.put(email, new Entry(code, now + TTL_MS, now));

        // 开发模式:SMTP username 未配置时不真发邮件,直接把验证码打到日志(本地联调用)。
        // 部署时在外置 application.properties 填上 spring.mail.username/password 即恢复发邮件。
        if (mailFrom == null || mailFrom.isBlank()) {
            log.warn("=========================================================");
            log.warn("[DEV] 验证码 {} -> {} ({})  [SMTP 未配置,不发邮件]", code, email, purpose);
            log.warn("=========================================================");
            return SendOutcome.SENT;
        }

        try {
            SimpleMailMessage msg = new SimpleMailMessage();
            if (mailFrom != null && !mailFrom.isBlank()) msg.setFrom(mailFrom);
            msg.setTo(email);
            msg.setSubject("AI Coding Remote " + purpose + "验证码");
            msg.setText("你正在进行 AI Coding Remote 的「" + purpose + "」操作。\n\n"
                    + "验证码:" + code + "\n\n"
                    + "10 分钟内有效。若非本人操作,请忽略此邮件。");
            mail.send(msg);
            log.info("验证码已发往 {} ({})", email, purpose);
            return SendOutcome.SENT;
        } catch (Exception e) {
            codes.remove(email);
            log.warn("验证码发送失败 {} - {}", email, e.toString());
            return SendOutcome.SEND_FAILED;
        }
    }

    /** 校验验证码。OK 时消费掉该码。 */
    public CheckOutcome check(String email, String code) {
        Entry e = codes.get(email);
        long now = System.currentTimeMillis();
        if (e == null) return CheckOutcome.NONE;
        if (now > e.expireAt) { codes.remove(email); return CheckOutcome.EXPIRED; }
        if (e.tries >= MAX_VERIFY) { codes.remove(email); return CheckOutcome.TOO_MANY; }
        e.tries++;
        if (!e.code.equals(code == null ? "" : code.trim())) return CheckOutcome.WRONG;
        codes.remove(email);   // 一次性
        return CheckOutcome.OK;
    }
}
