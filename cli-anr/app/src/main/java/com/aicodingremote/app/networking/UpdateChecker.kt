package com.aicodingremote.app.networking

import android.app.Application
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import com.aicodingremote.app.BuildConfig
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import okhttp3.OkHttpClient
import okhttp3.Request
import java.util.concurrent.TimeUnit

/**
 * 客户端版本检测:启动时 + 设置页手动触发。对位 iOS `UpdateChecker`。
 * 服务器 data/app-version.json 是唯一事实源:
 *   latest > 当前 → 弹更新公告(每个版本只弹一次,可稍后)
 *   minimum > 当前 → 强制更新,全屏拦截直到升级
 *
 * UI(ForceUpdateView / AnnouncementSheet)由渲染层移植,这里只提供状态与逻辑。
 */
class UpdateChecker(app: Application) : AndroidViewModel(app) {

    @Serializable
    data class VersionInfo(
        val latest: String,
        val minimum: String,
        val notes: String,
        val url: String,
    )

    sealed class Status {
        object Unknown : Status()
        object UpToDate : Status()
        data class UpdateAvailable(val info: VersionInfo) : Status()   // 可选更新(公告)
        data class ForceUpdate(val info: VersionInfo) : Status()       // 必须更新才能用
    }

    var status by mutableStateOf<Status>(Status.Unknown)
        private set

    /** 本次是否应弹公告(同一版本看过/点过稍后就不再弹;强更不受此限制)。 */
    var showAnnouncement by mutableStateOf(false)

    private val prefs = app.getSharedPreferences(PREFS, Application.MODE_PRIVATE)
    private val json = Json { ignoreUnknownKeys = true }

    private val http: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(10, TimeUnit.SECONDS)
        .build()

    /** 启动时静默检查;手动检查时 manual=true(无新版本也要给反馈)。 */
    suspend fun check(manual: Boolean = false) {
        val url = "${ServerConfig.restBaseURL()}/api/app/version"
        try {
            val raw = withContext(Dispatchers.IO) {
                val req = Request.Builder().url(url).build()
                http.newCall(req).execute().use { resp ->
                    if (!resp.isSuccessful) error("HTTP ${resp.code}")
                    resp.body?.string() ?: error("empty body")
                }
            }
            val info = json.decodeFromString(VersionInfo.serializer(), raw)
            apply(info, manual)
        } catch (_: Throwable) {
            if (manual) status = Status.Unknown
        }
    }

    private fun apply(info: VersionInfo, manual: Boolean) {
        val cur = currentVersion
        if (older(cur, info.minimum)) {
            status = Status.ForceUpdate(info)
            return
        }
        if (older(cur, info.latest)) {
            status = Status.UpdateAvailable(info)
            val seenKey = "announce.seen.${info.latest}"
            if (manual || !prefs.getBoolean(seenKey, false)) {
                prefs.edit().putBoolean(seenKey, true).apply()
                showAnnouncement = true
            }
        } else {
            status = Status.UpToDate
        }
    }

    companion object {
        private const val PREFS = "update_checker"

        /** 当前版本号(平台标识在握手/上报处用 "android")。 */
        val currentVersion: String get() = BuildConfig.VERSION_NAME

        /** 语义化版本比较:a < b ? */
        fun older(a: String, b: String): Boolean {
            val pa = a.split(".").map { it.toIntOrNull() ?: 0 }
            val pb = b.split(".").map { it.toIntOrNull() ?: 0 }
            for (i in 0 until maxOf(pa.size, pb.size)) {
                val x = pa.getOrElse(i) { 0 }
                val y = pb.getOrElse(i) { 0 }
                if (x != y) return x < y
            }
            return false
        }
    }
}
