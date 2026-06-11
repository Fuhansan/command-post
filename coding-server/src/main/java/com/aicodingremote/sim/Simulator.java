package com.aicodingremote.sim;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.WebSocket;
import java.util.concurrent.CompletionStage;

/**
 * 端到端模拟器：不依赖真机，验证「数据 → 服务器 → 手机端」全链路。
 *
 * <p>用 JDK 自带的 {@link java.net.http.WebSocket}（零依赖）开两条连接：
 * <ul>
 *   <li><b>Agent</b>（扮演电脑代理）：auth 后按 PROTOCOL §5 下发一串 ui 富消息。</li>
 *   <li><b>Client</b>（扮演手机端）：auth 后接收并打印每条 frame；对权限卡回传 action（PROTOCOL §6）。</li>
 * </ul>
 * 跑通即证明中转服务器的配对与双向转发正确。真机 iOS 只要用同一 account 连上来，就能收到同样的下发。
 *
 * 用法：先启动 coding-server，再
 *   java -cp target/classes com.aicodingremote.sim.Simulator [account] [wsUrl]
 */
public final class Simulator {

    public static void main(String[] args) throws Exception {
        String account = args.length > 0 ? args[0] : "demo";
        String url = args.length > 1 ? args[1] : "ws://127.0.0.1:8090/ws";
        String sid = "sess_demo";

        HttpClient http = HttpClient.newHttpClient();
        log("SYS", "连接中转: " + url + "  account=" + account);

        // 1) 手机端先上线，等待下发
        WebSocket client = http.newWebSocketBuilder()
                .buildAsync(URI.create(url), new Printer("手机端"))
                .join();
        client.sendText(authFrame("client", "ios", "我的 iPhone", account), true).join();
        sleep(300);

        // 2) Agent 上线
        WebSocket agent = http.newWebSocketBuilder()
                .buildAsync(URI.create(url), new Printer("Agent"))
                .join();
        agent.sendText(authFrame("agent", "mac", "工作 Mac", account), true).join();
        sleep(400);

        // 3) Agent 下发一串协议组件（和 iOS 详情页 demo 同源）
        for (String[] f : agentFrames(sid)) {
            log("Agent↑", f[0]);
            agent.sendText(f[1], true).join();
            sleep(600);
        }

        // 4) 手机端对权限卡回传 action（允许）—— 验证反向上行
        sleep(600);
        String action = """
            {"v":1,"t":"action","id":"act_1","sid":"%s","from":"client",
             "body":{"msg_id":"m_perm","action_id":"perm_allow","value":"allow"}}
            """.formatted(sid);
        log("手机端↑", "点击「允许」→ 回传 action perm_allow");
        client.sendText(action, true).join();
        sleep(800);

        // HOLD=1 时保持 Agent 在线(便于真机联调/截图);否则演示完即退出。
        if (System.getenv("HOLD") != null) {
            log("SYS", "演示帧已推送，保持 Agent 在线(HOLD)。Ctrl+C 退出。");
            Thread.currentThread().join();
        }

        log("SYS", "演示结束，关闭连接");
        client.sendClose(WebSocket.NORMAL_CLOSURE, "bye");
        agent.sendClose(WebSocket.NORMAL_CLOSURE, "bye");
        sleep(300);
        System.exit(0);
    }

    /** PROTOCOL §8.1 握手帧。account 显式带上，作为最小版的配对键。 */
    private static String authFrame(String from, String platform, String name, String account) {
        return """
            {"v":1,"t":"auth","id":"h_%s","from":"%s",
             "body":{"token":"tok_%s","account":"%s",
                     "device":{"id":"dev_%s","platform":"%s","name":"%s"},
                     "caps":{"protocol":1}}}
            """.formatted(from, from, account, account, from, platform, name);
    }

    /** Agent 下发的 ui 帧序列（标签, JSON）。复刻 iOS 详情页的四张卡。 */
    private static String[][] agentFrames(String sid) {
        return new String[][]{
            {"当前任务", uiCard(sid, "m_task", 1,
                "当前任务: 修复模型切换 UI 交互",
                "{\"type\":\"card\",\"props\":{\"title\":\"当前任务\",\"icon\":\"doc.text\"}," +
                "\"children\":[{\"type\":\"text\",\"props\":{\"text\":\"修复模型切换 UI 交互\"}}]}")},

            {"需要你处理(命令审批)", uiCard(sid, "m_perm", 2,
                "Claude 想运行 `npm install`,允许吗?",
                "{\"type\":\"card\",\"props\":{\"title\":\"需要你处理\",\"icon\":\"exclamationmark.circle.fill\",\"style\":\"danger\"}," +
                "\"children\":[" +
                "{\"type\":\"text\",\"props\":{\"text\":\"Claude Code 请求执行:\",\"color\":\"secondary\",\"style\":\"caption\"}}," +
                "{\"type\":\"code\",\"props\":{\"code\":\"npm install\",\"language\":\"bash\"}}," +
                "{\"type\":\"button_group\",\"props\":{\"buttons\":[" +
                "{\"type\":\"button\",\"props\":{\"label\":\"拒绝\",\"style\":\"default\"},\"action\":{\"id\":\"perm_deny\",\"value\":\"deny\"}}," +
                "{\"type\":\"button\",\"props\":{\"label\":\"允许\",\"style\":\"danger\"},\"action\":{\"id\":\"perm_allow\",\"value\":\"allow\"}}]}}]}")},

            {"流式进展(patch 可后续追加)", uiCard(sid, "m_prog", 3,
                "进展: 已分析组件结构 / 发现 ModelSwitch 文件",
                "{\"type\":\"card\",\"props\":{\"title\":\"最近进展\",\"icon\":\"chart.line.uptrend.xyaxis\",\"tint\":\"blue\"}," +
                "\"children\":[{\"type\":\"text\",\"props\":{\"text\":\"已分析组件结构 → 发现 ModelSwitch 文件 → 准备安装依赖\",\"color\":\"secondary\",\"style\":\"caption\"}}]}")},

            {"文件改动(diff)", uiCard(sid, "m_diff", 4,
                "修改了 src/components/ModelSwitch.tsx",
                "{\"type\":\"diff\",\"props\":{\"filename\":\"src/components/ModelSwitch.tsx\",\"hunks\":[" +
                "{\"op\":\"ctx\",\"text\":\"function ModelSwitch() {\"}," +
                "{\"op\":\"del\",\"text\":\"  const [m,setM]=useState()\"}," +
                "{\"op\":\"add\",\"text\":\"  const {model,setModel}=useModel()\"}," +
                "{\"op\":\"ctx\",\"text\":\"}\"}]}}")},
        };
    }

    private static String uiCard(String sid, String id, int seq, String fallback, String root) {
        return ("{\"v\":1,\"t\":\"ui\",\"id\":\"" + id + "\",\"sid\":\"" + sid + "\",\"seq\":" + seq +
                ",\"from\":\"agent\",\"fallbackText\":\"" + fallback +
                "\",\"body\":{\"role\":\"agent\",\"root\":" + root + "}}");
    }

    // ---- WebSocket 监听:把收到的每条 frame 打印出来 ----
    private static final class Printer implements WebSocket.Listener {
        private final String who;
        private final StringBuilder buf = new StringBuilder();
        Printer(String who) { this.who = who; }

        @Override public void onOpen(WebSocket ws) { ws.request(1); }

        @Override public CompletionStage<?> onText(WebSocket ws, CharSequence data, boolean last) {
            buf.append(data);
            if (last) {
                log(who + "↓", brief(buf.toString()));
                buf.setLength(0);
            }
            ws.request(1);
            return null;
        }

        @Override public void onError(WebSocket ws, Throwable err) {
            log(who, "连接错误: " + err);
        }
    }

    /** 摘要打印:抽出 t 和关键字段,避免刷屏。 */
    private static String brief(String json) {
        String t = field(json, "\"t\":\"");
        String fb = field(json, "\"fallbackText\":\"");
        if (fb != null) return "frame t=" + t + "  « " + fb + " »";
        if ("auth_ok".equals(t)) return "frame t=auth_ok  (握手成功,已配对)";
        if ("presence".equals(t)) return "frame t=presence  " + (json.contains("\"online\":true") ? "Agent 上线" : "Agent 下线");
        if ("action".equals(t)) return "frame t=action  action_id=" + field(json, "\"action_id\":\"");
        return "frame t=" + t;
    }

    private static String field(String json, String key) {
        int i = json.indexOf(key);
        if (i < 0) return null;
        i += key.length();
        int j = json.indexOf('"', i);
        return j < 0 ? null : json.substring(i, j);
    }

    private static void log(String tag, String msg) {
        System.out.printf("%-10s %s%n", "[" + tag + "]", msg);
    }

    private static void sleep(long ms) {
        try { Thread.sleep(ms); } catch (InterruptedException ignored) {}
    }
}
