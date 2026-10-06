package dev.nestlo.core.term

/** Non-text keys the keyboard UI can produce. */
enum class TermKey {
    UP, DOWN, LEFT, RIGHT, HOME, END, PAGE_UP, PAGE_DOWN, INSERT, DELETE,
    ESCAPE, TAB, ENTER, BACKSPACE,
    F1, F2, F3, F4, F5, F6, F7, F8, F9, F10, F11, F12,
}

/** Turns key presses into the bytes a PTY expects (xterm conventions). */
object KeyEncoder {
    private const val ESC = 0x1B

    private fun modParam(shift: Boolean, alt: Boolean, ctrl: Boolean): Int =
        1 + (if (shift) 1 else 0) + (if (alt) 2 else 0) + (if (ctrl) 4 else 0)

    private fun s(text: String): ByteArray = text.toByteArray(Charsets.UTF_8)

    fun encodeKey(
        key: TermKey,
        ctrl: Boolean = false,
        alt: Boolean = false,
        shift: Boolean = false,
        appCursor: Boolean = false,
    ): ByteArray {
        val mod = modParam(shift, alt, ctrl)
        val modified = mod > 1
        return when (key) {
            TermKey.UP -> cursorKey('A', modified, mod, appCursor)
            TermKey.DOWN -> cursorKey('B', modified, mod, appCursor)
            TermKey.RIGHT -> cursorKey('C', modified, mod, appCursor)
            TermKey.LEFT -> cursorKey('D', modified, mod, appCursor)
            TermKey.HOME -> cursorKey('H', modified, mod, appCursor)
            TermKey.END -> cursorKey('F', modified, mod, appCursor)
            TermKey.PAGE_UP -> tilde(5, modified, mod)
            TermKey.PAGE_DOWN -> tilde(6, modified, mod)
            TermKey.INSERT -> tilde(2, modified, mod)
            TermKey.DELETE -> tilde(3, modified, mod)
            TermKey.ESCAPE -> if (alt) byteArrayOf(ESC.toByte(), ESC.toByte()) else byteArrayOf(ESC.toByte())
            TermKey.TAB -> when {
                shift -> s("\u001B[Z")
                alt -> byteArrayOf(ESC.toByte(), 0x09)
                else -> byteArrayOf(0x09)
            }
            TermKey.ENTER -> if (alt) byteArrayOf(ESC.toByte(), 0x0D) else byteArrayOf(0x0D)
            TermKey.BACKSPACE -> {
                val b = if (ctrl) 0x08 else 0x7F
                if (alt) byteArrayOf(ESC.toByte(), b.toByte()) else byteArrayOf(b.toByte())
            }
            TermKey.F1 -> ss3(modified, mod, 'P')
            TermKey.F2 -> ss3(modified, mod, 'Q')
            TermKey.F3 -> ss3(modified, mod, 'R')
            TermKey.F4 -> ss3(modified, mod, 'S')
            TermKey.F5 -> tilde(15, modified, mod)
            TermKey.F6 -> tilde(17, modified, mod)
            TermKey.F7 -> tilde(18, modified, mod)
            TermKey.F8 -> tilde(19, modified, mod)
            TermKey.F9 -> tilde(20, modified, mod)
            TermKey.F10 -> tilde(21, modified, mod)
            TermKey.F11 -> tilde(23, modified, mod)
            TermKey.F12 -> tilde(24, modified, mod)
        }
    }

    private fun cursorKey(final: Char, modified: Boolean, mod: Int, app: Boolean): ByteArray = when {
        modified -> s("\u001B[1;$mod$final")
        app -> s("\u001BO$final")
        else -> s("\u001B[$final")
    }

    private fun ss3(modified: Boolean, mod: Int, final: Char): ByteArray =
        if (modified) s("\u001B[1;$mod$final") else s("\u001BO$final")

    private fun tilde(n: Int, modified: Boolean, mod: Int): ByteArray =
        if (modified) s("\u001B[$n;$mod~") else s("\u001B[$n~")

    /**
     * Encodes typed text. With [ctrl], a single ASCII character becomes its control code
     * (Ctrl+A = 0x01 ... Ctrl+_ = 0x1F, Ctrl+Space = 0x00, Ctrl+? = 0x7F). With [alt] the
     * result is prefixed with ESC. Other text is sent as UTF-8.
     */
    fun encodeText(text: String, ctrl: Boolean = false, alt: Boolean = false): ByteArray {
        if (text.isEmpty()) return ByteArray(0)
        val body: ByteArray = if (ctrl && text.codePointCount(0, text.length) == 1) {
            controlCode(text.codePointAt(0))?.let { byteArrayOf(it.toByte()) } ?: s(text)
        } else {
            s(text)
        }
        return if (alt) byteArrayOf(ESC.toByte()) + body else body
    }

    private fun controlCode(cp: Int): Int? = when (cp) {
        in 'a'.code..'z'.code -> cp - 'a'.code + 1
        in 'A'.code..'Z'.code -> cp - 'A'.code + 1
        ' '.code, '@'.code, '2'.code -> 0
        '['.code, '3'.code -> 0x1B
        '\\'.code, '4'.code -> 0x1C
        ']'.code, '5'.code -> 0x1D
        '^'.code, '6'.code, '~'.code -> 0x1E
        '_'.code, '7'.code, '/'.code -> 0x1F
        '?'.code, '8'.code -> 0x7F
        else -> null
    }

    /** Wraps pasted text in bracketed-paste markers when the application asked for them. */
    fun paste(text: String, bracketed: Boolean): ByteArray {
        val normalized = text.replace("\u001B[201~", "").replace("\r\n", "\r").replace('\n', '\r')
        return if (bracketed) s("\u001B[200~$normalized\u001B[201~") else s(normalized)
    }
}
