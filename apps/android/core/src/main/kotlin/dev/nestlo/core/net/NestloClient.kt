package dev.nestlo.core.net

import dev.nestlo.core.protocol.Agent
import dev.nestlo.core.protocol.Approval
import dev.nestlo.core.protocol.ApprovalDecision
import dev.nestlo.core.protocol.Device
import dev.nestlo.core.protocol.ErrorResponse
import dev.nestlo.core.protocol.EventCodec
import dev.nestlo.core.protocol.ExitFrame
import dev.nestlo.core.protocol.NestloJson
import dev.nestlo.core.protocol.OkResponse
import dev.nestlo.core.protocol.Overview
import dev.nestlo.core.protocol.PairRequest
import dev.nestlo.core.protocol.PairResponse
import dev.nestlo.core.protocol.RequestLogEntry
import dev.nestlo.core.protocol.ResizeFrame
import dev.nestlo.core.protocol.ServerEvent
import dev.nestlo.core.protocol.ServerInfo
import dev.nestlo.core.protocol.TermSession
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.channelFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.serialization.KSerializer
import kotlinx.serialization.builtins.ListSerializer
import okhttp3.Call
import okhttp3.Callback
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import okio.ByteString.Companion.toByteString
import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** The server answered with an error status. */
open class ApiException(val status: Int, message: String) : IOException(message)

/** HTTP 401: the device token is unknown or revoked. The app returns to pairing. */
class UnauthorizedException(message: String = "Device token rejected") : ApiException(401, message)

/** No address in the pairing link answered. */
class NoRouteException(val tried: List<String>, cause: Throwable?) :
    IOException("No reachable address (${tried.joinToString()})", cause)

/** Result of a successful pairing. */
class PairResult(val endpoint: Endpoint, val response: PairResponse)

/** Exponential backoff for reconnects. */
class Backoff(private val initialMs: Long = 1_000, private val maxMs: Long = 30_000) {
    private var current = initialMs

    fun next(): Long {
        val v = current
        current = (current * 2).coerceAtMost(maxMs)
        return v
    }

    fun reset() {
        current = initialMs
    }
}

/** What the events stream is doing, for inline status text. */
sealed interface EventsUpdate {
    data object Connecting : EventsUpdate
    data object Connected : EventsUpdate
    data class Event(val event: ServerEvent) : EventsUpdate
    data class Disconnected(val error: String?, val retryInMs: Long) : EventsUpdate

    /** The token was rejected; the stream ends after this. */
    data object Unauthorized : EventsUpdate
}

interface TerminalListener {
    fun onOpen() {}
    fun onOutput(data: ByteArray)
    fun onExit(code: Int) {}

    /** Called once when the socket is finished; [error] is null for a normal close. */
    fun onClosed(error: Throwable?, httpStatus: Int?) {}
}

/** A live terminal WebSocket. */
class TerminalSocket internal constructor(private val ws: WebSocket) {
    fun send(bytes: ByteArray): Boolean = ws.send(bytes.toByteString())

    fun send(text: String): Boolean = send(text.toByteArray(Charsets.UTF_8))

    fun resize(cols: Int, rows: Int): Boolean =
        ws.send(NestloJson.encodeToString(ResizeFrame.serializer(), ResizeFrame(cols, rows)))

    fun close() {
        ws.close(1000, null)
    }

    fun cancel() = ws.cancel()
}

/**
 * Client side of docs/mobile-protocol.md for one paired machine. All requests are pinned to
 * the certificate fingerprint in [endpoint].
 */
class NestloClient(
    val endpoint: Endpoint,
    val fingerprint: ByteArray,
    private val token: String,
    base: OkHttpClient? = null,
) {
    private val http: OkHttpClient = endpoint.applyTrust((base ?: OkHttpClient()).newBuilder(), fingerprint)
        .connectTimeout(5, TimeUnit.SECONDS)
        .readTimeout(20, TimeUnit.SECONDS)
        .writeTimeout(20, TimeUnit.SECONDS)
        .build()

    /** Long-lived sockets: no read timeout, transport-level keepalive. */
    private val wsHttp: OkHttpClient = http.newBuilder()
        .readTimeout(0, TimeUnit.MILLISECONDS)
        .pingInterval(30, TimeUnit.SECONDS)
        .build()

    // ------------------------------------------------------------ REST

    suspend fun info(): ServerInfo = get("/v1/info", ServerInfo.serializer())

    suspend fun overview(): Overview = get("/v1/overview", Overview.serializer())

    suspend fun agents(): List<Agent> = get("/v1/agents", ListSerializer(Agent.serializer()))

    suspend fun agentRequests(id: String, limit: Int = 50): List<RequestLogEntry> =
        get("/v1/agents/${enc(id)}/requests?limit=$limit", ListSerializer(RequestLogEntry.serializer()))

    suspend fun killAgent(id: String): Boolean =
        post("/v1/agents/${enc(id)}/kill", null, OkResponse.serializer()).ok

    suspend fun approvals(): List<Approval> = get("/v1/approvals", ListSerializer(Approval.serializer()))

    suspend fun decide(id: String, decision: ApprovalDecision): Boolean = post(
        "/v1/approvals/${enc(id)}",
        NestloJson.encodeToString(ApprovalDecision.serializer(), decision),
        OkResponse.serializer(),
    ).ok

    suspend fun sessions(): List<TermSession> = get("/v1/sessions", ListSerializer(TermSession.serializer()))

    suspend fun devices(): List<Device> = get("/v1/devices", ListSerializer(Device.serializer()))

    suspend fun revokeDevice(deviceId: String): Boolean {
        val req = authed("/v1/devices/${enc(deviceId)}").delete().build()
        return decode(execute(http, req), OkResponse.serializer()).ok
    }

    /** The URL the desktop WebView loads; the token travels once to set the cookie. */
    fun desktopUrl(): String = endpoint.url("/desktop/").newBuilder().addQueryParameter("t", token).build().toString()

    private suspend fun <T> get(path: String, ser: KSerializer<T>): T =
        decode(execute(http, authed(path).get().build()), ser)

    private suspend fun <T> post(path: String, json: String?, ser: KSerializer<T>): T {
        val body = (json ?: "{}").toRequestBody(JSON_TYPE)
        return decode(execute(http, authed(path).post(body).build()), ser)
    }

    private fun authed(path: String): Request.Builder {
        val q = path.indexOf('?')
        val url = if (q < 0) endpoint.url(path) else endpoint.url(path.substring(0, q)).newBuilder()
            .encodedQuery(path.substring(q + 1)).build()
        return Request.Builder().url(url).header("Authorization", "Bearer $token").header("Accept", "application/json")
    }

    // ------------------------------------------------------------ events

    /**
     * Cold flow over `WS /v1/events` that reconnects with backoff until collection stops
     * or the token is rejected.
     */
    fun events(backoff: Backoff = Backoff()): Flow<EventsUpdate> = channelFlow {
        while (currentCoroutineContext().isActive) {
            send(EventsUpdate.Connecting)
            val closed = CompletableDeferred<Pair<Throwable?, Int?>>()
            val ws = wsHttp.newWebSocket(
                authed("/v1/events").build(),
                object : WebSocketListener() {
                    override fun onOpen(webSocket: WebSocket, response: Response) {
                        backoff.reset()
                        trySend(EventsUpdate.Connected)
                    }

                    override fun onMessage(webSocket: WebSocket, text: String) {
                        val ev = EventCodec.decodeOrNull(text) ?: return
                        if (ev is ServerEvent.Ping) webSocket.send(EventCodec.PONG)
                        trySend(EventsUpdate.Event(ev))
                    }

                    override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                        webSocket.close(code, null)
                    }

                    override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                        closed.complete(null to null)
                    }

                    override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                        closed.complete(t to response?.code)
                    }
                },
            )
            val (err, status) = try {
                closed.await()
            } finally {
                ws.cancel()
            }
            if (status == 401) {
                send(EventsUpdate.Unauthorized)
                return@channelFlow
            }
            val wait = backoff.next()
            send(EventsUpdate.Disconnected(err?.message ?: err?.javaClass?.simpleName, wait))
            delay(wait)
        }
        awaitClose()
    }

    // ------------------------------------------------------------ terminal

    fun openTerminal(sessionId: String, cols: Int, rows: Int, listener: TerminalListener): TerminalSocket {
        val url = endpoint.url("/v1/term").newBuilder()
            .addQueryParameter("session", sessionId)
            .addQueryParameter("cols", cols.toString())
            .addQueryParameter("rows", rows.toString())
            .build()
        val req = Request.Builder().url(url).header("Authorization", "Bearer $token").build()
        var finished = false
        fun finish(err: Throwable?, status: Int?) {
            synchronized(this) {
                if (finished) return
                finished = true
            }
            listener.onClosed(err, status)
        }
        val ws = wsHttp.newWebSocket(
            req,
            object : WebSocketListener() {
                override fun onOpen(webSocket: WebSocket, response: Response) = listener.onOpen()

                override fun onMessage(webSocket: WebSocket, bytes: ByteString) = listener.onOutput(bytes.toByteArray())

                override fun onMessage(webSocket: WebSocket, text: String) {
                    try {
                        val exit = NestloJson.decodeFromString(ExitFrame.serializer(), text)
                        if (exit.type == "exit") listener.onExit(exit.code)
                    } catch (_: Exception) {
                        // Unknown control frames are ignored.
                    }
                }

                override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                    webSocket.close(code, null)
                }

                override fun onClosed(webSocket: WebSocket, code: Int, reason: String) = finish(null, null)

                override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) =
                    finish(t, response?.code)
            },
        )
        return TerminalSocket(ws)
    }

    // ------------------------------------------------------------ plumbing

    fun shutdown() {
        http.dispatcher.executorService.shutdown()
        http.connectionPool.evictAll()
    }

    companion object {
        private val JSON_TYPE = "application/json; charset=utf-8".toMediaType()

        private fun enc(segment: String): String =
            java.net.URLEncoder.encode(segment, "UTF-8").replace("+", "%20")

        internal suspend fun execute(client: OkHttpClient, request: Request): String {
            val call = client.newCall(request)
            return suspendCancellableCoroutine { cont ->
                cont.invokeOnCancellation { call.cancel() }
                call.enqueue(object : Callback {
                    override fun onFailure(call: Call, e: IOException) {
                        if (cont.isActive) cont.resumeWithException(e)
                    }

                    override fun onResponse(call: Call, response: Response) {
                        response.use { r ->
                            try {
                                val text = r.body?.string().orEmpty()
                                if (r.isSuccessful) {
                                    cont.resume(text)
                                } else {
                                    val msg = try {
                                        NestloJson.decodeFromString(ErrorResponse.serializer(), text).error
                                    } catch (_: Exception) {
                                        ""
                                    }.ifBlank { "HTTP ${r.code}" }
                                    cont.resumeWithException(
                                        if (r.code == 401) UnauthorizedException(msg) else ApiException(r.code, msg),
                                    )
                                }
                            } catch (e: IOException) {
                                if (cont.isActive) cont.resumeWithException(e)
                            }
                        }
                    }
                })
            }
        }

        internal fun <T> decode(text: String, ser: KSerializer<T>): T = try {
            NestloJson.decodeFromString(ser, text)
        } catch (e: kotlinx.serialization.SerializationException) {
            throw IOException("Unexpected response from server", e)
        }

        /**
         * Pairs with the machine described by [uri]. Hosts are tried in order with a 2 s
         * connect timeout each; the first that answers wins. A server-side rejection
         * (wrong or expired code) is final and is not retried on another address.
         */
        suspend fun pair(
            uri: PairingUri,
            deviceName: String,
            deviceModel: String,
            base: OkHttpClient? = null,
            connectTimeoutMs: Long = 2_000,
        ): PairResult {
            val payload = NestloJson.encodeToString(
                PairRequest.serializer(),
                PairRequest(uri.code, deviceName, deviceModel),
            )
            var last: Throwable? = null
            for (ep in uri.endpoints) {
                val client = ep.applyTrust((base ?: OkHttpClient()).newBuilder(), uri.fingerprint)
                    .connectTimeout(connectTimeoutMs, TimeUnit.MILLISECONDS)
                    .readTimeout(15, TimeUnit.SECONDS)
                    .callTimeout(20, TimeUnit.SECONDS)
                    .build()
                val url = try {
                    ep.url("/v1/pair")
                } catch (e: IllegalArgumentException) {
                    last = e
                    continue
                }
                val req = Request.Builder().url(url).post(payload.toRequestBody(JSON_TYPE)).build()
                try {
                    val text = execute(client, req)
                    return PairResult(ep, decode(text, PairResponse.serializer()))
                } catch (e: ApiException) {
                    throw e
                } catch (e: IOException) {
                    last = e
                }
            }
            throw NoRouteException(uri.endpoints.map { it.authority }, last)
        }
    }
}
