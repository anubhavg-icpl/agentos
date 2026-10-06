package dev.nestlo.core.net

import dev.nestlo.core.protocol.ApprovalDecision
import dev.nestlo.core.protocol.ServerEvent
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.flow.takeWhile
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.SocketPolicy
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import okio.ByteString
import okio.ByteString.Companion.toByteString
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

class NestloClientTest {
    private lateinit var held: HeldCertificate
    private lateinit var server: MockWebServer
    private lateinit var fp: ByteArray
    private lateinit var client: NestloClient

    @BeforeTest fun setUp() {
        held = HeldCertificate.Builder().ecdsa256().commonName("nestlo").build()
        fp = PinnedTls.fingerprintOf(held.certificate)
        server = MockWebServer()
        server.useHttps(HandshakeCertificates.Builder().heldCertificate(held).build().sslSocketFactory(), false)
        server.start()
        client = NestloClient(Endpoint.pinned("127.0.0.1", server.port), fp, "TOKEN")
    }

    @AfterTest fun tearDown() {
        client.shutdown()
        server.shutdown()
    }

    private fun json(body: String) = MockResponse().setHeader("Content-Type", "application/json").setBody(body)

    @Test fun getSendsBearerAndParses() = runBlocking {
        server.enqueue(json("""{"name":"n","version":"1","features":["agents"]}"""))
        val info = client.info()
        assertEquals("n", info.name)
        val req = server.takeRequest()
        assertEquals("/v1/info", req.path)
        assertEquals("Bearer TOKEN", req.getHeader("Authorization"))
    }

    @Test fun agentRequestsQuery() = runBlocking {
        server.enqueue(json("[]"))
        client.agentRequests("a b", 20)
        assertEquals("/v1/agents/a%20b/requests?limit=20", server.takeRequest().path)
    }

    @Test fun killAndDecide() = runBlocking {
        server.enqueue(json("""{"ok":true}"""))
        server.enqueue(json("""{"ok":true}"""))
        assertTrue(client.killAgent("a1"))
        val k = server.takeRequest()
        assertEquals("POST", k.method)
        assertEquals("/v1/agents/a1/kill", k.path)
        assertTrue(client.decide("p1", ApprovalDecision.DENY))
        val d = server.takeRequest()
        assertEquals("/v1/approvals/p1", d.path)
        assertEquals("""{"decision":"deny"}""", d.body.readUtf8())
    }

    @Test fun revokeUsesDelete() = runBlocking {
        server.enqueue(json("""{"ok":true}"""))
        assertTrue(client.revokeDevice("d_1"))
        val r = server.takeRequest()
        assertEquals("DELETE", r.method)
        assertEquals("/v1/devices/d_1", r.path)
    }

    @Test fun unauthorizedMapsToException() {
        server.enqueue(json("""{"error":"bad token"}""").setResponseCode(401))
        val e = assertFailsWith<UnauthorizedException> { runBlocking { client.overview() } }
        assertEquals("bad token", e.message)
    }

    @Test fun otherErrorsMapToApiException() {
        server.enqueue(json("""{"error":"conflict"}""").setResponseCode(409))
        val e = assertFailsWith<ApiException> { runBlocking { client.sessions() } }
        assertEquals(409, e.status)
    }

    @Test fun wrongPinFailsRequests() {
        val other = NestloClient(Endpoint.pinned("127.0.0.1", server.port), ByteArray(32), "T")
        server.enqueue(json("{}"))
        assertFailsWith<java.io.IOException> { runBlocking { other.info() } }
        other.shutdown()
    }

    @Test fun desktopUrl() {
        assertEquals("https://127.0.0.1:${server.port}/desktop/?t=TOKEN", client.desktopUrl())
    }

    // ---------------------------------------------------------------- pairing

    private fun pairingUri(vararg hosts: String, port: Int = server.port): PairingUri {
        val code = PairingUri.b64(ByteArray(16) { 1 })
        val q = hosts.joinToString("&") { "host=$it" }
        return PairingUri.parse("nestlo://pair?v=1&name=n&port=$port&fp=${PairingUri.b64(fp)}&code=$code&$q")
    }

    @Test fun pairPostsCodeAndReturnsEndpoint() = runBlocking {
        server.enqueue(json("""{"device_id":"d_1","token":"tk","server_name":"n","server_version":"1"}"""))
        val uri = pairingUri("127.0.0.1")
        val res = NestloClient.pair(uri, "Pixel", "google/tokay")
        assertEquals("tk", res.response.token)
        assertEquals("127.0.0.1", res.endpoint.host)
        val req = server.takeRequest()
        assertEquals("POST", req.method)
        assertEquals("/v1/pair", req.path)
        assertEquals(null, req.getHeader("Authorization"))
        assertTrue(req.body.readUtf8().contains("\"device_name\":\"Pixel\""))
    }

    @Test fun pairSkipsUnreachableHosts() = runBlocking {
        server.enqueue(json("""{"device_id":"d_1","token":"tk"}"""))
        val res = NestloClient.pair(pairingUri("no-such-host.invalid", "127.0.0.1"), "a", "b")
        assertEquals("127.0.0.1", res.endpoint.host)
    }

    @Test fun pairFailsWhenNothingAnswers() {
        val dead = java.net.ServerSocket(0).use { it.localPort }
        val e = assertFailsWith<NoRouteException> {
            runBlocking { NestloClient.pair(pairingUri("127.0.0.1", port = dead), "a", "b") }
        }
        assertEquals(listOf("127.0.0.1:$dead"), e.tried)
    }

    @Test fun pairServerRejectionIsFinal() {
        server.enqueue(json("""{"error":"bad code"}""").setResponseCode(403))
        server.enqueue(json("""{"device_id":"d_1","token":"tk"}"""))
        val e = assertFailsWith<ApiException> {
            runBlocking { NestloClient.pair(pairingUri("127.0.0.1", "localhost"), "a", "b") }
        }
        assertEquals(403, e.status)
        assertEquals(1, server.requestCount)
    }

    // ---------------------------------------------------------------- events

    private fun wsServer(onOpen: (WebSocket) -> Unit, onText: (String) -> Unit = {}, onBin: (ByteString) -> Unit = {}) {
        server.enqueue(
            MockResponse().withWebSocketUpgrade(object : WebSocketListener() {
                override fun onOpen(webSocket: WebSocket, response: Response) = onOpen(webSocket)
                override fun onMessage(webSocket: WebSocket, text: String) = onText(text)
                override fun onMessage(webSocket: WebSocket, bytes: ByteString) = onBin(bytes)
                override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                    webSocket.close(code, null)
                }
            }),
        )
    }

    @Test fun eventsDecodeAndPong() = runBlocking {
        val pong = LinkedBlockingQueue<String>()
        wsServer(
            onOpen = {
                it.send("""{"type":"hello","server_name":"n","version":"1"}""")
                it.send("""{"type":"ping"}""")
                it.send("""{"type":"needs_input","id":"a","agent":"c","workspace":"w","since":"t"}""")
            },
            onText = { pong.add(it) },
        )
        val got = withTimeout(10_000) {
            client.events().takeWhile { it !is EventsUpdate.Event || it.event !is ServerEvent.NeedsInput }.toList()
        }
        assertTrue(got.first() is EventsUpdate.Connecting)
        assertTrue(got.any { it is EventsUpdate.Connected })
        assertTrue(got.any { it is EventsUpdate.Event && it.event is ServerEvent.Hello })
        assertEquals("""{"type":"pong"}""", pong.poll(5, TimeUnit.SECONDS))
        assertEquals("Bearer TOKEN", server.takeRequest().getHeader("Authorization"))
    }

    @Test fun eventsReconnectsAfterDrop() = runBlocking {
        server.enqueue(MockResponse().setSocketPolicy(SocketPolicy.DISCONNECT_AT_START))
        wsServer(onOpen = { it.send("""{"type":"spend","today_usd":1,"budget_usd":2}""") })
        val backoff = Backoff(initialMs = 50, maxMs = 100)
        val got = withTimeout(15_000) {
            client.events(backoff).takeWhile { !(it is EventsUpdate.Event && it.event is ServerEvent.SpendChanged) }.toList()
        }
        val d = got.filterIsInstance<EventsUpdate.Disconnected>()
        assertTrue(d.isNotEmpty())
        assertEquals(50, d.first().retryInMs)
    }

    @Test fun eventsStopOn401() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(401))
        val got = withTimeout(10_000) { client.events(Backoff(10, 10)).toList() }
        assertIs<EventsUpdate.Unauthorized>(got.last())
        Unit
    }

    @Test fun backoffDoublesAndResets() {
        val b = Backoff(1000, 4000)
        assertEquals(listOf(1000L, 2000L, 4000L, 4000L), List(4) { b.next() })
        b.reset()
        assertEquals(1000, b.next())
    }

    // ---------------------------------------------------------------- terminal

    @Test fun terminalBinaryInOutResizeAndExit() {
        val received = CopyOnWriteArrayList<ByteString>()
        val texts = LinkedBlockingQueue<String>()
        val inputLatch = CountDownLatch(1)
        wsServer(
            onOpen = { it.send("hello \u001B[1m".toByteArray().toByteString()) },
            onText = { t ->
                texts.add(t)
                if (t.contains("resize")) {
                    // reply with exit so the client sees the control frame
                }
            },
            onBin = { received.add(it); inputLatch.countDown() },
        )
        val out = LinkedBlockingQueue<ByteArray>()
        val exit = LinkedBlockingQueue<Int>()
        val closed = CountDownLatch(1)
        val sock = client.openTerminal(
            "shell:bob", 100, 40,
            object : TerminalListener {
                override fun onOutput(data: ByteArray) { out.add(data) }
                override fun onExit(code: Int) { exit.add(code) }
                override fun onClosed(error: Throwable?, httpStatus: Int?) { closed.countDown() }
            },
        )
        val first = out.poll(5, TimeUnit.SECONDS)
        assertNotNull(first)
        assertEquals("hello \u001B[1m", String(first))
        sock.send(byteArrayOf(0x1B, '['.code.toByte(), 'A'.code.toByte()))
        assertTrue(inputLatch.await(5, TimeUnit.SECONDS))
        assertEquals(3, received[0].size)
        sock.resize(120, 50)
        assertEquals("""{"cols":120,"rows":50,"type":"resize"}""", texts.poll(5, TimeUnit.SECONDS))
        val req = server.takeRequest()
        assertEquals("/v1/term?session=shell%3Abob&cols=100&rows=40", req.path)
        assertEquals("Bearer TOKEN", req.getHeader("Authorization"))
        sock.close()
        assertTrue(closed.await(5, TimeUnit.SECONDS))
    }

    @Test fun terminalExitFrame() {
        wsServer(onOpen = {
            it.send("""{"type":"exit","code":7}""")
            it.close(1000, null)
        })
        val exit = LinkedBlockingQueue<Int>()
        val closed = CountDownLatch(1)
        client.openTerminal("s", 80, 24, object : TerminalListener {
            override fun onOutput(data: ByteArray) {}
            override fun onExit(code: Int) { exit.add(code) }
            override fun onClosed(error: Throwable?, httpStatus: Int?) { closed.countDown() }
        })
        assertEquals(7, exit.poll(5, TimeUnit.SECONDS))
        assertTrue(closed.await(5, TimeUnit.SECONDS))
    }
}
