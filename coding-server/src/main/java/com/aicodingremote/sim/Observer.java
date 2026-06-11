package com.aicodingremote.sim;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.WebSocket;
import java.util.concurrent.CompletionStage;

/**
 * 诊断用:以 Client 身份连中转,打印收到的每一帧(看手机端到底收到了什么)。
 * 用法:java -cp target/classes com.aicodingremote.sim.Observer [account] [wsUrl]
 */
public final class Observer {
    public static void main(String[] args) throws Exception {
        String account = args.length > 0 ? args[0] : "demo";
        String url = args.length > 1 ? args[1] : "ws://127.0.0.1:8090/ws";

        HttpClient http = HttpClient.newHttpClient();
        WebSocket ws = http.newWebSocketBuilder()
                .buildAsync(URI.create(url), new WebSocket.Listener() {
                    private final StringBuilder buf = new StringBuilder();
                    @Override public void onOpen(WebSocket w) { w.request(1); }
                    @Override public CompletionStage<?> onText(WebSocket w, CharSequence d, boolean last) {
                        buf.append(d);
                        if (last) { System.out.println("[recv] " + brief(buf.toString())); buf.setLength(0); }
                        w.request(1);
                        return null;
                    }
                }).join();

        ws.sendText("{\"v\":1,\"t\":\"auth\",\"id\":\"h_obs\",\"from\":\"client\"," +
                "\"body\":{\"token\":\"obs\",\"account\":\"" + account + "\"," +
                "\"device\":{\"id\":\"obs\",\"platform\":\"ios\",\"name\":\"观察者\"}}}", true).join();
        System.out.println("[obs] connected as client, account=" + account + ". 打印所有收到的帧, Ctrl+C 退出。");
        Thread.currentThread().join();
    }

    static String brief(String j) {
        String t = field(j, "\"t\":\"");
        String sid = field(j, "\"sid\":\"");
        if ("patch".equals(t)) {
            String op = field(j, "\"op\":\"");
            String scope = field(j, "\"scope\":\"");
            return "PATCH op=" + op + " scope=" + scope + " sid=" + sid + " id=" + field(j, "\"id\":\"");
        }
        if ("ui".equals(t)) return "UI sid=" + sid + " id=" + field(j, "\"id\":\"") + " « " + field(j, "\"fallbackText\":\"") + " »";
        if ("presence".equals(t)) return "PRESENCE " + (j.contains("\"online\":true") ? "online" : "offline");
        if ("auth_ok".equals(t)) return "AUTH_OK";
        return "t=" + t + " sid=" + sid;
    }
    static String field(String j, String key) {
        int i = j.indexOf(key); if (i < 0) return null; i += key.length();
        int e = j.indexOf('"', i); return e < 0 ? null : j.substring(i, e);
    }
}
