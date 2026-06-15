package com.aicodingremote.app.features.auth

import android.content.Context
import androidx.credentials.CredentialManager
import androidx.credentials.CustomCredential
import androidx.credentials.GetCredentialRequest
import androidx.credentials.exceptions.GetCredentialCancellationException
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AccountCircle
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material.icons.filled.Wifi
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.aicodingremote.app.app.LocalAppState
import com.aicodingremote.app.auth.GoogleSignInConfig
import com.aicodingremote.app.designsystem.Theme
import com.aicodingremote.app.designsystem.cardStyle
import com.aicodingremote.app.designsystem.darkFieldColors
import com.aicodingremote.app.designsystem.dismissKeyboardOnTap
import com.aicodingremote.app.networking.AuthAPI
import com.aicodingremote.app.networking.RelayClient
import com.aicodingremote.app.networking.ServerConfig
import com.google.android.libraries.identity.googleid.GetGoogleIdOption
import com.google.android.libraries.identity.googleid.GoogleIdTokenCredential
import com.google.android.libraries.identity.googleid.GoogleIdTokenParsingException
import kotlinx.coroutines.launch

/**
 * 登录页。账号体系:
 *   注册 = 用 Google 验证邮箱(只此一次,需能访问 Google),首次登录后设置密码;
 *   日常 = 邮箱 + 密码(只连自己的服务器,国内单 Tailscale 即可,不再碰 Google)。
 *
 * 对位 iOS `LoginView`:服务器常驻配置(IP+端口)→ 必须先「测试连接」测通才放开登录。
 */
@Composable
fun LoginScreen() {
    val appState = LocalAppState.current
    val context = androidx.compose.ui.platform.LocalContext.current
    val scope = rememberCoroutineScope()

    // 服务器配置(从 ServerConfig 读初值,对位 iOS @AppStorage 绑定 RelayClient.hostKey/portKey)。
    var host by rememberSaveable { mutableStateOf(ServerConfig.savedHost) }
    var portText by rememberSaveable { mutableStateOf(ServerConfig.savedPort.toString()) }
    var reachable by rememberSaveable { mutableStateOf(false) }
    var testing by rememberSaveable { mutableStateOf(false) }
    var serverMsg by rememberSaveable { mutableStateOf<String?>(null) }

    var account by rememberSaveable { mutableStateOf("") }
    var password by rememberSaveable { mutableStateOf("") }
    var loading by rememberSaveable { mutableStateOf(false) }
    var errorMessage by rememberSaveable { mutableStateOf<String?>(null) }

    // 首次 Google 登录后设密码
    var setPwToken by rememberSaveable { mutableStateOf<String?>(null) }
    var setPwAccount by rememberSaveable { mutableStateOf("") }
    var newPassword by rememberSaveable { mutableStateOf("") }
    var showSetPassword by rememberSaveable { mutableStateOf(false) }
    var setPwError by rememberSaveable { mutableStateOf<String?>(null) }

    val port = portText.toIntOrNull() ?: 0
    val serverValid = ServerConfig.sanitizeHost(host).isNotEmpty() && port in 1..65535
    val canLogin = reachable && account.trim().isNotEmpty() && password.length >= 4

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Theme.bg)
            .dismissKeyboardOnTap(),
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .systemBarsPadding()
                .verticalScroll(rememberScrollState())
                .padding(20.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(18.dp),
        ) {
            Spacer(Modifier.height(8.dp))
            Box(
                modifier = Modifier
                    .size(68.dp)
                    .background(
                        Brush.linearGradient(listOf(Theme.blueBtn, Theme.blueBtn.copy(alpha = 0.78f))),
                        RoundedCornerShape(20.dp),
                    ),
                contentAlignment = Alignment.Center,
            ) {
                Icon(Icons.Default.Terminal, contentDescription = null, tint = Color.White, modifier = Modifier.size(30.dp))
            }
            Text("AI Coding Remote", color = Theme.text, fontSize = 22.sp, fontWeight = FontWeight.Bold)

            ServerCard(
                host = host,
                portText = portText,
                reachable = reachable,
                testing = testing,
                serverMsg = serverMsg,
                serverValid = serverValid,
                onHostChange = { host = it; reachable = false; serverMsg = null },
                onPortChange = { portText = it.filter { c -> c.isDigit() }; reachable = false; serverMsg = null },
                onTest = {
                    if (testing || !serverValid) return@ServerCard
                    testing = true; serverMsg = null; reachable = false
                    val h = ServerConfig.sanitizeHost(host)
                    val p = port
                    scope.launch {
                        val (ok, msg) = RelayClient.testServer(host = h, port = p)
                        if (ok) {
                            ServerConfig.savedHost = h
                            ServerConfig.savedPort = p
                            reachable = true
                        }
                        serverMsg = if (ok) msg
                        else "✗ $msg —— 检查 IP/端口、电脑服务器是否运行、手机 Tailscale 是否连接"
                        testing = false
                    }
                },
            )

            LoginCard(
                account = account,
                password = password,
                loading = loading,
                reachable = reachable,
                canLogin = canLogin,
                onAccountChange = { account = it },
                onPasswordChange = { password = it },
                onLogin = {
                    if (!canLogin || loading) return@LoginCard
                    errorMessage = null; loading = true
                    val acc = account.trim()
                    val pwd = password
                    scope.launch {
                        try {
                            val r = AuthAPI.login(account = acc, password = pwd)
                            appState.login(account = r.account, token = r.token)
                        } catch (e: Throwable) {
                            errorMessage = e.message ?: "登录失败"
                        } finally {
                            loading = false
                        }
                    }
                },
                onGoogle = {
                    if (loading || !reachable) return@LoginCard
                    if (!GoogleSignInConfig.isConfigured) {
                        errorMessage = "Google 登录尚未配置:请在 GoogleSignInConfig 填入 Web Client ID 后启用"
                        return@LoginCard
                    }
                    errorMessage = null; loading = true
                    scope.launch {
                        try {
                            val idToken = requestGoogleIdToken(context)
                            val r = AuthAPI.loginWithGoogle(idToken)
                            if (r.hasPassword == "true") {
                                appState.login(account = r.account, token = r.token)
                            } else {
                                setPwToken = r.token
                                setPwAccount = r.account
                                newPassword = ""; setPwError = null
                                showSetPassword = true
                            }
                        } catch (e: GetCredentialCancellationException) {
                            // 用户取消账号选择时不显示错误,对齐 iOS 行为。
                        } catch (e: Throwable) {
                            errorMessage = e.message ?: "Google 登录失败"
                        } finally {
                            loading = false
                        }
                    }
                },
            )

            errorMessage?.let {
                Text(
                    it,
                    color = Theme.coral,
                    fontSize = 13.sp,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.fillMaxWidth(),
                )
            }
            Spacer(Modifier.height(12.dp))
        }
    }

    if (showSetPassword) {
        SetPasswordDialog(
            account = setPwAccount,
            newPassword = newPassword,
            loading = loading,
            error = setPwError,
            onPasswordChange = { newPassword = it },
            onConfirm = {
                val token = setPwToken ?: return@SetPasswordDialog
                if (newPassword.length < 4 || loading) return@SetPasswordDialog
                setPwError = null; loading = true
                val pwd = newPassword
                scope.launch {
                    try {
                        AuthAPI.setPassword(token = token, password = pwd)
                        showSetPassword = false
                        appState.login(account = setPwAccount, token = token)   // 设好即登录
                    } catch (e: Throwable) {
                        setPwError = e.message ?: "设置密码失败"
                    } finally {
                        loading = false
                    }
                }
            },
        )
    }
}

private suspend fun requestGoogleIdToken(context: Context): String {
    val option = GetGoogleIdOption.Builder()
        .setFilterByAuthorizedAccounts(false)
        .setServerClientId(GoogleSignInConfig.WEB_CLIENT_ID)
        .setAutoSelectEnabled(false)
        .build()
    val request = GetCredentialRequest.Builder()
        .addCredentialOption(option)
        .build()
    val result = CredentialManager.create(context).getCredential(
        context = context,
        request = request,
    )
    val credential = result.credential
    if (credential is CustomCredential &&
        credential.type == GoogleIdTokenCredential.TYPE_GOOGLE_ID_TOKEN_CREDENTIAL
    ) {
        return try {
            GoogleIdTokenCredential.createFrom(credential.data).idToken
        } catch (e: GoogleIdTokenParsingException) {
            throw IllegalStateException("未取得 Google 凭证,请重试", e)
        }
    }
    throw IllegalStateException("未取得 Google 凭证,请重试")
}

/** 中转服务器卡:IP + 端口两栏 + 测试连接按钮。 */
@Composable
private fun ServerCard(
    host: String,
    portText: String,
    reachable: Boolean,
    testing: Boolean,
    serverMsg: String?,
    serverValid: Boolean,
    onHostChange: (String) -> Unit,
    onPortChange: (String) -> Unit,
    onTest: () -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .cardStyle()
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Text(
            "中转服务器(电脑的局域网 / Tailscale IP)",
            color = Theme.textSec,
            fontSize = 13.sp,
            fontWeight = FontWeight.SemiBold,
        )
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            OutlinedTextField(
                value = host,
                onValueChange = onHostChange,
                modifier = Modifier.weight(1f),
                placeholder = { Text("IP,如 100.84.170.113", color = Theme.textTer) },
                singleLine = true,
                shape = RoundedCornerShape(10.dp),
                colors = darkFieldColors(),
                textStyle = androidx.compose.ui.text.TextStyle(fontFamily = FontFamily.Monospace, fontSize = 15.sp),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
            )
            OutlinedTextField(
                value = portText,
                onValueChange = onPortChange,
                modifier = Modifier.width(96.dp),
                placeholder = { Text("端口", color = Theme.textTer) },
                singleLine = true,
                shape = RoundedCornerShape(10.dp),
                colors = darkFieldColors(),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
            )
        }
        Button(
            onClick = onTest,
            enabled = !testing && serverValid,
            modifier = Modifier
                .fillMaxWidth()
                .height(44.dp),
            shape = RoundedCornerShape(10.dp),
            colors = ButtonDefaults.buttonColors(
                containerColor = if (reachable) Theme.green else Theme.blueBtn,
                contentColor = Color.White,
                disabledContainerColor = Theme.cardHi,
                disabledContentColor = Theme.textTer,
            ),
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                if (testing) {
                    CircularProgressIndicator(color = Color.White, strokeWidth = 2.dp, modifier = Modifier.size(14.dp))
                } else {
                    Icon(
                        if (reachable) Icons.Default.CheckCircle else Icons.Default.Wifi,
                        contentDescription = null,
                        modifier = Modifier.size(16.dp),
                    )
                }
                Text(
                    if (testing) "测试中…" else if (reachable) "连接正常" else "测试连接",
                    fontSize = 14.sp,
                    fontWeight = FontWeight.SemiBold,
                )
            }
        }
        serverMsg?.let {
            Text(it, color = if (reachable) Theme.green else Theme.coral, fontSize = 12.sp)
        }
    }
}

/** 登录卡:邮箱 + 密码 + 登录按钮 + Google 注册/设密码入口。 */
@Composable
private fun LoginCard(
    account: String,
    password: String,
    loading: Boolean,
    reachable: Boolean,
    canLogin: Boolean,
    onAccountChange: (String) -> Unit,
    onPasswordChange: (String) -> Unit,
    onLogin: () -> Unit,
    onGoogle: () -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .cardStyle()
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(
            "邮箱密码登录",
            color = Theme.textSec,
            fontSize = 14.sp,
            fontWeight = FontWeight.SemiBold,
            modifier = Modifier.fillMaxWidth(),
        )
        OutlinedTextField(
            value = account,
            onValueChange = onAccountChange,
            modifier = Modifier.fillMaxWidth(),
            placeholder = { Text("邮箱(注册时的 Google 邮箱)", color = Theme.textTer) },
            singleLine = true,
            shape = RoundedCornerShape(10.dp),
            colors = darkFieldColors(),
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email),
        )
        OutlinedTextField(
            value = password,
            onValueChange = onPasswordChange,
            modifier = Modifier.fillMaxWidth(),
            placeholder = { Text("密码", color = Theme.textTer) },
            singleLine = true,
            shape = RoundedCornerShape(10.dp),
            colors = darkFieldColors(),
            visualTransformation = PasswordVisualTransformation(),
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
        )

        Button(
            onClick = onLogin,
            enabled = canLogin && !loading,
            modifier = Modifier
                .fillMaxWidth()
                .height(50.dp),
            shape = RoundedCornerShape(12.dp),
            colors = ButtonDefaults.buttonColors(
                containerColor = Theme.blueBtn,
                contentColor = Color.White,
                disabledContainerColor = Theme.cardHi,
                disabledContentColor = Theme.textTer,
            ),
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                if (loading) {
                    CircularProgressIndicator(color = Color.White, strokeWidth = 2.dp, modifier = Modifier.size(16.dp))
                }
                Text("登录", fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
            }
        }

        if (!reachable) {
            Text("请先在上方测试连接到服务器", color = Theme.textTer, fontSize = 12.sp)
        }

        // 分隔:首次使用
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Box(Modifier.weight(1f).height(1.dp).background(Theme.stroke))
            Text("首次使用", color = Theme.textTer, fontSize = 12.sp)
            Box(Modifier.weight(1f).height(1.dp).background(Theme.stroke))
        }

        Button(
            onClick = onGoogle,
            enabled = !loading && reachable,
            modifier = Modifier
                .fillMaxWidth()
                .height(44.dp),
            shape = RoundedCornerShape(10.dp),
            colors = ButtonDefaults.buttonColors(
                containerColor = Theme.cardHi,
                contentColor = if (reachable) Theme.text else Theme.textTer,
                disabledContainerColor = Theme.cardHi,
                disabledContentColor = Theme.textTer,
            ),
            border = androidx.compose.foundation.BorderStroke(1.dp, Theme.stroke),
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Icon(Icons.Default.AccountCircle, contentDescription = null, modifier = Modifier.size(18.dp))
                Text("用 Google 注册 / 设置密码", fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
            }
        }
        Text(
            "用 Google 验证邮箱来创建账号(仅首次,需能访问 Google);设好密码后,以后用邮箱密码登录即可",
            color = Theme.textTer,
            fontSize = 11.sp,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

/** 首次 Google 登录后设密码弹窗(对位 iOS setPasswordSheet,不可点外侧关闭)。 */
@Composable
private fun SetPasswordDialog(
    account: String,
    newPassword: String,
    loading: Boolean,
    error: String?,
    onPasswordChange: (String) -> Unit,
    onConfirm: () -> Unit,
) {
    androidx.compose.ui.window.Dialog(
        onDismissRequest = { /* 不可手动关闭,必须设密码 */ },
        properties = androidx.compose.ui.window.DialogProperties(
            dismissOnBackPress = false,
            dismissOnClickOutside = false,
        ),
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .cardStyle(fill = Theme.bg)
                .padding(24.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text("设置密码", color = Theme.text, fontSize = 20.sp, fontWeight = FontWeight.Bold)
            Text(
                "账号 $account 验证成功。设置一个密码,以后用邮箱密码登录(不再需要 Google)。",
                color = Theme.textSec,
                fontSize = 14.sp,
            )
            OutlinedTextField(
                value = newPassword,
                onValueChange = onPasswordChange,
                modifier = Modifier.fillMaxWidth(),
                placeholder = { Text("新密码(至少 4 位)", color = Theme.textTer) },
                singleLine = true,
                shape = RoundedCornerShape(10.dp),
                colors = darkFieldColors(),
                visualTransformation = PasswordVisualTransformation(),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
            )
            error?.let { Text(it, color = Theme.coral, fontSize = 13.sp) }
            Button(
                onClick = onConfirm,
                enabled = newPassword.length >= 4 && !loading,
                modifier = Modifier
                    .fillMaxWidth()
                    .height(50.dp),
                shape = RoundedCornerShape(12.dp),
                colors = ButtonDefaults.buttonColors(
                    containerColor = Theme.blueBtn,
                    contentColor = Color.White,
                    disabledContainerColor = Theme.cardHi,
                    disabledContentColor = Theme.textTer,
                ),
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    if (loading) {
                        CircularProgressIndicator(color = Color.White, strokeWidth = 2.dp, modifier = Modifier.size(16.dp))
                    }
                    Text("设置密码并进入", fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
                }
            }
        }
    }
}
