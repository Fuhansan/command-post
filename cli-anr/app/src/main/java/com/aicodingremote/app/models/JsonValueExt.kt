package com.aicodingremote.app.models

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.longOrNull

/**
 * 协议里 `props`/`body` 这类「结构不固定」的字段统一用 [JsonElement] 承载。
 * 这是 SDUI 的关键:渲染器按需从中取值,取不到就用默认,永不因缺字段崩溃。
 *
 * 注:与 cli-ios 的 `JSONValue` 一一对应,但底层复用 kotlinx.serialization 的 [JsonElement]。
 */

/** 像 SwiftUI 那样的下标取值:对非对象返回 null。 */
operator fun JsonElement.get(key: String): JsonElement? =
    (this as? JsonObject)?.get(key)?.takeUnless { it is JsonNull }

val JsonElement.stringValue: String?
    get() = (this as? JsonPrimitive)?.takeIf { it.isString }?.content

val JsonElement.doubleValue: Double?
    get() = (this as? JsonPrimitive)?.doubleOrNull

val JsonElement.intValue: Int?
    get() = (this as? JsonPrimitive)?.intOrNull ?: doubleValue?.toInt()

val JsonElement.longValue: Long?
    get() = (this as? JsonPrimitive)?.longOrNull ?: doubleValue?.toLong()

val JsonElement.boolValue: Boolean?
    get() = (this as? JsonPrimitive)?.booleanOrNull

val JsonElement.arrayValue: List<JsonElement>?
    get() = (this as? JsonArray)

val JsonElement.objectValue: Map<String, JsonElement>?
    get() = (this as? JsonObject)

val JsonElement.isNull: Boolean
    get() = this is JsonNull

// MARK: - 便捷取值(取不到一律返回默认,不抛错)

fun JsonElement.string(key: String, default: String = ""): String =
    this[key]?.stringValue ?: default

fun JsonElement.bool(key: String, default: Boolean = false): Boolean =
    this[key]?.boolValue ?: default

fun JsonElement.double(key: String): Double? =
    this[key]?.doubleValue

fun JsonElement.int(key: String): Int? =
    this[key]?.intValue
