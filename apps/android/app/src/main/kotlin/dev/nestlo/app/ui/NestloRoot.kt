package dev.nestlo.app.ui

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import dev.nestlo.app.data.Repository
import dev.nestlo.app.ui.components.DotGrid
import dev.nestlo.app.ui.screens.AgentDetailScreen
import dev.nestlo.app.ui.screens.ApprovalsScreen
import dev.nestlo.app.ui.screens.DesktopScreen
import dev.nestlo.app.ui.screens.HomeScreen
import dev.nestlo.app.ui.screens.PairScreen
import dev.nestlo.app.ui.screens.SettingsScreen
import dev.nestlo.app.ui.screens.TerminalScreen

sealed interface Route {
    data object Home : Route
    data class Agent(val id: String) : Route
    data object Approvals : Route
    data object Terminal : Route
    data object Desktop : Route
    data object Settings : Route
}

@Composable
fun NestloRoot(repo: Repository) {
    val creds by repo.credentials.collectAsState()
    val pending by repo.pendingLink.collectAsState()

    if (creds == null || pending != null) {
        DotGrid(Modifier.fillMaxSize()) {
            Box(Modifier.fillMaxSize().systemBarsPadding()) {
                PairScreen(repo, pending)
            }
        }
        return
    }

    val stack = remember { mutableStateListOf<Route>(Route.Home) }
    BackHandler(enabled = stack.size > 1) { stack.removeAt(stack.lastIndex) }
    fun push(r: Route) { stack.add(r) }
    fun pop() { if (stack.size > 1) stack.removeAt(stack.lastIndex) }

    val current = stack.last()
    // Desktop and terminal draw edge to edge; every other screen sits inside the system bars.
    val fullBleed = current is Route.Terminal || current is Route.Desktop

    DotGrid(Modifier.fillMaxSize()) {
        AnimatedContent(
            targetState = current,
            transitionSpec = {
                // Short, linear, no overshoot: a hard mechanical cut with a small slide.
                (fadeIn(tween(90, easing = LinearEasing)) + slideInHorizontally(tween(90, easing = LinearEasing)) { it / 12 }) togetherWith
                    (fadeOut(tween(60, easing = LinearEasing)) + slideOutHorizontally(tween(60, easing = LinearEasing)) { -it / 12 })
            },
            label = "route",
            modifier = Modifier.fillMaxSize(),
        ) { route ->
            Box(if (fullBleed) Modifier.fillMaxSize() else Modifier.fillMaxSize().systemBarsPadding()) {
                when (route) {
                    Route.Home -> HomeScreen(
                        repo,
                        onAgent = { push(Route.Agent(it)) },
                        onApprovals = { push(Route.Approvals) },
                        onTerminal = { push(Route.Terminal) },
                        onDesktop = { push(Route.Desktop) },
                        onSettings = { push(Route.Settings) },
                    )
                    is Route.Agent -> AgentDetailScreen(repo, route.id, onBack = ::pop)
                    Route.Approvals -> ApprovalsScreen(repo, onBack = ::pop)
                    Route.Terminal -> TerminalScreen(repo, onBack = ::pop)
                    Route.Desktop -> DesktopScreen(repo, onBack = ::pop)
                    Route.Settings -> SettingsScreen(repo, onBack = ::pop)
                }
            }
        }
    }
}
