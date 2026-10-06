package dev.nestlo.app.data

import android.content.Context
import android.os.Build
import dev.nestlo.core.net.ApiException
import dev.nestlo.core.net.EndpointResolver
import dev.nestlo.core.net.EventsUpdate
import dev.nestlo.core.net.NestloClient
import dev.nestlo.core.net.PairingUri
import dev.nestlo.core.net.Resolution
import dev.nestlo.core.net.UnauthorizedException
import dev.nestlo.core.protocol.Agent
import dev.nestlo.core.protocol.Approval
import dev.nestlo.core.protocol.Overview
import dev.nestlo.core.protocol.ServerEvent
import dev.nestlo.core.protocol.ServerInfo
import dev.nestlo.core.protocol.SpendInfo
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.io.IOException

/** Connection state shown as inline status text. */
sealed interface ConnState {
    data object Idle : ConnState
    data object Connecting : ConnState
    data object Live : ConnState
    data class Offline(val reason: String?) : ConnState
    data object TunnelExpired : ConnState
}

/**
 * Single source of truth for the paired machine: credentials, the cached REST snapshot and the
 * live events connection. The connection is shared by the UI and the background service through
 * [acquireEvents] / [releaseEvents].
 */
@OptIn(ExperimentalCoroutinesApi::class)
class Repository(context: Context) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    val store = CredentialStore(context)

    private val _credentials = MutableStateFlow(store.load())
    val credentials: StateFlow<Credentials?> = _credentials.asStateFlow()

    private val _conn = MutableStateFlow<ConnState>(ConnState.Idle)
    val conn: StateFlow<ConnState> = _conn.asStateFlow()

    private val _info = MutableStateFlow<ServerInfo?>(null)
    val info: StateFlow<ServerInfo?> = _info.asStateFlow()

    private val _overview = MutableStateFlow<Overview?>(null)
    val overview: StateFlow<Overview?> = _overview.asStateFlow()

    private val _agents = MutableStateFlow<List<Agent>>(emptyList())
    val agents: StateFlow<List<Agent>> = _agents.asStateFlow()

    private val _approvals = MutableStateFlow<List<Approval>>(emptyList())
    val approvals: StateFlow<List<Approval>> = _approvals.asStateFlow()

    /** One-shot message for the pairing screen, e.g. after the token was revoked. */
    val notice = MutableStateFlow<String?>(null)

    /** A pairing link delivered by a deep link, waiting for the pair screen to consume it. */
    val pendingLink = MutableStateFlow<String?>(null)

    private val _events = MutableSharedFlow<ServerEvent>(extraBufferCapacity = 64)
    val events: SharedFlow<ServerEvent> = _events.asSharedFlow()

    private val holders = MutableStateFlow(0)
    private val overviewTick = Channel<Unit>(Channel.CONFLATED)

    init {
        scope.launch {
            combine(_credentials, holders) { c, h -> c to (h > 0) }
                .distinctUntilChanged()
                .collectLatest { (c, on) ->
                    if (c != null && on) runEvents(c) else if (c == null) resetData()
                }
        }
        scope.launch {
            for (u in overviewTick) {
                delay(300)
                call { overview() }.onSuccess { o -> _overview.value = o }
            }
        }
    }

    private var cached: Pair<Credentials, NestloClient>? = null

    @Synchronized
    fun clientOrNull(): NestloClient? {
        val c = _credentials.value ?: return null
        cached?.takeIf { it.first === c }?.let { return it.second }
        return NestloClient(c.endpoint, c.fingerprint, c.token).also { cached = c to it }
    }

    fun acquireEvents() = holders.update { it + 1 }

    fun releaseEvents() = holders.update { (it - 1).coerceAtLeast(0) }

    // ------------------------------------------------------------------ calls

    /** Runs a REST call against the current client, mapping auth failure to unpairing. */
    suspend fun <T> call(block: suspend NestloClient.() -> T): Result<T> {
        val client = clientOrNull() ?: return Result.failure(IOException("Not paired"))
        return try {
            Result.success(client.block())
        } catch (e: UnauthorizedException) {
            handleUnauthorized()
            Result.failure(e)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun refreshAll() {
        call { info() }.onSuccess { _info.value = it }
        call { overview() }.onSuccess { _overview.value = it }
        call { agents() }.onSuccess { _agents.value = it }
        if (_info.value?.has("approvals") != false) {
            call { approvals() }.onSuccess { _approvals.value = it }
        }
    }

    suspend fun pair(link: String): Result<Unit> {
        val uri = try {
            PairingUri.parse(link)
        } catch (e: Exception) {
            return Result.failure(e)
        }
        return try {
            val name = listOf(Build.MANUFACTURER, Build.MODEL).filter { it.isNotBlank() }.joinToString(" ")
            val model = "${Build.MANUFACTURER.lowercase()}/${Build.DEVICE}"
            val res = NestloClient.pair(uri, name, model)
            val eps = uri.endpoints
            val creds = Credentials(
                serverName = res.response.serverName.ifBlank { uri.name },
                deviceId = res.response.deviceId,
                token = res.response.token,
                fingerprint = uri.fingerprint,
                endpoints = eps,
                active = eps.indexOf(res.endpoint).coerceAtLeast(0),
            )
            store.save(creds)
            notice.value = null
            _credentials.value = creds
            Result.success(Unit)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    /** Forget this machine. With [revokeSelf] the server is told first (best effort). */
    suspend fun unpair(revokeSelf: Boolean) {
        if (revokeSelf) {
            clientOrNull()?.let { c ->
                try {
                    c.devices().firstOrNull { it.current }?.let { c.revokeDevice(it.deviceId) }
                } catch (_: Exception) {
                    // Best effort: the local state is cleared either way.
                }
            }
        }
        store.clear()
        _credentials.value = null
    }

    private fun handleUnauthorized() {
        if (_credentials.value == null) return
        store.clear()
        notice.value = "DEVICE REVOKED OR TOKEN INVALID — PAIR AGAIN"
        _credentials.value = null
    }

    private fun resetData() {
        _info.value = null
        _overview.value = null
        _agents.value = emptyList()
        _approvals.value = emptyList()
        _conn.value = ConnState.Idle
    }

    // ------------------------------------------------------------------ events

    private suspend fun runEvents(c: Credentials) {
        val client = NestloClient(c.endpoint, c.fingerprint, c.token)
        try {
            _conn.value = ConnState.Connecting
            refreshAll()
            var failures = 0
            client.events().collect { u ->
                when (u) {
                    EventsUpdate.Connecting -> if (_conn.value !is ConnState.Live) _conn.value = ConnState.Connecting
                    EventsUpdate.Connected -> {
                        failures = 0
                        _conn.value = ConnState.Live
                        refreshAll()
                    }
                    is EventsUpdate.Event -> handle(u.event)
                    is EventsUpdate.Disconnected -> {
                        failures++
                        _conn.value = ConnState.Offline(u.error)
                        if (failures >= 2) failover(c)
                    }
                    EventsUpdate.Unauthorized -> handleUnauthorized()
                }
            }
        } finally {
            client.shutdown()
        }
    }

    /** Walks the stored endpoints in order (tunnel first, then LAN) and switches to the first that answers. */
    private suspend fun failover(c: Credentials) {
        when (val r = EndpointResolver.resolve(c.endpoints, c.fingerprint, c.token, preferred = c.endpoint)) {
            is Resolution.Found -> {
                if (r.endpoint != c.endpoint) {
                    val next = c.withActive(r.endpoint)
                    store.save(next)
                    _credentials.value = next
                }
            }
            is Resolution.Failed -> _conn.value =
                if (r.tunnelExpired) ConnState.TunnelExpired else ConnState.Offline(null)
            Resolution.Unauthorized -> handleUnauthorized()
        }
    }

    private suspend fun handle(e: ServerEvent) {
        when (e) {
            is ServerEvent.AgentChanged -> {
                _agents.update { list ->
                    if (list.any { it.id == e.agent.id }) list.map { if (it.id == e.agent.id) e.agent else it } else list + e.agent
                }
                overviewTick.trySend(Unit)
            }
            is ServerEvent.AgentGone -> {
                _agents.update { l -> l.filterNot { it.id == e.id } }
                overviewTick.trySend(Unit)
            }
            is ServerEvent.NeedsInput -> {
                call { agents() }.onSuccess { _agents.value = it }
                overviewTick.trySend(Unit)
            }
            is ServerEvent.ApprovalRequested ->
                _approvals.update { l -> if (l.any { it.id == e.approval.id }) l else l + e.approval }
            is ServerEvent.ApprovalDone -> _approvals.update { l -> l.filterNot { it.id == e.id } }
            is ServerEvent.SpendChanged -> _overview.update { o ->
                (o ?: Overview()).copy(spend = SpendInfo(e.todayUsd, e.budgetUsd))
            }
            else -> Unit
        }
        _events.emit(e)
    }

    companion object {
        /** Short upper-case text for inline [ERROR: ...] status. */
        fun describe(e: Throwable): String = when (e) {
            is UnauthorizedException -> "UNAUTHORIZED"
            is ApiException -> (e.message ?: "HTTP ${e.status}").uppercase()
            is java.net.SocketTimeoutException -> "TIMEOUT"
            is javax.net.ssl.SSLException -> "CERTIFICATE MISMATCH"
            is java.net.UnknownHostException -> "UNKNOWN HOST"
            is IOException -> (e.message ?: "NETWORK").uppercase().take(60)
            else -> (e.message ?: e.javaClass.simpleName).uppercase().take(60)
        }
    }
}
