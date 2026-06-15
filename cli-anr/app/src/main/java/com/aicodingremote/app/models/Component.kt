package com.aicodingremote.app.models

import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.add
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.UUID

/**
 * PROTOCOL §6 —— 交互组件携带的动作。
 */
data class ComponentAction(
    val id: String,
    val value: JsonElement?,
) {
    companion object {
        fun from(json: JsonElement?): ComponentAction? {
            val id = json?.get("id")?.stringValue ?: return null
            return ComponentAction(id, json["value"])
        }
    }
}

/**
 * PROTOCOL §5 —— 组件树节点。`type` 是自由字符串,未知类型在渲染层兜底(不在解码层报错)。
 *
 * [uid] 仅用于 Compose 的 `remember(key)` / `key()`,与协议无关。
 */
data class Component(
    val uid: String = UUID.randomUUID().toString(),
    val type: String,
    val cid: String?,
    val props: JsonElement,
    val children: List<Component>,
    val action: ComponentAction?,
) {
    companion object {
        fun from(json: JsonElement?): Component {
            if (json == null) {
                return Component(
                    type = "unknown",
                    cid = null,
                    props = JsonObject(emptyMap()),
                    children = emptyList(),
                    action = null,
                )
            }
            return Component(
                type = json["type"]?.stringValue ?: "unknown",
                cid = json["cid"]?.stringValue,
                props = json["props"] ?: JsonObject(emptyMap()),
                children = json["children"]?.arrayValue?.map { from(it) } ?: emptyList(),
                action = ComponentAction.from(json["action"]),
            )
        }
    }
}

/**
 * 暂存待发送的一张图片(已编码,可直接入帧/回显)。对位 iOS `StagedImagePayload`。
 */
data class StagedImagePayload(
    val data: String,   // base64 JPEG
    val ext: String,    // "jpg"
    val name: String,   // 展示文件名
    val kind: String,   // "JPEG"
    val size: String,   // "1.2 MB"
)

/**
 * 上行消息的投递状态(两段式 ack:服务器 → 代理端)。对位 iOS `DeliveryStatus`。
 */
enum class DeliveryStatus {
    SENDING,    // 已发出,未收到任何 ack
    SENT,       // 服务器已确认(单勾)
    DELIVERED,  // 电脑端已确认(双勾)
    FAILED,     // 重试耗尽,可手动重发
}

/**
 * PROTOCOL §5 —— 一条渲染用的富消息。由 `t: "ui"` 的 [Frame] 构造。
 */
data class UIMessage(
    val id: String,
    val seq: Int,
    val role: String, // agent | user | system
    val root: Component,
    val fallbackText: String?,
    val time: String? = null,                  // 消息时间(HH:mm,首次出现时刻,由 agent 下发)
    val status: DeliveryStatus? = null,        // 仅本地发出的消息有;agent 下发的为 null
    val upstreamId: String? = null,            // 对应的上行帧 id(重发/对账用)
) {
    companion object {
        fun from(frame: Frame): UIMessage? {
            if (frame.t !is FrameType.Ui) return null
            val id = frame.id ?: return null
            val body = frame.body ?: return null
            return UIMessage(
                id = id,
                seq = frame.seq ?: 0,
                role = body["role"]?.stringValue ?: "agent",
                root = Component.from(body["root"]),
                fallbackText = frame.fallbackText,
                time = body["time"]?.stringValue,
            )
        }

        /** 本地构造一条用户文本消息(用户在输入框发送时)。 */
        fun localUserText(text: String): UIMessage {
            val root = buildJsonObject {
                put("type", "text")
                putJsonObject("props") { put("text", text) }
            }
            return UIMessage(
                id = UUID.randomUUID().toString(),
                seq = Int.MAX_VALUE,
                role = "user",
                root = Component.from(root),
                fallbackText = text,
                time = hhmm(),
            )
        }

        /**
         * 本地构造一条图文消息(手机发送图片时的即时回显,与 agent 的 photomsg 同构)。
         */
        fun localUserImages(images: List<StagedImagePayload>, text: String): UIMessage {
            val root = buildJsonObject {
                put("type", "photomsg")
                putJsonObject("props") {
                    put("images", buildJsonArray {
                        images.forEach { img ->
                            add(buildJsonObject {
                                put("data", img.data)
                                put("name", img.name)
                                put("kind", img.kind)
                                put("size", img.size)
                            })
                        }
                    })
                    put("time", hhmm())
                    if (text.isNotEmpty()) put("text", text)
                }
            }
            return UIMessage(
                id = UUID.randomUUID().toString(),
                seq = Int.MAX_VALUE,
                role = "user",
                root = Component.from(root),
                fallbackText = if (text.isEmpty()) "图片" else text,
                time = hhmm(),
            )
        }

        private val hhmmFormat = SimpleDateFormat("HH:mm", Locale.getDefault())
        private fun hhmm(): String = hhmmFormat.format(Date())
    }
}
