package dev.nestlo.app.ui.screens

import android.content.ClipboardManager
import android.content.Context
import android.graphics.Paint
import android.graphics.Typeface
import android.view.inputmethod.InputMethodManager
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.res.ResourcesCompat
import dev.nestlo.app.R
import dev.nestlo.app.data.Repository
import dev.nestlo.app.ui.components.Label
import dev.nestlo.app.ui.components.Row1px
import dev.nestlo.app.ui.components.ScreenHeader
import dev.nestlo.app.ui.components.Status
import dev.nestlo.app.ui.components.StatusLine
import dev.nestlo.app.ui.theme.NColor
import dev.nestlo.app.ui.theme.NType
import dev.nestlo.app.util.Haptics
import dev.nestlo.core.net.TerminalListener
import dev.nestlo.core.net.TerminalSocket
import dev.nestlo.core.protocol.TermSession
import dev.nestlo.core.term.Attr
import dev.nestlo.core.term.KeyEncoder
import dev.nestlo.core.term.TermColor
import dev.nestlo.core.term.TermKey
import dev.nestlo.core.term.TerminalEmulator
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.delay
import kotlin.math.ceil
import kotlin.math.max

@Composable
fun TerminalScreen(repo: Repository, onBack: () -> Unit) {
    var session by remember { mutableStateOf<TermSession?>(null) }
    val s = session
    if (s == null) {
        Box(Modifier.fillMaxSize().systemBarsPadding().padding(horizontal = 16.dp)) {
            SessionPicker(repo, onBack) { session = it }
        }
    } else {
        TerminalSessionView(repo, s) { session = null }
    }
}

@Composable
private fun SessionPicker(repo: Repository, onBack: () -> Unit, onPick: (TermSession) -> Unit) {
    var sessions by remember { mutableStateOf<List<TermSession>?>(null) }
    var status by remember { mutableStateOf<Status>(Status.Busy("LOADING SESSIONS")) }
    LaunchedEffect(Unit) {
        repo.call { sessions() }
            .onSuccess { sessions = it; status = Status.None }
            .onFailure { status = Status.Error(Repository.describe(it)) }
    }
    LazyColumn(Modifier.fillMaxSize()) {
        item {
            ScreenHeader("TERMINAL", onBack)
            StatusLine(status)
            Label("PICK A SESSION")
        }
        if (sessions?.isEmpty() == true) {
            item { Text("No sessions available.", style = NType.Body.copy(color = NColor.Gray60)) }
        }
        items(sessions.orEmpty(), key = { it.id }) { s ->
            Row1px(onClick = { onPick(s) }) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text(s.title.ifBlank { s.id }, style = NType.BodyStrong)
                        Label("${s.kind}  ${s.user}")
                    }
                    Label(">", color = NColor.White)
                }
            }
        }
    }
}

private val ANSI16 = intArrayOf(
    0x000000, 0xCC3333, 0x33AA55, 0xC8A32B, 0x4A7FD4, 0xA855B5, 0x3AA6A6, 0xCCCCCC,
    0x666666, 0xFF5555, 0x55DD77, 0xFFD84A, 0x7AA2FF, 0xD68AE0, 0x62DCDC, 0xFFFFFF,
)
private const val DEFAULT_FG = 0xFFE8E8E8.toInt()
private const val DEFAULT_BG = 0xFF000000.toInt()

private fun resolve(color: Int, isFg: Boolean, bold: Boolean): Int = when {
    TermColor.isDefault(color) -> if (isFg) DEFAULT_FG else DEFAULT_BG
    TermColor.isPalette(color) -> {
        var i = TermColor.paletteIndex(color)
        if (isFg && bold && i < 8) i += 8
        0xFF000000.toInt() or TermColor.paletteRgb(i, ANSI16)
    }
    else -> 0xFF000000.toInt() or TermColor.rgbValue(color)
}

private fun blend(fg: Int, bg: Int, t: Float): Int {
    fun ch(s: Int) = (((fg shr s) and 0xFF) * t + ((bg shr s) and 0xFF) * (1 - t)).toInt()
    return 0xFF000000.toInt() or (ch(16) shl 16) or (ch(8) shl 8) or ch(0)
}

private class TermPaints(textPx: Float, regular: Typeface, bold: Typeface) {
    val text = Paint(Paint.ANTI_ALIAS_FLAG).apply { typeface = regular; textSize = textPx }
    val boldText = Paint(Paint.ANTI_ALIAS_FLAG).apply { typeface = bold; textSize = textPx }
    val fill = Paint()
    val cellW: Float = text.measureText("M")
    val cellH: Float = ceil(text.fontMetrics.descent - text.fontMetrics.ascent + text.fontMetrics.leading)
    val ascent: Float = -text.fontMetrics.ascent
}

@Composable
private fun TerminalSessionView(repo: Repository, s: TermSession, onClose: () -> Unit) {
    val context = LocalContext.current
    val view = LocalView.current
    val density = LocalDensity.current

    var fontSp by remember { mutableFloatStateOf(repo.store.terminalFontSp) }
    val regular = remember { ResourcesCompat.getFont(context, R.font.space_mono_regular) ?: Typeface.MONOSPACE }
    val bold = remember { ResourcesCompat.getFont(context, R.font.space_mono_bold) ?: Typeface.DEFAULT_BOLD }
    val paints = remember(fontSp, density) { TermPaints(with(density) { fontSp.sp.toPx() }, regular, bold) }

    val emulator = remember(s.id) { TerminalEmulator(80, 24, 5000) }
    var frame by remember { mutableLongStateOf(0L) }
    var status by remember { mutableStateOf<Status>(Status.Busy("CONNECTING")) }
    var socket by remember { mutableStateOf<TerminalSocket?>(null) }
    var size by remember { mutableStateOf(IntSize.Zero) }
    var connectGen by remember { mutableIntStateOf(0) }
    var scrollOffset by remember { mutableIntStateOf(0) }
    var inputView by remember { mutableStateOf<TerminalInputView?>(null) }
    val mods = remember { ModState() }

    val cols = max(2, (size.width / paints.cellW).toInt())
    val rows = max(2, (size.height / paints.cellH).toInt())
    val sized = size.width > 0 && size.height > 0

    fun sendBytes(b: ByteArray) {
        scrollOffset = 0
        socket?.send(b)
    }

    fun showKeyboard() {
        inputView?.let {
            it.requestFocus()
            (context.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager).showSoftInput(it, 0)
        }
    }

    DisposableEffect(emulator) {
        emulator.onUpdate = { frame = emulator.version }
        emulator.onReply = { socket?.send(it) }
        emulator.onBell = { view.post { Haptics.heavy(view) } }
        view.keepScreenOn = true
        onDispose {
            emulator.onUpdate = null
            emulator.onReply = null
            emulator.onBell = null
            view.keepScreenOn = false
            repo.store.terminalFontSp = fontSp
        }
    }

    // One connection per (session, reconnect request); the first one waits for the canvas to be measured.
    LaunchedEffect(s.id, connectGen, sized) {
        if (!sized) return@LaunchedEffect
        val client = repo.clientOrNull() ?: return@LaunchedEffect
        status = Status.Busy("CONNECTING")
        emulator.resize(cols, rows)
        emulator.write("\u001Bc")
        var exited = false
        val sock = client.openTerminal(
            s.id, cols, rows,
            object : TerminalListener {
                override fun onOpen() { status = Status.Ok("LIVE") }
                override fun onOutput(data: ByteArray) { emulator.write(data) }
                override fun onExit(code: Int) {
                    exited = true
                    status = Status.Info("EXITED $code")
                }
                override fun onClosed(error: Throwable?, httpStatus: Int?) {
                    if (exited) return
                    status = when {
                        httpStatus == 401 -> Status.Error("UNAUTHORIZED")
                        httpStatus != null -> Status.Error("HTTP $httpStatus")
                        error != null -> Status.Error(Repository.describe(error))
                        else -> Status.Alert("DISCONNECTED")
                    }
                }
            },
        )
        socket = sock
        try {
            awaitCancellation()
        } finally {
            sock.close()
            if (socket === sock) socket = null
        }
    }

    // Keep the PTY and the model in step with the canvas (rotation, keyboard, pinch zoom).
    LaunchedEffect(cols, rows) {
        val sock = socket ?: return@LaunchedEffect
        delay(80)
        emulator.resize(cols, rows)
        sock.resize(cols, rows)
    }

    LaunchedEffect(inputView) {
        if (inputView != null) {
            delay(250)
            showKeyboard()
        }
    }

    BackHandler { onClose() }

    Column(Modifier.fillMaxSize().background(Color.Black).systemBarsPadding().imePadding()) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            val src = remember { MutableInteractionSource() }
            Label("< BACK", Modifier.clickable(src, null) { Haptics.tap(view); onClose() }.padding(vertical = 6.dp), color = NColor.Gray90)
            Label(s.title.ifBlank { s.id }, Modifier.weight(1f).padding(horizontal = 12.dp), color = NColor.White)
            if (status is Status.Alert || status is Status.Error) {
                Label("RECONNECT", Modifier.clickable(src, null) { Haptics.tap(view); connectGen++ }.padding(end = 10.dp), color = NColor.White)
            }
            StatusLine(status)
        }

        Box(Modifier.weight(1f).fillMaxWidth()) {
            Canvas(
                Modifier
                    .fillMaxSize()
                    .onSizeChanged { size = it }
                    .pointerInput(Unit) {
                        detectTapGestures(
                            onTap = { showKeyboard() },
                            onLongPress = {
                                val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                                val text = cm.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.coerceToText(context)?.toString()
                                if (!text.isNullOrEmpty()) {
                                    Haptics.heavy(view)
                                    sendBytes(KeyEncoder.paste(text, emulator.bracketedPaste))
                                }
                            },
                        )
                    }
                    .pointerInput(paints) {
                        var acc = 0f
                        detectTransformGestures { _, pan, zoom, _ ->
                            if (zoom != 1f) fontSp = (fontSp * zoom).coerceIn(6f, 30f)
                            acc += pan.y
                            val step = paints.cellH
                            while (acc >= step || acc <= -step) {
                                val up = acc > 0 // finger moves down: show older content
                                acc += if (up) -step else step
                                if (emulator.altScreenActive) {
                                    sendBytes(KeyEncoder.encodeKey(if (up) TermKey.UP else TermKey.DOWN, appCursor = emulator.applicationCursorKeys))
                                } else {
                                    scrollOffset = (scrollOffset + if (up) 1 else -1).coerceIn(0, emulator.scrollbackSize)
                                }
                            }
                        }
                    },
            ) {
                frame // subscribe to emulator updates
                scrollOffset
                drawIntoCanvas { c ->
                    drawTerminal(c.nativeCanvas, emulator, paints, scrollOffset, rows)
                }
            }
            AndroidView(
                modifier = Modifier.size(1.dp),
                factory = { ctx ->
                    TerminalInputView(ctx).also {
                        it.mods = mods
                        it.send = { b -> sendBytes(b) }
                        it.appCursorKeys = { emulator.applicationCursorKeys }
                        inputView = it
                    }
                },
            )
        }

        ExtraKeys(mods, emulator, view) { sendBytes(it) }
    }
}

private fun drawTerminal(canvas: android.graphics.Canvas, em: TerminalEmulator, p: TermPaints, scrollOffset: Int, visibleRows: Int) {
    canvas.drawColor(DEFAULT_BG)
    em.read { e ->
        val reverse = e.reverseVideo
        val buf = CharArray(1)
        for (y in 0 until minOf(visibleRows, e.rows)) {
            val line = e.lineAt(y - scrollOffset) ?: continue
            val top = y * p.cellH
            val baseline = top + p.ascent
            val n = minOf(line.cols, e.cols)
            for (x in 0 until n) {
                val attr = line.attr[x]
                if ((attr and Attr.WIDE_TAIL) != 0) continue
                val isBold = (attr and Attr.BOLD) != 0
                var fg = resolve(line.fg[x], true, isBold)
                var bg = resolve(line.bg[x], false, false)
                if (reverse) { val t = fg; fg = bg; bg = t }
                if ((attr and Attr.INVERSE) != 0) { val t = fg; fg = bg; bg = t }
                if ((attr and Attr.DIM) != 0) fg = blend(fg, bg, 0.6f)
                val w = if ((attr and Attr.WIDE) != 0) 2 else 1
                val left = x * p.cellW
                if (bg != DEFAULT_BG) {
                    p.fill.color = bg
                    canvas.drawRect(left, top, left + w * p.cellW, top + p.cellH, p.fill)
                }
                val cp = line.chars[x]
                if (cp != 0 && cp != 0x20 && (attr and Attr.INVISIBLE) == 0) {
                    val paint = if (isBold) p.boldText else p.text
                    paint.color = fg
                    paint.textSkewX = if ((attr and Attr.ITALIC) != 0) -0.2f else 0f
                    if (cp < 0x10000) {
                        buf[0] = cp.toChar()
                        canvas.drawText(buf, 0, 1, left, baseline, paint)
                    } else {
                        canvas.drawText(String(Character.toChars(cp)), left, baseline, paint)
                    }
                }
                if ((attr and Attr.UNDERLINE) != 0) {
                    p.fill.color = fg
                    canvas.drawRect(left, top + p.cellH - 2f, left + w * p.cellW, top + p.cellH - 1f, p.fill)
                }
                if ((attr and Attr.STRIKE) != 0) {
                    p.fill.color = fg
                    canvas.drawRect(left, top + p.cellH / 2, left + w * p.cellW, top + p.cellH / 2 + 1f, p.fill)
                }
            }
        }
        if (e.cursorVisible && scrollOffset == 0 && e.cursorY < visibleRows) {
            val cx = e.cursorX * p.cellW
            val cy = e.cursorY * p.cellH
            p.fill.color = 0xFFFFFFFF.toInt()
            when (e.cursorStyle) {
                3, 4 -> canvas.drawRect(cx, cy + p.cellH - 3f, cx + p.cellW, cy + p.cellH, p.fill)
                5, 6 -> canvas.drawRect(cx, cy, cx + 2f, cy + p.cellH, p.fill)
                else -> {
                    canvas.drawRect(cx, cy, cx + p.cellW, cy + p.cellH, p.fill)
                    val cp = e.cpAt(e.cursorX, e.cursorY)
                    if (cp != 0 && cp != 0x20) {
                        p.text.color = DEFAULT_BG
                        p.text.textSkewX = 0f
                        canvas.drawText(String(Character.toChars(cp)), cx, cy + p.ascent, p.text)
                    }
                }
            }
        }
    }
}

@Composable
private fun ExtraKeys(mods: ModState, em: TerminalEmulator, view: android.view.View, send: (ByteArray) -> Unit) {
    fun key(k: TermKey) {
        send(KeyEncoder.encodeKey(k, ctrl = mods.ctrl, alt = mods.alt, appCursor = em.applicationCursorKeys))
        mods.clear()
    }
    fun text(t: String) {
        send(KeyEncoder.encodeText(t, ctrl = mods.ctrl, alt = mods.alt))
        mods.clear()
    }
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 4.dp, vertical = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        ExtraKey("ESC", view) { key(TermKey.ESCAPE) }
        ExtraKey("TAB", view) { key(TermKey.TAB) }
        ExtraKey("CTRL", view, active = mods.ctrl) { mods.ctrl = !mods.ctrl }
        ExtraKey("ALT", view, active = mods.alt) { mods.alt = !mods.alt }
        ExtraKey("←", view) { key(TermKey.LEFT) }
        ExtraKey("↑", view) { key(TermKey.UP) }
        ExtraKey("↓", view) { key(TermKey.DOWN) }
        ExtraKey("→", view) { key(TermKey.RIGHT) }
        ExtraKey("|", view) { text("|") }
        ExtraKey("-", view) { text("-") }
        ExtraKey("/", view) { text("/") }
    }
}

@Composable
private fun androidx.compose.foundation.layout.RowScope.ExtraKey(
    label: String,
    view: android.view.View,
    active: Boolean = false,
    onClick: () -> Unit,
) {
    val src = remember { MutableInteractionSource() }
    val pressed by src.collectIsPressedAsState()
    val inverted = pressed || active
    Box(
        Modifier
            .weight(1f)
            .height(40.dp)
            .background(if (inverted) NColor.White else Color.Transparent)
            .border(1.dp, if (inverted) NColor.White else NColor.BorderStrong)
            .clickable(src, null) {
                Haptics.tick(view)
                onClick()
            },
        contentAlignment = Alignment.Center,
    ) {
        Text(label, style = NType.Label.copy(color = if (inverted) NColor.Black else NColor.White, fontSize = 11.sp, letterSpacing = 0.sp))
    }
}
