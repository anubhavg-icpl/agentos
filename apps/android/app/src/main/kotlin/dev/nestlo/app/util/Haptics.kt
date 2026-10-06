package dev.nestlo.app.util

import android.os.Build
import android.view.HapticFeedbackConstants
import android.view.View

/** Small, percussive haptic vocabulary for the mechanical feel. */
object Haptics {
    fun tap(v: View) {
        v.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
    }

    fun tick(v: View) {
        v.performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)
    }

    fun heavy(v: View) {
        v.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
    }

    fun confirm(v: View) {
        v.performHapticFeedback(if (Build.VERSION.SDK_INT >= 30) HapticFeedbackConstants.CONFIRM else HapticFeedbackConstants.LONG_PRESS)
    }

    fun reject(v: View) {
        v.performHapticFeedback(if (Build.VERSION.SDK_INT >= 30) HapticFeedbackConstants.REJECT else HapticFeedbackConstants.LONG_PRESS)
    }
}
