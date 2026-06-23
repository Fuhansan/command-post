package com.aicodingremote.app.features.tasks

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.util.Base64
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Chat
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowLeft
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Cancel
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.MoreHoriz
import androidx.compose.material.icons.filled.PhotoCamera
import androidx.compose.material.icons.filled.PhotoLibrary
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.aicodingremote.app.app.LocalOnComponentAction
import com.aicodingremote.app.app.LocalRelayClient
import com.aicodingremote.app.designsystem.Theme
import com.aicodingremote.app.designsystem.cardStyle
import com.aicodingremote.app.designsystem.darkFieldColors
import com.aicodingremote.app.models.ComponentAction
import com.aicodingremote.app.models.DeliveryStatus
import com.aicodingremote.app.models.StagedImagePayload
import com.aicodingremote.app.models.CLIKind
import com.aicodingremote.app.models.UIMessage
import com.aicodingremote.app.networking.ImageAPI
import com.aicodingremote.app.networking.RelaySession
import com.aicodingremote.app.rendering.ComponentView
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import kotlinx.coroutines.launch
import com.aicodingremote.app.rendering.renderers.AvatarStyle
import com.aicodingremote.app.rendering.renderers.MessageAvatar
import com.aicodingremote.app.rendering.renderers.messageAvatarStyle
import android.content.Context
import androidx.compose.foundation.gestures.detectTapGestures
import java.io.ByteArrayOutputStream

/**
 * 屏 2 —— 会话详情(对话流)。每条消息 = 左侧头像 + 悬浮内容卡;用户输入靠右蓝气泡。
 * 内容全部来自该 `sid` 会话的实时下行(agent 下发的组件树)。
 * 对位 iOS `TaskDetailView`。
 */
@Composable
fun TaskDetailScreen(sessionId: String, onBack: () -> Unit) {
    val relay = LocalRelayClient.current
    val scope = rememberCoroutineScope()
    val session = relay.session(sessionId)
    var draft by rememberSaveable { mutableStateOf("") }
    var showEndConfirm by remember { mutableStateOf(false) }
    val stagedImages = remember { mutableStateListOf<StagedImagePayload>() }

    val keyboard = LocalSoftwareKeyboardController.current
    val listState = rememberLazyListState()
    val working = session?.status == "working"
    val hasMore = session?.hasMore == true

    // 按 agent 下发的逻辑序号 ord 排(同 ord 保持到达顺序,本地刚发的 MAX_VALUE 排末尾)。
    // 对位 iOS `orderedMessages`:LazyColumn 顺序与底部跟随都用它。
    val msgs = session?.messages
    val orderedMessages = remember(msgs?.toList()) {
        (msgs ?: emptyList()).withIndex()
            .sortedWith(compareBy({ it.value.ord }, { it.index }))
            .map { it.value }
    }
    val lastId = orderedMessages.lastOrNull()?.id
    val firstId = orderedMessages.firstOrNull()?.id

    // 顶部「加载更早」防重复触发;新一批到了(顶部 id 变)→ 解锁。
    var loadingMore by remember { mutableStateOf(false) }
    LaunchedEffect(firstId) { if (loadingMore) loadingMore = false }

    // 会话被移除(结束 / 异常退出 / 死亡巡检翻转)→ 自动返回列表
    val gone = session == null
    LaunchedEffect(gone) {
        if (gone) onBack()
    }

    // 只在「底部新增消息」/状态切到 working 时跟随落底,「加载更早」是往上插入(lastId 不变)
    // → 不触发,避免把用户从正在看的位置弹回底部。对位 iOS `.onChange(of: last?.id)`。
    LaunchedEffect(lastId, working) {
        val lastIndex = listState.layoutInfo.totalItemsCount - 1
        if (lastIndex >= 0) listState.animateScrollToItem(lastIndex)
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(Theme.bg),
    ) {
        NavBar(session = session, onBack = onBack, onEnd = { showEndConfirm = true })
        Box(Modifier.weight(1f)) {
            LazyColumn(
                state = listState,
                modifier = Modifier
                    .fillMaxSize()
                    // 点击消息区空白也收键盘(落在按钮/选项上的点击由子项消费,不会误触)
                    .pointerInput(Unit) {
                        detectTapGestures { keyboard?.hide() }
                    },
                contentPadding = PaddingValues(horizontal = 16.dp, vertical = 12.dp),
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                item(key = "header") { SessionHeader(session) }
                if (hasMore) {
                    // 微信式:滚到顶部这一行自动出现 → 触发加载更早 + 转圈,不用点按钮。
                    item(key = "loadMore") {
                        LoadEarlierRow()
                        LaunchedEffect(Unit) {
                            if (!loadingMore) {
                                loadingMore = true
                                relay.loadMoreMessages(sessionId = sessionId)
                            }
                        }
                    }
                }
                if (orderedMessages.isNotEmpty()) {
                    items(orderedMessages, key = { it.id }) { msg ->
                        MessageRow(
                            msg = msg,
                            onAction = { action ->
                                relay.sendAction(action, messageId = msg.id, sessionId = sessionId)
                            },
                            onRetry = { relay.retryUpstream(messageId = msg.id, sessionId = sessionId) },
                        )
                    }
                } else if (!working) {
                    item { EmptyDetailState() }
                }
                if (working) {
                    item(key = "typing") { TypingIndicatorRow() }
                }
            }
        }
        InputBar(
            draft = draft,
            onDraftChange = { draft = it },
            cli = session?.cli ?: "",
            onPickQuickCommand = { cmd ->
                relay.sendInput(cmd, sessionId = sessionId)
                draft = ""
            },
            stagedImages = stagedImages,
            onRemoveImage = { stagedImages.removeAt(it) },
            onPickImages = { stagedImages.addAll(it) },
            onSend = {
                if (stagedImages.isEmpty()) {
                    relay.sendInput(draft, sessionId = sessionId)
                } else {
                    // 1) 立即气泡回显;2) 后台并发上传换 id;3) 拿到 id 后发引用帧。
                    val thumbs = stagedImages.toList()
                    val text = draft
                    val localId = relay.beginImageEcho(thumbs, text, sessionId = sessionId)
                    stagedImages.clear()
                    scope.launch {
                        val refs = thumbs.mapNotNull { img ->
                            try {
                                val bytes = Base64.decode(img.data, Base64.DEFAULT)
                                ImageAPI.upload(bytes) to img.ext
                            } catch (_: Throwable) {
                                null
                            }
                        }
                        relay.sendImageRefs(refs, text, sessionId = sessionId, localMsgId = localId)
                    }
                }
                draft = ""
            },
            modifier = Modifier.imePadding(),
        )
    }

    if (showEndConfirm) {
        EndConfirmDialog(
            onConfirm = {
                relay.endSession(sessionId = sessionId)
                showEndConfirm = false
            },
            onDismiss = { showEndConfirm = false },
        )
    }
}

@Composable
private fun NavBar(session: RelaySession?, onBack: () -> Unit, onEnd: () -> Unit) {
    var menuOpen by remember { mutableStateOf(false) }
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 8.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconButton(onClick = onBack) {
            Icon(
                Icons.AutoMirrored.Filled.KeyboardArrowLeft,
                contentDescription = "返回",
                tint = Theme.text,
                modifier = Modifier.size(22.dp),
            )
        }
        Text(
            text = session?.title ?: "会话",
            color = Theme.text,
            fontSize = 17.sp,
            fontWeight = FontWeight.SemiBold,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f, fill = false),
        )
        if (session?.isManual == true) {
            Spacer(Modifier.width(8.dp))
            // 手动会话:用户自己敲的 claude,反控走 GUI 模拟,电脑锁屏后无法操作。
            Row(
                modifier = Modifier
                    .clip(androidx.compose.foundation.shape.CircleShape)
                    .background(Theme.gold.copy(alpha = 0.15f))
                    .padding(horizontal = 8.dp, vertical = 3.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Text("锁屏不可控", color = Theme.gold, fontSize = 11.sp, fontWeight = FontWeight.Medium)
            }
        }
        Spacer(Modifier.weight(1f))
        Box {
            IconButton(onClick = { menuOpen = true }) {
                Icon(
                    Icons.Default.MoreHoriz,
                    contentDescription = "更多",
                    tint = Theme.text,
                    modifier = Modifier.size(20.dp),
                )
            }
            DropdownMenu(
                expanded = menuOpen,
                onDismissRequest = { menuOpen = false },
                modifier = Modifier.background(Theme.card),
            ) {
                DropdownMenuItem(
                    text = { Text("结束任务", color = Theme.coral, fontSize = 14.sp) },
                    leadingIcon = {
                        Icon(Icons.Default.Cancel, null, tint = Theme.coral, modifier = Modifier.size(18.dp))
                    },
                    onClick = {
                        menuOpen = false
                        onEnd()
                    },
                )
            }
        }
    }
}

@Composable
private fun EndConfirmDialog(onConfirm: () -> Unit, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = Theme.card,
        title = { Text("结束任务", color = Theme.text, fontSize = 17.sp, fontWeight = FontWeight.SemiBold) },
        text = {
            Text(
                "将终止电脑上对应的 Claude Code 会话进程,任务从列表移除。",
                color = Theme.textSec,
                fontSize = 14.sp,
            )
        },
        confirmButton = {
            TextButton(onClick = onConfirm) {
                Text("结束任务(关闭电脑端会话)", color = Theme.coral, fontSize = 14.sp)
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text("取消", color = Theme.textSec, fontSize = 14.sp)
            }
        },
    )
}

@Composable
private fun SessionHeader(session: RelaySession?) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(bottom = 4.dp),
        verticalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(
                modifier = Modifier
                    .size(52.dp)
                    .clip(RoundedCornerShape(14.dp))
                    .background(
                        Brush.linearGradient(
                            listOf(Color(0xFF7C5CD6), Color(0xFFC061E0)),
                        ),
                    ),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    text = (session?.title ?: "会").firstOrNull()?.toString() ?: "会",
                    color = Color.White,
                    fontSize = 22.sp,
                    fontWeight = FontWeight.Bold,
                )
            }
            Spacer(Modifier.width(12.dp))
            Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text(
                    session?.title ?: "会话",
                    color = Theme.text,
                    fontSize = 22.sp,
                    fontWeight = FontWeight.Bold,
                )
                val status = session?.status ?: "working"
                val term = session?.terminal
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(
                        Modifier
                            .size(7.dp)
                            .clip(CircleShape)
                            .background(SessionStatusUI.color(status)),
                    )
                    Spacer(Modifier.width(6.dp))
                    Text(
                        SessionStatusUI.label(status),
                        color = SessionStatusUI.color(status),
                        fontSize = 14.sp,
                        fontWeight = FontWeight.Medium,
                    )
                    if (!term.isNullOrEmpty() && term != "?") {
                        Text(" · $term", color = Theme.textSec, fontSize = 14.sp)
                    }
                }
                val cwd = session?.cwd
                if (!cwd.isNullOrEmpty() && cwd != "?") {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(
                            Icons.Default.Folder,
                            contentDescription = null,
                            tint = Theme.textTer,
                            modifier = Modifier.size(11.dp),
                        )
                        Spacer(Modifier.width(5.dp))
                        Text(
                            shortMacPath(cwd),
                            color = Theme.textSec,
                            fontSize = 12.sp,
                            fontFamily = FontFamily.Monospace,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
            }
        }
    }
}

/**
 * 一条消息:agent → [头像 + 内容 + 时间];工具 chip 紧凑无头像;user → 右对齐气泡 + 时间/状态。
 * 与 iOS `messageRow` 渲染逻辑一致。photomsg 卡内自带时间,行尾不再重复。
 */
@Composable
private fun MessageRow(
    msg: UIMessage,
    onAction: (ComponentAction) -> Unit,
    onRetry: () -> Unit,
) {
    val showTime = msg.time != null && msg.root.type != "photomsg"
    CompositionLocalProvider(LocalOnComponentAction provides onAction) {
        when {
            msg.role == "user" -> {
                Column(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalAlignment = Alignment.End,
                    verticalArrangement = Arrangement.spacedBy(3.dp),
                ) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.End,
                    ) {
                        Spacer(Modifier.width(44.dp))
                        ComponentView(msg.root)
                    }
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(4.dp),
                    ) {
                        if (showTime) TimeLabel(msg.time!!)
                        StatusLabel(msg, onRetry)
                    }
                }
            }
            msg.root.type == "toolchip" -> {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(start = 44.dp),
                ) {
                    ComponentView(msg.root)
                }
            }
            else -> {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.Top,
                ) {
                    MessageAvatar(messageAvatarStyle(msg.root))
                    Spacer(Modifier.width(10.dp))
                    Column(
                        modifier = Modifier.weight(1f),
                        verticalArrangement = Arrangement.spacedBy(3.dp),
                    ) {
                        ComponentView(msg.root)
                        if (showTime) TimeLabel(msg.time!!)
                    }
                }
            }
        }
    }
}

@Composable
private fun TimeLabel(t: String) {
    Text(t, color = Theme.textTer, fontSize = 10.sp)
}

/** 投递状态:发送中(钟表) / 单勾(到服务器) / 双勾(电脑端已收) / 失败(点按重发)。 */
@Composable
private fun StatusLabel(msg: UIMessage, onRetry: () -> Unit) {
    when (msg.status) {
        DeliveryStatus.SENDING -> Icon(
            Icons.Default.Schedule,
            contentDescription = "发送中",
            tint = Theme.textTer,
            modifier = Modifier.size(11.dp),
        )
        DeliveryStatus.SENT -> Icon(
            Icons.Default.Check,
            contentDescription = "已送达服务器",
            tint = Theme.textTer,
            modifier = Modifier.size(11.dp),
        )
        DeliveryStatus.DELIVERED -> Box(Modifier.padding(end = 4.dp)) {
            Icon(Icons.Default.Check, null, tint = Theme.blue, modifier = Modifier.size(11.dp))
            Icon(
                Icons.Default.Check,
                null,
                tint = Theme.blue,
                modifier = Modifier
                    .size(11.dp)
                    .padding(start = 4.dp),
            )
        }
        DeliveryStatus.FAILED -> Row(
            modifier = Modifier
                .clip(RoundedCornerShape(6.dp))
                .clickable { onRetry() }
                .padding(horizontal = 2.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(3.dp),
        ) {
            Icon(Icons.Default.Refresh, null, tint = Theme.coral, modifier = Modifier.size(12.dp))
            Text("重试", color = Theme.coral, fontSize = 10.sp, fontWeight = FontWeight.Medium)
        }
        null -> Unit
    }
}

@Composable
private fun EmptyDetailState() {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 60.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Icon(
            Icons.AutoMirrored.Filled.Chat,
            contentDescription = null,
            tint = Theme.textTer,
            modifier = Modifier.size(34.dp),
        )
        Text("等待下发内容…", color = Theme.textSec, fontSize = 14.sp)
    }
}

/**
 * 「AI 正在思考」指示气泡:头像 + 三个呼吸跳动的圆点。
 * 会话状态 working 时挂在消息流末尾,让用户知道对面在干活。对位 iOS `TypingIndicatorRow`。
 */
@Composable
private fun TypingIndicatorRow() {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.Top,
    ) {
        MessageAvatar(
            AvatarStyle(
                Icons.Default.AutoAwesome,
                listOf(Color(0xFF7C5CD6), Color(0xFFC061E0)),
            ),
        )
        Spacer(Modifier.width(10.dp))
        val shape = RoundedCornerShape(16.dp)
        Row(
            modifier = Modifier
                .clip(shape)
                .background(Theme.card, shape)
                .border(1.dp, Theme.stroke, shape)
                .padding(horizontal = 14.dp, vertical = 13.dp),
            horizontalArrangement = Arrangement.spacedBy(5.dp),
        ) {
            val transition = rememberInfiniteTransition(label = "typing")
            repeat(3) { i ->
                val scale by transition.animateFloat(
                    initialValue = 0.7f,
                    targetValue = 1.2f,
                    animationSpec = infiniteRepeatable(
                        animation = tween(450, delayMillis = i * 160, easing = LinearEasing),
                        repeatMode = RepeatMode.Reverse,
                    ),
                    label = "dot$i",
                )
                Box(
                    modifier = Modifier
                        .size((7 * scale).dp)
                        .clip(CircleShape)
                        .background(Theme.textSec),
                )
            }
        }
        Spacer(Modifier.weight(1f))
    }
}

@Composable
private fun InputBar(
    draft: String,
    onDraftChange: (String) -> Unit,
    cli: String,
    onPickQuickCommand: (String) -> Unit,
    stagedImages: List<StagedImagePayload>,
    onRemoveImage: (Int) -> Unit,
    onPickImages: (List<StagedImagePayload>) -> Unit,
    onSend: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = androidx.compose.ui.platform.LocalContext.current
    var menuOpen by remember { mutableStateOf(false) }

    // 相册多选(系统照片选择器,最多 4 张)
    val galleryLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.PickMultipleVisualMedia(4),
    ) { uris: List<Uri> ->
        val payloads = uris.mapNotNull { uri -> encodeUriToPayload(context, uri) }
        if (payloads.isNotEmpty()) onPickImages(payloads)
    }
    // 拍照(返回缩略 Bitmap)
    val cameraLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.TakePicturePreview(),
    ) { bitmap: Bitmap? ->
        bitmap?.let { encodeBitmapToPayload(it, stagedImages.size + 1) }?.let { onPickImages(listOf(it)) }
    }

    Column(
        modifier = modifier
            .fillMaxWidth()
            .background(Theme.bg),
    ) {
        CommandPopup(draft = draft, cli = cli, onPick = onPickQuickCommand)
        if (stagedImages.isNotEmpty()) {
            StagingStrip(stagedImages, onRemoveImage)
        }
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box {
                IconButton(onClick = { menuOpen = true }, modifier = Modifier.size(38.dp)) {
                    Icon(
                        Icons.Default.Add,
                        contentDescription = "添加图片",
                        tint = Theme.textSec,
                        modifier = Modifier.size(20.dp),
                    )
                }
                DropdownMenu(
                    expanded = menuOpen,
                    onDismissRequest = { menuOpen = false },
                    modifier = Modifier.background(Theme.card),
                ) {
                    DropdownMenuItem(
                        text = { Text("相册选图", color = Theme.text, fontSize = 14.sp) },
                        leadingIcon = {
                            Icon(Icons.Default.PhotoLibrary, null, tint = Theme.textSec, modifier = Modifier.size(18.dp))
                        },
                        onClick = {
                            menuOpen = false
                            galleryLauncher.launch(
                                PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly),
                            )
                        },
                    )
                    DropdownMenuItem(
                        text = { Text("拍照", color = Theme.text, fontSize = 14.sp) },
                        leadingIcon = {
                            Icon(Icons.Default.PhotoCamera, null, tint = Theme.textSec, modifier = Modifier.size(18.dp))
                        },
                        onClick = {
                            menuOpen = false
                            cameraLauncher.launch(null)
                        },
                    )
                }
            }
            OutlinedTextField(
                value = draft,
                onValueChange = onDraftChange,
                modifier = Modifier.weight(1f),
                placeholder = {
                    Text(
                        if (stagedImages.isEmpty()) "输入指令…" else "配上说明文字(可选)…",
                        color = Theme.textTer,
                        fontSize = 15.sp,
                    )
                },
                shape = RoundedCornerShape(12.dp),
                colors = darkFieldColors(),
                singleLine = false,
                maxLines = 4,
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
                keyboardActions = KeyboardActions(onSend = { onSend() }),
            )
            IconButton(
                onClick = onSend,
                modifier = Modifier
                    .size(46.dp)
                    .clip(RoundedCornerShape(12.dp))
                    .background(Theme.blueBtn),
            ) {
                Icon(
                    Icons.AutoMirrored.Filled.Send,
                    contentDescription = "发送",
                    tint = Color.White,
                    modifier = Modifier.size(18.dp),
                )
            }
        }
    }
}

/** 暂存框:已选图片缩略图横排,可单张移除;发送时与文字合并为一条消息。 */
@Composable
private fun StagingStrip(images: List<StagedImagePayload>, onRemove: (Int) -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState())
            .padding(start = 16.dp, top = 12.dp, end = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        images.forEachIndexed { i, img ->
            val bitmap = remember(img.data) {
                runCatching {
                    val bytes = Base64.decode(img.data, Base64.DEFAULT)
                    BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
                }.getOrNull()
            }
            Box {
                if (bitmap != null) {
                    Image(
                        bitmap = bitmap.asImageBitmap(),
                        contentDescription = img.name,
                        modifier = Modifier
                            .size(64.dp)
                            .clip(RoundedCornerShape(10.dp)),
                        contentScale = ContentScale.Crop,
                    )
                }
                IconButton(
                    onClick = { onRemove(i) },
                    modifier = Modifier
                        .align(Alignment.TopEnd)
                        .size(22.dp),
                ) {
                    Icon(
                        Icons.Default.Cancel,
                        contentDescription = "移除",
                        tint = Color.White,
                        modifier = Modifier
                            .size(18.dp)
                            .clip(CircleShape)
                            .background(Color.Black.copy(alpha = 0.6f)),
                    )
                }
            }
        }
    }
}

/** 相册选图:URI → 等比缩到最长边 1568 的 JPEG base64,封装成 [StagedImagePayload]。 */
private fun encodeUriToPayload(context: Context, uri: Uri): StagedImagePayload? {
    val bitmap = runCatching {
        context.contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it) }
    }.getOrNull() ?: return null
    val name = uri.lastPathSegment?.substringAfterLast('/') ?: "photo"
    return encodeBitmapToPayload(bitmap, 1, displayName = "$name.jpg")
}

/** Bitmap → 等比缩到最长边 1568 的 JPEG(quality 0.7),封装成 [StagedImagePayload]。 */
private fun encodeBitmapToPayload(
    bitmap: Bitmap,
    index: Int,
    displayName: String = "photo_$index.jpg",
): StagedImagePayload? {
    val scaled = bitmap.resizedToMaxDim(1568)
    val out = ByteArrayOutputStream()
    if (!scaled.compress(Bitmap.CompressFormat.JPEG, 70, out)) return null
    val bytes = out.toByteArray()
    val sizeStr = if (bytes.size >= 1_000_000) {
        String.format("%.1f MB", bytes.size / 1_000_000.0)
    } else {
        "${bytes.size / 1_000} KB"
    }
    return StagedImagePayload(
        data = Base64.encodeToString(bytes, Base64.NO_WRAP),
        ext = "jpg",
        name = displayName,
        kind = "JPEG",
        size = sizeStr,
    )
}

/** 等比缩到最长边 maxDim(已小于则原样返回)。对位 iOS `UIImage.resized`。 */
private fun Bitmap.resizedToMaxDim(maxDim: Int): Bitmap {
    val m = maxOf(width, height)
    if (m <= maxDim) return this
    val scale = maxDim.toFloat() / m
    return Bitmap.createScaledBitmap(this, (width * scale).toInt(), (height * scale).toInt(), true)
}

/**
 * 输入「/」时,在输入框上方弹出匹配的快捷指令气泡(命令+说明);点一个直接发送。
 * 不输「/」就不显示,不占地方。指令集按会话的 CLI 类型(claude/codex)取。
 * 对位 iOS `commandPopup`。
 */
@Composable
private fun CommandPopup(draft: String, cli: String, onPick: (String) -> Unit) {
    val q = draft.trim()
    if (!q.startsWith("/")) return
    val cmds = CLIKind.by(cli)?.quickCommands ?: return
    val matches = cmds.filter { it.cmd.startsWith(q) }
    if (matches.isEmpty()) return
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp, vertical = 0.dp)
            .padding(bottom = 8.dp)
            .cardStyle(fill = Theme.field, stroke = Theme.stroke, radius = 12.dp),
    ) {
        matches.forEachIndexed { i, c ->
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable { onPick(c.cmd) }
                    .padding(horizontal = 14.dp, vertical = 11.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Text(
                    c.cmd,
                    color = Theme.text,
                    fontSize = 14.sp,
                    fontWeight = FontWeight.SemiBold,
                    fontFamily = FontFamily.Monospace,
                )
                Text(c.desc, color = Theme.textSec, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            if (i != matches.lastIndex) {
                HorizontalDivider(color = Theme.stroke, thickness = 1.dp)
            }
        }
    }
}

/**
 * 滚到顶时这一行自动出现 → 触发加载更早 + 转圈。对位 iOS hasMore 块。
 */
@Composable
private fun LoadEarlierRow() {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Spacer(Modifier.weight(1f))
        CircularProgressIndicator(
            color = Theme.textSec,
            strokeWidth = 2.dp,
            modifier = Modifier.size(12.dp),
        )
        Text("加载更早消息…", color = Theme.textSec, fontSize = 12.sp)
        Spacer(Modifier.weight(1f))
    }
}
