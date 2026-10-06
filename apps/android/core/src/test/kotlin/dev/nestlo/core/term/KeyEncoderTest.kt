package dev.nestlo.core.term

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals

class KeyEncoderTest {
    private fun enc(k: TermKey, ctrl: Boolean = false, alt: Boolean = false, shift: Boolean = false, app: Boolean = false) =
        String(KeyEncoder.encodeKey(k, ctrl, alt, shift, app), Charsets.ISO_8859_1)

    @Test fun arrowsNormalAndApplication() {
        assertEquals("\u001B[A", enc(TermKey.UP))
        assertEquals("\u001B[B", enc(TermKey.DOWN))
        assertEquals("\u001B[C", enc(TermKey.RIGHT))
        assertEquals("\u001B[D", enc(TermKey.LEFT))
        assertEquals("\u001BOA", enc(TermKey.UP, app = true))
        assertEquals("\u001BOD", enc(TermKey.LEFT, app = true))
    }

    @Test fun arrowsWithModifiersIgnoreAppMode() {
        assertEquals("\u001B[1;5C", enc(TermKey.RIGHT, ctrl = true, app = true))
        assertEquals("\u001B[1;3A", enc(TermKey.UP, alt = true))
        assertEquals("\u001B[1;2D", enc(TermKey.LEFT, shift = true))
        assertEquals("\u001B[1;8B", enc(TermKey.DOWN, ctrl = true, alt = true, shift = true))
    }

    @Test fun navigation() {
        assertEquals("\u001B[H", enc(TermKey.HOME))
        assertEquals("\u001BOF", enc(TermKey.END, app = true))
        assertEquals("\u001B[5~", enc(TermKey.PAGE_UP))
        assertEquals("\u001B[6~", enc(TermKey.PAGE_DOWN))
        assertEquals("\u001B[2~", enc(TermKey.INSERT))
        assertEquals("\u001B[3~", enc(TermKey.DELETE))
        assertEquals("\u001B[3;5~", enc(TermKey.DELETE, ctrl = true))
    }

    @Test fun specials() {
        assertEquals("\u001B", enc(TermKey.ESCAPE))
        assertEquals("\t", enc(TermKey.TAB))
        assertEquals("\u001B[Z", enc(TermKey.TAB, shift = true))
        assertEquals("\r", enc(TermKey.ENTER))
        assertEquals("\u001B\r", enc(TermKey.ENTER, alt = true))
        assertEquals("\u007F", enc(TermKey.BACKSPACE))
        assertEquals("\u0008", enc(TermKey.BACKSPACE, ctrl = true))
        assertEquals("\u001B\u007F", enc(TermKey.BACKSPACE, alt = true))
    }

    @Test fun functionKeys() {
        assertEquals("\u001BOP", enc(TermKey.F1))
        assertEquals("\u001BOS", enc(TermKey.F4))
        assertEquals("\u001B[15~", enc(TermKey.F5))
        assertEquals("\u001B[17~", enc(TermKey.F6))
        assertEquals("\u001B[24~", enc(TermKey.F12))
        assertEquals("\u001B[1;2P", enc(TermKey.F1, shift = true))
        assertEquals("\u001B[15;5~", enc(TermKey.F5, ctrl = true))
    }

    @Test fun controlLetters() {
        assertContentEquals(byteArrayOf(3), KeyEncoder.encodeText("c", ctrl = true))
        assertContentEquals(byteArrayOf(3), KeyEncoder.encodeText("C", ctrl = true))
        assertContentEquals(byteArrayOf(1), KeyEncoder.encodeText("a", ctrl = true))
        assertContentEquals(byteArrayOf(26), KeyEncoder.encodeText("z", ctrl = true))
        assertContentEquals(byteArrayOf(0), KeyEncoder.encodeText(" ", ctrl = true))
        assertContentEquals(byteArrayOf(0x1B), KeyEncoder.encodeText("[", ctrl = true))
        assertContentEquals(byteArrayOf(0x1C), KeyEncoder.encodeText("\\", ctrl = true))
        assertContentEquals(byteArrayOf(0x7F), KeyEncoder.encodeText("?", ctrl = true))
    }

    @Test fun altPrefixesEsc() {
        assertContentEquals(byteArrayOf(0x1B, 'x'.code.toByte()), KeyEncoder.encodeText("x", alt = true))
        assertContentEquals(byteArrayOf(0x1B, 3), KeyEncoder.encodeText("c", ctrl = true, alt = true))
    }

    @Test fun plainTextIsUtf8() {
        assertEquals("héllo", String(KeyEncoder.encodeText("héllo"), Charsets.UTF_8))
        assertContentEquals("é".toByteArray(), KeyEncoder.encodeText("é", ctrl = true))
        assertEquals(0, KeyEncoder.encodeText("").size)
    }

    @Test fun paste() {
        assertEquals("a\rb", String(KeyEncoder.paste("a\nb", false)))
        assertEquals("\u001B[200~a\rb\u001B[201~", String(KeyEncoder.paste("a\r\nb", true)))
        assertEquals("\u001B[200~x\u001B[201~", String(KeyEncoder.paste("x\u001B[201~", true)))
    }
}
