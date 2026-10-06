package dev.nestlo.app.ui.screens

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
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.unit.dp
import dev.nestlo.app.data.Repository
import dev.nestlo.app.ui.components.Label
import dev.nestlo.app.ui.components.MechButton
import dev.nestlo.app.ui.components.ScreenHeader
import dev.nestlo.app.ui.components.Status
import dev.nestlo.app.ui.components.StatusLine
import dev.nestlo.app.ui.theme.NColor
import dev.nestlo.app.ui.theme.NType
import dev.nestlo.app.util.Format
import dev.nestlo.app.util.Haptics
import dev.nestlo.core.protocol.ApprovalDecision
import kotlinx.coroutines.launch

@Composable
fun ApprovalsScreen(repo: Repository, onBack: () -> Unit) {
    val approvals by repo.approvals.collectAsState()
    val scope = rememberCoroutineScope()
    val view = LocalView.current
    val statuses = remember { mutableStateMapOf<String, Status>() }

    LaunchedEffect(Unit) { repo.refreshAll() }

    LazyColumn(Modifier.fillMaxWidth().padding(horizontal = 16.dp), contentPadding = androidx.compose.foundation.layout.PaddingValues(bottom = 24.dp)) {
        item {
            ScreenHeader("APPROVALS", onBack)
            if (approvals.isEmpty()) {
                Text("Nothing waiting for approval.", style = NType.Body.copy(color = NColor.Gray60))
            }
        }
        items(approvals, key = { it.id }) { a ->
            Column(
                Modifier.fillMaxWidth().padding(vertical = 6.dp).border(1.dp, NColor.Border).padding(14.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Label(a.kind, color = NColor.White)
                    a.createdAt?.let { Label(Format.clock(it)) }
                }
                Text(a.summary, style = NType.Body)
                Label("BY ${a.requestedBy}")
                Spacer(Modifier.height(2.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    fun send(d: ApprovalDecision) {
                        statuses[a.id] = Status.Busy("SENDING")
                        scope.launch {
                            repo.call { decide(a.id, d) }
                                .onSuccess {
                                    Haptics.confirm(view)
                                    statuses[a.id] = Status.Ok(if (d == ApprovalDecision.APPROVE) "APPROVED" else "DENIED")
                                    repo.refreshAll()
                                }
                                .onFailure {
                                    Haptics.reject(view)
                                    statuses[a.id] = Status.Error(Repository.describe(it))
                                }
                        }
                    }
                    MechButton("Approve", onClick = { send(ApprovalDecision.APPROVE) }, filled = true, modifier = Modifier.weight(1f))
                    MechButton("Deny", onClick = { send(ApprovalDecision.DENY) }, danger = true, modifier = Modifier.weight(1f))
                }
                StatusLine(statuses[a.id] ?: Status.None)
            }
        }
    }
}
