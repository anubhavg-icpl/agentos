package dev.nestlo.app

import android.app.Application
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Build
import dev.nestlo.app.data.Repository
import dev.nestlo.app.service.Notifier

class NestloApp : Application() {
    lateinit var repo: Repository
        private set

    override fun onCreate() {
        super.onCreate()
        repo = Repository(this)
        createChannels()
    }

    private fun createChannels() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.createNotificationChannel(
            NotificationChannel(
                Notifier.CHANNEL_ATTENTION,
                getString(R.string.channel_attention),
                NotificationManager.IMPORTANCE_HIGH,
            ),
        )
        nm.createNotificationChannel(
            NotificationChannel(
                Notifier.CHANNEL_STATUS,
                getString(R.string.channel_status),
                NotificationManager.IMPORTANCE_MIN,
            ),
        )
    }
}

val Context.repo: Repository get() = (applicationContext as NestloApp).repo
