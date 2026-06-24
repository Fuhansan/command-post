package com.aicodingremote.server;

import com.aicodingremote.server.auth.UserStore;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.io.File;
import java.io.IOException;
import java.nio.file.Files;
import java.security.SecureRandom;
import java.util.Locale;
import java.util.Map;
import java.util.Set;

/**
 * 图片中转(Spring MVC,8080)。
 *
 * 目的:图片走 HTTP 数据通道,WebSocket 控制通道(8090)只传 id —— 避免把
 * base64 塞进 WS 帧撑大流量、挤占心跳/ACK、重传时整图重发。
 *
 * 链路:手机 POST /upload 上传字节 → 拿到 id;消息帧里只带 id;
 *       电脑端 VibeNotch GET /{id} 凭同账号 token 把图拉下来,按原逻辑落盘给 claude。
 *
 * 存储:data/images/&lt;account&gt;/&lt;id&gt;.&lt;ext&gt;,按账号隔离(手机与其配对的电脑端
 *       是同一账号,故能互取;跨账号取不到)。上传时顺带清掉该账号 7 天前的旧图。
 */
@RestController
@RequestMapping("/api/image")
public class ImageController {

    private static final File ROOT = new File("data/images");
    private static final long TTL_MS = 7L * 24 * 3600 * 1000;  // 旧图保留 7 天(一周)
    private static final long MAX_BYTES = 12L * 1024 * 1024;  // 单图上限 12MB(压缩后远小于此)
    private static final Set<String> ALLOWED = Set.of("jpg", "jpeg", "png", "gif", "webp");

    private static final Logger log = LoggerFactory.getLogger(ImageController.class);
    private final UserStore store;
    private final SecureRandom rnd = new SecureRandom();

    public ImageController(UserStore store) {
        this.store = store;
    }

    /** 手机上传:原始图片字节(Content-Type 任意),返回 {id, ext}。 */
    @PostMapping("/upload")
    public ResponseEntity<?> upload(@RequestHeader(value = "Authorization", required = false) String auth,
                                    @RequestParam(value = "ext", defaultValue = "jpg") String ext,
                                    @RequestBody(required = false) byte[] body) {
        String account = accountOf(auth);
        if (account == null) {
            log.warn("image upload 拒绝:无效 token (authHeader={})", auth == null ? "无" : "有");
            return ResponseEntity.status(401).body(Map.of("error", "unauthorized"));
        }
        if (body == null || body.length == 0) return ResponseEntity.badRequest().body(Map.of("error", "empty body"));
        if (body.length > MAX_BYTES) return ResponseEntity.status(413).body(Map.of("error", "too large"));

        String e = ext.toLowerCase(Locale.ROOT);
        if (!ALLOWED.contains(e)) e = "jpg";

        File dir = new File(ROOT, safe(account));
        if (!dir.exists()) dir.mkdirs();
        sweepOld(dir);

        String id = "img_" + Long.toHexString(System.currentTimeMillis())
                + Integer.toHexString(rnd.nextInt(0x10000));
        File out = new File(dir, id + "." + e);
        try {
            Files.write(out.toPath(), body);
        } catch (IOException ex) {
            return ResponseEntity.status(500).body(Map.of("error", "write failed"));
        }
        log.info("image upload: account={} bytes={} → id={}", account, body.length, id);
        return ResponseEntity.ok(Map.of("id", id, "ext", e));
    }

    /** 电脑端按 id 下载:返回图片二进制(同账号才取得到)。 */
    @GetMapping("/{id}")
    public ResponseEntity<byte[]> download(@RequestHeader(value = "Authorization", required = false) String auth,
                                           @PathVariable String id) {
        String account = accountOf(auth);
        if (account == null) return ResponseEntity.status(401).build();
        // 仅允许形如 img_xxxx 的 id,挡掉路径穿越
        if (id == null || !id.matches("[A-Za-z0-9_]+")) return ResponseEntity.badRequest().build();

        File dir = new File(ROOT, safe(account));
        File[] hits = dir.listFiles((d, name) -> name.startsWith(id + "."));
        if (hits == null || hits.length == 0) return ResponseEntity.notFound().build();
        File f = hits[0];
        try {
            byte[] bytes = Files.readAllBytes(f.toPath());
            String fileExt = f.getName().substring(f.getName().lastIndexOf('.') + 1);
            return ResponseEntity.ok().contentType(mediaType(fileExt)).body(bytes);
        } catch (IOException ex) {
            return ResponseEntity.status(500).build();
        }
    }

    private String accountOf(String auth) {
        if (auth == null || auth.isBlank()) return null;
        String token = auth.startsWith("Bearer ") ? auth.substring(7) : auth;
        return store.accountOf(token.trim());
    }

    private static String safe(String account) {
        return account.replaceAll("[^a-zA-Z0-9._-]", "_");
    }

    private static void sweepOld(File dir) {
        File[] files = dir.listFiles();
        if (files == null) return;
        long now = System.currentTimeMillis();
        for (File f : files) {
            if (now - f.lastModified() > TTL_MS) f.delete();
        }
    }

    private static MediaType mediaType(String ext) {
        return switch (ext.toLowerCase(Locale.ROOT)) {
            case "png"  -> MediaType.IMAGE_PNG;
            case "gif"  -> MediaType.IMAGE_GIF;
            case "webp" -> MediaType.parseMediaType("image/webp");
            default     -> MediaType.IMAGE_JPEG;
        };
    }
}
