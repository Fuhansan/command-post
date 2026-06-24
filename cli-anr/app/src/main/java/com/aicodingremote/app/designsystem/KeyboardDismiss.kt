package com.aicodingremote.app.designsystem

import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController

/**
 * 点击空白处收起键盘。对位 iOS `KeyboardDismiss.dismissKeyboardOnTap()`。
 *
 * 用 `detectTapGestures` 监听背景点击 —— 它不消费子视图(按钮/输入框)的点击,
 * 因此挂在最外层容器上即可:点空白收键盘,点控件照常工作。
 */
fun Modifier.dismissKeyboardOnTap(): Modifier = composed {
    val focusManager = LocalFocusManager.current
    val keyboard = LocalSoftwareKeyboardController.current
    pointerInput(Unit) {
        detectTapGestures(onTap = {
            keyboard?.hide()
            focusManager.clearFocus()
        })
    }
}
