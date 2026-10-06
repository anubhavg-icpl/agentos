package dev.nestlo.core.net

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import kotlin.test.assertTrue

class PairingUriTest {
    private val fp = PairingUri.b64(ByteArray(32) { it.toByte() })
    private val code = PairingUri.b64(ByteArray(16) { (it * 3).toByte() })
    private val params = "v=1&name=my%20box&port=7443&fp=$fp&code=$code&host=192.168.1.5&host=10.0.0.2&host=box&host=localhost"

    private fun check(u: PairingUri) {
        assertEquals(1, u.version)
        assertEquals("my box", u.name)
        assertEquals(7443, u.port)
        assertEquals(32, u.fingerprint.size)
        assertEquals(fp, u.fingerprintB64)
        assertEquals(code, u.code)
        assertEquals(listOf("192.168.1.5", "10.0.0.2", "box", "localhost"), u.hosts)
    }

    @Test fun parsesDeepLink() = check(PairingUri.parse("nestlo://pair?$params"))

    @Test fun parsesHttpFragment() = check(PairingUri.parse("http://192.168.1.5:7080/pair#$params"))

    @Test fun parsesHttpsFragment() = check(PairingUri.parse("https://nestlo.example.com/pair#$params"))

    @Test fun trimsPastedWhitespace() = check(PairingUri.parse("  \n nestlo://pair?$params \n"))

    @Test fun schemeIsCaseInsensitive() = check(PairingUri.parse("NESTLO://pair?$params"))

    @Test fun acceptsTrailingSlashAfterPair() = check(PairingUri.parse("http://h:7080/pair/#$params"))

    @Test fun defaultsPort() {
        val u = PairingUri.parse("nestlo://pair?v=1&fp=$fp&code=$code&host=a")
        assertEquals(7443, u.port)
        assertEquals("a", u.name)
    }

    @Test fun keepsHostOrderAndIpv6() {
        val u = PairingUri.parse("nestlo://pair?v=1&fp=$fp&code=$code&host=fd00::1&host=b&host=a")
        assertEquals(listOf("fd00::1", "b", "a"), u.hosts)
    }

    @Test fun rejectsWrongScheme() {
        assertFailsWith<PairingUriException> { PairingUri.parse("ftp://pair?$params") }
        assertFailsWith<PairingUriException> { PairingUri.parse("hello") }
        assertNull(PairingUri.parseOrNull(""))
    }

    @Test fun rejectsHttpWithoutFragmentOrWrongPath() {
        assertFailsWith<PairingUriException> { PairingUri.parse("http://h:7080/pair?$params") }
        assertFailsWith<PairingUriException> { PairingUri.parse("http://h:7080/other#$params") }
    }

    @Test fun rejectsMissingOrBadVersion() {
        assertFailsWith<PairingUriException> { PairingUri.parse("nestlo://pair?fp=$fp&code=$code&host=a") }
        assertFailsWith<PairingUriException> { PairingUri.parse("nestlo://pair?v=2&fp=$fp&code=$code&host=a") }
        assertFailsWith<PairingUriException> { PairingUri.parse("nestlo://pair?v=x&fp=$fp&code=$code&host=a") }
    }

    @Test fun rejectsMissingOrBadFingerprint() {
        assertFailsWith<PairingUriException> { PairingUri.parse("nestlo://pair?v=1&code=$code&host=a") }
        assertFailsWith<PairingUriException> { PairingUri.parse("nestlo://pair?v=1&fp=abc&code=$code&host=a") }
        val short = PairingUri.b64(ByteArray(31))
        assertFailsWith<PairingUriException> { PairingUri.parse("nestlo://pair?v=1&fp=$short&code=$code&host=a") }
        assertFailsWith<PairingUriException> { PairingUri.parse("nestlo://pair?v=1&fp=$fp%3D&code=$code&host=a") }
        assertFailsWith<PairingUriException> { PairingUri.parse("nestlo://pair?v=1&fp=${fp}=&code=$code&host=a") }
    }

    @Test fun rejectsMissingOrBadCode() {
        assertFailsWith<PairingUriException> { PairingUri.parse("nestlo://pair?v=1&fp=$fp&host=a") }
        val long = PairingUri.b64(ByteArray(17))
        assertFailsWith<PairingUriException> { PairingUri.parse("nestlo://pair?v=1&fp=$fp&code=$long&host=a") }
        assertFailsWith<PairingUriException> { PairingUri.parse("nestlo://pair?v=1&fp=$fp&code=!!&host=a") }
    }

    @Test fun rejectsNoHostsAndBadPort() {
        assertFailsWith<PairingUriException> { PairingUri.parse("nestlo://pair?v=1&fp=$fp&code=$code") }
        assertFailsWith<PairingUriException> { PairingUri.parse("nestlo://pair?v=1&fp=$fp&code=$code&host=a&port=0") }
        assertFailsWith<PairingUriException> { PairingUri.parse("nestlo://pair?v=1&fp=$fp&code=$code&host=a&port=99999") }
        assertFailsWith<PairingUriException> { PairingUri.parse("nestlo://pair?v=1&fp=$fp&code=$code&host=a/b") }
    }

    @Test fun fingerprintRoundTrips() {
        val u = PairingUri.parse("nestlo://pair?$params")
        assertTrue(u.fingerprint.contentEquals(ByteArray(32) { it.toByte() }))
    }

    @Test fun urlParamsComeFirstAndSetTrust() {
        val u = PairingUri.parse(
            "https://abc-def.trycloudflare.com/pair#v=1&port=7443&fp=$fp&code=$code" +
                "&url=https%3A%2F%2Fabc-def.trycloudflare.com&host=192.168.1.5&host=box",
        )
        assertEquals(listOf("https://abc-def.trycloudflare.com"), u.urls)
        val eps = u.endpoints
        assertEquals(3, eps.size)
        assertEquals(Endpoint("abc-def.trycloudflare.com", 443, Trust.WEBPKI), eps[0])
        assertEquals(Endpoint("192.168.1.5", 7443, Trust.PINNED), eps[1])
        assertEquals(Trust.PINNED, eps[2].trust)
    }

    @Test fun urlOnlyLinkIsValidAndHttpUrlsAreDropped() {
        val u = PairingUri.parse("nestlo://pair?v=1&fp=$fp&code=$code&url=https://t.example.org:8443&url=http://plain.example.org")
        assertEquals(listOf("https://t.example.org:8443"), u.urls)
        assertEquals(8443, u.endpoints.single().port)
        assertFailsWith<PairingUriException> { PairingUri.parse("nestlo://pair?v=1&fp=$fp&code=$code&url=http://plain.example.org") }
        assertFailsWith<PairingUriException> { PairingUri.parse("nestlo://pair?v=1&fp=$fp&code=$code&url=junk") }
    }

    @Test fun repeatedUrlsKeepOrder() {
        val u = PairingUri.parse("nestlo://pair?v=1&fp=$fp&code=$code&url=https://a.example.com&url=https://b.example.com&host=h")
        assertEquals(listOf("a.example.com", "b.example.com", "h"), u.endpoints.map { it.host })
    }

    @Test fun hostEntriesMayCarryPorts() {
        val u = PairingUri.parse(
            "nestlo://pair?v=1&port=7443&fp=$fp&code=$code&url=https://t.example.com" +
                "&host=bore.pub:12345&host=[fd00::1]:8443&host=[fd00::2]&host=fd00::3&host=10.0.0.5&host=a.a.pinggy.link:443",
        )
        assertEquals(
            listOf(
                Endpoint("t.example.com", 443, Trust.WEBPKI),
                Endpoint("bore.pub", 12345, Trust.PINNED),
                Endpoint("fd00::1", 8443, Trust.PINNED),
                Endpoint("fd00::2", 7443, Trust.PINNED),
                Endpoint("fd00::3", 7443, Trust.PINNED),
                Endpoint("10.0.0.5", 7443, Trust.PINNED),
                Endpoint("a.a.pinggy.link", 443, Trust.PINNED),
            ),
            u.endpoints,
        )
    }

    @Test fun rejectsBadHostPorts() {
        assertFailsWith<PairingUriException> { PairingUri.parse("nestlo://pair?v=1&fp=$fp&code=$code&host=a:0") }
        assertFailsWith<PairingUriException> { PairingUri.parse("nestlo://pair?v=1&fp=$fp&code=$code&host=a:70000") }
        assertFailsWith<PairingUriException> { PairingUri.parse("nestlo://pair?v=1&fp=$fp&code=$code&host=[::1") }
    }
}
