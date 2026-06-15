package com.aicodingremote.app.models

/**
 * 一个在线的电脑代理(会话入口)。
 * 对位 iOS `AgentInfo`,PROTOCOL §8.1 `auth_ok.agents`。
 */
data class AgentInfo(
    val id: String,
    val name: String,
    val online: Boolean,
    val suspended: Boolean = false,  // 被手机端「断开」挂起,可点重连恢复
    val resuming: Boolean = false,   // 已点「重连」,等待电脑回连(≤10s 探测周期)
)
