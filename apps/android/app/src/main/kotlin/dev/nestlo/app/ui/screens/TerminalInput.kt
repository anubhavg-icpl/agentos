package dev.nestlo.app.ui.screens

import android.content.Context
import android.text.InputType
import android.view.KeyEvent
import android.view.View
import android.view.inputmethod.BaseInputConnection
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import dev.nestlo.core.term.KeyEncoder
import dev.nestlo.core.term.TermKey

/** Sticky CTRL / ALT toggles shared by the extra-keys row and the soft keyboard. */
class ModState {
    var ctrl by mutableStateOf(false)
    var alt by mutableStateOf(false)

    fun clear() {
        ctrl = false
        alt = false
    }
}

/**
 * Invisible view that owns the soft keyboard. It turns IME text, deletions and hardware key events
 * into terminal bytes; nothing is ever shown in it.
 */
class TerminalInputView(context: Context) : View(context) {
    var send: (ByteArray) -> Unit = {}
    var mods: ModState = ModState()
    var appCursorKeys: () -> Boolean = { false }

    private var composing: String = ""

    init {
        isFocusable = true
        isFocusableInTouchMode = true
    }

    override fun onCheckIsTextEditor(): Boolean = true

    override fun onCreateInputConnection(outAttrs: EditorInfo): InputConnection {
        outAttrs.inputType = InputType.TYPE_CLASS_TEXT or
            InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD or
            InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
        outAttrs.imeOptions = EditorInfo.IME_FLAG_NO_FULLSCREEN or EditorInfo.IME_FLAG_NO_EXTRACT_UI or EditorInfo.IME_ACTION_NONE
        composing = ""
        return object : BaseInputConnection(this, false) {
            override fun commitText(text: CharSequence, newCursorPosition: Int): Boolean {
                replaceComposing(text.toString())
                composing = ""
                return true
            }

            override fun setComposingText(text: CharSequence, newCursorPosition: Int): Boolean {
                replaceComposing(text.toString())
                composing = text.toString()
                return true
            }

            override fun finishComposingText(): Boolean {
                composing = ""
                return true
            }

            override fun deleteSurroundingText(beforeLength: Int, afterLength: Int): Boolean {
                repeat(beforeLength.coerceAtLeast(1).coerceAtMost(64)) { emit(KeyEncoder.encodeKey(TermKey.BACKSPACE)) }
                composing = ""
                return true
            }

            override fun sendKeyEvent(event: KeyEvent): Boolean {
                if (event.action == KeyEvent.ACTION_DOWN) handleKey(event.keyCode, event)
                return true
            }

            override fun performEditorAction(editorAction: Int): Boolean {
                emit(KeyEncoder.encodeKey(TermKey.ENTER))
                return true
            }
        }
    }

    /** Sends only what changed between the previous composing text and [now]. */
    private fun replaceComposing(now: String) {
        val old = composing
        var common = 0
        while (common < old.length && common < now.length && old[common] == now[common]) common++
        repeat(old.length - common) { emit(KeyEncoder.encodeKey(TermKey.BACKSPACE)) }
        val tail = now.substring(common)
        if (tail.isNotEmpty()) text(tail)
    }

    private fun text(s: String) {
        val bytes = KeyEncoder.encodeText(s, ctrl = mods.ctrl, alt = mods.alt)
        mods.clear()
        emit(bytes)
    }

    private fun emit(b: ByteArray) {
        if (b.isNotEmpty()) send(b)
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean =
        if (handleKey(keyCode, event)) true else super.onKeyDown(keyCode, event)

    private fun handleKey(keyCode: Int, event: KeyEvent): Boolean {
        val key: TermKey? = when (keyCode) {
            KeyEvent.KEYCODE_DPAD_UP -> TermKey.UP
            KeyEvent.KEYCODE_DPAD_DOWN -> TermKey.DOWN
            KeyEvent.KEYCODE_DPAD_LEFT -> TermKey.LEFT
            KeyEvent.KEYCODE_DPAD_RIGHT -> TermKey.RIGHT
            KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_NUMPAD_ENTER -> TermKey.ENTER
            KeyEvent.KEYCODE_DEL -> TermKey.BACKSPACE
            KeyEvent.KEYCODE_FORWARD_DEL -> TermKey.DELETE
            KeyEvent.KEYCODE_TAB -> TermKey.TAB
            KeyEvent.KEYCODE_ESCAPE -> TermKey.ESCAPE
            KeyEvent.KEYCODE_MOVE_HOME -> TermKey.HOME
            KeyEvent.KEYCODE_MOVE_END -> TermKey.END
            KeyEvent.KEYCODE_PAGE_UP -> TermKey.PAGE_UP
            KeyEvent.KEYCODE_PAGE_DOWN -> TermKey.PAGE_DOWN
            KeyEvent.KEYCODE_INSERT -> TermKey.INSERT
            in KeyEvent.KEYCODE_F1..KeyEvent.KEYCODE_F12 -> TermKey.entries[TermKey.F1.ordinal + (keyCode - KeyEvent.KEYCODE_F1)]
            else -> null
        }
        val ctrl = event.isCtrlPressed || mods.ctrl
        val alt = event.isAltPressed || mods.alt
        if (key != null) {
            emit(KeyEncoder.encodeKey(key, ctrl = ctrl, alt = alt, shift = event.isShiftPressed, appCursor = appCursorKeys()))
            mods.clear()
            return true
        }
        if (keyCode == KeyEvent.KEYCODE_SHIFT_LEFT || keyCode == KeyEvent.KEYCODE_SHIFT_RIGHT ||
            keyCode == KeyEvent.KEYCODE_CTRL_LEFT || keyCode == KeyEvent.KEYCODE_CTRL_RIGHT ||
            keyCode == KeyEvent.KEYCODE_ALT_LEFT || keyCode == KeyEvent.KEYCODE_ALT_RIGHT
        ) {
            return true
        }
        val cp = event.getUnicodeChar(event.metaState and (KeyEvent.META_CTRL_MASK or KeyEvent.META_ALT_MASK).inv())
        if (cp > 0) {
            emit(KeyEncoder.encodeText(String(Character.toChars(cp)), ctrl = ctrl, alt = alt))
            mods.clear()
            return true
        }
        return false
    }
}
