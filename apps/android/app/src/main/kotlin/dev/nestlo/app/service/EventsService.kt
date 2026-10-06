package dev.nestlo.app.service

import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.IBinder
import androidx.core.app.ServiceCompat
import dev.nestlo.app.repo
import dev.nestlo.core.protocol.AgentStatus
import dev.nestlo.core.protocol.ServerEvent
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

/**
 * Opt-in foreground service that keeps the events connection open while the UI is closed and raises
 * notifications for agents that need input and for approvals.
 */
class EventsService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private lateinit var notifier: Notifier
    private var started = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        notifier = Notifier(this)
        ServiceCompat.startForeground(
            this,
            Notifier.FOREGROUND_ID,
            notifier.foreground(),
            ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
        )
        if (!started) {
            started = true
            val r = this.repo
            r.acquireEvents()
            scope.launch {
                r.events.collect { e ->
                    when (e) {
                        is ServerEvent.NeedsInput -> notifier.needsInput(e)
                        is ServerEvent.ApprovalRequested -> notifier.approval(e.approval)
                        is ServerEvent.ApprovalDone -> notifier.clearApproval(e.id)
                        is ServerEvent.AgentGone -> notifier.clearAgent(e.id)
                        is ServerEvent.AgentChanged ->
                            if (e.agent.state != AgentStatus.BLOCKED) notifier.clearAgent(e.agent.id)
                        else -> Unit
                    }
                }
            }
        }
        return START_STICKY
    }

    /** Android 15 limits dataSync foreground services; stop cleanly and leave the toggle for the user to re-enable. */
    override fun onTimeout(startId: Int, fgsType: Int) {
        repo.store.alertsEnabled = false
        stopSelf()
    }

    override fun onDestroy() {
        if (started) repo.releaseEvents()
        scope.cancel()
        super.onDestroy()
    }
}
