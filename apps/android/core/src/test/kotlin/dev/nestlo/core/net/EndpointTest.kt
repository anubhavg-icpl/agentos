package dev.nestlo.core.net

import kotlinx.coroutines.runBlocking
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue

class EndpointTest {
    @Test fun ipLiteralDetection() {
        assertTrue(Endpoint.isIpLiteral("192.168.1.5"))
        assertTrue(Endpoint.isIpLiteral("100.64.0.1"))
        assertTrue(Endpoint.isIpLiteral("::1"))
        assertTrue(Endpoint.isIpLiteral("fd00::1234"))
        assertTrue(Endpoint.isIpLiteral("[fe80::1]"))
        assertFalse(Endpoint.isIpLiteral("localhost"))
        assertFalse(Endpoint.isIpLiteral("box.local"))
        assertFalse(Endpoint.isIpLiteral("1.2.3.4.example.com"))
        assertFalse(Endpoint.isIpLiteral("999.1.1.1".replace("999", "abc")))
        assertFalse(Endpoint.isIpLiteral("256.1.1.1x"))
    }

    @Test fun httpsNameIsWebPki() {
        val e = Endpoint.fromUrl("https://abc.trycloudflare.com")!!
        assertEquals(Trust.WEBPKI, e.trust)
        assertEquals(443, e.port)
        assertEquals("https://abc.trycloudflare.com:443", e.baseUrl)
    }

    @Test fun httpsIpLiteralStaysPinned() {
        assertEquals(Trust.PINNED, Endpoint.fromUrl("https://10.0.0.5:7443")!!.trust)
        assertEquals(Trust.PINNED, Endpoint.fromUrl("https://[fd00::1]:7443")!!.trust)
    }

    @Test fun httpAndGarbageAreRejected() {
        assertNull(Endpoint.fromUrl("http://abc.example.com"))
        assertNull(Endpoint.fromUrl("ftp://abc.example.com"))
        assertNull(Endpoint.fromUrl("not a url"))
    }

    @Test fun bareHostIsPinnedAndIpv6IsBracketed() {
        val e = Endpoint.pinned("fd00::1", 7443)
        assertEquals(Trust.PINNED, e.trust)
        assertEquals("[fd00::1]:7443", e.authority)
        assertEquals("fd00::1", Endpoint.pinned("[fd00::1]", 7443).host)
        assertEquals("https://[fd00::1]:7443/v1/info", e.url("/v1/info").toString())
    }

    @Test fun webPkiEndpointRejectsSelfSignedServer() {
        val held = HeldCertificate.Builder().ecdsa256().commonName("x").build()
        val server = MockWebServer()
        server.useHttps(HandshakeCertificates.Builder().heldCertificate(held).build().sslSocketFactory(), false)
        server.enqueue(MockResponse().setBody("{}"))
        server.start()
        try {
            // Same self-signed server: pinned works, WebPKI must not.
            val fp = PinnedTls.fingerprintOf(held.certificate)
            val pinned = NestloClient(Endpoint.pinned("127.0.0.1", server.port), fp, "t")
            runBlocking { pinned.info() }
            val web = NestloClient(Endpoint("localhost", server.port, Trust.WEBPKI), fp, "t")
            server.enqueue(MockResponse().setBody("{}"))
            var failed = false
            try { runBlocking { web.info() } } catch (e: java.io.IOException) { failed = true }
            assertTrue(failed)
            pinned.shutdown(); web.shutdown()
        } finally {
            server.shutdown()
        }
    }

    private fun tlsServer(held: HeldCertificate, body: String = """{"name":"n"}"""): MockWebServer =
        MockWebServer().apply {
            useHttps(HandshakeCertificates.Builder().heldCertificate(held).build().sslSocketFactory(), false)
            enqueue(MockResponse().setBody(body))
            start()
        }

    @Test fun resolverFallsBackInOrder() = runBlocking {
        val held = HeldCertificate.Builder().ecdsa256().commonName("x").build()
        val fp = PinnedTls.fingerprintOf(held.certificate)
        val s = tlsServer(held)
        val dead = java.net.ServerSocket(0).use { it.localPort }
        try {
            val res = EndpointResolver.resolve(
                listOf(Endpoint.pinned("127.0.0.1", dead), Endpoint.pinned("127.0.0.1", s.port)), fp, "t",
            )
            assertEquals(Endpoint.pinned("127.0.0.1", s.port), assertIs<Resolution.Found>(res).endpoint)
        } finally { s.shutdown() }
    }

    @Test fun resolverPrefersLastWorking() = runBlocking {
        val held = HeldCertificate.Builder().ecdsa256().commonName("x").build()
        val fp = PinnedTls.fingerprintOf(held.certificate)
        val a = tlsServer(held)
        val b = tlsServer(held)
        try {
            val ea = Endpoint.pinned("127.0.0.1", a.port)
            val eb = Endpoint.pinned("127.0.0.1", b.port)
            val res = EndpointResolver.resolve(listOf(ea, eb), fp, "t", preferred = eb)
            assertEquals(eb, assertIs<Resolution.Found>(res).endpoint)
        } finally { a.shutdown(); b.shutdown() }
    }

    @Test fun resolverReportsTunnelExpired() = runBlocking {
        val dead = java.net.ServerSocket(0).use { it.localPort }
        val res = EndpointResolver.resolve(
            listOf(Endpoint("localhost", dead, Trust.WEBPKI), Endpoint.pinned("127.0.0.1", dead)),
            ByteArray(32), "t", timeoutMs = 1500,
        )
        val f = assertIs<Resolution.Failed>(res)
        assertTrue(f.tunnelExpired)
        assertEquals(2, f.tried.size)
        val lan = EndpointResolver.resolve(listOf(Endpoint.pinned("127.0.0.1", dead)), ByteArray(32), "t")
        assertFalse(assertIs<Resolution.Failed>(lan).tunnelExpired)
    }

    @Test fun resolverStopsOn401() = runBlocking {
        val held = HeldCertificate.Builder().ecdsa256().commonName("x").build()
        val s = MockWebServer().apply {
            useHttps(HandshakeCertificates.Builder().heldCertificate(held).build().sslSocketFactory(), false)
            enqueue(MockResponse().setResponseCode(401).setBody("""{"error":"revoked"}"""))
            start()
        }
        try {
            val res = EndpointResolver.resolve(listOf(Endpoint.pinned("127.0.0.1", s.port)), PinnedTls.fingerprintOf(held.certificate), "t")
            assertIs<Resolution.Unauthorized>(res)
            Unit
        } finally { s.shutdown() }
    }

    @Test fun hostEntriesWithPorts() {
        assertEquals(Endpoint("bore.pub", 12345, Trust.PINNED), Endpoint.parseHost("bore.pub:12345", 7443))
        assertEquals(Endpoint("x.a.pinggy.link", 443, Trust.PINNED), Endpoint.parseHost("x.a.pinggy.link:443", 7443))
        assertEquals(Endpoint("10.0.0.5", 9000, Trust.PINNED), Endpoint.parseHost("10.0.0.5:9000", 7443))
        assertEquals(Endpoint("fd00::1", 8443, Trust.PINNED), Endpoint.parseHost("[fd00::1]:8443", 7443))
        assertEquals(Endpoint("fd00::1", 7443, Trust.PINNED), Endpoint.parseHost("[fd00::1]", 7443))
        assertEquals(Endpoint("fd00::1", 7443, Trust.PINNED), Endpoint.parseHost("fd00::1", 7443))
        assertEquals(Endpoint("box", 7443, Trust.PINNED), Endpoint.parseHost("box", 7443))
        assertNull(Endpoint.parseHost("box:0", 7443))
        assertNull(Endpoint.parseHost("box:99999", 7443))
        assertNull(Endpoint.parseHost("box:abc", 7443))
        assertNull(Endpoint.parseHost("[fd00::1]x", 7443))
        assertNull(Endpoint.parseHost("[]", 7443))
        assertNull(Endpoint.parseHost(":80", 7443))
    }
}
