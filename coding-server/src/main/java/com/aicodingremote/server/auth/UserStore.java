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
 * 用户与会话令牌存储:内存 Map + JSON 文件持久化(重启不丢)。
 * 用户结构化为 {@link User}(data/users.json:email→User 对象),
 * 兼容并自动升级旧的扁平格式(email→"salt:hash" / "external:provider")。
 * 密码存「盐 + SHA-256(盐+密码)」,不存明文。后续换数据库时只动这一层。
 */
@Component
public class UserStore {

    private static final ObjectMapper M = new ObjectMapper();
    private final File dataDir = new File("data");
    private final File usersFile = new File(dataDir, "users.json");
    private final File tokensFile = new File(dataDir, "tokens.json");
    private final File devicesFile = new File(dataDir, "devices.json");

    /** 登录过的设备记录(便于区分是哪台设备;不再单活动踢人,多设备可同时在线)。 */
    public record DeviceRec(String id, String name, String role, long lastSeen) {}

    /** email → User */
    private final Map<String, User> users = new ConcurrentHashMap<>();
    /** token → account(email) */
    private final Map<String, String> tokens = new ConcurrentHashMap<>();
    /** account → (deviceId → 设备记录)。 */
    private final Map<String, Map<String, DeviceRec>> devices = new ConcurrentHashMap<>();
    private final SecureRandom random = new SecureRandom();

    public UserStore() {
        boolean migrated = loadUsers();
        loadTokens();
        loadDevices();
        if (migrated) persistUsers();   // 旧格式 → 升级落盘一次
    }

    // ── 注册 / 校验 ─────────────────────────────────────────

    /** 邮箱验证码注册:创建带密码的账号。已存在返回 false。 */
    public synchronized boolean createWithPassword(String email, String password, String displayName) {
        if (users.containsKey(email)) return false;
        User u = new User(email, "email");
        u.passwordHash = makeHash(password);
        u.displayName = (displayName == null || displayName.isBlank())
                ? email.substring(0, Math.max(1, email.indexOf('@'))) : displayName;
        users.put(email, u);
        persistUsers();
        return true;
    }

    /** 旧接口保留:注册(账号已存在返回 false)。 */
    public synchronized boolean register(String account, String password) {
        return createWithPassword(account, password, null);
    }

    /** 校验账号密码。 */
    public boolean verify(String account, String password) {
        User u = users.get(account);
        if (u == null || !u.hasPassword()) return false;
        String[] parts = u.passwordHash.split(":", 2);
        return parts.length == 2 && parts[1].equals(hash(parts[0], password));
    }

    // ── 令牌 ───────────────────────────────────────────────

    /** 签发令牌(电脑配对用;不动单活动表)。 */
    public String issueToken(String account) {
        byte[] raw = new byte[24];
        random.nextBytes(raw);
        String token = HexFormat.of().formatHex(raw);
        tokens.put(token, account);
        persistTokens();
        return token;
    }

    /** 签发**手机/登录**令牌。已不再单活动,等同 issueToken(保留方法名,免改调用方)。 */
    public String issueClientToken(String account) {
        return issueToken(account);
    }

    /** 记录某账号登录/上线的设备(不踢人,只留档,便于区分是哪台设备)。 */
    public void recordDevice(String account, String deviceId, String name, String role) {
        if (account == null || account.isEmpty() || deviceId == null || deviceId.isEmpty()) return;
        devices.computeIfAbsent(account, k -> new ConcurrentHashMap<>())
               .put(deviceId, new DeviceRec(deviceId, name, role, System.currentTimeMillis()));
        persistDevices();
    }

    /** 某账号登录过的设备列表(便于区分)。 */
    public java.util.Collection<DeviceRec> devicesOf(String account) {
        Map<String, DeviceRec> m = devices.get(account);
        return m == null ? java.util.List.of() : m.values();
    }

    /** 令牌 → 账号;无效返回 null。 */
    public String accountOf(String token) {
        return token == null || token.isEmpty() ? null : tokens.get(token);
    }

    // ── 查询 / 改密 ─────────────────────────────────────────

    public boolean exists(String account) {
        return users.containsKey(account);
    }

    /** 该账号是否已设置密码(可用邮箱密码登录)。 */
    public boolean hasPassword(String account) {
        User u = users.get(account);
        return u != null && u.hasPassword();
    }

    /** 取用户记录(展示昵称等;不存在返回 null)。 */
    public User user(String account) {
        return users.get(account);
    }

    /** 外部登录(Google 等)的账号:首次出现时登记,无本地密码。 */
    public synchronized void ensureExternal(String account, String provider) {
        if (!users.containsKey(account)) {
            users.put(account, new User(account, provider));
            persistUsers();
        }
    }

    /** 给账号设置/更新密码(Google 验证 / 忘记密码重置后调用)。账号不存在则创建。 */
    public synchronized void setPassword(String account, String password) {
        User u = users.computeIfAbsent(account, k -> new User(k, "email"));
        u.passwordHash = makeHash(password);
        u.updatedAt = System.currentTimeMillis();
        persistUsers();
    }

    // ── 哈希 ───────────────────────────────────────────────

    private String makeHash(String password) {
        byte[] salt = new byte[16];
        random.nextBytes(salt);
        String saltHex = HexFormat.of().formatHex(salt);
        return saltHex + ":" + hash(saltHex, password);
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

    // ── 持久化 ─────────────────────────────────────────────

    /** 读取 users.json。返回是否发生了「旧格式 → 新结构」的迁移(用于决定是否回写升级)。 */
    private boolean loadUsers() {
        if (!usersFile.isFile()) return false;
        boolean migrated = false;
        try {
            JsonNode root = M.readTree(usersFile);
            var it = root.fields();
            while (it.hasNext()) {
                var e = it.next();
                String email = e.getKey();
                JsonNode v = e.getValue();
                if (v.isObject()) {
                    User u = M.treeToValue(v, User.class);
                    if (u.email == null) u.email = email;
                    users.put(email, u);
                } else {
                    // 旧扁平格式:迁移
                    users.put(email, migrateLegacy(email, v.asText()));
                    migrated = true;
                }
            }
        } catch (Exception ignored) {
        }
        return migrated;
    }

    /** 旧值 "external:provider"(无密码外部账号)或 "salt:hash"(已设密码)→ User。 */
    private static User migrateLegacy(String email, String legacy) {
        if (legacy.startsWith("external:")) {
            return new User(email, legacy.substring("external:".length()));
        }
        User u = new User(email, "email");          // 已有密码,按邮箱账号处理
        u.passwordHash = legacy;                     // 旧值本身就是 "salt:hash"
        u.displayName = email.substring(0, Math.max(1, email.indexOf('@')));
        return u;
    }

    private void loadTokens() {
        if (!tokensFile.isFile()) return;
        try {
            JsonNode n = M.readTree(tokensFile);
            n.fields().forEachRemaining(e -> tokens.put(e.getKey(), e.getValue().asText()));
        } catch (Exception ignored) {
        }
    }

    @SuppressWarnings("unchecked")
    private void loadDevices() {
        if (!devicesFile.isFile()) return;
        try {
            Map<String, Map<String, DeviceRec>> loaded = M.readValue(
                    devicesFile,
                    M.getTypeFactory().constructMapType(java.util.HashMap.class,
                        M.constructType(String.class),
                        M.getTypeFactory().constructMapType(java.util.HashMap.class, String.class, DeviceRec.class)));
            loaded.forEach((acc, m) -> devices.put(acc, new ConcurrentHashMap<>(m)));
        } catch (Exception ignored) {
        }
    }

    private synchronized void persistDevices() {
        try {
            dataDir.mkdirs();
            M.writerWithDefaultPrettyPrinter().writeValue(devicesFile, devices);
        } catch (Exception ignored) {
        }
    }

    private synchronized void persistUsers() {
        try {
            dataDir.mkdirs();
            M.writerWithDefaultPrettyPrinter().writeValue(usersFile, users);
        } catch (Exception ignored) {
        }
    }

    private synchronized void persistTokens() {
        try {
            dataDir.mkdirs();
            ObjectNode n = M.createObjectNode();
            tokens.forEach(n::put);
            M.writerWithDefaultPrettyPrinter().writeValue(tokensFile, n);
        } catch (Exception ignored) {
        }
    }
}
