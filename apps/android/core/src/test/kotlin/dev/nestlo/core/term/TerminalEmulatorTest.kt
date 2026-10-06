package dev.nestlo.core.term

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

private const val E = "\u001B"

class TerminalEmulatorTest {
    private fun term(c: Int = 20, r: Int = 6) = TerminalEmulator(c, r)

    private fun TerminalEmulator.rowsText(): List<String> = screenText().split("\n")

    // ------------------------------------------------------------ basics

    @Test fun plainTextAndNewlines() {
        val t = term()
        t.write("hello\r\nworld")
        assertEquals("hello", t.lineText(0))
        assertEquals("world", t.lineText(1))
        assertEquals(5, t.cursorX)
        assertEquals(1, t.cursorY)
    }

    @Test fun lfAloneKeepsColumn() {
        val t = term()
        t.write("ab\ncd")
        assertEquals("ab", t.lineText(0))
        assertEquals("  cd", t.lineText(1))
    }

    @Test fun backspaceTabAndCr() {
        val t = term()
        t.write("abc\b\bX\tY\rZ")
        assertEquals("ZX", t.lineText(0).substring(0, 2))
        assertEquals('Y', t.cpAt(8, 0).toChar())
        assertEquals('X', t.cpAt(1, 0).toChar())
    }

    @Test fun autowrapIsDeferred() {
        val t = term(5, 3)
        t.write("abcde")
        assertEquals(4, t.cursorX)
        assertEquals(0, t.cursorY)
        t.write("f")
        assertEquals("abcde", t.lineText(0))
        assertEquals("f", t.lineText(1))
        assertTrue(t.lineAt(0)!!.wrapped)
    }

    @Test fun autowrapOffOverwritesLastColumn() {
        val t = term(5, 3)
        t.write("$E[?7labcdefg")
        assertEquals("abcdg", t.lineText(0))
        assertEquals("", t.lineText(1))
        assertFalse(t.autoWrap)
        t.write("$E[?7h")
        assertTrue(t.autoWrap)
    }

    @Test fun scrollsAtBottomAndKeepsHistory() {
        val t = term(10, 3)
        t.write("1\r\n2\r\n3\r\n4")
        assertEquals(listOf("2", "3", "4"), t.rowsText())
        assertEquals(1, t.scrollbackSize)
        assertEquals("1", t.lineText(-1))
    }

    // ------------------------------------------------------------ UTF-8

    @Test fun utf8SplitAcrossFrames() {
        val t = term()
        val bytes = "é€😀".toByteArray()
        for (b in bytes) t.write(byteArrayOf(b))
        assertEquals('é'.code, t.cpAt(0, 0))
        assertEquals('€'.code, t.cpAt(1, 0))
        assertEquals(0x1F600, t.cpAt(2, 0))
        assertEquals(Attr.WIDE, t.attrAt(2, 0) and Attr.WIDE)
        assertEquals(Attr.WIDE_TAIL, t.attrAt(3, 0) and Attr.WIDE_TAIL)
        assertEquals(4, t.cursorX)
    }

    @Test fun invalidUtf8BecomesReplacement() {
        val t = term()
        t.write(byteArrayOf(0xC3.toByte(), 'a'.code.toByte(), 0xFF.toByte(), 0xC0.toByte(), 0x80.toByte()))
        assertEquals(0xFFFD, t.cpAt(0, 0))
        assertEquals('a'.code, t.cpAt(1, 0))
        assertEquals(0xFFFD, t.cpAt(2, 0))
    }

    @Test fun wideCharWrapsInsteadOfSplitting() {
        val t = term(5, 3)
        t.write("abcd漢")
        assertEquals("abcd", t.lineText(0))
        assertEquals("漢", t.lineText(1))
    }

    @Test fun overwritingHalfOfWideClearsOther() {
        val t = term(6, 2)
        t.write("漢")
        t.write("$E[1;2HX")
        assertEquals(0, t.cpAt(0, 0))
        assertEquals('X'.code, t.cpAt(1, 0))
        assertEquals(0, t.attrAt(1, 0) and Attr.WIDE_TAIL)
    }

    @Test fun combiningMarksAreZeroWidth() {
        val t = term()
        t.write("éx")
        assertEquals('x'.code, t.cpAt(1, 0))
        assertEquals(2, t.cursorX)
    }

    // ------------------------------------------------------------ cursor movement

    @Test fun cursorPositioning() {
        val t = term()
        t.write("$E[3;5H")
        assertEquals(4, t.cursorX); assertEquals(2, t.cursorY)
        t.write("$E[A"); assertEquals(1, t.cursorY)
        t.write("$E[2B"); assertEquals(3, t.cursorY)
        t.write("$E[3C"); assertEquals(7, t.cursorX)
        t.write("$E[2D"); assertEquals(5, t.cursorX)
        t.write("$E[10G"); assertEquals(9, t.cursorX)
        t.write("$E[5d"); assertEquals(4, t.cursorY)
        t.write("$E[H"); assertEquals(0, t.cursorX); assertEquals(0, t.cursorY)
        t.write("$E[99;99H"); assertEquals(19, t.cursorX); assertEquals(5, t.cursorY)
        t.write("$E[0;0H"); assertEquals(0, t.cursorX); assertEquals(0, t.cursorY)
    }

    @Test fun cnlCplAndHvp() {
        val t = term()
        t.write("$E[3;4f$E[2E")
        assertEquals(0, t.cursorX); assertEquals(4, t.cursorY)
        t.write("$E[3F")
        assertEquals(1, t.cursorY)
    }

    @Test fun saveRestoreCursorEsc() {
        val t = term()
        t.write("$E[1;31m$E[2;3H${E}7$E[5;5H$E[0m${E}8X")
        assertEquals('X'.code, t.cpAt(2, 1))
        assertEquals(TermColor.palette(1), t.fgAt(2, 1))
    }

    @Test fun saveRestoreCursorCsi() {
        val t = term()
        t.write("$E[2;3H$E[s$E[5;5H$E[uX")
        assertEquals('X'.code, t.cpAt(2, 1))
    }

    @Test fun indReverseIndexNel() {
        val t = term(10, 3)
        t.write("a${E}Db${E}Ec")
        assertEquals("a", t.lineText(0))
        assertEquals(" b", t.lineText(1))
        assertEquals("c", t.lineText(2))
        t.write("$E[1;1H${E}Mz")
        assertEquals("z", t.lineText(0))
        assertEquals("a", t.lineText(1))
    }

    @Test fun tabStops() {
        val t = term(30, 2)
        t.write("\t\tx")
        assertEquals('x'.code, t.cpAt(16, 0))
        t.write("$E[1;5H${E}H$E[1;1H\t")
        assertEquals(4, t.cursorX)
        t.write("$E[3g$E[1;1H\t")
        assertEquals(29, t.cursorX)
        t.write("$E[1;1H$E[2Z")
        assertEquals(0, t.cursorX)
    }

    // ------------------------------------------------------------ erase / edit

    @Test fun eraseInLine() {
        val t = term(10, 2)
        t.write("0123456789$E[1;5H$E[K")
        assertEquals("0123", t.lineText(0))
        t.write("$E[1;1H0123456789$E[1;5H$E[1K")
        assertEquals("     56789", t.lineText(0))
        t.write("$E[2K")
        assertEquals("", t.lineText(0))
    }

    @Test fun eraseInDisplay() {
        val t = term(5, 4)
        t.write("aaaaa\r\nbbbbb\r\nccccc\r\nddddd")
        t.write("$E[2;3H$E[J")
        assertEquals(listOf("aaaaa", "bb", "", ""), t.rowsText())
        t.write("$E[1J")
        assertEquals(listOf("", "", "", ""), t.rowsText().map { it.trim() })
        t.write("zzz$E[2J")
        assertEquals("", t.screenText().replace("\n", ""))
    }

    @Test fun eraseUsesCurrentBackground() {
        val t = term(5, 2)
        t.write("$E[44m$E[2J")
        assertEquals(TermColor.palette(4), t.bgAt(0, 0))
        assertEquals(TermColor.palette(4), t.bgAt(4, 1))
    }

    @Test fun insertDeleteEraseChars() {
        val t = term(10, 2)
        t.write("abcdef$E[1;3H$E[2@")
        assertEquals("ab  cdef", t.lineText(0))
        t.write("$E[2P")
        assertEquals("abcdef", t.lineText(0))
        t.write("$E[3X")
        assertEquals("ab   f", t.lineText(0))
    }

    @Test fun insertDeleteLines() {
        val t = term(5, 5)
        t.write("1\r\n2\r\n3\r\n4\r\n5$E[2;1H$E[L")
        assertEquals(listOf("1", "", "2", "3", "4"), t.rowsText())
        t.write("$E[2M")
        assertEquals(listOf("1", "3", "4", "", ""), t.rowsText())
    }

    @Test fun scrollUpDownCsi() {
        val t = term(5, 4)
        t.write("1\r\n2\r\n3\r\n4$E[S")
        assertEquals(listOf("2", "3", "4", ""), t.rowsText())
        t.write("$E[T")
        assertEquals(listOf("", "2", "3", "4"), t.rowsText())
        t.write("$E[2T")
        assertEquals(listOf("", "", "", "2"), t.rowsText())
    }

    @Test fun repeatPrecedingChar() {
        val t = term()
        t.write("a$E[3b")
        assertEquals("aaaa", t.lineText(0))
    }

    // ------------------------------------------------------------ scroll region

    @Test fun scrollRegionKeepsOutsideRowsAndNoHistory() {
        val t = term(6, 5)
        t.write("H\r\n1\r\n2\r\n3\r\nF")
        t.write("$E[2;4r") // region rows 2..4, cursor homes
        assertEquals(0, t.cursorX); assertEquals(0, t.cursorY)
        t.write("$E[4;1H\r\n") // linefeed at region bottom
        assertEquals(listOf("H", "2", "3", "", "F"), t.rowsText())
        assertEquals(0, t.scrollbackSize)
        t.write("$E[2;1H${E}M") // reverse index at top of region
        assertEquals(listOf("H", "", "2", "3", "F"), t.rowsText())
    }

    @Test fun insertLinesRespectRegionBottom() {
        val t = term(6, 5)
        t.write("1\r\n2\r\n3\r\n4\r\n5$E[2;4r$E[2;1H$E[L")
        assertEquals(listOf("1", "", "2", "3", "5"), t.rowsText())
    }

    @Test fun invalidRegionIgnoredAndResetRestoresFull() {
        val t = term(6, 4)
        t.write("$E[3;2r")
        t.write("a\r\nb\r\nc\r\nd\r\ne")
        assertEquals(listOf("b", "c", "d", "e"), t.rowsText())
        t.write("$E[2;3r$E[r$E[4;1H")
        t.write("\r\nf")
        assertEquals(listOf("c", "d", "e", "f"), t.rowsText())
    }

    @Test fun originMode() {
        val t = term(6, 6)
        t.write("$E[2;4r$E[?6h$E[1;1HX$E[9;1HY")
        assertEquals('X'.code, t.cpAt(0, 1))
        assertEquals('Y'.code, t.cpAt(0, 3))
        assertTrue(t.originMode)
        t.write("$E[?6l")
        assertEquals(0, t.cursorY)
    }

    // ------------------------------------------------------------ SGR

    @Test fun sgrBasic() {
        val t = term()
        t.write("$E[1;3;4;7mA$E[22;23;24;27mB")
        assertEquals(Attr.BOLD or Attr.ITALIC or Attr.UNDERLINE or Attr.INVERSE, t.attrAt(0, 0))
        assertEquals(0, t.attrAt(1, 0))
    }

    @Test fun sgrColors16() {
        val t = term()
        t.write("$E[31;42mA$E[91;103mB$E[39;49mC")
        assertEquals(TermColor.palette(1), t.fgAt(0, 0))
        assertEquals(TermColor.palette(2), t.bgAt(0, 0))
        assertEquals(TermColor.palette(9), t.fgAt(1, 0))
        assertEquals(TermColor.palette(11), t.bgAt(1, 0))
        assertEquals(TermColor.DEFAULT, t.fgAt(2, 0))
        assertEquals(TermColor.DEFAULT, t.bgAt(2, 0))
    }

    @Test fun sgr256And24Bit() {
        val t = term()
        t.write("$E[38;5;208;48;5;17mA$E[38;2;1;2;3;48;2;250;251;252mB")
        assertEquals(TermColor.palette(208), t.fgAt(0, 0))
        assertEquals(TermColor.palette(17), t.bgAt(0, 0))
        assertEquals(TermColor.rgb(1, 2, 3), t.fgAt(1, 0))
        assertEquals(TermColor.rgb(250, 251, 252), t.bgAt(1, 0))
    }

    @Test fun sgrColonForms() {
        val t = term()
        t.write("$E[38:2::10:20:30mA$E[38:2:40:50:60mB$E[48:5:99mC$E[4:3mD$E[4:0mE")
        assertEquals(TermColor.rgb(10, 20, 30), t.fgAt(0, 0))
        assertEquals(TermColor.rgb(40, 50, 60), t.fgAt(1, 0))
        assertEquals(TermColor.palette(99), t.bgAt(2, 0))
        assertEquals(Attr.UNDERLINE, t.attrAt(3, 0) and Attr.UNDERLINE)
        assertEquals(0, t.attrAt(4, 0) and Attr.UNDERLINE)
    }

    @Test fun sgrResetVariants() {
        val t = term()
        t.write("$E[1;31mA${E}[mB$E[1;31mC$E[0mD$E[1mE$E[mF")
        assertEquals(0, t.attrAt(1, 0)); assertEquals(0, t.fgAt(1, 0))
        assertEquals(0, t.attrAt(3, 0)); assertEquals(0, t.attrAt(5, 0))
        assertEquals(Attr.BOLD, t.attrAt(4, 0))
    }

    @Test fun truncatedSgrExtendedDoesNotCrash() {
        val t = term()
        t.write("$E[38;5mA$E[38;2;1;2mB$E[38mC")
        assertEquals("ABC", t.lineText(0))
    }

    @Test fun paletteMath() {
        assertEquals(0xFF0000, TermColor.paletteRgb(196))
        assertEquals(0x000000, TermColor.paletteRgb(16))
        assertEquals(0xFFFFFF, TermColor.paletteRgb(231))
        assertEquals(0x080808, TermColor.paletteRgb(232))
        assertEquals(0xEEEEEE, TermColor.paletteRgb(255))
    }

    // ------------------------------------------------------------ modes

    @Test fun privateModes() {
        val t = term()
        t.write("$E[?1h$E[?2004h$E[?25l")
        assertTrue(t.applicationCursorKeys); assertTrue(t.bracketedPaste); assertFalse(t.cursorVisible)
        t.write("$E[?1l$E[?2004l$E[?25h")
        assertFalse(t.applicationCursorKeys); assertFalse(t.bracketedPaste); assertTrue(t.cursorVisible)
    }

    @Test fun combinedModeParameters() {
        val t = term()
        t.write("$E[?1;2004;25l")
        assertFalse(t.cursorVisible)
        t.write("$E[?1;2004h")
        assertTrue(t.applicationCursorKeys && t.bracketedPaste)
    }

    @Test fun insertMode() {
        val t = term(10, 2)
        t.write("abc$E[1;1H$E[4hXY")
        assertEquals("XYabc", t.lineText(0))
        t.write("$E[4l$E[1;1HQ")
        assertEquals("QYabc", t.lineText(0))
    }

    @Test fun mouseModes() {
        val t = term()
        t.write("$E[?1000h$E[?1006h")
        assertEquals(1000, t.mouseMode); assertTrue(t.mouseSgr)
        t.write("$E[?1000l")
        assertEquals(0, t.mouseMode)
    }

    // ------------------------------------------------------------ alt screen

    @Test fun altScreenEnterLeaveRestoresPrimaryAndCursor() {
        val t = term(10, 4)
        t.write("prompt$ ls\r\nfile\r\n$ ")
        val before = t.screenText()
        val cx = t.cursorX; val cy = t.cursorY
        t.write("$E[?1049h")
        assertTrue(t.altScreenActive)
        assertEquals("", t.screenText().replace("\n", ""))
        t.write("$E[1;1HALT")
        assertEquals("ALT", t.lineText(0))
        t.write("$E[?1049l")
        assertFalse(t.altScreenActive)
        assertEquals(before, t.screenText())
        assertEquals(cx, t.cursorX); assertEquals(cy, t.cursorY)
    }

    @Test fun altScreenDoesNotFeedScrollback() {
        val t = term(10, 3)
        t.write("$E[?1049h1\r\n2\r\n3\r\n4\r\n5")
        assertEquals(0, t.scrollbackSize)
        t.write("$E[?1049l")
        assertEquals(0, t.scrollbackSize)
    }

    @Test fun altScreenAlwaysStartsClean() {
        val t = term(10, 3)
        t.write("$E[?1049hstale$E[?1049l$E[?1049h")
        assertEquals("", t.screenText().replace("\n", ""))
    }

    @Test fun mode47SwitchesWithoutClearing() {
        val t = term(10, 3)
        t.write("main$E[?47hALT$E[?47l")
        assertEquals("main", t.lineText(0))
    }

    // ------------------------------------------------------------ strings / charsets / queries

    @Test fun oscTitleBelAndStTerminators() {
        val t = term()
        var seen = ""
        t.onTitleChanged = { seen = it }
        t.write("${E}]0;my title\u0007ok")
        assertEquals("my title", t.title); assertEquals("my title", seen)
        t.write("${E}]2;other$E\\!")
        assertEquals("other", t.title)
        assertEquals("ok!", t.lineText(0))
    }

    @Test fun oscWithUtf8AndSplitFrames() {
        val t = term()
        t.write("${E}]0;caf")
        t.write(byteArrayOf(0xC3.toByte()))
        t.write(byteArrayOf(0xA9.toByte(), 7))
        assertEquals("café", t.title)
    }

    @Test fun unknownOscDcsAndApcAreIgnored() {
        val t = term()
        t.write("${E}]8;;http://x\u0007link${E}]8;;\u0007")
        t.write("${E}Pq#0;2;0;0;0~$E\\a")
        t.write("${E}_Gi=1;data$E\\b")
        assertEquals("linkab", t.lineText(0))
    }

    @Test fun canAbortsSequence() {
        val t = term()
        t.write("$E[31\u0018m")
        assertEquals("m", t.lineText(0))
        assertEquals(0, t.fgAt(0, 0))
    }

    @Test fun escapeInsideCsiRestarts() {
        val t = term()
        t.write("$E[3$E[1;1HX")
        assertEquals("X", t.lineText(0))
    }

    @Test fun decLineDrawing() {
        val t = term(10, 3)
        t.write("$E(0lqqk\r\nx  x\r\nmqqj$E(B lqk")
        assertEquals("┌──┐", t.lineText(0))
        assertEquals("│  │", t.lineText(1))
        assertEquals("└──┘ lqk", t.lineText(2))
    }

    @Test fun shiftOutShiftIn() {
        val t = term()
        t.write("$E)0a\u000Eq\u000Fq")
        assertEquals("a─q", t.lineText(0))
    }

    @Test fun deviceStatusReports() {
        val t = term()
        val out = StringBuilder()
        t.onReply = { out.append(String(it)) }
        t.write("$E[3;7H$E[6n$E[5n")
        assertEquals("$E[3;7R$E[0n", out.toString())
        out.setLength(0)
        t.write("$E[c$E[>c")
        assertEquals("$E[?1;2c$E[>0;0;0c", out.toString())
    }

    @Test fun cprHonoursOriginMode() {
        val t = term(10, 10)
        val out = StringBuilder()
        t.onReply = { out.append(String(it)) }
        t.write("$E[3;8r$E[?6h$E[2;2H$E[6n")
        assertEquals("$E[2;2R", out.toString())
    }

    @Test fun bellCallback() {
        val t = term()
        var n = 0
        t.onBell = { n++ }
        t.write("\u0007\u0007")
        assertEquals(2, n)
    }

    @Test fun decalnFillsScreen() {
        val t = term(3, 2)
        t.write("$E#8")
        assertEquals("EEE\nEEE", t.screenText())
    }

    @Test fun fullResetClearsState() {
        val t = term()
        t.write("$E[?1h$E[31mabc${E}c")
        assertFalse(t.applicationCursorKeys)
        assertEquals("", t.screenText().replace("\n", ""))
        t.write("x")
        assertEquals(0, t.fgAt(0, 0))
    }

    @Test fun softReset() {
        val t = term()
        t.write("$E[?25l$E[4h$E[!p")
        assertTrue(t.cursorVisible); assertFalse(t.insertMode)
    }

    @Test fun cursorStyle() {
        val t = term()
        t.write("$E[5 q")
        assertEquals(5, t.cursorStyle)
    }

    // ------------------------------------------------------------ resize

    @Test fun resizeKeepsContentAndClampsCursor() {
        val t = term(10, 5)
        t.write("abc\r\ndef$E[3;10H")
        t.resize(6, 3)
        assertEquals("abc", t.lineText(0))
        assertEquals(6, t.cols); assertEquals(3, t.rows)
        assertTrue(t.cursorX <= 5 && t.cursorY <= 2)
    }

    @Test fun shrinkRowsMovesTopToScrollbackWhenCursorAtBottom() {
        val t = term(5, 4)
        t.write("1\r\n2\r\n3\r\n4")
        t.resize(5, 2)
        assertEquals(listOf("3", "4"), t.rowsText())
        assertEquals(2, t.scrollbackSize)
        assertEquals(1, t.cursorY)
    }

    @Test fun growRowsAddsBlankLines() {
        val t = term(5, 2)
        t.write("a\r\nb")
        t.resize(8, 4)
        assertEquals(listOf("a", "b", "", ""), t.rowsText())
        t.write("\r\nc")
        assertEquals("c", t.lineText(2))
    }

    @Test fun resizeDuringAltScreen() {
        val t = term(10, 4)
        t.write("main$E[?1049h$E[HALT")
        t.resize(5, 3)
        assertEquals("ALT", t.lineText(0))
        t.write("$E[?1049l")
        assertEquals("main", t.lineText(0))
        assertEquals(3, t.rows)
    }

    @Test fun resizeSplitWideCharAtEdge() {
        val t = term(6, 1)
        t.write("abcd漢")
        t.resize(5, 1)
        assertEquals("abcd", t.lineText(0))
    }

    @Test fun versionAndUpdateCallback() {
        val t = term()
        var n = 0
        t.onUpdate = { n++ }
        val v = t.version
        t.write("x")
        t.resize(10, 3)
        assertEquals(2, n)
        assertTrue(t.version > v)
    }

    @Test fun scrollbackIsCapped() {
        val t = TerminalEmulator(5, 2, maxScrollback = 3)
        t.write((1..10).joinToString("\r\n"))
        assertEquals(3, t.scrollbackSize)
    }

    @Test fun garbageNeverThrows() {
        val t = term(7, 3)
        val rnd = java.util.Random(42)
        val buf = ByteArray(20000)
        rnd.nextBytes(buf)
        // bias towards escape-ish bytes
        for (i in buf.indices step 7) buf[i] = 0x1B
        for (i in 3 until buf.size step 11) buf[i] = '['.code.toByte()
        t.write(buf)
        t.resize(3, 9)
        t.write(buf)
        assertEquals(9, t.rows)
    }

    // ------------------------------------------------------------ real-world style captures

    /** A vim-like session: enter alt screen, draw tildes, status line, redraw and leave. */
    @Test fun vimLikeRedraw() {
        val t = term(20, 6)
        t.write("user@box:~$ vim a.txt\r\n")
        val before = t.screenText()
        t.write("$E[?1049h$E[22;0;0t$E[>4;2m$E[?1h$E=$E[?2004h")
        t.write("$E[?25l$E[1;1H$E[2J")
        t.write("hello world$E[K\r\n")
        for (r in 2..5) t.write("$E[34m~$E[39;49m$E[K\r\n".replace("\r\n", if (r == 5) "" else "\r\n"))
        t.write("$E[6;1H$E[7m\"a.txt\" 1L, 12B$E[K$E[0m")
        t.write("$E[?25h$E[1;1H")
        assertEquals("hello world", t.lineText(0))
        assertEquals("~", t.lineText(3))
        assertEquals(TermColor.palette(4), t.fgAt(0, 3))
        assertEquals(Attr.INVERSE, t.attrAt(0, 5))
        assertTrue(t.applicationCursorKeys && t.bracketedPaste && t.cursorVisible)
        // user types "x" then redraws just line 1 and the ruler, using cursor addressing only
        t.write("$E[1;1Hhello worl$E[1;11H$E[K$E[6;1H$E[7m-- INSERT --$E[K$E[0m$E[1;11H")
        assertEquals("hello worl", t.lineText(0))
        assertEquals("-- INSERT --", t.lineText(5))
        assertEquals(10, t.cursorX)
        // quit
        t.write("$E[?2004l$E[?1l$E>$E[?25h$E[?1049l")
        assertEquals(before, t.screenText())
        assertFalse(t.applicationCursorKeys)
    }

    /** An htop-like layout: header outside a scroll region, process list inside, footer pinned. */
    @Test fun htopLikeScrollRegion() {
        val t = term(24, 8)
        t.write("$E[?1049h$E[H$E[2J")
        t.write("$E[1;1H$E[1mCPU [|||   ]$E[0m")
        t.write("$E[2;1H$E[30;46m  PID USER      CMD$E[K$E[0m")
        t.write("$E[8;1H$E[30;46mF1Help F10Quit$E[K$E[0m")
        t.write("$E[3;7r$E[3;1H")
        for (i in 1..9) t.write("  $i root      proc$i\r\n".let { if (i == 9) it.trimEnd() else it })
        // 9 rows written into a 5-row region: first four scrolled off, header/footer untouched
        assertEquals("CPU [|||   ]", t.lineText(0))
        assertEquals("PID USER      CMD", t.lineText(1).trim())
        assertEquals("5 root      proc5", t.lineText(2).trim())
        assertEquals("9 root      proc9", t.lineText(6).trim())
        assertEquals("F1Help F10Quit", t.lineText(7))
        assertEquals(TermColor.palette(6), t.bgAt(0, 7))
        assertEquals(0, t.scrollbackSize)
        // reverse scroll inside region
        t.write("$E[3;1H${E}M")
        assertEquals("", t.lineText(2))
        assertEquals("5 root      proc5", t.lineText(3).trim())
        assertEquals("PID USER      CMD", t.lineText(1).trim())
    }

    /** A less-like pager and prompt flow on the primary screen, including colour reset at line end. */
    @Test fun promptWithColoursAndWrap() {
        val t = term(12, 4)
        t.write("$E[1;32muser@h$E[0m:$E[1;34m~$E[0m\$ ")
        assertEquals("user@h:~$", t.lineText(0))
        assertEquals(TermColor.palette(2), t.fgAt(0, 0))
        assertEquals(TermColor.palette(4), t.fgAt(7, 0))
        assertEquals(0, t.fgAt(8, 0))
        t.write("echo a-very-long-command\r\n")
        assertEquals("user@h:~$ ec", t.lineText(0))
        assertEquals("ho a-very-lo", t.lineText(1))
    }

    /** tmux/TUIOS-like status line: save cursor, draw on last row, restore. */
    @Test fun statusLineSaveRestore() {
        val t = term(16, 4)
        t.write("work$E[?1049h$E[1;1Hbody${E}7$E[4;1H$E[7m[0] bash$E[K$E[0m${E}8!")
        assertEquals("body!", t.lineText(0))
        assertEquals("[0] bash", t.lineText(3))
        assertEquals(Attr.INVERSE, t.attrAt(0, 3))
    }

    @Test fun boxDrawing() {
        val t = term(8, 3)
        t.write("┌──────┐\r\n│ ok   │")
        assertEquals("┌──────┐".take(8), t.lineText(0))
    }

    @Test fun readLockedSnapshot() {
        val t = term()
        t.write("abc")
        val s = t.read { e -> (0 until 3).map { e.cpAt(it, 0).toChar() }.joinToString("") }
        assertEquals("abc", s)
    }

    @Test fun replyBytesAreUtf8() {
        val t = term()
        var got: ByteArray? = null
        t.onReply = { got = it }
        t.write("$E[5n")
        assertContentEquals("$E[0n".toByteArray(), got)
    }
}
