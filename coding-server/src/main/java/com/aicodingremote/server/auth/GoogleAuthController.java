package com.aicodingremote.server.auth;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.net.URI;
import java.net.URLEncoder;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.Map;

/**
 * Google 登录:手机端用 GoogleSignIn SDK 拿到 idToken 后送来这里。
 * 服务端经 Google tokeninfo 端点校验(签名/有效期由 Google 验),再核对
 * audience 是否为本应用的客户端 ID,通过后以 Google 邮箱为账号签发本系统 token。
 */
@RestController
@RequestMapping("/api/auth")
public class GoogleAuthController {

    private static final Logger log = LoggerFactory.getLogger(GoogleAuthController.class);
    private static final ObjectMapper M = new ObjectMapper();
    private final HttpClient http = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(8)).build();

    private final UserStore store;
    private final String clientId;

    public GoogleAuthController(UserStore store,
                                @Value("${auth.google.client-id:}") String clientId) {
        this.store = store;
        this.clientId = clientId;
    }

    public record GoogleLogin(String idToken) {}

    @PostMapping("/google")
    public ResponseEntity<Map<String, String>> google(@RequestBody GoogleLogin body) {
        if (body.idToken() == null || body.idToken().isEmpty()) {
            return ResponseEntity.badRequest().body(Map.of("error", "缺少 idToken"));
        }
        if (clientId.isEmpty()) {
            return ResponseEntity.status(HttpStatus.INTERNAL_SERVER_ERROR)
                    .body(Map.of("error", "服务端未配置 auth.google.client-id"));
        }
        try {
            String url = "https://oauth2.googleapis.com/tokeninfo?id_token="
                    + URLEncoder.encode(body.idToken(), StandardCharsets.UTF_8);
            HttpResponse<String> resp = http.send(
                    HttpRequest.newBuilder(URI.create(url)).timeout(Duration.ofSeconds(8)).GET().build(),
                    HttpResponse.BodyHandlers.ofString());
            if (resp.statusCode() != 200) {
                return ResponseEntity.status(HttpStatus.UNAUTHORIZED).body(Map.of("error", "Google 令牌无效"));
            }
            JsonNode info = M.readTree(resp.body());
            if (!clientId.equals(info.path("aud").asText(""))) {
                log.warn("google login: aud 不匹配 {}", info.path("aud").asText(""));
                return ResponseEntity.status(HttpStatus.UNAUTHORIZED).body(Map.of("error", "令牌不属于本应用"));
            }
            String email = info.path("email").asText("").toLowerCase();
            boolean verified = "true".equals(info.path("email_verified").asText(""));
            if (email.isEmpty() || !verified) {
                return ResponseEntity.status(HttpStatus.UNAUTHORIZED).body(Map.of("error", "Google 账号缺少已验证邮箱"));
            }
            store.ensureExternal(email, "google");
            String token = store.issueClientToken(email);
            boolean hasPassword = store.hasPassword(email);
            log.info("google login ok: {} (hasPassword={})", email, hasPassword);
            // hasPassword=false → 客户端引导设置密码(之后可邮箱密码登录,不再需要 Google)
            return ResponseEntity.ok(Map.of("account", email, "token", token,
                    "name", info.path("name").asText(""),
                    "hasPassword", String.valueOf(hasPassword)));
        } catch (Exception e) {
            log.warn("google login error", e);
            return ResponseEntity.status(HttpStatus.BAD_GATEWAY).body(Map.of("error", "校验 Google 令牌失败,请重试"));
        }
    }
}
