package dev.nestlo.app.ui.screens

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
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.unit.dp
import dev.nestlo.app.data.Repository
import dev.nestlo.app.ui.components.HoldToConfirm
import dev.nestlo.app.ui.components.Label
import dev.nestlo.app.ui.components.ScreenHeader
import dev.nestlo.app.ui.components.SegmentedBar
import dev.nestlo.app.ui.components.Status
import dev.nestlo.app.ui.components.StatusLine
import dev.nestlo.app.ui.theme.NColor
import dev.nestlo.app.ui.theme.NType
import dev.nestlo.app.util.Format
import dev.nestlo.app.util.Haptics
import dev.nestlo.core.protocol.AgentStatus
import dev.nestlo.core.protocol.RequestLogEntry
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

@Composable
fun AgentDetailScreen(repo: Repository, id: String, onBack: () -> Unit) {
    val agents by repo.agents.collectAsState()
    val agent = agents.firstOrNull { it.id == id }
    val view = LocalView.current
    val scope = rememberCoroutineScope()
    var log by remember { mutableStateOf<List<RequestLogEntry>?>(null) }
    var status by remember { mutableStateOf<Status>(Status.Busy("LOADING")) }
    var killStatus by remember { mutableStateOf<Status>(Status.None) }

    LaunchedEffect(id) {
        while (true) {
            repo.call { agentRequests(id, 50) }
                .onSuccess { log = it; status = Status.None }
                .onFailure { status = Status.Error(Repository.describe(it)) }
            delay(5_000)
        }
    }

    LazyColumn(Modifier.fillMaxWidth().padding(horizontal = 16.dp), contentPadding = androidx.compose.foundation.layout.PaddingValues(bottom = 24.dp)) {
        item {
            ScreenHeader(agent?.agent ?: "AGENT", onBack)
            if (agent == null) {
                StatusLine(Status.Alert("AGENT GONE"))
            } else {
                val blocked = agent.state == AgentStatus.BLOCKED
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Label(if (blocked) "NEEDS INPUT" else agent.status, color = if (blocked || agent.state == AgentStatus.FAILED) NColor.Red else NColor.White)
                    Label(agent.workspace.ifBlank { agent.id })
                }
                Spacer(Modifier.height(16.dp))
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Label("SPEND")
                    Text(
                        Format.usd(agent.spendUsd) + if (agent.budgetUsd > 0) " / " + Format.usd(agent.budgetUsd) else "",
                        style = NType.Mono.copy(color = NColor.White),
                    )
                }
                Spacer(Modifier.height(8.dp))
                SegmentedBar(if (agent.budgetUsd > 0) (agent.spendUsd / agent.budgetUsd).toFloat() else 0f)
            }
            Spacer(Modifier.height(28.dp))
            Label("REQUESTS")
            Spacer(Modifier.height(4.dp))
            StatusLine(status)
            Spacer(Modifier.height(8.dp))
        }

        val entries = log.orEmpty()
        if (log != null && entries.isEmpty()) {
            item { Text("No requests yet.", style = NType.Body.copy(color = NColor.Gray60)) }
        }
        items(entries) { e ->
            Column(Modifier.fillMaxWidth().padding(vertical = 6.dp)) {
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Text(Format.clock(e.ts), style = NType.Mono.copy(color = NColor.Gray60))
                    Text(
                        e.status.uppercase(),
                        style = NType.Mono.copy(color = if (e.status.startsWith("ok") || e.status.startsWith("2")) NColor.Gray90 else NColor.Red),
                    )
                }
                Text("${e.provider}/${e.model}", style = NType.Mono.copy(color = NColor.White))
                Text(
                    "in ${Format.tokens(e.inputTokens)}  out ${Format.tokens(e.outputTokens)}  ${Format.usd(e.costUsd)}",
                    style = NType.Mono.copy(color = NColor.Gray60),
                )
            }
        }

        if (agent != null && agent.isLive) {
            item {
                Spacer(Modifier.height(28.dp))
                HoldToConfirm(
                    "Hold to kill agent",
                    modifier = Modifier.fillMaxWidth(),
                    onConfirm = {
                        killStatus = Status.Busy("KILLING")
                        scope.launch {
                            repo.call { killAgent(id) }
                                .onSuccess {
                                    Haptics.confirm(view)
                                    killStatus = Status.Ok("KILLED")
                                    repo.refreshAll()
                                }
                                .onFailure {
                                    Haptics.reject(view)
                                    killStatus = Status.Error(Repository.describe(it))
                                }
                        }
                    },
                )
                Spacer(Modifier.height(8.dp))
                StatusLine(killStatus)
            }
        }
    }
}
