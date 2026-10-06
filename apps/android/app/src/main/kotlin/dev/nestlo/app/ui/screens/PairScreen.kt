package dev.nestlo.app.ui.screens

import android.Manifest
import android.content.pm.PackageManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
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
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import dev.nestlo.app.data.Repository
import dev.nestlo.app.ui.components.Label
import dev.nestlo.app.ui.components.MechButton
import dev.nestlo.app.ui.components.MonoField
import dev.nestlo.app.ui.components.Status
import dev.nestlo.app.ui.components.StatusLine
import dev.nestlo.app.ui.theme.NColor
import dev.nestlo.app.ui.theme.NType
import dev.nestlo.app.util.Haptics
import dev.nestlo.core.net.PairingUri
import kotlinx.coroutines.launch

@Composable
fun PairScreen(repo: Repository, pendingLink: String?) {
    val context = LocalContext.current
    val view = LocalView.current
    val scope = rememberCoroutineScope()
    val notice by repo.notice.collectAsState()

    var status by remember { mutableStateOf<Status>(Status.None) }
    var paste by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var hasCamera by remember {
        mutableStateOf(ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED)
    }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { hasCamera = it }

    fun submit(raw: String) {
        if (busy) return
        if (PairingUri.parseOrNull(raw) == null) {
            Haptics.reject(view)
            status = Status.Error(runCatching { PairingUri.parse(raw) }.exceptionOrNull()?.message ?: "NOT A NESTLO LINK")
            repo.pendingLink.value = null
            return
        }
        busy = true
        status = Status.Busy("CONNECTING")
        scope.launch {
            repo.pair(raw).onSuccess {
                Haptics.confirm(view)
                status = Status.Ok("PAIRED")
            }.onFailure {
                Haptics.reject(view)
                status = Status.Error(Repository.describe(it))
            }
            repo.pendingLink.value = null
            busy = false
        }
    }

    LaunchedEffect(pendingLink) {
        if (pendingLink != null) submit(pendingLink)
    }

    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Label("NESTLO")
        Text("PAIR", style = NType.hero(64))
        Text(
            "Run nestlo-mobile pair on your machine and scan the QR code. " +
                "The link can be LAN, a tunnel or Tailscale: the app tries every address in the code, in order.",
            style = NType.Body,
        )

        Box(
            Modifier.fillMaxWidth().aspectRatio(1f).border(1.dp, NColor.BorderStrong),
        ) {
            if (hasCamera) {
                QrScanner(Modifier.fillMaxSize()) { text -> if (!busy) submit(text) }
            } else {
                Column(Modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.Center) {
                    Label("CAMERA OFF")
                    Spacer(Modifier.height(12.dp))
                    MechButton("Enable camera", onClick = { permission.launch(Manifest.permission.CAMERA) })
                }
            }
        }

        notice?.let { StatusLine(Status.Alert(it)) }
        StatusLine(status)

        Label("OR PASTE LINK")
        MonoField(paste, { paste = it }, hint = "nestlo://pair?...  or  http://host/pair#...")
        MechButton(
            "Pair",
            onClick = { submit(paste) },
            enabled = paste.isNotBlank() && !busy,
            filled = true,
            modifier = Modifier.fillMaxWidth(),
        )
    }
}
