package com.aicodingremote.server;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

import java.io.File;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * 客户端版本清单。开发者编辑 data/app-version.json 即可发布:
 *   latest   最新版本号(语义化,如 0.2.0)—— 高于客户端当前版本时提示更新+公告
 *   minimum  最低可用版本 —— 客户端低于它时强制更新,拦截使用
 *   notes    更新公告(支持多行,重大功能在这里写)
 *   url      更新地址(TestFlight 链接等;留空时客户端提示连线安装)
 * 文件每次请求现读,改完立即生效,无需重启服务器。
 */
@RestController
public class AppVersionController {

    private static final ObjectMapper M = new ObjectMapper();
    private static final File FILE = new File("data/app-version.json");

    @GetMapping("/api/app/version")
    public Map<String, String> version() {
        Map<String, String> out = new LinkedHashMap<>();
        out.put("latest", "0.1.0");
        out.put("minimum", "0.1.0");
        out.put("notes", "");
        out.put("url", "");
        try {
            if (!FILE.isFile()) {
                // 首次访问生成模板,方便开发者直接编辑
                FILE.getParentFile().mkdirs();
                ObjectNode n = M.createObjectNode();
                out.forEach(n::put);
                M.writerWithDefaultPrettyPrinter().writeValue(FILE, n);
                return out;
            }
            JsonNode n = M.readTree(FILE);
            for (String k : out.keySet()) {
                if (n.hasNonNull(k)) out.put(k, n.path(k).asText());
            }
        } catch (Exception ignored) {
        }
        return out;
    }
}
