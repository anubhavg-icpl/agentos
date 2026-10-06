package dev.nestlo.app.ui.screens

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import dev.nestlo.app.BuildConfig
import dev.nestlo.app.data.Repository
import dev.nestlo.app.service.EventsService
import dev.nestlo.app.ui.components.HoldToConfirm
import dev.nestlo.app.ui.components.Label
import dev.nestlo.app.ui.components.MechButton
import dev.nestlo.app.ui.components.ScreenHeader
import dev.nestlo.app.ui.components.Status
import dev.nestlo.app.ui.components.StatusLine
import dev.nestlo.app.ui.theme.NColor
import dev.nestlo.app.ui.theme.NType
import dev.nestlo.app.util.Format
import dev.nestlo.core.net.Trust
import dev.nestlo.core.protocol.Device
import kotlinx.coroutines.launch

@Composable
fun SettingsScreen(repo: Repository, onBack: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val creds by repo.credentials.collectAsState()
    val info by repo.info.collectAsState()
    val conn by repo.conn.collectAsState()

    var devices by remember { mutableStateOf<List<Device>?>(null) }
    var status by remember { mutableStateOf<Status>(Status.None) }
    var alerts by remember { mutableStateOf(repo.store.alertsEnabled) }

    suspend fun loadDevices() {
        repo.call { devices() }
            .onSuccess { devices = it }
            .onFailure { status = Status.Error(Repository.describe(it)) }
    }
    LaunchedEffect(Unit) { loadDevices() }

    fun setAlerts(on: Boolean) {
        repo.store.alertsEnabled = on
        alerts = on
        val i = Intent(context, EventsService::class.java)
        if (on) ContextCompat.startForegroundService(context, i) else context.stopService(i)
    }

    val notifPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        // Alerts still run without the permission (the service itself is allowed), but no notification can show.
        setAlerts(true)
        if (!granted) status = Status.Alert("NOTIFICATIONS BLOCKED IN SYSTEM SETTINGS")
    }

    LazyColumn(Modifier.fillMaxWidth().padding(horizontal = 16.dp), contentPadding = androidx.compose.foundation.layout.PaddingValues(bottom = 32.dp)) {
        item {
            ScreenHeader("SETTINGS", onBack)
            Label("SERVER")
            Spacer(Modifier.height(8.dp))
            KeyValue("NAME", info?.name ?: creds?.serverName.orEmpty())
            KeyValue("VERSION", info?.version.orEmpty())
            KeyValue("UPTIME", info?.let { Format.uptime(it.uptimeS) }.orEmpty())
            KeyValue("ENDPOINT", creds?.endpoint?.authority.orEmpty())
            KeyValue("TRUST", when (creds?.endpoint?.trust) { Trust.WEBPKI -> "WEBPKI"; Trust.PINNED -> "PINNED CERT"; null -> "" })
            KeyValue("FEATURES", info?.features?.joinToString(" ").orEmpty())
            creds?.let { KeyValue("FINGERPRINT", Format.hex(it.fingerprint)) }
            Spacer(Modifier.height(6.dp))
            StatusLine(connStatus(conn))

            Spacer(Modifier.height(28.dp))
            Label("BACKGROUND ALERTS")
            Spacer(Modifier.height(8.dp))
            Text(
                "Keeps a connection open and notifies you when an agent needs input or something needs approval.",
                style = NType.Body.copy(color = NColor.Gray60),
            )
            Spacer(Modifier.height(10.dp))
            MechButton(
                if (alerts) "Alerts on - tap to stop" else "Turn alerts on",
                onClick = {
                    if (alerts) {
                        setAlerts(false)
                    } else if (Build.VERSION.SDK_INT >= 33 &&
                        ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
                    ) {
                        notifPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
                    } else {
                        setAlerts(true)
                    }
                },
                filled = alerts,
                modifier = Modifier.fillMaxWidth(),
            )

            Spacer(Modifier.height(28.dp))
            Label("DEVICES")
            Spacer(Modifier.height(8.dp))
            StatusLine(status)
        }

        items(devices.orEmpty(), key = { it.deviceId }) { d ->
            Column(Modifier.fillMaxWidth().padding(vertical = 6.dp).border(1.dp, NColor.Border).padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Text(d.deviceName.ifBlank { d.deviceId }, style = NType.BodyStrong)
                    if (d.current) Label("THIS DEVICE", color = NColor.White)
                }
                Label(d.deviceModel)
                d.lastSeen?.let { Label("LAST SEEN ${Format.clock(it)}") }
                MechButton(
                    if (d.current) "Revoke this device" else "Revoke",
                    danger = true,
                    onClick = {
                        scope.launch {
                            status = Status.Busy("REVOKING")
                            repo.call { revokeDevice(d.deviceId) }
                                .onSuccess {
                                    if (d.current) repo.unpair(revokeSelf = false) else {
                                        status = Status.Ok("REVOKED")
                                        loadDevices()
                                    }
                                }
                                .onFailure { status = Status.Error(Repository.describe(it)) }
                        }
                    },
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        }

        item {
            Spacer(Modifier.height(28.dp))
            HoldToConfirm(
                "Hold to unpair",
                modifier = Modifier.fillMaxWidth(),
                onConfirm = {
                    scope.launch {
                        context.stopService(Intent(context, EventsService::class.java))
                        repo.store.alertsEnabled = false
                        repo.unpair(revokeSelf = true)
                    }
                },
            )
            Spacer(Modifier.height(20.dp))
            Label("NESTLO ${BuildConfig.VERSION_NAME}")
        }
    }
}

@Composable
private fun KeyValue(key: String, value: String) {
    Row(Modifier.fillMaxWidth().padding(vertical = 4.dp), horizontalArrangement = Arrangement.SpaceBetween) {
        Label(key)
        Text(value, style = NType.Mono.copy(color = NColor.White), modifier = Modifier.padding(start = 16.dp).weight(1f, fill = false))
    }
}
