package com.aicodingremote.app.models

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject

/**
 * PROTOCOL §4 —— Frame 类型。未知类型走 [Unknown],解码不抛错(原则 2)。
 */
sealed class FrameType {
    object Auth : FrameType()
    object AuthOk : FrameType()
    object AuthErr : FrameType()
    object Presence : FrameType()
    object Ui : FrameType()
    object Patch : FrameType()
    object Action : FrameType()
    object Input : FrameType()
    object Ack : FrameType()
    object Ping : FrameType()
    object Pong : FrameType()
    object Resume : FrameType()
    object Error : FrameType()
    data class Unknown(val raw: String) : FrameType()

    val wireValue: String
        get() = when (this) {
            Auth -> "auth"
            AuthOk -> "auth_ok"
            AuthErr -> "auth_err"
            Presence -> "presence"
            Ui -> "ui"
            Patch -> "patch"
            Action -> "action"
            Input -> "input"
            Ack -> "ack"
            Ping -> "ping"
            Pong -> "pong"
            Resume -> "resume"
            Error -> "error"
            is Unknown -> raw
        }

    companion object {
        fun from(raw: String): FrameType = when (raw) {
            "auth" -> Auth
            "auth_ok" -> AuthOk
            "auth_err" -> AuthErr
            "presence" -> Presence
            "ui" -> Ui
            "patch" -> Patch
            "action" -> Action
            "input" -> Input
            "ack" -> Ack
            "ping" -> Ping
            "pong" -> Pong
            "resume" -> Resume
            "error" -> Error
            else -> Unknown(raw)
        }
    }
}

/**
 * PROTOCOL §3 —— 统一信封。字段尽量可选,缺字段不崩(原则 2)。
 */
data class Frame(
    val v: Int?,
    val t: FrameType,
    val id: String?,
    val sid: String?,
    val seq: Int?,
    val ts: Long?,
    val from: String?,
    val fallbackText: String?,
    val body: JsonElement?,
) {
    companion object {
        private val json = Json {
            ignoreUnknownKeys = true
            isLenient = true
            coerceInputValues = true
        }

        fun decode(text: String): Frame? {
            return try {
                val root = json.parseToJsonElement(text)
                if (root !is JsonObject) return null
                Frame(
                    v = root["v"]?.intValue,
                    t = FrameType.from(root["t"]?.stringValue ?: ""),
                    id = root["id"]?.stringValue,
                    sid = root["sid"]?.stringValue,
                    seq = root["seq"]?.intValue,
                    ts = root["ts"]?.longValue,
                    from = root["from"]?.stringValue,
                    fallbackText = root["fallbackText"]?.stringValue,
                    body = root["body"],
                )
            } catch (_: Throwable) {
                null
            }
        }
    }
}
