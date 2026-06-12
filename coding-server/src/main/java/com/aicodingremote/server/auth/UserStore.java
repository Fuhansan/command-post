package com.aicodingremote.server.auth;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import org.springframework.stereotype.Component;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.HexFormat;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

/**
 * 用户与会话令牌存储(最小版):内存 Map + JSON 文件持久化(重启不丢)。
 * 密码存「盐 + SHA-256(盐+密码)」,不存明文。后续换数据库时只动这一层。
 */
@Component
public class UserStore {

    private static final ObjectMapper M = new ObjectMapper();
    private final File dataDir = new File("data");
    private final File usersFile = new File(dataDir, "users.json");
    private final File tokensFile = new File(dataDir, "tokens.json");

    /** account → "salt:hash" */
    private final Map<String, String> users = new ConcurrentHashMap<>();
    /** token → account */
    private final Map<String, String> tokens = new ConcurrentHashMap<>();
    private final SecureRandom random = new SecureRandom();

    public UserStore() {
        load(usersFile, users);
        load(tokensFile, tokens);
    }

    /** 注册:账号已存在返回 false。 */
    public synchronized boolean register(String account, String password) {
        if (users.containsKey(account)) return false;
        byte[] salt = new byte[16];
        random.nextBytes(salt);
        String saltHex = HexFormat.of().formatHex(salt);
        users.put(account, saltHex + ":" + hash(saltHex, password));
        persist(usersFile, users);
        return true;
    }

    /** 校验账号密码。 */
    public boolean verify(String account, String password) {
        String stored = users.get(account);
        if (stored == null) return false;
        String[] parts = stored.split(":", 2);
        return parts.length == 2 && parts[1].equals(hash(parts[0], password));
    }

    /** 签发令牌(登录成功后调用)。 */
    public String issueToken(String account) {
        byte[] raw = new byte[24];
        random.nextBytes(raw);
        String token = HexFormat.of().formatHex(raw);
        tokens.put(token, account);
        persist(tokensFile, tokens);
        return token;
    }

    /** 令牌 → 账号;无效返回 null。 */
    public String accountOf(String token) {
        return token == null || token.isEmpty() ? null : tokens.get(token);
    }

    public boolean exists(String account) {
        return users.containsKey(account);
    }

    private static String hash(String saltHex, String password) {
        try {
            MessageDigest d = MessageDigest.getInstance("SHA-256");
            d.update(saltHex.getBytes(StandardCharsets.UTF_8));
            d.update(password.getBytes(StandardCharsets.UTF_8));
            return HexFormat.of().formatHex(d.digest());
        } catch (Exception e) {
            throw new IllegalStateException(e);
        }
    }

    private void load(File f, Map<String, String> into) {
        if (!f.isFile()) return;
        try {
            JsonNode n = M.readTree(f);
            n.fields().forEachRemaining(e -> into.put(e.getKey(), e.getValue().asText()));
        } catch (Exception ignored) {
        }
    }

    private synchronized void persist(File f, Map<String, String> map) {
        try {
            dataDir.mkdirs();
            ObjectNode n = M.createObjectNode();
            map.forEach(n::put);
            M.writerWithDefaultPrettyPrinter().writeValue(f, n);
        } catch (Exception ignored) {
        }
    }
}
