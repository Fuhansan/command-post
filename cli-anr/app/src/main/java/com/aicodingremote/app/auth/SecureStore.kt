package com.aicodingremote.app.auth

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

/**
 * 登录 token / 账号的安全存储。
 * 对位 iOS 的 [KeychainStore],底层用 [EncryptedSharedPreferences];
 * 若 Keystore 在某些定制 ROM / 模拟器上不可用,降级到普通 SharedPreferences,
 * 避免登录链路在边角设备上整体崩坏。
 */
class SecureStore(context: Context) {
    private val prefs: SharedPreferences = createPrefs(context.applicationContext)

    fun token(): String? = prefs.getString(KEY_TOKEN, null)
    fun saveToken(value: String) = prefs.edit().putString(KEY_TOKEN, value).apply()
    fun clearToken() = prefs.edit().remove(KEY_TOKEN).apply()

    fun account(): String? = prefs.getString(KEY_ACCOUNT, null)
    fun saveAccount(value: String) = prefs.edit().putString(KEY_ACCOUNT, value).apply()
    fun clearAccount() = prefs.edit().remove(KEY_ACCOUNT).apply()

    private fun createPrefs(ctx: Context): SharedPreferences = try {
        val mk = MasterKey.Builder(ctx)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()
        EncryptedSharedPreferences.create(
            ctx,
            FILE_SECURE,
            mk,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )
    } catch (t: Throwable) {
        Log.w("SecureStore", "EncryptedSharedPreferences unavailable, falling back to plain prefs", t)
        ctx.getSharedPreferences(FILE_FALLBACK, Context.MODE_PRIVATE)
    }

    private companion object {
        const val KEY_TOKEN = "auth_token"
        const val KEY_ACCOUNT = "relay_account"
        const val FILE_SECURE = "secure_store"
        const val FILE_FALLBACK = "secure_store_plain"
    }
}
