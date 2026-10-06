package dev.nestlo.core.term

/**
 * A VT100/xterm screen model. Feed it the raw bytes of a PTY with [write]; read the grid back
 * with [lineAt] / [cpAt] and friends. All public methods are safe to call from any thread;
 * for a consistent multi-cell read (drawing a frame) wrap the reads in [read].
 *
 * Supported: UTF-8 (split across writes), C0 controls, CSI cursor/erase/insert/delete/scroll
 * sequences, DECSTBM scroll regions, SGR with 16/256/true colour, DEC special graphics
 * charsets, save/restore cursor, alternate screen (47/1047/1049), autowrap with deferred wrap,
 * origin mode, insert mode, bracketed paste, application cursor keys, tab stops, OSC titles.
 */
class TerminalEmulator(
    cols: Int,
    rows: Int,
    private val maxScrollback: Int = 2000,
) {
    var cols: Int = cols.coerceAtLeast(1)
        private set
    var rows: Int = rows.coerceAtLeast(1)
        private set

    private var primary: Array<Line> = Array(this.rows) { Line(this.cols) }
    private var alt: Array<Line> = Array(this.rows) { Line(this.cols) }
    private var screen: Array<Line> = primary
    private val scrollback = ArrayDeque<Line>()

    // ---- public state
    var cursorX: Int = 0
        private set
    var cursorY: Int = 0
        private set
    var cursorVisible: Boolean = true
        private set

    /** DECSCUSR style: 0/1/2 block, 3/4 underline, 5/6 bar. */
    var cursorStyle: Int = 0
        private set
    var altScreenActive: Boolean = false
        private set
    var applicationCursorKeys: Boolean = false
        private set
    var bracketedPaste: Boolean = false
        private set
    var autoWrap: Boolean = true
        private set
    var reverseVideo: Boolean = false
        private set
    var originMode: Boolean = false
        private set
    var insertMode: Boolean = false
        private set

    /** Highest active xterm mouse mode (1000/1002/1003) or 0. */
    var mouseMode: Int = 0
        private set
    var mouseSgr: Boolean = false
        private set
    var title: String = ""
        private set
    val scrollbackSize: Int get() = scrollback.size

    /** Incremented on every [write] / [resize]; lets a renderer detect change cheaply. */
    @Volatile
    var version: Long = 0
        private set

    /** Replies to queries (DSR, DA). Bytes should be sent to the PTY as keyboard input. */
    @Volatile
    var onReply: ((ByteArray) -> Unit)? = null

    @Volatile
    var onBell: (() -> Unit)? = null

    @Volatile
    var onTitleChanged: ((String) -> Unit)? = null

    @Volatile
    var onUpdate: (() -> Unit)? = null

    // ---- internal state
    private var scrollTop = 0
    private var scrollBottom = this.rows - 1
    private var wrapNext = false
    private var penFg = 0
    private var penBg = 0
    private var penAttr = 0
    private var tabs = BooleanArray(this.cols).also { initTabs(it) }
    private val charsets = IntArray(4) { 'B'.code }
    private var glSet = 0
    private var lastPrinted = 0

    private class Saved(
        val x: Int, val y: Int, val fg: Int, val bg: Int, val attr: Int,
        val wrapNext: Boolean, val origin: Boolean, val charsets: IntArray, val gl: Int,
    )

    private var saved: Saved? = null
    private var saved1049: Saved? = null

    // ---- parser state
    private var state = GROUND
    private var strKind = 0
    private val params = IntArray(MAX_PARAMS)
    private val subFlag = BooleanArray(MAX_PARAMS)
    private var paramCount = 0
    private var curParam = -1
    private var nextIsSub = false
    private var paramPending = false
    private var privPrefix = 0
    private var interm = 0
    private var csiInvalid = false
    private val strBuf = StringBuilder()
    private var utf8Pending = 0
    private var utf8Cp = 0
    private var utf8Min = 0

    // ================================================================== public API

    fun write(bytes: ByteArray, offset: Int = 0, length: Int = bytes.size - offset) {
        synchronized(this) {
            for (i in offset until offset + length) feedByte(bytes[i].toInt() and 0xFF)
            version++
        }
        onUpdate?.invoke()
    }

    fun write(text: String) {
        val b = text.toByteArray(Charsets.UTF_8)
        write(b, 0, b.size)
    }

    fun <T> read(block: (TerminalEmulator) -> T): T = synchronized(this) { block(this) }

    /** Row at [line]: 0 until [rows] is the live screen, negative values reach into scrollback (-1 newest). */
    fun lineAt(line: Int): Line? = synchronized(this) {
        when {
            line >= rows -> null
            line >= 0 -> screen[line]
            else -> scrollback.getOrNull(scrollback.size + line)
        }
    }

    fun cpAt(x: Int, line: Int): Int = lineAt(line)?.takeIf { x in 0 until it.cols }?.chars?.get(x) ?: 0
    fun fgAt(x: Int, line: Int): Int = lineAt(line)?.takeIf { x in 0 until it.cols }?.fg?.get(x) ?: 0
    fun bgAt(x: Int, line: Int): Int = lineAt(line)?.takeIf { x in 0 until it.cols }?.bg?.get(x) ?: 0
    fun attrAt(x: Int, line: Int): Int = lineAt(line)?.takeIf { x in 0 until it.cols }?.attr?.get(x) ?: 0

    fun lineText(line: Int): String = lineAt(line)?.text() ?: ""

    /** The visible screen as text, one row per line, trailing blanks trimmed (for tests and copy). */
    fun screenText(): String = synchronized(this) { (0 until rows).joinToString("\n") { screen[it].text() } }

    fun resize(newCols: Int, newRows: Int) {
        val nc = newCols.coerceAtLeast(1)
        val nr = newRows.coerceAtLeast(1)
        synchronized(this) {
            if (nc == cols && nr == rows) return
            doResize(nc, nr)
            version++
        }
        onUpdate?.invoke()
    }

    /** Resets to power-on state and clears the screen (keeps scrollback). */
    fun reset() {
        synchronized(this) {
            fullReset()
            version++
        }
        onUpdate?.invoke()
    }

    // ================================================================== byte / code point input

    private fun feedByte(v: Int) {
        if (utf8Pending > 0) {
            if ((v and 0xC0) == 0x80) {
                utf8Cp = (utf8Cp shl 6) or (v and 0x3F)
                utf8Pending--
                if (utf8Pending == 0) {
                    val cp = utf8Cp
                    val bad = cp < utf8Min || cp > 0x10FFFF || cp in 0xD800..0xDFFF
                    feedCp(if (bad) 0xFFFD else cp)
                }
                return
            }
            utf8Pending = 0
            feedCp(0xFFFD)
        }
        when {
            v < 0x80 -> feedCp(v)
            (v and 0xE0) == 0xC0 -> { utf8Pending = 1; utf8Cp = v and 0x1F; utf8Min = 0x80 }
            (v and 0xF0) == 0xE0 -> { utf8Pending = 2; utf8Cp = v and 0x0F; utf8Min = 0x800 }
            (v and 0xF8) == 0xF0 -> { utf8Pending = 3; utf8Cp = v and 0x07; utf8Min = 0x10000 }
            else -> feedCp(0xFFFD)
        }
    }

    private fun feedCp(cp: Int) {
        if (cp < 0x20 || cp == 0x7F) {
            control(cp)
            return
        }
        when (state) {
            GROUND -> if (cp !in 0x80..0x9F) print(cp)
            ESC -> escDispatch(cp)
            ESC_INTERM -> escIntermediate(cp)
            CSI -> csiByte(cp)
            OSC, DCS, IGNORE_STR -> if (strKind == STR_OSC && strBuf.length < MAX_OSC) strBuf.appendCodePoint(cp)
            STRING_ESC -> {
                // ESC \ is ST. Any other byte aborts the string and starts a new escape sequence.
                endString()
                if (cp == '\\'.code) state = GROUND else { beginEscape(); escDispatch(cp) }
            }
        }
    }

    private fun control(c: Int) {
        when (c) {
            0x1B -> {
                when (state) {
                    OSC, DCS, IGNORE_STR -> state = STRING_ESC
                    STRING_ESC -> { endString(); beginEscape() }
                    else -> beginEscape()
                }
                return
            }
            0x18, 0x1A -> {
                if (state == OSC || state == DCS || state == IGNORE_STR || state == STRING_ESC) strBuf.setLength(0)
                state = GROUND
                return
            }
        }
        if (state == OSC && c == 0x07) {
            endString()
            state = GROUND
            return
        }
        if (state == OSC || state == DCS || state == IGNORE_STR) return
        if (state == STRING_ESC) {
            endString()
            state = GROUND
        }
        when (c) {
            0x07 -> onBell?.invoke()
            0x08 -> { if (cursorX > 0) cursorX--; wrapNext = false }
            0x09 -> { cursorX = nextTab(cursorX); wrapNext = false }
            0x0A, 0x0B, 0x0C -> { index(); wrapNext = false }
            0x0D -> { cursorX = 0; wrapNext = false }
            0x0E -> glSet = 1
            0x0F -> glSet = 0
        }
    }

    private fun beginEscape() {
        state = ESC
        interm = 0
    }

    // ================================================================== escape sequences

    private fun escDispatch(cp: Int) {
        state = GROUND
        when (cp) {
            '['.code -> {
                state = CSI
                paramCount = 0; curParam = -1; nextIsSub = false; paramPending = false
                privPrefix = 0; interm = 0; csiInvalid = false
            }
            ']'.code -> startString(STR_OSC, OSC)
            'P'.code -> startString(STR_DCS, DCS)
            '_'.code, '^'.code, 'X'.code -> startString(STR_OTHER, IGNORE_STR)
            '7'.code -> saved = saveCursor()
            '8'.code -> restoreCursor(saved)
            'D'.code -> { index(); wrapNext = false }
            'E'.code -> { cursorX = 0; index(); wrapNext = false }
            'M'.code -> { reverseIndex(); wrapNext = false }
            'H'.code -> if (cursorX in tabs.indices) tabs[cursorX] = true
            'c'.code -> fullReset()
            '='.code, '>'.code -> Unit
            '\\'.code -> Unit
            in 0x20..0x2F -> { interm = cp; state = ESC_INTERM }
            else -> Unit
        }
    }

    private fun escIntermediate(cp: Int) {
        if (cp in 0x20..0x2F) return
        state = GROUND
        when (interm) {
            '('.code -> charsets[0] = cp
            ')'.code -> charsets[1] = cp
            '*'.code -> charsets[2] = cp
            '+'.code -> charsets[3] = cp
            '#'.code -> if (cp == '8'.code) {
                for (y in 0 until rows) {
                    val l = screen[y]
                    for (x in 0 until cols) {
                        l.chars[x] = 'E'.code; l.fg[x] = 0; l.bg[x] = 0; l.attr[x] = 0
                    }
                }
            }
        }
    }

    private fun startString(kind: Int, st: Int) {
        strKind = kind
        strBuf.setLength(0)
        state = st
    }

    private fun endString() {
        if (strKind == STR_OSC) {
            val s = strBuf.toString()
            val semi = s.indexOf(';')
            val code = (if (semi < 0) s else s.substring(0, semi)).toIntOrNull()
            if (semi >= 0 && (code == 0 || code == 2)) {
                title = s.substring(semi + 1)
                onTitleChanged?.invoke(title)
            }
        }
        strBuf.setLength(0)
        strKind = 0
    }

    // ================================================================== CSI

    private fun csiByte(cp: Int) {
        when {
            cp in 0x30..0x39 -> {
                if (interm != 0) csiInvalid = true
                if (curParam < 0) curParam = 0
                curParam = minOf(curParam * 10 + (cp - 0x30), 99999)
                paramPending = true
            }
            cp == ':'.code || cp == ';'.code -> {
                if (interm != 0) csiInvalid = true
                pushParam()
                nextIsSub = cp == ':'.code
                paramPending = true
            }
            cp in 0x3C..0x3F -> {
                if (paramCount == 0 && !paramPending && interm == 0 && privPrefix == 0) privPrefix = cp else csiInvalid = true
            }
            cp in 0x20..0x2F -> { if (interm == 0) interm = cp }
            cp in 0x40..0x7E -> {
                if (paramPending) pushParam()
                state = GROUND
                if (!csiInvalid) csiDispatch(cp)
            }
            else -> state = GROUND
        }
    }

    private fun pushParam() {
        if (paramCount < MAX_PARAMS) {
            params[paramCount] = curParam
            subFlag[paramCount] = nextIsSub
            paramCount++
        }
        curParam = -1
        nextIsSub = false
    }

    /** Parameter [i], or [def] when missing or zero. */
    private fun p(i: Int, def: Int): Int = if (i < paramCount && params[i] > 0) params[i] else def

    private fun raw(i: Int): Int = if (i < paramCount && params[i] >= 0) params[i] else 0

    private fun csiDispatch(final: Int) {
        val priv = privPrefix
        if (interm != 0) {
            when {
                interm == ' '.code && final == 'q'.code -> cursorStyle = raw(0)
                interm == '!'.code && final == 'p'.code -> softReset()
            }
            return
        }
        if (priv == '?'.code) {
            when (final) {
                'h'.code -> for (i in 0 until paramCount) setPrivateMode(raw(i), true)
                'l'.code -> for (i in 0 until paramCount) setPrivateMode(raw(i), false)
                'n'.code -> if (raw(0) == 6) reply("\u001B[?${reportRow()};${cursorX + 1}R")
            }
            return
        }
        if (priv == '>'.code) {
            if (final == 'c'.code) reply("\u001B[>0;0;0c")
            return
        }
        if (priv != 0) return
        when (final) {
            '@'.code -> insertChars(p(0, 1))
            'A'.code -> moveUp(p(0, 1))
            'B'.code, 'e'.code -> moveDown(p(0, 1))
            'C'.code, 'a'.code -> { cursorX = (cursorX + p(0, 1)).coerceAtMost(cols - 1); wrapNext = false }
            'D'.code -> { cursorX = (cursorX - p(0, 1)).coerceAtLeast(0); wrapNext = false }
            'E'.code -> { moveDown(p(0, 1)); cursorX = 0 }
            'F'.code -> { moveUp(p(0, 1)); cursorX = 0 }
            'G'.code, '`'.code -> { cursorX = (p(0, 1) - 1).coerceIn(0, cols - 1); wrapNext = false }
            'H'.code, 'f'.code -> moveTo(p(1, 1) - 1, p(0, 1) - 1)
            'I'.code -> repeat(p(0, 1)) { cursorX = nextTab(cursorX) }.also { wrapNext = false }
            'J'.code -> eraseDisplay(raw(0))
            'K'.code -> eraseLine(raw(0))
            'L'.code -> insertLines(p(0, 1))
            'M'.code -> deleteLines(p(0, 1))
            'P'.code -> deleteChars(p(0, 1))
            'S'.code -> scrollUp(scrollTop, scrollBottom, p(0, 1), history = true)
            'T'.code -> if (paramCount <= 1) scrollDown(scrollTop, scrollBottom, p(0, 1))
            'X'.code -> eraseChars(p(0, 1))
            'Z'.code -> repeat(p(0, 1)) { cursorX = prevTab(cursorX) }.also { wrapNext = false }
            'b'.code -> if (lastPrinted != 0) repeat(p(0, 1).coerceAtMost(cols * rows)) { print(lastPrinted) }
            'c'.code -> if (raw(0) == 0) reply("\u001B[?1;2c")
            'd'.code -> moveTo(cursorX, p(0, 1) - 1, keepX = true)
            'g'.code -> when (raw(0)) {
                0 -> if (cursorX in tabs.indices) tabs[cursorX] = false
                3 -> tabs.fill(false)
            }
            'h'.code -> for (i in 0 until paramCount) setMode(raw(i), true)
            'l'.code -> for (i in 0 until paramCount) setMode(raw(i), false)
            'm'.code -> sgr()
            'n'.code -> when (raw(0)) {
                5 -> reply("\u001B[0n")
                6 -> reply("\u001B[${reportRow()};${cursorX + 1}R")
            }
            'r'.code -> setScrollRegion(p(0, 1), p(1, rows))
            's'.code -> saved = saveCursor()
            'u'.code -> restoreCursor(saved)
        }
    }

    private fun reportRow(): Int = (if (originMode) cursorY - scrollTop else cursorY) + 1

    private fun reply(s: String) {
        onReply?.invoke(s.toByteArray(Charsets.UTF_8))
    }

    private fun setMode(mode: Int, on: Boolean) {
        when (mode) {
            4 -> insertMode = on
        }
    }

    private fun setPrivateMode(mode: Int, on: Boolean) {
        when (mode) {
            1 -> applicationCursorKeys = on
            5 -> reverseVideo = on
            6 -> { originMode = on; moveTo(0, 0) }
            7 -> { autoWrap = on; if (!on) wrapNext = false }
            25 -> cursorVisible = on
            47, 1047 -> if (on) enterAlt(clear = false) else leaveAlt(clearFirst = mode == 1047)
            1048 -> if (on) saved1049 = saveCursor() else restoreCursor(saved1049)
            1049 -> if (on) {
                if (!altScreenActive) saved1049 = saveCursor()
                enterAlt(clear = true)
            } else {
                leaveAlt(clearFirst = false)
                restoreCursor(saved1049)
            }
            1000, 1002, 1003 -> mouseMode = if (on) mode else if (mouseMode == mode) 0 else mouseMode
            1006 -> mouseSgr = on
            2004 -> bracketedPaste = on
        }
    }

    // ================================================================== SGR

    private fun sgr() {
        if (paramCount == 0) {
            resetPen()
            return
        }
        var i = 0
        while (i < paramCount) {
            val v = if (params[i] < 0) 0 else params[i]
            when (v) {
                0 -> resetPen()
                1 -> penAttr = penAttr or Attr.BOLD
                2 -> penAttr = penAttr or Attr.DIM
                3 -> penAttr = penAttr or Attr.ITALIC
                4 -> {
                    // 4:0 clears underline; 4:n (styles) are all drawn as a plain underline.
                    if (i + 1 < paramCount && subFlag[i + 1]) {
                        penAttr = if (params[i + 1] == 0) penAttr and Attr.UNDERLINE.inv() else penAttr or Attr.UNDERLINE
                        i++
                    } else {
                        penAttr = penAttr or Attr.UNDERLINE
                    }
                }
                5, 6 -> penAttr = penAttr or Attr.BLINK
                7 -> penAttr = penAttr or Attr.INVERSE
                8 -> penAttr = penAttr or Attr.INVISIBLE
                9 -> penAttr = penAttr or Attr.STRIKE
                21 -> penAttr = penAttr or Attr.UNDERLINE
                22 -> penAttr = penAttr and (Attr.BOLD or Attr.DIM).inv()
                23 -> penAttr = penAttr and Attr.ITALIC.inv()
                24 -> penAttr = penAttr and Attr.UNDERLINE.inv()
                25 -> penAttr = penAttr and Attr.BLINK.inv()
                27 -> penAttr = penAttr and Attr.INVERSE.inv()
                28 -> penAttr = penAttr and Attr.INVISIBLE.inv()
                29 -> penAttr = penAttr and Attr.STRIKE.inv()
                in 30..37 -> penFg = TermColor.palette(v - 30)
                38, 48 -> {
                    val c = extendedColor(i)
                    if (c != null) {
                        if (v == 38) penFg = c.first else penBg = c.first
                        i += c.second
                    } else {
                        i = paramCount
                    }
                }
                39 -> penFg = 0
                in 40..47 -> penBg = TermColor.palette(v - 40)
                49 -> penBg = 0
                in 90..97 -> penFg = TermColor.palette(v - 90 + 8)
                in 100..107 -> penBg = TermColor.palette(v - 100 + 8)
            }
            i++
        }
    }

    /** Parses a 38/48 colour starting at [i]; returns (colour, extra params consumed) or null. */
    private fun extendedColor(i: Int): Pair<Int, Int>? {
        val colon = i + 1 < paramCount && subFlag[i + 1]
        if (colon) {
            var end = i + 1
            while (end + 1 < paramCount && subFlag[end + 1]) end++
            val mode = raw(i + 1)
            val consumed = end - i
            val rest = end - (i + 1)
            return when {
                mode == 5 && rest >= 1 -> TermColor.palette(raw(i + 2)) to consumed
                mode == 2 && rest >= 3 -> {
                    val r = raw(end - 2); val g = raw(end - 1); val b = raw(end)
                    TermColor.rgb(r, g, b) to consumed
                }
                else -> null
            }
        }
        if (i + 1 >= paramCount) return null
        return when (raw(i + 1)) {
            5 -> if (i + 2 < paramCount) TermColor.palette(raw(i + 2)) to 2 else null
            2 -> if (i + 4 < paramCount) TermColor.rgb(raw(i + 2), raw(i + 3), raw(i + 4)) to 4 else null
            else -> null
        }
    }

    private fun resetPen() {
        penFg = 0; penBg = 0; penAttr = 0
    }

    // ================================================================== printing

    private fun mapCharset(cp: Int): Int {
        if (charsets[glSet] == '0'.code && cp in 0x5F..0x7E) return DEC_GRAPHICS[cp - 0x5F]
        return cp
    }

    private fun print(raw: Int) {
        val cp = mapCharset(raw)
        var w = CharWidth.of(cp)
        if (w == 0) return
        if (cols < 2) w = 1
        if (wrapNext) {
            if (autoWrap) {
                screen[cursorY].wrapped = true
                cursorX = 0
                index()
            }
            wrapNext = false
        }
        if (w == 2 && cursorX == cols - 1) {
            if (!autoWrap) return
            val l = screen[cursorY]
            unlinkWide(l, cursorX)
            l.chars[cursorX] = 0; l.fg[cursorX] = penFg; l.bg[cursorX] = penBg; l.attr[cursorX] = 0
            l.wrapped = true
            cursorX = 0
            index()
        }
        if (insertMode) insertChars(w)
        val line = screen[cursorY]
        unlinkWide(line, cursorX)
        if (w == 2) unlinkWide(line, cursorX + 1)
        line.chars[cursorX] = cp
        line.fg[cursorX] = penFg
        line.bg[cursorX] = penBg
        line.attr[cursorX] = (penAttr and Attr.STYLE_MASK) or (if (w == 2) Attr.WIDE else 0)
        if (w == 2) {
            val t = cursorX + 1
            line.chars[t] = 0
            line.fg[t] = penFg
            line.bg[t] = penBg
            line.attr[t] = (penAttr and Attr.STYLE_MASK) or Attr.WIDE_TAIL
        }
        lastPrinted = raw
        cursorX += w
        if (cursorX >= cols) {
            cursorX = cols - 1
            wrapNext = autoWrap
        }
    }

    /** Before overwriting cell [x], blank the other half of a wide character that it belongs to. */
    private fun unlinkWide(line: Line, x: Int) {
        if (x < 0 || x >= line.cols) return
        val a = line.attr[x]
        if ((a and Attr.WIDE_TAIL) != 0 && x > 0) {
            line.chars[x - 1] = 0
            line.attr[x - 1] = line.attr[x - 1] and (Attr.WIDE or Attr.WIDE_TAIL).inv()
        }
        if ((a and Attr.WIDE) != 0 && x + 1 < line.cols) {
            line.chars[x + 1] = 0
            line.attr[x + 1] = line.attr[x + 1] and (Attr.WIDE or Attr.WIDE_TAIL).inv()
        }
    }

    // ================================================================== cursor movement & scrolling

    private fun moveTo(x: Int, y: Int, keepX: Boolean = false) {
        wrapNext = false
        if (!keepX) cursorX = x.coerceIn(0, cols - 1)
        cursorY = if (originMode) (scrollTop + y).coerceIn(scrollTop, scrollBottom) else y.coerceIn(0, rows - 1)
    }

    private fun moveUp(n: Int) {
        wrapNext = false
        val limit = if (cursorY >= scrollTop) scrollTop else 0
        cursorY = (cursorY - n).coerceAtLeast(limit)
    }

    private fun moveDown(n: Int) {
        wrapNext = false
        val limit = if (cursorY <= scrollBottom) scrollBottom else rows - 1
        cursorY = (cursorY + n).coerceAtMost(limit)
    }

    private fun index() {
        if (cursorY == scrollBottom) scrollUp(scrollTop, scrollBottom, 1, history = true)
        else if (cursorY < rows - 1) cursorY++
    }

    private fun reverseIndex() {
        if (cursorY == scrollTop) scrollDown(scrollTop, scrollBottom, 1)
        else if (cursorY > 0) cursorY--
    }

    private fun blankLine(): Line {
        val l = Line(cols)
        if (penBg != 0) l.clear(0, cols, penBg)
        return l
    }

    private fun scrollUp(top: Int, bottom: Int, count: Int, history: Boolean) {
        val n = count.coerceIn(0, bottom - top + 1)
        val toHistory = history && !altScreenActive && top == 0 && bottom == rows - 1
        repeat(n) {
            val removed = screen[top]
            System.arraycopy(screen, top + 1, screen, top, bottom - top)
            if (toHistory) {
                scrollback.addLast(removed)
                if (scrollback.size > maxScrollback) scrollback.removeFirst()
                screen[bottom] = blankLine()
            } else {
                removed.clearAll(penBg)
                screen[bottom] = removed
            }
        }
    }

    private fun scrollDown(top: Int, bottom: Int, count: Int) {
        val n = count.coerceIn(0, bottom - top + 1)
        repeat(n) {
            val removed = screen[bottom]
            System.arraycopy(screen, top, screen, top + 1, bottom - top)
            removed.clearAll(penBg)
            screen[top] = removed
        }
    }

    private fun setScrollRegion(top1: Int, bottom1: Int) {
        val t = top1 - 1
        val b = bottom1.coerceAtMost(rows) - 1
        if (t < b && t >= 0) {
            scrollTop = t
            scrollBottom = b
        } else if (top1 == 1 && bottom1 >= rows) {
            scrollTop = 0
            scrollBottom = rows - 1
        } else {
            return
        }
        moveTo(0, 0)
    }

    private fun nextTab(x: Int): Int {
        var i = x + 1
        while (i < cols && !(i < tabs.size && tabs[i])) i++
        return minOf(i, cols - 1)
    }

    private fun prevTab(x: Int): Int {
        var i = x - 1
        while (i > 0 && !(i < tabs.size && tabs[i])) i--
        return maxOf(i, 0)
    }

    // ================================================================== erase / insert / delete

    private fun eraseRange(line: Line, from: Int, to: Int) {
        val a = from.coerceIn(0, cols)
        val b = to.coerceIn(0, cols)
        if (a >= b) return
        unlinkWide(line, a)
        unlinkWide(line, b - 1)
        line.clear(a, b, penBg)
    }

    private fun eraseDisplay(mode: Int) {
        wrapNext = false
        when (mode) {
            0 -> {
                eraseRange(screen[cursorY], cursorX, cols)
                for (y in cursorY + 1 until rows) screen[y].clearAll(penBg)
            }
            1 -> {
                for (y in 0 until cursorY) screen[y].clearAll(penBg)
                eraseRange(screen[cursorY], 0, cursorX + 1)
            }
            2 -> for (y in 0 until rows) screen[y].clearAll(penBg)
            3 -> scrollback.clear()
        }
    }

    private fun eraseLine(mode: Int) {
        wrapNext = false
        val l = screen[cursorY]
        when (mode) {
            0 -> eraseRange(l, cursorX, cols)
            1 -> eraseRange(l, 0, cursorX + 1)
            2 -> eraseRange(l, 0, cols)
        }
    }

    private fun eraseChars(n: Int) {
        wrapNext = false
        eraseRange(screen[cursorY], cursorX, cursorX + n)
    }

    private fun insertChars(count: Int) {
        wrapNext = false
        val l = screen[cursorY]
        val n = count.coerceAtMost(cols - cursorX)
        if (n <= 0) return
        unlinkWide(l, cursorX)
        for (x in cols - 1 downTo cursorX + n) l.copyCell(x - n, x)
        l.clear(cursorX, cursorX + n, penBg)
        // A wide character cut by the right edge loses its head.
        if ((l.attr[cols - 1] and Attr.WIDE) != 0) { l.chars[cols - 1] = 0; l.attr[cols - 1] = 0 }
    }

    private fun deleteChars(count: Int) {
        wrapNext = false
        val l = screen[cursorY]
        val n = count.coerceAtMost(cols - cursorX)
        if (n <= 0) return
        unlinkWide(l, cursorX)
        unlinkWide(l, cursorX + n - 1)
        for (x in cursorX until cols - n) l.copyCell(x + n, x)
        l.clear(cols - n, cols, penBg)
    }

    private fun insertLines(n: Int) {
        if (cursorY < scrollTop || cursorY > scrollBottom) return
        scrollDown(cursorY, scrollBottom, n)
        cursorX = 0
        wrapNext = false
    }

    private fun deleteLines(n: Int) {
        if (cursorY < scrollTop || cursorY > scrollBottom) return
        scrollUp(cursorY, scrollBottom, n, history = false)
        cursorX = 0
        wrapNext = false
    }

    // ================================================================== save / restore, alt screen, reset

    private fun saveCursor() = Saved(
        cursorX, cursorY, penFg, penBg, penAttr, wrapNext, originMode, charsets.copyOf(), glSet,
    )

    private fun restoreCursor(s: Saved?) {
        if (s == null) {
            cursorX = 0; cursorY = 0; resetPen(); wrapNext = false; originMode = false
            return
        }
        cursorX = s.x.coerceIn(0, cols - 1)
        cursorY = s.y.coerceIn(0, rows - 1)
        penFg = s.fg; penBg = s.bg; penAttr = s.attr
        wrapNext = s.wrapNext
        originMode = s.origin
        s.charsets.copyInto(charsets)
        glSet = s.gl
    }

    private fun enterAlt(clear: Boolean) {
        if (altScreenActive) return
        altScreenActive = true
        screen = alt
        if (clear) for (l in alt) l.clearAll(0)
        scrollTop = 0
        scrollBottom = rows - 1
        wrapNext = false
    }

    private fun leaveAlt(clearFirst: Boolean) {
        if (!altScreenActive) return
        if (clearFirst) for (l in alt) l.clearAll(0)
        altScreenActive = false
        screen = primary
        scrollTop = 0
        scrollBottom = rows - 1
        wrapNext = false
    }

    private fun softReset() {
        resetPen()
        originMode = false; insertMode = false; autoWrap = true
        applicationCursorKeys = false; cursorVisible = true
        scrollTop = 0; scrollBottom = rows - 1
        saved = null
        charsets.fill('B'.code); glSet = 0
        wrapNext = false
    }

    private fun fullReset() {
        softReset()
        bracketedPaste = false; reverseVideo = false; mouseMode = 0; mouseSgr = false; cursorStyle = 0
        altScreenActive = false
        screen = primary
        for (l in primary) l.clearAll(0)
        for (l in alt) l.clearAll(0)
        cursorX = 0; cursorY = 0
        tabs = BooleanArray(cols).also { initTabs(it) }
        state = GROUND
        utf8Pending = 0
        saved1049 = null
        title = ""
    }

    // ================================================================== resize

    private fun doResize(nc: Int, nr: Int) {
        // Primary screen: when it shrinks, keep the cursor row visible by moving top rows to history.
        var drop = 0
        if (nr < rows && !altScreenActive) drop = (cursorY - (nr - 1)).coerceIn(0, rows - nr)
        if (drop > 0) {
            for (i in 0 until drop) {
                scrollback.addLast(primary[i])
                if (scrollback.size > maxScrollback) scrollback.removeFirst()
            }
        }
        val newPrimary = Array(nr) { y ->
            val src = y + drop
            if (src < rows) primary[src].resized(nc) else Line(nc)
        }
        val newAlt = Array(nr) { y -> if (y < rows) alt[y].resized(nc) else Line(nc) }
        primary = newPrimary
        alt = newAlt
        screen = if (altScreenActive) alt else primary
        if (!altScreenActive) cursorY -= drop
        cols = nc
        rows = nr
        scrollTop = 0
        scrollBottom = nr - 1
        cursorX = cursorX.coerceIn(0, nc - 1)
        cursorY = cursorY.coerceIn(0, nr - 1)
        wrapNext = false
        val oldTabs = tabs
        tabs = BooleanArray(nc).also { t ->
            initTabs(t)
            for (i in 0 until minOf(oldTabs.size, nc)) t[i] = oldTabs[i]
        }
        saved?.let { saved = Saved(it.x.coerceAtMost(nc - 1), it.y.coerceAtMost(nr - 1), it.fg, it.bg, it.attr, false, it.origin, it.charsets, it.gl) }
    }

    private companion object {
        const val MAX_PARAMS = 32
        const val MAX_OSC = 4096

        const val GROUND = 0
        const val ESC = 1
        const val ESC_INTERM = 2
        const val CSI = 3
        const val OSC = 4
        const val DCS = 5
        const val IGNORE_STR = 6
        const val STRING_ESC = 7

        const val STR_OSC = 1
        const val STR_DCS = 2
        const val STR_OTHER = 3

        fun initTabs(t: BooleanArray) {
            for (i in t.indices) t[i] = i % 8 == 0 && i > 0
        }

        /** DEC special graphics for 0x5F..0x7E. */
        val DEC_GRAPHICS = intArrayOf(
            0x20, 0x25C6, 0x2592, 0x2409, 0x240C, 0x240D, 0x240A, 0xB0, 0xB1, 0x2424, 0x240B,
            0x2518, 0x2510, 0x250C, 0x2514, 0x253C, 0x23BA, 0x23BB, 0x2500, 0x23BC, 0x23BD,
            0x251C, 0x2524, 0x2534, 0x252C, 0x2502, 0x2264, 0x2265, 0x3C0, 0x2260, 0xA3, 0xB7,
        )
    }
}
