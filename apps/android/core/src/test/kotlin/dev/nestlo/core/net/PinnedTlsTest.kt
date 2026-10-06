package dev.nestlo.core.net

import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.tls.HeldCertificate
import okhttp3.tls.HandshakeCertificates
import java.io.IOException
import java.security.cert.CertificateException
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

class PinnedTlsTest {
    private fun cert(): HeldCertificate = HeldCertificate.Builder()
        .ecdsa256().commonName("not-the-host").addSubjectAlternativeName("not-the-host.invalid").build()

    private fun server(held: HeldCertificate): MockWebServer {
        val hc = HandshakeCertificates.Builder().heldCertificate(held).build()
        return MockWebServer().apply {
            useHttps(hc.sslSocketFactory(), false)
            enqueue(MockResponse().setBody("hi"))
            start()
        }
    }

    @Test fun trustManagerAcceptsOnlyPinnedCertificate() {
        val a = cert()
        val b = cert()
        val tls = PinnedTls(PinnedTls.fingerprintOf(a.certificate))
        tls.trustManager.checkServerTrusted(arrayOf(a.certificate), "ECDHE_ECDSA")
        assertFailsWith<CertificateException> {
            tls.trustManager.checkServerTrusted(arrayOf(b.certificate), "ECDHE_ECDSA")
        }
        assertFailsWith<CertificateException> { tls.trustManager.checkServerTrusted(emptyArray(), "x") }
    }

    @Test fun rejectsBadFingerprintLength() {
        assertFailsWith<IllegalArgumentException> { PinnedTls(ByteArray(5)) }
    }

    @Test fun connectsToPinnedServerRegardlessOfHostname() {
        val held = cert()
        val s = server(held)
        try {
            val client = PinnedTls(PinnedTls.fingerprintOf(held.certificate)).apply(OkHttpClient.Builder()).build()
            // 127.0.0.1 is not in the certificate's names; the pin alone decides.
            val r = client.newCall(Request.Builder().url("https://127.0.0.1:${s.port}/").build()).execute()
            assertEquals("hi", r.body!!.string())
        } finally {
            s.shutdown()
        }
    }

    @Test fun refusesAnotherCertificate() {
        val s = server(cert())
        try {
            val client = PinnedTls(PinnedTls.fingerprintOf(cert().certificate)).apply(OkHttpClient.Builder()).build()
            assertFailsWith<IOException> {
                client.newCall(Request.Builder().url("https://127.0.0.1:${s.port}/").build()).execute()
            }
        } finally {
            s.shutdown()
        }
    }

    @Test fun fingerprintHelpers() {
        val c = cert()
        val fp = PinnedTls.fingerprintOf(c.certificate)
        assertEquals(32, fp.size)
        assertTrue(PinnedTls.fingerprintMatches(c.certificate, fp))
        assertTrue(!PinnedTls.fingerprintMatches(cert().certificate, fp))
    }
}
