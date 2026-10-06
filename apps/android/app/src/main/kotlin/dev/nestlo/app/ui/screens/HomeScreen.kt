package dev.nestlo.app.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import dev.nestlo.app.data.ConnState
import dev.nestlo.app.data.Repository
import dev.nestlo.app.ui.components.HealthDot
import dev.nestlo.app.ui.components.DotRing
import dev.nestlo.app.ui.components.Label
import dev.nestlo.app.ui.components.MechButton
import dev.nestlo.app.ui.components.Row1px
import dev.nestlo.app.ui.components.SegmentedBar
import dev.nestlo.app.ui.components.Status
import dev.nestlo.app.ui.components.StatusDot
import dev.nestlo.app.ui.components.StatusLine
import dev.nestlo.app.ui.theme.NColor
import dev.nestlo.app.ui.theme.NType
import dev.nestlo.app.util.Format
import dev.nestlo.core.protocol.Agent
import dev.nestlo.core.protocol.AgentStatus
import dev.nestlo.core.protocol.Feature

fun connStatus(c: ConnState): Status = when (c) {
    ConnState.Idle -> Status.None
    ConnState.Connecting -> Status.Busy("CONNECTING")
    ConnState.Live -> Status.Ok("LIVE")
    is ConnState.Offline -> Status.Alert("OFFLINE")
    ConnState.TunnelExpired -> Status.Alert(dev.nestlo.core.net.EndpointResolver.TUNNEL_EXPIRED_MESSAGE)
}

@Composable
fun HomeScreen(
    repo: Repository,
    onAgent: (String) -> Unit,
    onApprovals: () -> Unit,
    onTerminal: () -> Unit,
    onDesktop: () -> Unit,
    onSettings: () -> Unit,
) {
    val overview by repo.overview.collectAsState()
    val agents by repo.agents.collectAsState()
    val approvals by repo.approvals.collectAsState()
    val conn by repo.conn.collectAsState()
    val info by repo.info.collectAsState()
    val creds by repo.credentials.collectAsState()

    LaunchedEffect(Unit) { repo.refreshAll() }

    val total = overview?.agents?.total ?: agents.size
    val working = overview?.agents?.working ?: agents.count { it.state == AgentStatus.WORKING }
    val blocked = overview?.agents?.blocked ?: agents.count { it.state == AgentStatus.BLOCKED }
    val spend = overview?.spend
    val budget = spend?.budgetUsd ?: 0.0
    val today = spend?.todayUsd ?: 0.0
    val features = info?.features.orEmpty()

    LazyColumn(Modifier.fillMaxWidth().padding(horizontal = 16.dp), contentPadding = androidx.compose.foundation.layout.PaddingValues(vertical = 12.dp)) {
        item {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Label("NESTLO")
                    Text((creds?.serverName ?: "").uppercase(), style = NType.Label.copy(color = NColor.White))
                }
                StatusLine(connStatus(conn))
            }
            Spacer(Modifier.height(24.dp))
        }

        item {
            Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                DotRing(
                    fraction = if (total > 0) working.toFloat() / total else 0f,
                    modifier = Modifier.size(248.dp),
                    dots = 60,
                ) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Text(working.toString(), style = NType.hero(104))
                        Label("WORKING")
                    }
                }
            }
            Spacer(Modifier.height(20.dp))
        }

        if (blocked > 0) {
            item {
                val firstBlocked = agents.firstOrNull { it.state == AgentStatus.BLOCKED }
                Row1px(onClick = { firstBlocked?.let { onAgent(it.id) } }) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        StatusDot(NColor.Red)
                        Spacer(Modifier.width(10.dp))
                        Label("NEEDS INPUT", color = NColor.Red)
                        Spacer(Modifier.weight(1f))
                        Text(blocked.toString(), style = NType.Mono.copy(color = NColor.Red))
                    }
                }
            }
        }

        item {
            Spacer(Modifier.height(16.dp))
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Bottom) {
                Label("SPEND TODAY", Modifier.weight(1f))
                Text(
                    Format.usd(today) + if (budget > 0) " / " + Format.usd(budget) else "",
                    style = NType.Mono.copy(color = if (budget > 0 && today > budget) NColor.Red else NColor.White),
                )
            }
            Spacer(Modifier.height(10.dp))
            SegmentedBar(if (budget > 0) (today / budget).toFloat() else 0f)
            Spacer(Modifier.height(20.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(20.dp)) {
                val h = overview?.health
                HealthDot("REDIS", h?.redis ?: false)
                HealthDot("GATEWAY", h?.gateway ?: false)
                HealthDot("DAEMON", h?.daemon ?: false)
            }
            Spacer(Modifier.height(24.dp))
            Label("AGENTS  ${agents.size}")
            Spacer(Modifier.height(4.dp))
        }

        if (agents.isEmpty()) {
            item {
                Row1px { Text("No agents running.", style = NType.Body.copy(color = NColor.Gray60)) }
            }
        }
        items(agents, key = { it.id }) { a -> AgentRow(a) { onAgent(a.id) } }

        item {
            Spacer(Modifier.height(24.dp))
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                if (Feature.APPROVALS in features || approvals.isNotEmpty()) {
                    MechButton(
                        "Approvals" + if (approvals.isNotEmpty()) "  ${approvals.size}" else "",
                        onClick = onApprovals,
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
                if (Feature.TERMINAL in features) MechButton("Terminal", onClick = onTerminal, modifier = Modifier.fillMaxWidth())
                if (Feature.DESKTOP in features) MechButton("Desktop", onClick = onDesktop, modifier = Modifier.fillMaxWidth())
                MechButton("Settings", onClick = onSettings, modifier = Modifier.fillMaxWidth())
            }
            Spacer(Modifier.height(24.dp))
        }
    }
}

@Composable
private fun AgentRow(a: Agent, onClick: () -> Unit) {
    val blocked = a.state == AgentStatus.BLOCKED
    val failed = a.state == AgentStatus.FAILED
    val dot = when {
        blocked || failed -> NColor.Red
        a.state == AgentStatus.WORKING -> NColor.White
        else -> NColor.Gray40
    }
    Row1px(onClick = onClick) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            StatusDot(dot)
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(a.agent, style = NType.BodyStrong)
                Label(a.workspace.ifBlank { a.id }, color = NColor.Gray60)
            }
            Column(horizontalAlignment = Alignment.End) {
                Label(
                    if (blocked) "NEEDS INPUT" else a.status,
                    color = if (blocked || failed) NColor.Red else NColor.Gray90,
                )
                Text(Format.usd(a.spendUsd), style = NType.Mono.copy(color = NColor.Gray60))
            }
        }
    }
}
