package com.aicodingremote.app.rendering.renderers

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckBox
import androidx.compose.material.icons.filled.CheckBoxOutlineBlank
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.RadioButtonUnchecked
import androidx.compose.material.icons.filled.UnfoldMore
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.aicodingremote.app.app.LocalOnComponentAction
import com.aicodingremote.app.designsystem.IconResolver
import com.aicodingremote.app.designsystem.Theme
import com.aicodingremote.app.designsystem.darkFieldColors
import com.aicodingremote.app.models.Component
import com.aicodingremote.app.models.ComponentAction
import com.aicodingremote.app.models.arrayValue
import com.aicodingremote.app.models.bool
import com.aicodingremote.app.models.get
import com.aicodingremote.app.models.string
import com.aicodingremote.app.models.stringValue
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonPrimitive

/**
 * PROTOCOL §5.2 / §6 —— 按钮。点击经 [LocalOnComponentAction] 回传。
 *
 * 可选 [pressed]/[index]:组内共享的本地即时反馈(点击立刻转圈高亮所点项、其余置灰禁用,
 * 不等服务器回包)。agent 重发新卡片后视图重建自动复位。
 */
@Composable
fun ButtonRenderer(
    component: Component,
    pressed: MutableState<Int?>? = null,
    index: Int = 0,
) {
    val onAction = LocalOnComponentAction.current
    val label = component.props.string("label", "确定")
    val style = component.props.string("style", "default")
    val icon = component.props["icon"]?.stringValue

    val bg = when (style) {
        "primary" -> Theme.blueBtn
        "danger" -> Theme.coral
        else -> Theme.cardHi
    }
    val fg = if (style == "default") Theme.text else Color.White
    val border: BorderStroke? = if (style == "default") BorderStroke(1.dp, Theme.stroke) else null

    val isPressed = pressed?.value == index
    val anyPressed = pressed?.value != null
    val alpha by animateFloatAsState(
        targetValue = if (anyPressed && !isPressed) 0.35f else 1f,
        animationSpec = tween(durationMillis = 150, easing = LinearEasing),
        label = "btnAlpha",
    )

    Button(
        onClick = {
            if (anyPressed) return@Button       // 防重复点击
            pressed?.value = index               // 立即本地反馈,不等服务器
            component.action?.let(onAction)
        },
        modifier = Modifier
            .fillMaxWidth()
            .height(42.dp)
            .graphicsLayer { this.alpha = alpha },
        shape = RoundedCornerShape(Theme.rBtn),
        colors = ButtonDefaults.buttonColors(containerColor = bg, contentColor = fg),
        border = border,
        contentPadding = PaddingValues(horizontal = 12.dp),
    ) {
        if (isPressed) {
            CircularProgressIndicator(
                color = fg,
                strokeWidth = 2.dp,
                modifier = Modifier.size(14.dp),
            )
            Spacer(Modifier.width(6.dp))
        } else if (icon != null) {
            Icon(IconResolver.resolve(icon), null, modifier = Modifier.size(14.dp))
            Spacer(Modifier.width(6.dp))
        }
        Text(label, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
    }
}

/** PROTOCOL §5.2 —— 一排按钮(每个按钮均分宽度)。点击本地态组内共享(点一个,其余置灰)。 */
@Composable
fun ButtonGroupRenderer(component: Component) {
    val buttons = component.props["buttons"]?.arrayValue ?: emptyList()
    // 本地点击态;agent 重发新卡片后视图重建自动复位
    val pressed = remember(component.uid) { mutableStateOf<Int?>(null) }
    Row(
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        buttons.forEachIndexed { i, json ->
            Box(Modifier.weight(1f)) {
                ButtonRenderer(Component.from(json), pressed = pressed, index = i)
            }
        }
    }
}

/** PROTOCOL §5.2 —— 下拉选择。选中后立即回传 action。 */
@Composable
fun SelectRenderer(component: Component) {
    val onAction = LocalOnComponentAction.current
    val options = component.props["options"]?.arrayValue ?: emptyList()
    val placeholder = component.props.string("placeholder", "请选择")

    var selectedLabel by rememberSaveable(component.uid) { mutableStateOf<String?>(null) }
    var expanded by remember { mutableStateOf(false) }
    val shape = RoundedCornerShape(Theme.rBtn)

    Box {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clip(shape)
                .background(Theme.field, shape)
                .border(1.dp, Theme.stroke, shape)
                .clickable { expanded = true }
                .padding(horizontal = 14.dp, vertical = 11.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                selectedLabel ?: placeholder,
                color = if (selectedLabel == null) Theme.textTer else Theme.text,
                fontSize = 14.sp,
                modifier = Modifier.weight(1f),
            )
            Icon(
                Icons.Default.UnfoldMore,
                contentDescription = null,
                tint = Theme.textSec,
                modifier = Modifier.size(11.dp),
            )
        }
        DropdownMenu(
            expanded = expanded,
            onDismissRequest = { expanded = false },
            modifier = Modifier.background(Theme.card),
        ) {
            options.forEach { opt ->
                val label = opt.string("label")
                DropdownMenuItem(
                    text = { Text(label, color = Theme.text, fontSize = 14.sp) },
                    onClick = {
                        selectedLabel = label
                        expanded = false
                        component.action?.let { base ->
                            val value = opt["value"] ?: JsonPrimitive(label)
                            onAction(ComponentAction(base.id, value))
                        }
                    },
                )
            }
        }
    }
}

/** PROTOCOL §5.2 —— 文本输入框(带发送按钮)。 */
@Composable
fun TextInputRenderer(component: Component) {
    val onAction = LocalOnComponentAction.current
    val placeholder = component.props.string("placeholder", "")
    val submitLabel = component.props.string("submitLabel", "发送")
    val multiline = component.props.bool("multiline")
    var text by rememberSaveable(component.uid) { mutableStateOf("") }

    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        OutlinedTextField(
            value = text,
            onValueChange = { text = it },
            modifier = Modifier.weight(1f),
            placeholder = { Text(placeholder, color = Theme.textTer, fontSize = 14.sp) },
            shape = RoundedCornerShape(Theme.rBtn),
            colors = darkFieldColors(),
            singleLine = !multiline,
            maxLines = if (multiline) 5 else 1,
            keyboardOptions = KeyboardOptions(imeAction = if (multiline) ImeAction.Default else ImeAction.Send),
        )
        Button(
            onClick = {
                component.action?.let { onAction(ComponentAction(it.id, JsonPrimitive(text))) }
                text = ""
            },
            enabled = text.isNotEmpty(),
            shape = RoundedCornerShape(Theme.rBtn),
            colors = ButtonDefaults.buttonColors(
                containerColor = Theme.blueBtn,
                disabledContainerColor = Theme.cardHi,
                contentColor = Color.White,
                disabledContentColor = Theme.textTer,
            ),
        ) {
            Text(submitLabel, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
        }
    }
}

/** PROTOCOL §5.2 —— 开关。状态改变立即回传 action。 */
@Composable
fun ToggleRenderer(component: Component) {
    val onAction = LocalOnComponentAction.current
    var isOn by rememberSaveable(component.uid) {
        mutableStateOf(component.props.bool("value"))
    }
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            component.props.string("label"),
            color = Theme.text,
            fontSize = 14.sp,
            modifier = Modifier.weight(1f),
        )
        Switch(
            checked = isOn,
            onCheckedChange = { newValue ->
                isOn = newValue
                component.action?.let { base ->
                    onAction(ComponentAction(base.id, JsonPrimitive(newValue)))
                }
            },
            colors = SwitchDefaults.colors(
                checkedThumbColor = Color.White,
                checkedTrackColor = Theme.blue,
                uncheckedThumbColor = Theme.textSec,
                uncheckedTrackColor = Theme.cardHi,
                uncheckedBorderColor = Theme.stroke,
            ),
        )
    }
}

// MARK: - 选择题组件(单选/多选)。选项整行纵排;多选本地勾选、「完成」一次性回传。

/**
 * PROTOCOL §6 —— TUI 选择题(AskUserQuestion / 计划确认)在手机上的作答卡。
 * - 单选:即点即传(对齐 TUI 数字键即选即确认);
 * - 多选:本地勾选切换,「完成选择」一次性回传 CSV(如 "1,3");
 * - 答案值为 1-based 序号,经 [LocalOnComponentAction] → `relay.sendAction` 走 hook 精确回传。
 *
 * 对位 iOS `ChoicesRenderer`。
 */
@Composable
fun ChoicesRenderer(component: Component) {
    val onAction = LocalOnComponentAction.current
    val multi = component.props.bool("multi")
    val options = component.props["options"]?.arrayValue ?: emptyList()

    // 本地勾选(多选)/ 已提交态;agent 重发新卡片后视图重建自动复位
    val picked = remember(component.uid) { mutableStateListOf<Int>() }
    var submitted by remember(component.uid) { mutableStateOf(false) }

    fun sendAnswer(value: String) {
        component.action?.let { base ->
            onAction(ComponentAction(base.id, JsonPrimitive(value)))
        }
    }

    Column(
        modifier = Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        options.forEachIndexed { i, opt ->
            ChoiceOptionRow(
                index = i,
                option = opt,
                multi = multi,
                isPicked = picked.contains(i),
                submitted = submitted,
                onClick = onClick@{
                    if (submitted) return@onClick
                    if (multi) {
                        if (picked.contains(i)) picked.remove(i) else picked.add(i)
                    } else {
                        picked.clear(); picked.add(i); submitted = true
                        sendAnswer((i + 1).toString())   // 单选:即点即传
                    }
                },
            )
        }
        if (multi) {
            val empty = picked.isEmpty()
            Button(
                onClick = {
                    if (submitted || empty) return@Button
                    submitted = true
                    val csv = picked.sorted().joinToString(",") { (it + 1).toString() }
                    sendAnswer(csv)
                },
                enabled = !submitted && !empty,
                modifier = Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(Theme.rBtn),
                colors = ButtonDefaults.buttonColors(
                    containerColor = Theme.blueBtn,
                    disabledContainerColor = Theme.cardHi,
                    contentColor = Color.White,
                    disabledContentColor = Theme.textTer,
                ),
            ) {
                if (submitted) {
                    CircularProgressIndicator(
                        color = Color.White,
                        strokeWidth = 2.dp,
                        modifier = Modifier.size(14.dp),
                    )
                    Spacer(Modifier.width(6.dp))
                }
                Text(
                    if (submitted) "已提交,等待确认…" else "✓ 完成选择(已选 ${picked.size} 项)",
                    fontSize = 14.sp,
                    fontWeight = FontWeight.SemiBold,
                )
            }
        }
    }
}

@Composable
private fun ChoiceOptionRow(
    index: Int,
    option: JsonElement,
    multi: Boolean,
    isPicked: Boolean,
    submitted: Boolean,
    onClick: () -> Unit,
) {
    val label = option.string("label")
    val desc = option.string("description")
    val shape = RoundedCornerShape(10.dp)
    val borderColor = if (isPicked) Theme.blue.copy(alpha = 0.6f) else Theme.stroke
    val fill = if (isPicked) Theme.blue.copy(alpha = 0.12f) else Theme.field
    val checkIcon = if (isPicked) {
        if (multi) Icons.Default.CheckBox else Icons.Default.CheckCircle
    } else {
        if (multi) Icons.Default.CheckBoxOutlineBlank else Icons.Default.RadioButtonUnchecked
    }

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .graphicsLayer { alpha = if (submitted && !isPicked) 0.45f else 1f }
            .clip(shape)
            .background(fill, shape)
            .border(1.dp, borderColor, shape)
            .clickable(enabled = !submitted) { onClick() }
            .padding(10.dp),
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Icon(
            checkIcon,
            contentDescription = null,
            tint = if (isPicked) Theme.blue else Theme.textTer,
            modifier = Modifier
                .padding(top = 1.dp)
                .size(18.dp),
        )
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(3.dp),
        ) {
            Text(
                "${index + 1}. $label",
                color = Theme.text,
                fontSize = 14.sp,
                fontWeight = if (isPicked) FontWeight.SemiBold else FontWeight.Normal,
            )
            if (desc.isNotEmpty()) {
                Text(desc, color = Theme.textSec, fontSize = 12.sp)
            }
        }
        if (!multi && isPicked && submitted) {
            CircularProgressIndicator(
                color = Theme.blue,
                strokeWidth = 2.dp,
                modifier = Modifier.size(14.dp),
            )
        }
    }
}
