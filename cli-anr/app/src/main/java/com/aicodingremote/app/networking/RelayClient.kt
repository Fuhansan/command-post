package com.aicodingremote.app.networking

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshots.SnapshotStateList
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.aicodingremote.app.auth.SessionAuth
import com.aicodingremote.app.models.AgentInfo
import com.aicodingremote.app.models.Component
import com.aicodingremote.app.models.ComponentAction
import com.aicodingremote.app.models.DeliveryStatus
import com.aicodingremote.app.models.Frame
import com.aicodingremote.app.models.FrameType
import com.aicodingremote.app.models.ProjectHistory
import com.aicodingremote.app.models.ProjectInfo
import com.aicodingremote.app.models.StagedImagePayload
import com.aicodingremote.app.models.UIMessage
import com.aicodingremote.app.models.arrayValue
import com.aicodingremote.app.models.boolValue
import com.aicodingremote.app.models.get
import com.aicodingremote.app.models.string
import com.aicodingremote.app.models.stringValue
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import java.util.concurrent.TimeUnit
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.add
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject
import java.util.UUID
import kotlin.math.pow

/**
 * 一个会话(任务)= 一个 claude 终端会话,按协议 `sid` 区分。
 * 对位 iOS `RelaySession`。`messages` 是 Compose 的 [SnapshotStateList],
 * 直接增删即可触发详情页重组。
 */
data class RelaySession(
    val id: String,                 // sid
    val title: String,              // 项目名(cwd 末段)
    val terminal: String,           // 终端/IDE 名
    val cli: String = "",           // CLI 类型 claude|codex|""(决定快捷指令集)
    val cwd: String,                // 项目工作目录
    val subtitle: String,           // prompt 摘要 / 当前活动
    val status: String,             // idle | working | waiting | done | ended
    val needsAction: Boolean,       // 是否有待批准的命令
    val pendingKind: String,        // ""|perm(待审批,可批量)|question(待选择,需进会话)
    val pendingDetail: String,      // 待办摘要(命令 / 题目)
    val agentId: String,            // 来自哪台电脑(多机同账号时区分;reset 按机清理)
    val source: String = "",        // console=VibeNotch 项目会话 | hook=用户手动敲的(锁屏不可控)
    val agentSessionId: String = "",// claude session_id(项目内去重历史 / 定位进入)
    val hasMore: Boolean = false,   // 还有更早的消息没加载(顶部显示「加载更早」)
    val messages: SnapshotStateList<UIMessage>,
) {
    /** 手动会话:平铺首页 + 打「锁屏不可控」标签。 */
    val isManual: Boolean get() = source == "hook"
}

/**
 * 应用级中转连接(ViewModel),经 CompositionLocal 注入。
 * 客户端唯一真实数据源,无任何本地模拟数据。下行按 `sid` 分组成多个任务。
 *
 * 与 cli-ios `RelayClient` 行为对齐:握手 / 摄入 ui & patch & ack / 发 input & action /
 * 可靠上行(待确认队列 + 超时重发 + 两段 ack)/ 多电脑挂起恢复。
 */
class RelayClient : ViewModel() {

    var connection by mutableStateOf<ConnectionState>(ConnectionState.Disconnected)
        private set

    val agents: SnapshotStateList<AgentInfo> = mutableStateListOf()
    val sessions: SnapshotStateList<RelaySession> = mutableStateListOf()

    /** 电脑端打开的项目列表(结构化,来自 `console:projects` 通道)。首页「项目区」用。 */
    val projects: SnapshotStateList<ProjectInfo> = mutableStateListOf()

    private val ws = WebSocketClient(onState = { connection = it })
    private var account: String? = null

    init {
        ws.onFrame = { ingest(it) }
        ws.onConnect = { sendAuth() }
    }

    // MARK: - 连接

    fun connect(account: String) {
        if (this.account == account && connection !is ConnectionState.Disconnected) return
        this.account = account
        sessions.clear()
        agents.clear()
        projects.clear()
        ws.connect(ServerConfig.currentURL())
    }

    /** 设置页修改服务器地址后调用:断开并按新地址重连(沿用当前账号)。 */
    fun reconnectToCurrentServer() {
        if (account == null) return
        ws.disconnect()
        sessions.clear()
        agents.clear()
        projects.clear()
        ws.connect(ServerConfig.currentURL())
    }

    /** 手动断开(保留登录态与账号,不自动重连;设置页「重连」恢复)。 */
    fun manualDisconnect() {
        ws.disconnect()
        sessions.clear()
        agents.clear()
        projects.clear()
    }

    fun disconnect() {
        account = null
        agents.clear()
        sessions.clear()
        projects.clear()
        ws.disconnect()
    }

    fun session(id: String): RelaySession? = sessions.firstOrNull { it.id == id }

    /** 跨会话待办数(通知 Tab 角标)。 */
    val pendingCount: Int get() = sessions.count { it.pendingKind.isNotEmpty() }

    override fun onCleared() {
        ws.disconnect()
        super.onCleared()
    }

    private fun sendAuth() {
        val acc = account ?: return
        val body = buildJsonObject {
            // 登录后的会话令牌:服务器优先据此解析账号(未登录回退 account 会合)
            put("token", SessionAuth.token ?: "android")
            put("account", acc)
            putJsonObject("device") {
                put("id", "android_device")
                put("platform", "android")
                put("name", "我的 Android")
            }
            putJsonObject("caps") { put("protocol", 1) }
        }
        sendFrame(t = "auth", id = "h_android", sid = null, body = body)
    }

    // MARK: - 下行摄入

    private fun ingest(frame: Frame) {
        when (frame.t) {
            is FrameType.AuthOk -> {
                agents.clear()
                agents.addAll(parseAgents(frame.body))
                flushPending()   // 重连成功 → 补发断线期间未确认的上行
            }
            is FrameType.Presence -> applyPresence(frame.body)
            is FrameType.Ui -> applyUI(frame)
            is FrameType.Patch -> applyPatch(frame)
            is FrameType.Ack -> applyAck(frame)
            is FrameType.Error -> {
                // 致命错误(如令牌失效被服务器拒绝)→ 停止自动重连,避免风暴;
                // 用户重新登录后会以新令牌重连。
                if (frame.body?.get("fatal")?.boolValue == true) {
                    ws.disconnect()
                }
            }
            else -> Unit
        }
    }

    private fun parseAgents(body: JsonElement?): List<AgentInfo> {
        val list = body?.get("agents")?.arrayValue ?: emptyList()
        return list.map {
            AgentInfo(
                id = it.string("id"),
                name = it.string("name", "Agent"),
                online = it["online"]?.boolValue ?: true,
                suspended = it["suspended"]?.boolValue ?: false,
            )
        }
    }

    /** 断开某台电脑(服务器挂起它并踢下线;它的会话随 reset/离线清除)。 */
    fun suspendAgent(agent: AgentInfo) {
        sendFrame(
            t = "ctl", id = "ctl_${UUID.randomUUID()}", sid = null,
            body = buildJsonObject {
                put("op", "agent_suspend")
                put("agent", agent.id)
                put("name", agent.name)
            },
        )
        val i = agents.indexOfFirst { it.id == agent.id }
        if (i >= 0) {
            agents[i] = agent.copy(online = false, suspended = true, resuming = false)
        }
    }

    /**
     * 恢复某台电脑:解除挂起 → 显示「重连中」,电脑下一次探测(≤10s)上线;
     * 30s 仍未回来则落回离线(电脑可能根本没开机)。
     */
    fun resumeAgent(agent: AgentInfo) {
        sendFrame(
            t = "ctl", id = "ctl_${UUID.randomUUID()}", sid = null,
            body = buildJsonObject {
                put("op", "agent_resume")
                put("agent", agent.id)
            },
        )
        val i = agents.indexOfFirst { it.id == agent.id }
        if (i >= 0) {
            agents[i] = agent.copy(online = false, suspended = false, resuming = true)
        }
        viewModelScope.launch {
            delay(30_000)
            val idx = agents.indexOfFirst { it.id == agent.id }
            if (idx >= 0 && agents[idx].resuming && !agents[idx].online) {
                agents[idx] = agents[idx].copy(resuming = false)   // 超时:显示离线
            }
        }
    }

    private fun applyPresence(body: JsonElement?) {
        body ?: return
        val id = body["agent_id"]?.stringValue ?: return
        val online = body["online"]?.boolValue ?: false
        val name = body["name"]?.stringValue
        val idx = agents.indexOfFirst { it.id == id }
        if (idx >= 0) {
            // 上线即清掉挂起/重连中;离线保留原 suspended(挂起导致的离线仍显示「重连」)
            val susp = if (online) false else agents[idx].suspended
            val resuming = if (online) false else agents[idx].resuming
            agents[idx] = agents[idx].copy(
                name = name ?: agents[idx].name,
                online = online,
                suspended = susp,
                resuming = resuming,
            )
        } else if (online) {
            agents.add(AgentInfo(id, name ?: id, true))
        }
        // 客户端隔离(双保险):电脑离线 → 它的会话立即移除,不再展示旧数据。
        // 服务端同时会代发该设备的 reset 并清快照;电脑重连后会全量重推。
        if (!online) {
            sessions.removeAll { it.agentId == id }
        }
    }

    /**
     * PROTOCOL §5 —— ui 帧按 `sid` 归入对应会话;`body.session` 为任务元信息(首页行用)。
     */
    private fun applyUI(frame: Frame) {
        val sid = frame.sid ?: return
        // 项目列表通道:解析成结构化项目模型,不当作聊天会话展示。
        if (sid == "console:projects") {
            applyProjects(frame.body)
            return
        }
        val msg = UIMessage.from(frame) ?: return
        val meta = frame.body?.get("session")

        val idx = sessions.indexOfFirst { it.id == sid }
        val current = if (idx >= 0) sessions[idx] else RelaySession(
            id = sid,
            title = "会话",
            terminal = "",
            cwd = "",
            subtitle = "",
            status = "working",
            needsAction = false,
            pendingKind = "",
            pendingDetail = "",
            agentId = "",
            messages = mutableStateListOf(),
        )
        val updated = current.copy(
            agentId = meta?.get("agent")?.stringValue ?: current.agentId,
            source = meta?.get("source")?.stringValue ?: current.source,
            agentSessionId = meta?.get("claudeId")?.stringValue ?: current.agentSessionId,
            hasMore = meta?.get("hasMore")?.boolValue ?: current.hasMore,
            title = meta?.get("title")?.stringValue ?: current.title,
            terminal = meta?.get("terminal")?.stringValue ?: current.terminal,
            cli = meta?.get("cli")?.stringValue ?: current.cli,
            cwd = meta?.get("cwd")?.stringValue ?: current.cwd,
            subtitle = meta?.get("subtitle")?.stringValue ?: current.subtitle,
            status = meta?.get("status")?.stringValue ?: current.status,
            needsAction = meta?.get("needsAction")?.boolValue ?: current.needsAction,
            pendingKind = meta?.get("pendingKind")?.stringValue ?: current.pendingKind,
            pendingDetail = meta?.get("pendingDetail")?.stringValue ?: current.pendingDetail,
        )

        if (msg.role == "user") {
            // 正式的用户消息(经 agent 从转录回传)到达 → 移除发送时的本地回显,
            // 否则同一条消息显示两遍(本地一条 + 正式一条)。发送失败的保留(重试入口)。
            updated.messages.removeAll {
                it.seq == Int.MAX_VALUE && it.role == "user" && it.status != DeliveryStatus.FAILED
            }
        }

        val mIdx = updated.messages.indexOfFirst { it.id == msg.id }
        if (mIdx >= 0) updated.messages[mIdx] = msg else updated.messages.add(msg)

        if (idx >= 0) sessions[idx] = updated else sessions.add(updated)
    }

    /** 解析 `console:projects` 通道的结构化项目列表 → 驱动首页「项目区」。 */
    private fun applyProjects(body: JsonElement?) {
        val arr = body?.get("projects")?.arrayValue ?: emptyList()
        val next = arr.mapNotNull { p ->
            val wd = p.string("workdir")
            if (wd.isEmpty()) return@mapNotNull null
            val hist = (p["history"]?.arrayValue ?: emptyList()).map {
                ProjectHistory(id = it.string("id"), label = it.string("label"))
            }
            ProjectInfo(workdir = wd, name = p.string("name"), history = hist)
        }
        projects.clear()
        projects.addAll(next)
    }

    /**
     * PROTOCOL §7 —— patch:
     * - `op=reset` → 某台电脑的 agent 重启/退出配对,只清它的会话(老格式不带 agent 则全清);
     * - `op=remove` + `scope=session` → 删整个会话(任务关闭);
     * - `op=remove`(带消息 id)→ 删该条消息;
     * - `op=replace` → 替换根组件。
     */
    private fun applyPatch(frame: Frame) {
        val body = frame.body ?: return
        val op = body.string("op", "replace")

        if (op == "reset") {
            val agentId = body["agent"]?.stringValue
            if (!agentId.isNullOrEmpty()) {
                sessions.removeAll { it.agentId == agentId || it.agentId.isEmpty() }
            } else {
                sessions.clear()
            }
            return
        }

        val sid = frame.sid ?: return
        if (op == "remove") {
            if (body.string("scope") == "session") {
                val idx = sessions.indexOfFirst { it.id == sid }
                if (idx >= 0) sessions.removeAt(idx)
            } else {
                val id = frame.id ?: return
                val sIdx = sessions.indexOfFirst { it.id == sid }
                if (sIdx >= 0) sessions[sIdx].messages.removeAll { it.id == id }
            }
            return
        }

        val id = frame.id ?: return
        val sIdx = sessions.indexOfFirst { it.id == sid }
        if (sIdx < 0) return
        val mIdx = sessions[sIdx].messages.indexOfFirst { it.id == id }
        if (mIdx < 0) return

        if (op == "replace") {
            val value = body["value"] ?: return
            val current = sessions[sIdx].messages[mIdx]
            sessions[sIdx].messages[mIdx] = current.copy(root = Component.from(value))
        }
    }

    // MARK: - 上行(都带所属会话 sid)

    fun sendInput(text: String, sessionId: String) {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return
        val frameId = "in_${UUID.randomUUID()}"
        val msg = UIMessage.localUserText(trimmed)
            .copy(status = DeliveryStatus.SENDING, upstreamId = frameId)
        val idx = sessions.indexOfFirst { it.id == sessionId }
        if (idx >= 0) sessions[idx].messages.add(msg)
        sendReliable(
            t = "input", id = frameId, sid = sessionId, localMsgId = msg.id,
            body = buildJsonObject {
                put("kind", "text")
                put("text", trimmed)
            },
        )
    }

    /**
     * 图文回显:即时在气泡里显示(缩略图,仅本地展示),先不发送。
     * 返回本地消息 id,供图片上传完成后关联发送 / 更新投递状态。
     */
    fun beginImageEcho(thumbs: List<StagedImagePayload>, text: String, sessionId: String): String {
        val trimmed = text.trim()
        val msg = UIMessage.localUserImages(thumbs, trimmed)
            .copy(status = DeliveryStatus.SENDING)
        val idx = sessions.indexOfFirst { it.id == sessionId }
        if (idx >= 0) sessions[idx].messages.add(msg)
        return msg.id
    }

    /**
     * 图片上传换回 id 后,发送图文输入帧 —— 控制通道**只带图片 id**,不带 base64。
     * 电脑端 VibeNotch 凭 id 经 HTTP 把图拉下来再注入。
     */
    fun sendImageRefs(
        refs: List<Pair<String, String>>,   // (id, ext)
        text: String,
        sessionId: String,
        localMsgId: String,
    ) {
        if (refs.isEmpty()) {
            // 全部上传失败 → 标记失败,气泡可手动重发(此时无 pendingFrame,重发走重新上传由 UI 兜底)
            setStatus(DeliveryStatus.FAILED, localMsgId, sessionId)
            return
        }
        val trimmed = text.trim()
        val frameId = "in_${UUID.randomUUID()}"
        // 把上行帧 id 记到回显消息上(重发/对账用)
        val sIdx = sessions.indexOfFirst { it.id == sessionId }
        if (sIdx >= 0) {
            val mIdx = sessions[sIdx].messages.indexOfFirst { it.id == localMsgId }
            if (mIdx >= 0) {
                sessions[sIdx].messages[mIdx] = sessions[sIdx].messages[mIdx].copy(upstreamId = frameId)
            }
        }
        sendReliable(
            t = "input", id = frameId, sid = sessionId, localMsgId = localMsgId,
            body = buildJsonObject {
                put("kind", "image")
                put("text", trimmed)
                put("images", buildJsonArray {
                    refs.forEach { (id, ext) ->
                        add(buildJsonObject {
                            put("id", id)
                            put("ext", ext)
                        })
                    }
                })
            },
        )
    }

    /**
     * 新建会话:请求电脑端开一个 Terminal.app 窗口运行命令(默认 claude)。
     * 命令跑起来后,新 claude 会话会经 hook 正常出现在任务列表。
     */
    fun launchCommand(command: String) {
        val cmd = command.trim()
        if (cmd.isEmpty()) return
        sendReliable(
            t = "action", id = "act_${UUID.randomUUID()}", sid = "system", localMsgId = null,
            body = buildJsonObject {
                put("action_id", "launch_command")
                put("value", cmd)
            },
        )
    }

    // MARK: - 项目内开会话(电脑端 onRemoteConsoleOpen 处理)

    /** 在项目里「继续最近」会话(claude --continue)。 */
    fun consoleContinue(workdir: String) = sendConsoleOpen("console_continue", workdir)

    /** 在项目里开「全新」会话。 */
    fun consoleNewSession(workdir: String) = sendConsoleOpen("console_new", workdir)

    /** 从项目历史里「恢复」一条会话(claude --resume <id>)。 */
    fun consoleResume(workdir: String, historyId: String) =
        sendConsoleOpen("console_resume", "$workdir$historyId")

    /** 懒加载:请求该会话更早的一批消息(电脑端扩大窗口重推)。 */
    fun loadMoreMessages(sessionId: String) = sendConsoleOpen("console_load_more", sessionId)

    private fun sendConsoleOpen(actionId: String, value: String) {
        sendReliable(
            t = "action", id = "act_${UUID.randomUUID()}", sid = "system", localMsgId = null,
            body = buildJsonObject {
                put("action_id", actionId)
                put("value", value)
            },
        )
    }

    /** 某 cwd 属于哪个项目(最长前缀匹配)——把项目子目录里的手动会话也折叠进该项目。 */
    fun project(forCwd: String): ProjectInfo? =
        projects
            .filter { forCwd == it.workdir || forCwd.startsWith(it.workdir + "/") }
            .maxByOrNull { it.workdir.length }

    /**
     * 结束任务:请求电脑端关闭该 claude 会话(终止进程),随后会话经正常移除链路从手机消失。
     */
    fun endSession(sessionId: String) {
        sendReliable(
            t = "action", id = "act_${UUID.randomUUID()}", sid = sessionId, localMsgId = null,
            body = buildJsonObject {
                put("msg_id", "sess:$sessionId")
                put("action_id", "session_close")
                put("value", sessionId)
            },
        )
    }

    fun sendAction(action: ComponentAction, messageId: String, sessionId: String) {
        sendReliable(
            t = "action", id = "act_${UUID.randomUUID()}", sid = sessionId, localMsgId = null,
            body = buildJsonObject {
                put("msg_id", messageId)
                put("action_id", action.id)
                action.value?.let { put("value", it) }
            },
        )
    }

    /** 手动重发一条「发送失败」的消息(气泡上点重试)。 */
    fun retryUpstream(messageId: String, sessionId: String) {
        val entry = pendingFrames.entries.firstOrNull { it.value.localMsgId == messageId } ?: return
        pendingFrames[entry.key] = entry.value.copy(attempts = 0)
        setStatus(DeliveryStatus.SENDING, messageId, sessionId)
        transmit(entry.key)
    }

    // MARK: - 可靠上行(待确认队列 + 超时重发 + 两段 ack)

    /** 一条等待确认的上行帧。重发用同一帧 id —— agent 端按 id 幂等去重。 */
    private data class PendingFrame(
        val text: String,           // 已序列化的帧原文
        val sessionId: String,
        val localMsgId: String?,    // 关联的本地回显消息(状态展示)
        val attempts: Int = 0,
    )

    private val pendingFrames: MutableMap<String, PendingFrame> = mutableMapOf()
    private val ackTimeouts: MutableMap<String, Job> = mutableMapOf()

    private fun sendReliable(t: String, id: String, sid: String, localMsgId: String?, body: JsonElement) {
        val text = frameText(t, id, sid, body)
        pendingFrames[id] = PendingFrame(text = text, sessionId = sid, localMsgId = localMsgId)
        transmit(id)
    }

    private fun transmit(frameId: String) {
        val p = pendingFrames[frameId] ?: return
        val next = p.copy(attempts = p.attempts + 1)
        pendingFrames[frameId] = next
        ws.sendRaw(next.text)
        scheduleAckTimeout(frameId, next.attempts)
    }

    /** 超时未收到 delivered ack → 重发(指数退避 5/10/20s);耗尽次数 → 标记失败。 */
    private fun scheduleAckTimeout(frameId: String, attempt: Int) {
        ackTimeouts[frameId]?.cancel()
        val delaySec = 5.0 * 2.0.pow((attempt - 1).toDouble())
        ackTimeouts[frameId] = viewModelScope.launch {
            delay((delaySec * 1000).toLong())
            if (!isActive) return@launch
            val p = pendingFrames[frameId] ?: return@launch
            if (p.attempts >= MAX_ATTEMPTS) {
                ackTimeouts.remove(frameId)
                p.localMsgId?.let { setStatus(DeliveryStatus.FAILED, it, p.sessionId) }
                // pendingFrames 保留,供手动重试
            } else {
                transmit(frameId)
            }
        }
    }

    /** 处理服务器/代理端回的 ack:server 级 → 单勾;delivered 级 → 双勾并出队。 */
    private fun applyAck(frame: Frame) {
        val body = frame.body ?: return
        val ackId = body["ack_id"]?.stringValue ?: return
        val p = pendingFrames[ackId] ?: return
        val stage = body["stage"]?.stringValue ?: "server"
        if (stage == "delivered") {
            ackTimeouts[ackId]?.cancel()
            ackTimeouts.remove(ackId)
            pendingFrames.remove(ackId)
            p.localMsgId?.let { setStatus(DeliveryStatus.DELIVERED, it, p.sessionId) }
        } else {
            p.localMsgId?.let { setStatus(DeliveryStatus.SENT, it, p.sessionId) }
        }
    }

    /** 重连认证成功后补发所有未确认的上行(重置重试次数)。 */
    private fun flushPending() {
        for (id in pendingFrames.keys.toList()) {
            pendingFrames[id]?.let { pendingFrames[id] = it.copy(attempts = 0) }
            transmit(id)
        }
    }

    private fun setStatus(status: DeliveryStatus, localMsgId: String, sessionId: String) {
        val sIdx = sessions.indexOfFirst { it.id == sessionId }
        if (sIdx < 0) return
        val mIdx = sessions[sIdx].messages.indexOfFirst { it.id == localMsgId }
        if (mIdx < 0) return
        val cur = sessions[sIdx].messages[mIdx]
        sessions[sIdx].messages[mIdx] = cur.copy(status = status)
    }

    // MARK: - 出站封装

    private fun frameText(t: String, id: String, sid: String?, body: JsonElement): String {
        val obj = buildJsonObject {
            put("v", 1)
            put("t", t)
            put("id", id)
            sid?.let { put("sid", it) }
            put("from", "client")
            put("body", body)
        }
        return obj.toString()
    }

    private fun sendFrame(t: String, id: String, sid: String?, body: JsonElement) {
        ws.sendRaw(frameText(t, id, sid, body))
    }

    companion object {
        private const val MAX_ATTEMPTS = 3

        /**
         * 连通性测试:握手成功即视为可达,返回是否可达与往返耗时。
         * 对位 iOS `RelayClient.testServer`(iOS 用 WS 协议 ping;OkHttp 以 onOpen 为准)。
         */
        suspend fun testServer(host: String, port: Int): Pair<Boolean, String> {
            val url = ServerConfig.buildURL(host, port) ?: return false to "地址无效"
            val http = OkHttpClient.Builder()
                .connectTimeout(5, TimeUnit.SECONDS)
                .build()
            val start = System.currentTimeMillis()
            return kotlinx.coroutines.withTimeoutOrNull(5_000) {
                kotlinx.coroutines.suspendCancellableCoroutine<Pair<Boolean, String>> { cont ->
                    val req = Request.Builder().url(url).build()
                    val socket = http.newWebSocket(req, object : WebSocketListener() {
                        override fun onOpen(webSocket: WebSocket, response: Response) {
                            val ms = maxOf(1L, System.currentTimeMillis() - start)
                            webSocket.cancel()
                            if (cont.isActive) cont.resumeWith(Result.success(true to "连通正常 · ${ms}ms"))
                        }

                        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                            if (cont.isActive) cont.resumeWith(Result.success(false to "无法连接"))
                        }
                    })
                    cont.invokeOnCancellation { socket.cancel() }
                }
            } ?: (false to "无法连接")
        }
    }
}

/** 透出一个不依赖 mutableStateOf 的瞬时值,给非 Compose 调用方读取(测试 / 调试)。 */
@Suppress("unused")
fun RelayClient.snapshotConnection(): ConnectionState = connection
