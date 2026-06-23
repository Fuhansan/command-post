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
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowLeft
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
import androidx.compose.material3.TextButton
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
 * 登录页(分步流程,仿 App Store)。账号体系:
 *   注册 = 邮箱验证码(国内 SMTP 必通,无需 Google);Google 登录可选,首次后落地设密码
 *   日常 = 邮箱密码(默认) 或 验证码登录
 *   忘记密码 = 邮箱验证码重置
 *
 * 对位 iOS `LoginView`:输入邮箱 → check() 分流到 password / setPassword / code(login)。
 */
@Composable
fun LoginScreen() {
    val appState = LocalAppState.current
    val context = androidx.compose.ui.platform.LocalContext.current
    val scope = rememberCoroutineScope()

    // 服务器配置(对位 iOS @AppStorage 绑定 RelayClient.hostKey/portKey)
    var host by rememberSaveable { mutableStateOf(ServerConfig.savedHost) }
    var portText by rememberSaveable { mutableStateOf(ServerConfig.savedPort.toString()) }
    var reachable by rememberSaveable { mutableStateOf(false) }
    var testing by rememberSaveable { mutableStateOf(false) }
    var serverMsg by rememberSaveable { mutableStateOf<String?>(null) }

    // 主流程
    var account by rememberSaveable { mutableStateOf("") }
    var password by rememberSaveable { mutableStateOf("") }
    var code by rememberSaveable { mutableStateOf("") }
    var loading by rememberSaveable { mutableStateOf(false) }
    var errorMessage by rememberSaveable { mutableStateOf<String?>(null) }
    var checking by rememberSaveable { mutableStateOf(false) }      // 邮箱 check 中
    var codeSending by rememberSaveable { mutableStateOf(false) }   // 发码中

    var loginStep by rememberSaveable { mutableStateOf(Step.EMAIL) }
    var codeFor by rememberSaveable { mutableStateOf(CodeFor.LOGIN) }

    // 首次 Google 登录后设密码
    var setPwToken by rememberSaveable { mutableStateOf<String?>(null) }
    var setPwAccount by rememberSaveable { mutableStateOf("") }
    var newPassword by rememberSaveable { mutableStateOf("") }
    var showSetPassword by rememberSaveable { mutableStateOf(false) }
    var setPwError by rememberSaveable { mutableStateOf<String?>(null) }

    // 忘记密码弹层
    var showReset by rememberSaveable { mutableStateOf(false) }
    var resetAccount by rememberSaveable { mutableStateOf("") }
    var resetCode by rememberSaveable { mutableStateOf("") }
    var resetNewPassword by rememberSaveable { mutableStateOf("") }
    var resetSending by rememberSaveable { mutableStateOf(false) }
    var resetStep by rememberSaveable { mutableStateOf(Step.EMAIL) }
    var resetError by rememberSaveable { mutableStateOf<String?>(null) }
    var resetInfo by rememberSaveable { mutableStateOf<String?>(null) }

    val port = portText.toIntOrNull() ?: 0
    val serverValid = ServerConfig.sanitizeHost(host).isNotEmpty() && port in 1..65535
    fun isEmail(s: String) = s.trim().contains("@")
    val canLogin = reachable && account.trim().isNotEmpty() && password.length >= 4
    val canSendReset = reachable && resetAccount.trim().contains("@")

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
                step = loginStep,
                codeFor = codeFor,
                account = account,
                password = password,
                code = code,
                reachable = reachable,
                loading = loading,
                checking = checking,
                codeSending = codeSending,
                canLogin = canLogin,
                onAccountChange = { account = it },
                onPasswordChange = { password = it },
                onCodeChange = { code = it.filter { c -> c.isDigit() }.take(8) },

                onProceedEmail = {
                    if (!reachable || !isEmail(account) || checking) return@LoginCard
                    errorMessage = null; checking = true
                    val acc = account.trim()
                    scope.launch {
                        try {
                            val r = AuthAPI.check(acc)
                            when {
                                !r.exists -> { password = ""; loginStep = Step.SET_PASSWORD }
                                r.hasPassword -> { password = ""; loginStep = Step.PASSWORD }
                                else -> {
                                    // 已注册但无密码(如 Google 建的)→ 直接走验证码登录
                                    codeFor = CodeFor.LOGIN
                                    AuthAPI.loginCode(acc)
                                    code = ""; loginStep = Step.CODE
                                }
                            }
                        } catch (e: Throwable) {
                            errorMessage = e.message ?: "检查失败"
                        } finally {
                            checking = false
                        }
                    }
                },

                onLogin = {
                    if (!canLogin || loading) return@LoginCard
                    errorMessage = null; loading = true
                    val acc = account.trim()
                    val pwd = password
                    scope.launch {
                        try {
                            val r = AuthAPI.login(acc, pwd)
                            appState.login(account = r.account, token = r.token)
                        } catch (e: Throwable) {
                            errorMessage = e.message ?: "登录失败"
                        } finally {
                            loading = false
                        }
                    }
                },

                onSwitchToCodeLogin = {
                    if (codeSending) return@LoginCard
                    errorMessage = null; codeSending = true
                    val acc = account.trim()
                    scope.launch {
                        try {
                            AuthAPI.loginCode(acc)
                            codeFor = CodeFor.LOGIN; code = ""
                            loginStep = Step.CODE
                        } catch (e: Throwable) {
                            errorMessage = e.message ?: "发送失败"
                        } finally {
                            codeSending = false
                        }
                    }
                },

                onOpenReset = {
                    resetAccount = account.trim()
                    resetCode = ""; resetNewPassword = ""
                    resetInfo = null; resetError = null
                    resetStep = Step.EMAIL
                    showReset = true
                },

                onSendRegisterCode = {
                    if (password.length < 4 || codeSending) return@LoginCard
                    errorMessage = null; codeSending = true
                    val acc = account.trim()
                    scope.launch {
                        try {
                            AuthAPI.registerCode(acc)
                            codeFor = CodeFor.REGISTER; code = ""
                            loginStep = Step.CODE
                        } catch (e: Throwable) {
                            errorMessage = e.message ?: "发送失败"
                        } finally {
                            codeSending = false
                        }
                    }
                },

                onSubmitCode = {
                    if (code.trim().length < 4 || loading) return@LoginCard
                    errorMessage = null; loading = true
                    val acc = account.trim()
                    val c = code.trim()
                    val pwd = password
                    scope.launch {
                        try {
                            val r = if (codeFor == CodeFor.REGISTER) {
                                AuthAPI.register(account = acc, code = c, password = pwd)
                            } else {
                                AuthAPI.loginVerify(account = acc, code = c)
                            }
                            appState.login(account = r.account, token = r.token)
                        } catch (e: Throwable) {
                            errorMessage = e.message ?: "登录失败"
                        } finally {
                            loading = false
                        }
                    }
                },

                onResendCode = {
                    if (codeSending) return@LoginCard
                    errorMessage = null; codeSending = true
                    val acc = account.trim()
                    scope.launch {
                        try {
                            if (codeFor == CodeFor.REGISTER) AuthAPI.registerCode(acc)
                            else AuthAPI.loginCode(acc)
                        } catch (e: Throwable) {
                            errorMessage = e.message ?: "发送失败"
                        } finally {
                            codeSending = false
                        }
                    }
                },

                onBackToEmail = {
                    loginStep = Step.EMAIL
                    password = ""; code = ""; errorMessage = null
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
                            // 用户取消账号选择 — 静默
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
                        appState.login(account = setPwAccount, token = token)
                    } catch (e: Throwable) {
                        setPwError = e.message ?: "设置密码失败"
                    } finally {
                        loading = false
                    }
                }
            },
        )
    }

    if (showReset) {
        ResetPasswordDialog(
            step = resetStep,
            account = resetAccount,
            code = resetCode,
            newPassword = resetNewPassword,
            sending = resetSending,
            loading = loading,
            canSend = canSendReset,
            info = resetInfo,
            error = resetError,
            onAccountChange = { resetAccount = it; resetError = null },
            onCodeChange = { resetCode = it.filter { c -> c.isDigit() }.take(8); resetError = null },
            onNewPasswordChange = { resetNewPassword = it; resetError = null },
            onSendCode = {
                if (!canSendReset || resetSending) return@ResetPasswordDialog
                resetError = null; resetInfo = null; resetSending = true
                val acc = resetAccount.trim()
                scope.launch {
                    try {
                        AuthAPI.forgotPassword(acc)
                        if (resetStep == Step.EMAIL) resetStep = Step.CODE
                    } catch (e: Throwable) {
                        resetError = e.message ?: "发送失败"
                    } finally {
                        resetSending = false
                    }
                }
            },
            onNextFromCode = {
                if (resetCode.trim().length < 4) return@ResetPasswordDialog
                resetError = null
                resetStep = Step.PASSWORD
            },
            onConfirmReset = {
                if (resetNewPassword.length < 4 || loading) return@ResetPasswordDialog
                resetError = null; resetInfo = null; loading = true
                val acc = resetAccount.trim()
                val c = resetCode.trim()
                val pwd = resetNewPassword
                scope.launch {
                    try {
                        AuthAPI.resetPassword(account = acc, code = c, password = pwd)
                        showReset = false
                        account = acc; password = ""; loginStep = Step.PASSWORD
                        errorMessage = "密码已重置,请用新密码登录"
                    } catch (e: Throwable) {
                        resetError = e.message ?: "重置失败"
                    } finally {
                        loading = false
                    }
                }
            },
            onBackFromCode = {
                resetStep = Step.EMAIL
                resetCode = ""
                resetError = null
            },
            onBackFromPassword = {
                resetStep = Step.CODE
                resetError = null
            },
            onCancel = { showReset = false },
        )
    }
}

/** 分步流程(对位 iOS LoginView.Step):email → password / setPassword / code。 */
enum class Step { EMAIL, PASSWORD, SET_PASSWORD, CODE }

/** 验证码用途(对位 iOS LoginView.CodeFor):决定 submitCode 走 register 还是 loginVerify。 */
enum class CodeFor { REGISTER, LOGIN }

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

/** 中转服务器卡:IP + 端口 + 测试连接。 */
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
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
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

/**
 * 登录卡:按 step 切换 — 邮箱 → 密码 / 设密码 / 验证码。
 * 对位 iOS LoginView.loginCard。
 */
@Composable
private fun LoginCard(
    step: Step,
    codeFor: CodeFor,
    account: String,
    password: String,
    code: String,
    reachable: Boolean,
    loading: Boolean,
    checking: Boolean,
    codeSending: Boolean,
    canLogin: Boolean,
    onAccountChange: (String) -> Unit,
    onPasswordChange: (String) -> Unit,
    onCodeChange: (String) -> Unit,
    onProceedEmail: () -> Unit,
    onLogin: () -> Unit,
    onSwitchToCodeLogin: () -> Unit,
    onOpenReset: () -> Unit,
    onSendRegisterCode: () -> Unit,
    onSubmitCode: () -> Unit,
    onResendCode: () -> Unit,
    onBackToEmail: () -> Unit,
    onGoogle: () -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .cardStyle()
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        when (step) {
            Step.EMAIL -> EmailStep(
                account = account,
                reachable = reachable,
                checking = checking,
                onAccountChange = onAccountChange,
                onNext = onProceedEmail,
                onGoogle = onGoogle,
            )
            Step.PASSWORD -> PasswordStep(
                account = account,
                password = password,
                loading = loading,
                codeSending = codeSending,
                canLogin = canLogin,
                onPasswordChange = onPasswordChange,
                onLogin = onLogin,
                onSwitchToCodeLogin = onSwitchToCodeLogin,
                onForgot = onOpenReset,
                onBack = onBackToEmail,
            )
            Step.SET_PASSWORD -> SetPasswordStep(
                account = account,
                password = password,
                codeSending = codeSending,
                onPasswordChange = onPasswordChange,
                onNext = onSendRegisterCode,
                onBack = onBackToEmail,
            )
            Step.CODE -> CodeStep(
                account = account,
                code = code,
                codeFor = codeFor,
                loading = loading,
                codeSending = codeSending,
                onCodeChange = onCodeChange,
                onSubmit = onSubmitCode,
                onResend = onResendCode,
                onBack = onBackToEmail,
            )
        }
    }
}

@Composable
private fun EmailStep(
    account: String,
    reachable: Boolean,
    checking: Boolean,
    onAccountChange: (String) -> Unit,
    onNext: () -> Unit,
    onGoogle: () -> Unit,
) {
    fun isEmail(s: String) = s.trim().contains("@")
    Text(
        "登录 / 注册",
        color = Theme.text,
        fontSize = 15.sp,
        fontWeight = FontWeight.SemiBold,
        modifier = Modifier.fillMaxWidth(),
    )
    Text(
        "输入邮箱继续。新邮箱将创建账号,已有账号可用密码或验证码登录。",
        color = Theme.textTer,
        fontSize = 12.sp,
    )
    OutlinedTextField(
        value = account,
        onValueChange = onAccountChange,
        modifier = Modifier.fillMaxWidth(),
        placeholder = { Text("邮箱", color = Theme.textTer) },
        singleLine = true,
        shape = RoundedCornerShape(10.dp),
        colors = darkFieldColors(),
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email),
    )
    PrimaryButton(
        text = if (checking) "请稍候…" else "下一步",
        loading = checking,
        enabled = reachable && isEmail(account) && !checking,
        onClick = onNext,
    )
    if (!reachable) {
        Text(
            "请先在上方测试连接到服务器",
            color = Theme.textTer,
            fontSize = 12.sp,
        )
    }
    // 分隔 + Google 一键
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Box(Modifier.weight(1f).height(1.dp).background(Theme.stroke))
        Text("或", color = Theme.textTer, fontSize = 12.sp)
        Box(Modifier.weight(1f).height(1.dp).background(Theme.stroke))
    }
    Button(
        onClick = onGoogle,
        enabled = reachable && !checking,
        modifier = Modifier.fillMaxWidth().height(44.dp),
        shape = RoundedCornerShape(10.dp),
        colors = ButtonDefaults.buttonColors(
            containerColor = Theme.cardHi,
            contentColor = if (reachable) Theme.text else Theme.textTer,
            disabledContainerColor = Theme.cardHi,
            disabledContentColor = Theme.textTer,
        ),
        border = androidx.compose.foundation.BorderStroke(1.dp, Theme.stroke),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Icon(Icons.Default.AccountCircle, contentDescription = null, modifier = Modifier.size(18.dp))
            Text("Google 登录", fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
        }
    }
}

@Composable
private fun PasswordStep(
    account: String,
    password: String,
    loading: Boolean,
    codeSending: Boolean,
    canLogin: Boolean,
    onPasswordChange: (String) -> Unit,
    onLogin: () -> Unit,
    onSwitchToCodeLogin: () -> Unit,
    onForgot: () -> Unit,
    onBack: () -> Unit,
) {
    AccountHeader(email = account, onBack = onBack)
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
    PrimaryButton(text = "登录", loading = loading, enabled = canLogin && !loading, onClick = onLogin)
    Row(modifier = Modifier.fillMaxWidth()) {
        TextButton(onClick = onSwitchToCodeLogin, enabled = !codeSending) {
            Text(
                if (codeSending) "发送中…" else "用验证码登录",
                color = if (codeSending) Theme.textTer else Theme.blue,
                fontSize = 13.sp,
            )
        }
        Spacer(Modifier.weight(1f))
        TextButton(onClick = onForgot) {
            Text("忘记密码?", color = Theme.blue, fontSize = 13.sp)
        }
    }
}

@Composable
private fun SetPasswordStep(
    account: String,
    password: String,
    codeSending: Boolean,
    onPasswordChange: (String) -> Unit,
    onNext: () -> Unit,
    onBack: () -> Unit,
) {
    AccountHeader(email = account, onBack = onBack)
    Text(
        "新邮箱,创建账号。设置登录密码,下一步用验证码验证邮箱。",
        color = Theme.textSec,
        fontSize = 13.sp,
    )
    OutlinedTextField(
        value = password,
        onValueChange = onPasswordChange,
        modifier = Modifier.fillMaxWidth(),
        placeholder = { Text("设置密码(至少 4 位)", color = Theme.textTer) },
        singleLine = true,
        shape = RoundedCornerShape(10.dp),
        colors = darkFieldColors(),
        visualTransformation = PasswordVisualTransformation(),
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
    )
    PrimaryButton(
        text = if (codeSending) "发送中…" else "下一步",
        loading = codeSending,
        enabled = password.length >= 4 && !codeSending,
        onClick = onNext,
    )
}

@Composable
private fun CodeStep(
    account: String,
    code: String,
    codeFor: CodeFor,
    loading: Boolean,
    codeSending: Boolean,
    onCodeChange: (String) -> Unit,
    onSubmit: () -> Unit,
    onResend: () -> Unit,
    onBack: () -> Unit,
) {
    AccountHeader(email = account, onBack = onBack)
    Text(
        if (codeFor == CodeFor.REGISTER)
            "验证码已发到 $account,验证邮箱后即创建账号并登录。"
        else
            "验证码已发到 $account,请查收(可能在垃圾箱)。",
        color = Theme.textSec,
        fontSize = 13.sp,
    )
    OutlinedTextField(
        value = code,
        onValueChange = onCodeChange,
        modifier = Modifier.fillMaxWidth(),
        placeholder = { Text("6 位验证码", color = Theme.textTer) },
        singleLine = true,
        shape = RoundedCornerShape(10.dp),
        colors = darkFieldColors(),
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
    )
    PrimaryButton(
        text = if (codeFor == CodeFor.REGISTER) "注册并登录" else "登录",
        loading = loading,
        enabled = code.trim().length >= 4 && !loading,
        onClick = onSubmit,
    )
    TextButton(
        onClick = onResend,
        enabled = !codeSending,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Text(
            if (codeSending) "发送中…" else "重新发送验证码",
            color = if (codeSending) Theme.textTer else Theme.blue,
            fontSize = 13.sp,
        )
    }
}

/** 分步流程顶部的「‹ 邮箱  更改」可点返回行。对位 iOS `accountHeader`。 */
@Composable
private fun AccountHeader(email: String, onBack: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .height(28.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        TextButton(onClick = onBack, contentPadding = androidx.compose.foundation.layout.PaddingValues(0.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                Icon(
                    Icons.AutoMirrored.Filled.KeyboardArrowLeft,
                    contentDescription = null,
                    tint = Theme.textSec,
                    modifier = Modifier.size(16.dp),
                )
                Text(email, color = Theme.textSec, fontSize = 14.sp, fontWeight = FontWeight.Medium, maxLines = 1)
                Spacer(Modifier.width(6.dp))
                Text("更改", color = Theme.blue, fontSize = 12.sp)
            }
        }
    }
}

/** 主操作按钮的统一样式(蓝底白字,可带 loading)。对位 iOS `primaryLabel`。 */
@Composable
private fun PrimaryButton(text: String, loading: Boolean, enabled: Boolean, onClick: () -> Unit) {
    Button(
        onClick = onClick,
        enabled = enabled,
        modifier = Modifier.fillMaxWidth().height(50.dp),
        shape = RoundedCornerShape(12.dp),
        colors = ButtonDefaults.buttonColors(
            containerColor = Theme.blueBtn,
            contentColor = Color.White,
            disabledContainerColor = Theme.cardHi,
            disabledContentColor = Theme.textTer,
        ),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            if (loading) {
                CircularProgressIndicator(color = Color.White, strokeWidth = 2.dp, modifier = Modifier.size(16.dp))
            }
            Text(text, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
        }
    }
}

/** 首次 Google 登录后设密码弹窗。 */
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
        onDismissRequest = { /* 必须设密码 */ },
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
            PrimaryButton(
                text = "设置密码并进入",
                loading = loading,
                enabled = newPassword.length >= 4 && !loading,
                onClick = onConfirm,
            )
        }
    }
}

/** 忘记密码弹层(三步:输入邮箱 → 发码 → 验码 → 设新密码)。对位 iOS `resetSheet`。 */
@Composable
private fun ResetPasswordDialog(
    step: Step,
    account: String,
    code: String,
    newPassword: String,
    sending: Boolean,
    loading: Boolean,
    canSend: Boolean,
    info: String?,
    error: String?,
    onAccountChange: (String) -> Unit,
    onCodeChange: (String) -> Unit,
    onNewPasswordChange: (String) -> Unit,
    onSendCode: () -> Unit,
    onNextFromCode: () -> Unit,
    onConfirmReset: () -> Unit,
    onBackFromCode: () -> Unit,
    onBackFromPassword: () -> Unit,
    onCancel: () -> Unit,
) {
    androidx.compose.ui.window.Dialog(onDismissRequest = onCancel) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .cardStyle(fill = Theme.bg)
                .padding(24.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text("重置密码", color = Theme.text, fontSize = 20.sp, fontWeight = FontWeight.Bold)

            when (step) {
                Step.EMAIL -> {
                    Text(
                        "输入注册邮箱,我们会把验证码发到该邮箱。",
                        color = Theme.textSec,
                        fontSize = 14.sp,
                    )
                    OutlinedTextField(
                        value = account,
                        onValueChange = onAccountChange,
                        modifier = Modifier.fillMaxWidth(),
                        placeholder = { Text("邮箱", color = Theme.textTer) },
                        singleLine = true,
                        shape = RoundedCornerShape(10.dp),
                        colors = darkFieldColors(),
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email),
                    )
                    PrimaryButton(
                        text = if (sending) "发送中…" else "发送验证码",
                        loading = sending,
                        enabled = canSend && !sending,
                        onClick = onSendCode,
                    )
                }
                Step.CODE -> {
                    AccountHeader(email = account, onBack = onBackFromCode)
                    Text(
                        "验证码已发到 $account,请查收(可能在垃圾箱)。",
                        color = Theme.textSec,
                        fontSize = 13.sp,
                    )
                    OutlinedTextField(
                        value = code,
                        onValueChange = onCodeChange,
                        modifier = Modifier.fillMaxWidth(),
                        placeholder = { Text("6 位验证码", color = Theme.textTer) },
                        singleLine = true,
                        shape = RoundedCornerShape(10.dp),
                        colors = darkFieldColors(),
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    )
                    PrimaryButton(
                        text = "下一步",
                        loading = false,
                        enabled = code.trim().length >= 4,
                        onClick = onNextFromCode,
                    )
                    TextButton(
                        onClick = onSendCode,
                        enabled = !sending,
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Text(
                            if (sending) "发送中…" else "重新发送验证码",
                            color = if (sending) Theme.textTer else Theme.blue,
                            fontSize = 13.sp,
                        )
                    }
                }
                Step.PASSWORD -> {
                    AccountHeader(email = account, onBack = onBackFromPassword)
                    Text("设置新密码,完成重置。", color = Theme.textSec, fontSize = 14.sp)
                    OutlinedTextField(
                        value = newPassword,
                        onValueChange = onNewPasswordChange,
                        modifier = Modifier.fillMaxWidth(),
                        placeholder = { Text("新密码(至少 4 位)", color = Theme.textTer) },
                        singleLine = true,
                        shape = RoundedCornerShape(10.dp),
                        colors = darkFieldColors(),
                        visualTransformation = PasswordVisualTransformation(),
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                    )
                    PrimaryButton(
                        text = "重置密码",
                        loading = loading,
                        enabled = newPassword.length >= 4 && !loading,
                        onClick = onConfirmReset,
                    )
                }
                Step.SET_PASSWORD -> Unit   // 重置流程不用此步
            }

            info?.let { Text(it, color = Theme.green, fontSize = 13.sp) }
            error?.let { Text(it, color = Theme.coral, fontSize = 13.sp) }

            TextButton(onClick = onCancel, modifier = Modifier.fillMaxWidth()) {
                Text("取消", color = Theme.textSec, fontSize = 14.sp)
            }
        }
    }
}
