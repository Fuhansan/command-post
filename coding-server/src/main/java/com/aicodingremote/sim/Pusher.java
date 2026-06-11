package com.aicodingremote.sim;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.WebSocket;

/**
 * 一次性消息发送器：以 Agent 身份连上中转，向同账号的 Client 推一条文本 ui 消息。
 *
 * 用法：java -cp target/classes com.aicodingremote.sim.Pusher "文本" [account] [wsUrl]
 * 设 HOLD=1 可保持 Agent 在线（便于真机持续在线/截图）。
 */
public final class Pusher {

    public static void main(String[] args) throws Exception {
        String text = args.length > 0 ? args[0] : "这是在跑自动化测试";
        String account = args.length > 1 ? args[1] : "demo";
        String url = args.length > 2 ? args[2] : "ws://127.0.0.1:8090/ws";

        HttpClient http = HttpClient.newHttpClient();
        WebSocket agent = http.newWebSocketBuilder()
                .buildAsync(URI.create(url), new WebSocket.Listener() {})
                .join();

        // auth 为 agent
        agent.sendText("""
            {"v":1,"t":"auth","id":"h_push","from":"agent",
             "body":{"token":"tok","account":"%s",
                     "device":{"id":"dev_agent","platform":"mac","name":"工作 Mac"},
                     "caps":{"protocol":1}}}
            """.formatted(account), true).join();
        Thread.sleep(800);

        // 一条 agent 文本富消息（PROTOCOL §5）
        String esc = text.replace("\\", "\\\\").replace("\"", "\\\"");
        String frame = ("{\"v\":1,\"t\":\"ui\",\"id\":\"m_auto_test\",\"sid\":\"sess_main\",\"seq\":99," +
                "\"from\":\"agent\",\"fallbackText\":\"" + esc + "\"," +
                "\"body\":{\"role\":\"agent\",\"root\":{\"type\":\"card\"," +
                "\"props\":{\"title\":\"自动化测试\",\"icon\":\"checkmark.seal.fill\",\"style\":\"info\"}," +
                "\"children\":[{\"type\":\"text\",\"props\":{\"text\":\"" + esc + "\"}}]}}}");
        agent.sendText(frame, true).join();
        System.out.println("[Pusher] 已向 account=" + account + " 推送: " + text);
        Thread.sleep(500);

        if (System.getenv("HOLD") != null) {
            System.out.println("[Pusher] 保持 Agent 在线(HOLD)。Ctrl+C 退出。");
            Thread.currentThread().join();
        }
        agent.sendClose(WebSocket.NORMAL_CLOSURE, "bye");
        Thread.sleep(300);
        System.exit(0);
    }
}
