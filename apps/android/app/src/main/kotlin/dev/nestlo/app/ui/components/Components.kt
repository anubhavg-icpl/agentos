package dev.nestlo.app.ui.components

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.nestlo.app.ui.theme.NColor
import dev.nestlo.app.ui.theme.NType
import dev.nestlo.app.util.Haptics
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.tween
import kotlinx.coroutines.launch
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin

/** Black page with a faint dot grid behind the content. */
@Composable
fun DotGrid(modifier: Modifier = Modifier, content: @Composable BoxScope.() -> Unit) {
    Box(
        modifier
            .background(NColor.Black)
            .drawBehind {
                val step = 22.dp.toPx()
                val r = 0.9.dp.toPx()
                var y = step / 2
                while (y < size.height) {
                    var x = step / 2
                    while (x < size.width) {
                        drawCircle(NColor.Dot, r, Offset(x, y))
                        x += step
                    }
                    y += step
                }
            },
        content = content,
    )
}

/** Upper-case, letter-spaced mono label. */
@Composable
fun Label(text: String, modifier: Modifier = Modifier, color: Color = NColor.Gray60, style: TextStyle = NType.Label) {
    Text(text.uppercase(), modifier, style = style.copy(color = color))
}

/** Inline status in square brackets: [CONNECTING…], [PAIRED], [ERROR: …]. */
sealed interface Status {
    data object None : Status
    data class Busy(val text: String) : Status
    data class Ok(val text: String) : Status
    data class Error(val text: String) : Status
    data class Info(val text: String) : Status

    /** Red bracketed text without the ERROR prefix (e.g. tunnel expired). */
    data class Alert(val text: String) : Status
}

@Composable
fun StatusLine(status: Status, modifier: Modifier = Modifier) {
    val (text, color) = when (status) {
        Status.None -> return
        is Status.Busy -> "[${status.text.uppercase()}…]" to NColor.Gray60
        is Status.Ok -> "[${status.text.uppercase()}]" to NColor.White
        is Status.Info -> "[${status.text.uppercase()}]" to NColor.Gray60
        is Status.Alert -> "[${status.text.uppercase()}]" to NColor.Red
        is Status.Error -> "[ERROR: ${status.text.uppercase()}]" to NColor.Red
    }
    Text(text, modifier, style = NType.Label.copy(color = color, fontSize = 12.sp))
}

/** Flat bordered surface. */
@Composable
fun Panel(
    modifier: Modifier = Modifier,
    borderColor: Color = NColor.Border,
    padding: PaddingValues = PaddingValues(16.dp),
    content: @Composable () -> Unit,
) {
    Box(modifier.border(1.dp, borderColor).padding(padding)) { content() }
}

/** Segmented progress bar. Turns red once the value passes the limit. */
@Composable
fun SegmentedBar(
    fraction: Float,
    modifier: Modifier = Modifier,
    segments: Int = 24,
    height: Dp = 14.dp,
    alert: Boolean = fraction > 1f,
) {
    val f = fraction.coerceIn(0f, 1f)
    val filled = Math.round(f * segments).let { if (fraction > 0f && it == 0) 1 else it }
    Canvas(modifier.fillMaxWidth().height(height)) {
        val gap = 3.dp.toPx()
        val w = (size.width - gap * (segments - 1)) / segments
        for (i in 0 until segments) {
            val on = i < filled
            val color = if (on) (if (alert) NColor.Red else NColor.White) else NColor.Border
            drawRect(color, Offset(i * (w + gap), 0f), Size(w, size.height))
        }
    }
}

/** Ring of dots, the single circular "break" on a screen. */
@Composable
fun DotRing(
    fraction: Float,
    modifier: Modifier = Modifier,
    dots: Int = 48,
    dotRadius: Dp = 2.dp,
    alert: Boolean = false,
    content: @Composable BoxScope.() -> Unit = {},
) {
    val filled = Math.round(fraction.coerceIn(0f, 1f) * dots)
    Box(modifier, contentAlignment = Alignment.Center) {
        Canvas(Modifier.matchParentSize()) {
            val r = size.minDimension / 2 - dotRadius.toPx() - 1.dp.toPx()
            val c = Offset(size.width / 2, size.height / 2)
            for (i in 0 until dots) {
                val a = (-PI / 2) + 2 * PI * i / dots
                val p = Offset(c.x + (r * cos(a)).toFloat(), c.y + (r * sin(a)).toFloat())
                val color = if (i < filled) (if (alert) NColor.Red else NColor.White) else NColor.BorderStrong
                drawCircle(color, dotRadius.toPx(), p)
            }
        }
        content()
    }
}

@Composable
fun HealthDot(label: String, ok: Boolean, modifier: Modifier = Modifier) {
    Row(modifier, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Box(
            Modifier
                .size(9.dp)
                .then(if (ok) Modifier.background(NColor.White, CircleShape) else Modifier.border(1.dp, NColor.Red, CircleShape)),
        )
        Label(label, color = if (ok) NColor.Gray90 else NColor.Red)
    }
}

/** Small filled dot; red variant is the "needs input" marker. */
@Composable
fun StatusDot(color: Color, modifier: Modifier = Modifier, size: Dp = 9.dp) {
    Box(modifier.size(size).background(color, CircleShape))
}

/**
 * Flat button with a hard state change: pressed inverts instantly (no ripple, no tween).
 */
@Composable
fun MechButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    danger: Boolean = false,
    enabled: Boolean = true,
    filled: Boolean = false,
) {
    val view = LocalView.current
    val source = remember { MutableInteractionSource() }
    val pressed by source.collectIsPressedAsState()
    val accent = if (danger) NColor.Red else NColor.White
    val bg = when {
        pressed -> accent
        filled -> accent
        else -> Color.Transparent
    }
    val fg = when {
        !enabled -> NColor.Gray40
        pressed || filled -> if (danger) NColor.White else NColor.Black
        else -> accent
    }
    Box(
        modifier
            .background(bg)
            .border(1.dp, if (enabled) accent else NColor.BorderStrong)
            .clickable(source, indication = null, enabled = enabled) {
                Haptics.tap(view)
                onClick()
            }
            .padding(horizontal = 16.dp, vertical = 12.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(text.uppercase(), style = NType.Label.copy(color = fg, fontSize = 12.sp))
    }
}

/**
 * Hold-to-confirm control: a segmented bar fills while the finger stays down, with a tick per segment
 * and a heavy click on completion. Releasing early resets instantly.
 */
@Composable
fun HoldToConfirm(
    text: String,
    onConfirm: () -> Unit,
    modifier: Modifier = Modifier,
    holdMillis: Int = 1400,
    danger: Boolean = true,
    enabled: Boolean = true,
) {
    val view = LocalView.current
    val scope = rememberCoroutineScope()
    val progress = remember { Animatable(0f) }
    var lastSegment by remember { mutableStateOf(0) }
    val segments = 12
    val accent = if (danger) NColor.Red else NColor.White
    Column(
        modifier
            .border(1.dp, if (enabled) accent else NColor.BorderStrong)
            .pointerInput(enabled) {
                if (!enabled) return@pointerInput
                detectTapGestures(
                    onPress = {
                        lastSegment = 0
                        val job = scope.launch {
                            progress.snapTo(0f)
                            progress.animateTo(1f, tween(holdMillis, easing = LinearEasing)) {
                                val seg = (value * segments).toInt()
                                if (seg != lastSegment) {
                                    lastSegment = seg
                                    Haptics.tick(view)
                                }
                            }
                            Haptics.heavy(view)
                            onConfirm()
                            progress.snapTo(0f)
                        }
                        tryAwaitRelease()
                        if (progress.value < 1f) {
                            job.cancel()
                            scope.launch { progress.snapTo(0f) }
                        }
                    },
                )
            }
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Text(
            text.uppercase(),
            style = NType.Label.copy(color = if (enabled) accent else NColor.Gray40, fontSize = 12.sp),
        )
        SegmentedBar(progress.value, segments = segments, height = 8.dp, alert = danger)
    }
}

/** Divider-style row container with a 1px bottom border. */
@Composable
fun Row1px(modifier: Modifier = Modifier, onClick: (() -> Unit)? = null, content: @Composable () -> Unit) {
    val view = LocalView.current
    Box(
        modifier
            .fillMaxWidth()
            .drawBehind { drawRect(NColor.Border, Offset(0f, size.height - 1.dp.toPx()), Size(size.width, 1.dp.toPx())) }
            .then(
                if (onClick != null) Modifier.clickable(remember { MutableInteractionSource() }, null) {
                    Haptics.tap(view)
                    onClick()
                } else Modifier,
            )
            .padding(vertical = 14.dp),
    ) { content() }
}

/** Screen header: back label, title in dot matrix. */
@Composable
fun ScreenHeader(title: String, onBack: (() -> Unit)?, trailing: @Composable () -> Unit = {}) {
    Column(Modifier.fillMaxWidth().padding(top = 8.dp, bottom = 12.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            if (onBack != null) {
                val view = LocalView.current
                Label(
                    "< BACK",
                    modifier = Modifier
                        .clickable(remember { MutableInteractionSource() }, null) {
                            Haptics.tap(view)
                            onBack()
                        }
                        .padding(vertical = 8.dp, horizontal = 2.dp),
                    color = NColor.Gray90,
                )
            }
            Box(Modifier.weight(1f))
            trailing()
        }
        Text(title.uppercase(), style = NType.Headline)
    }
}

@Composable
fun MonoField(
    value: String,
    onValueChange: (String) -> Unit,
    modifier: Modifier = Modifier,
    hint: String = "",
    singleLine: Boolean = false,
) {
    BasicTextField(
        value = value,
        onValueChange = onValueChange,
        modifier = modifier.fillMaxWidth().border(1.dp, NColor.BorderStrong).padding(12.dp),
        textStyle = NType.Mono.copy(color = NColor.White),
        cursorBrush = SolidColor(NColor.White),
        singleLine = singleLine,
        decorationBox = { inner ->
            Box {
                if (value.isEmpty()) Text(hint, style = NType.Mono.copy(color = NColor.Gray40))
                inner()
            }
        },
    )
}
