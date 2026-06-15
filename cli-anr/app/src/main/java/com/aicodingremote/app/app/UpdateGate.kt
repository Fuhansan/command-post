package com.aicodingremote.app.app

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowCircleDown
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.aicodingremote.app.designsystem.Theme
import com.aicodingremote.app.designsystem.cardStyle
import com.aicodingremote.app.networking.UpdateChecker

/**
 * 客户端版本门禁 UI(对位 iOS UpdateChecker.swift 里的 ForceUpdateView / AnnouncementSheet /
 * updateButton)。逻辑/状态在 UpdateChecker,这里只画界面。
 */

/** 强制更新全屏拦截页:低于最低可用版本时替换整个界面。 */
@Composable
fun ForceUpdateScreen(info: UpdateChecker.VersionInfo) {
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Theme.bg)
            .systemBarsPadding()
            .padding(28.dp),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(18.dp),
        ) {
            Icon(
                Icons.Default.ArrowCircleDown,
                contentDescription = null,
                tint = Theme.blue,
                modifier = Modifier.size(56.dp),
            )
            Text("需要更新", color = Theme.text, fontSize = 22.sp, fontWeight = FontWeight.Bold)
            Text(
                "当前版本 ${UpdateChecker.currentVersion} 已停用,请升级到 ${info.latest} 后继续使用",
                color = Theme.textSec,
                fontSize = 14.sp,
                textAlign = TextAlign.Center,
            )
            if (info.notes.isNotEmpty()) {
                Column(
                    modifier = Modifier
                        .heightIn(max = 180.dp)
                        .cardStyle()
                        .padding(12.dp)
                        .verticalScroll(rememberScrollState()),
                ) {
                    Text(
                        info.notes,
                        color = Theme.textSec,
                        fontSize = 13.sp,
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
            }
            UpdateButton(info)
        }
    }
}

/** 更新公告弹层(可选更新):重大功能说明 + 稍后/去更新。 */
@Composable
fun AnnouncementSheet(info: UpdateChecker.VersionInfo, onDismiss: () -> Unit) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = false)
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = Theme.bg,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(start = 24.dp, end = 24.dp, bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Icon(
                    Icons.Default.AutoAwesome,
                    contentDescription = null,
                    tint = Theme.gold,
                    modifier = Modifier.size(22.dp),
                )
                Text("新版本 ${info.latest}", color = Theme.text, fontSize = 20.sp, fontWeight = FontWeight.Bold)
            }
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(max = 320.dp)
                    .verticalScroll(rememberScrollState()),
            ) {
                Text(
                    info.notes.ifEmpty { "修复与体验优化。" },
                    color = Theme.text,
                    fontSize = 15.sp,
                    lineHeight = 21.sp,
                )
            }
            UpdateButton(info)
            Text(
                "稍后再说",
                color = Theme.textSec,
                fontSize = 14.sp,
                textAlign = TextAlign.Center,
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable(onClick = onDismiss)
                    .padding(vertical = 8.dp),
            )
        }
    }
}

/** 「去更新」按钮:有 URL 则跳转(浏览器/商店),无则提示连线安装。 */
@Composable
private fun UpdateButton(info: UpdateChecker.VersionInfo) {
    val context = LocalContext.current
    if (info.url.isNotEmpty()) {
        Button(
            onClick = {
                runCatching {
                    context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(info.url)))
                }
            },
            modifier = Modifier.fillMaxWidth(),
            shape = RoundedCornerShape(13.dp),
            colors = ButtonDefaults.buttonColors(containerColor = Theme.blueBtn, contentColor = Color.White),
        ) {
            Text("去更新", fontSize = 16.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(vertical = 4.dp))
        }
    } else {
        Text(
            "请将手机连接电脑,用 Android Studio 安装最新构建",
            color = Theme.gold,
            fontSize = 13.sp,
            textAlign = TextAlign.Center,
            modifier = Modifier
                .fillMaxWidth()
                .background(Theme.gold.copy(alpha = 0.12f), RoundedCornerShape(12.dp))
                .padding(vertical = 12.dp),
        )
    }
}
