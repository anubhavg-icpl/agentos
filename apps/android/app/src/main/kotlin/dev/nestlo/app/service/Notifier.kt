package dev.nestlo.app.service

import android.Manifest
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import dev.nestlo.app.MainActivity
import dev.nestlo.app.R
import dev.nestlo.core.protocol.Approval
import dev.nestlo.core.protocol.ServerEvent

/** Posts and clears notifications for events that need a person. */
class Notifier(private val context: Context) {
    private val nm = NotificationManagerCompat.from(context)

    private fun canPost(): Boolean =
        Build.VERSION.SDK_INT < 33 ||
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

    private fun open(): PendingIntent = PendingIntent.getActivity(
        context,
        0,
        Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    private fun post(id: Int, title: String, text: String) {
        if (!canPost()) return
        val n = NotificationCompat.Builder(context, CHANNEL_ATTENTION)
            .setSmallIcon(R.drawable.ic_stat_nestlo)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setContentIntent(open())
            .setAutoCancel(true)
            .setOnlyAlertOnce(true)
            .build()
        @Suppress("MissingPermission")
        nm.notify(id, n)
    }

    fun needsInput(e: ServerEvent.NeedsInput) =
        post(idFor("agent", e.id), "NEEDS INPUT", "${e.agent} in ${e.workspace.ifBlank { e.id }} is waiting for you.")

    fun approval(a: Approval) =
        post(idFor("approval", a.id), "APPROVAL: ${a.kind.uppercase()}", "${a.summary}\nRequested by ${a.requestedBy}")

    fun clearAgent(id: String) = nm.cancel(idFor("agent", id))

    fun clearApproval(id: String) = nm.cancel(idFor("approval", id))

    fun foreground(): android.app.Notification =
        NotificationCompat.Builder(context, CHANNEL_STATUS)
            .setSmallIcon(R.drawable.ic_stat_nestlo)
            .setContentTitle("NESTLO")
            .setContentText("Listening for agents that need you")
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .setContentIntent(open())
            .build()

    private fun idFor(kind: String, id: String): Int = 1000 + (kind + id).hashCode().and(0x3FFFFFFF)

    companion object {
        const val CHANNEL_ATTENTION = "attention"
        const val CHANNEL_STATUS = "status"
        const val FOREGROUND_ID = 1
    }
}
