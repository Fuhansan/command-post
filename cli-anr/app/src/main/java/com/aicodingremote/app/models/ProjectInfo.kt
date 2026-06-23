package com.aicodingremote.app.models

/**
 * 一个项目(= VibeNotch 打开的工作目录)。首页「项目区」一行,点进去看它的会话。
 * 数据来自电脑端 `console:projects` 通道的结构化 `body.projects`。
 * 对位 iOS `ProjectInfo`。
 */
data class ProjectInfo(
    val workdir: String,                    // 工作目录(项目唯一键)
    val name: String,                       // 目录末段,做标题
    val history: List<ProjectHistory>,      // 该项目可恢复的历史会话(新→旧)
) {
    val id: String get() = workdir
}

/**
 * 项目下一条可恢复的历史会话(--resume 用)。对位 iOS `ProjectHistory`。
 */
data class ProjectHistory(
    val id: String,         // claude session_id
    val label: String,      // 首句摘要
)
