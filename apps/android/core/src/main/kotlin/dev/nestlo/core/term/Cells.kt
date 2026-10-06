package dev.nestlo.core.term

/**
 * Cell colour encoding. The top byte is the kind:
 * 0 = terminal default, 1 = palette index (low byte), 2 = 24-bit RGB (low 24 bits).
 */
object TermColor {
    const val DEFAULT = 0
    private const val PALETTE = 0x01000000
    private const val RGB = 0x02000000

    fun palette(index: Int): Int = PALETTE or (index and 0xFF)
    fun rgb(r: Int, g: Int, b: Int): Int = RGB or ((r and 0xFF) shl 16) or ((g and 0xFF) shl 8) or (b and 0xFF)

    fun isDefault(c: Int): Boolean = (c ushr 24) == 0
    fun isPalette(c: Int): Boolean = (c ushr 24) == 1
    fun isRgb(c: Int): Boolean = (c ushr 24) == 2
    fun paletteIndex(c: Int): Int = c and 0xFF
    fun rgbValue(c: Int): Int = c and 0xFFFFFF

    /** The xterm 256-colour palette as 0xRRGGBB, with the 16 base colours supplied by [base16]. */
    fun paletteRgb(index: Int, base16: IntArray = XTERM_16): Int {
        val i = index and 0xFF
        if (i < 16) return base16[i]
        if (i < 232) {
            val n = i - 16
            val r = n / 36
            val g = (n / 6) % 6
            val b = n % 6
            fun level(v: Int) = if (v == 0) 0 else 55 + 40 * v
            return (level(r) shl 16) or (level(g) shl 8) or level(b)
        }
        val v = 8 + (i - 232) * 10
        return (v shl 16) or (v shl 8) or v
    }

    val XTERM_16: IntArray = intArrayOf(
        0x000000, 0xCD0000, 0x00CD00, 0xCDCD00, 0x0000EE, 0xCD00CD, 0x00CDCD, 0xE5E5E5,
        0x7F7F7F, 0xFF0000, 0x00FF00, 0xFFFF00, 0x5C5CFF, 0xFF00FF, 0x00FFFF, 0xFFFFFF,
    )
}

/** Attribute bit flags stored per cell. */
object Attr {
    const val BOLD = 1
    const val ITALIC = 2
    const val UNDERLINE = 4
    const val INVERSE = 8
    const val DIM = 16
    const val STRIKE = 32

    /** First cell of a double-width character. */
    const val WIDE = 64

    /** Placeholder right half of a double-width character. */
    const val WIDE_TAIL = 128
    const val BLINK = 256
    const val INVISIBLE = 512

    /** Bits that SGR controls (everything except the width markers). */
    const val STYLE_MASK = BOLD or ITALIC or UNDERLINE or INVERSE or DIM or STRIKE or BLINK or INVISIBLE
}

/** One row of cells, stored column-wise in primitive arrays. Code point 0 is an empty cell. */
class Line(val cols: Int) {
    val chars = IntArray(cols)
    val fg = IntArray(cols)
    val bg = IntArray(cols)
    val attr = IntArray(cols)

    /** True when this row continued onto the next one by autowrap. */
    var wrapped = false

    fun clear(from: Int, to: Int, bgColor: Int) {
        val a = from.coerceIn(0, cols)
        val b = to.coerceIn(0, cols)
        for (i in a until b) {
            chars[i] = 0
            fg[i] = 0
            bg[i] = bgColor
            attr[i] = 0
        }
    }

    fun clearAll(bgColor: Int = 0) {
        clear(0, cols, bgColor)
        wrapped = false
    }

    fun copyCell(from: Int, to: Int) {
        chars[to] = chars[from]
        fg[to] = fg[from]
        bg[to] = bg[from]
        attr[to] = attr[from]
    }

    fun resized(newCols: Int): Line {
        val n = Line(newCols)
        val m = minOf(cols, newCols)
        System.arraycopy(chars, 0, n.chars, 0, m)
        System.arraycopy(fg, 0, n.fg, 0, m)
        System.arraycopy(bg, 0, n.bg, 0, m)
        System.arraycopy(attr, 0, n.attr, 0, m)
        // Do not leave half of a wide character at the new right edge.
        if (m > 0 && (n.attr[m - 1] and Attr.WIDE) != 0 && newCols < cols) {
            n.chars[m - 1] = 0
            n.attr[m - 1] = 0
        }
        n.wrapped = wrapped
        return n
    }

    fun text(trimEnd: Boolean = true): String {
        val sb = StringBuilder()
        for (i in 0 until cols) {
            if ((attr[i] and Attr.WIDE_TAIL) != 0) continue
            val c = chars[i]
            if (c == 0) sb.append(' ') else sb.appendCodePoint(c)
        }
        return if (trimEnd) sb.toString().trimEnd() else sb.toString()
    }
}

/** Best-effort display width of a code point: 0 (combining), 1 or 2 (east asian wide / emoji). */
object CharWidth {
    fun of(cp: Int): Int {
        if (cp < 0x300) return 1
        if (isZeroWidth(cp)) return 0
        return if (isWide(cp)) 2 else 1
    }

    private fun isZeroWidth(cp: Int): Boolean =
        cp in 0x0300..0x036F || cp in 0x0483..0x0489 || cp in 0x0591..0x05BD ||
            cp in 0x0610..0x061A || cp in 0x064B..0x065F || cp in 0x0E31..0x0E3A && cp != 0x0E32 && cp != 0x0E33 ||
            cp in 0x1AB0..0x1AFF || cp in 0x1DC0..0x1DFF || cp in 0x200B..0x200F || cp in 0x202A..0x202E ||
            cp in 0x2060..0x2064 || cp in 0x20D0..0x20FF || cp in 0xFE00..0xFE0F || cp in 0xFE20..0xFE2F ||
            cp == 0xFEFF || cp in 0xE0100..0xE01EF

    private fun isWide(cp: Int): Boolean =
        cp in 0x1100..0x115F || cp in 0x2E80..0x303E || cp in 0x3041..0x33FF || cp in 0x3400..0x4DBF ||
            cp in 0x4E00..0x9FFF || cp in 0xA000..0xA4CF || cp in 0xAC00..0xD7A3 || cp in 0xF900..0xFAFF ||
            cp in 0xFE30..0xFE6F || cp in 0xFF00..0xFF60 || cp in 0xFFE0..0xFFE6 ||
            cp in 0x1F300..0x1F64F || cp in 0x1F680..0x1F6FF || cp in 0x1F900..0x1F9FF ||
            cp in 0x1FA70..0x1FAFF || cp in 0x20000..0x3FFFD ||
            cp == 0x231A || cp == 0x231B || cp == 0x23E9 || cp == 0x23EA || cp == 0x23F0 || cp == 0x23F3 ||
            cp == 0x2614 || cp == 0x2615 || cp == 0x267F || cp == 0x2693 || cp == 0x26A1 || cp == 0x26AA ||
            cp == 0x26AB || cp == 0x26BD || cp == 0x26BE || cp == 0x26C4 || cp == 0x26C5 || cp == 0x26CE ||
            cp == 0x26D4 || cp == 0x26EA || cp == 0x26F2 || cp == 0x26F3 || cp == 0x26F5 || cp == 0x26FA ||
            cp == 0x26FD || cp == 0x2705 || cp == 0x270A || cp == 0x270B || cp == 0x2728 || cp == 0x274C ||
            cp == 0x274E || cp in 0x2753..0x2755 || cp == 0x2757 || cp in 0x2795..0x2797 || cp == 0x27B0 ||
            cp == 0x27BF || cp == 0x2B1B || cp == 0x2B1C || cp == 0x2B50 || cp == 0x2B55
}
