package dev.nestlo.core.net

import okhttp3.OkHttpClient
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.cert.Certificate
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import javax.net.ssl.HostnameVerifier
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLPeerUnverifiedException
import javax.net.ssl.SSLSocketFactory
import javax.net.ssl.X509TrustManager

/**
 * TLS trust for a Nestlo machine: exactly one certificate is accepted, the one whose
 * SHA-256 over the DER encoding equals [fingerprint]. No CA chain and no host name check.
 */
class PinnedTls(fingerprint: ByteArray) {
    private val pin: ByteArray = fingerprint.copyOf()

    init {
        require(pin.size == 32) { "SHA-256 fingerprint must be 32 bytes" }
    }

    fun matches(cert: Certificate): Boolean = try {
        MessageDigest.isEqual(sha256(cert.encoded), pin)
    } catch (_: Exception) {
        false
    }

    val trustManager: X509TrustManager = object : X509TrustManager {
        override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) {
            throw CertificateException("client certificates are not supported")
        }

        override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) {
            val leaf = chain?.firstOrNull() ?: throw CertificateException("empty certificate chain")
            if (!matches(leaf)) throw CertificateException("server certificate does not match the pinned fingerprint")
        }

        override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
    }

    val sslSocketFactory: SSLSocketFactory by lazy {
        val ctx = SSLContext.getInstance("TLS")
        ctx.init(null, arrayOf(trustManager), SecureRandom())
        ctx.socketFactory
    }

    /** Accepts any host name, but only when the peer presented the pinned certificate. */
    val hostnameVerifier: HostnameVerifier = HostnameVerifier { _, session ->
        try {
            val leaf = session.peerCertificates.firstOrNull()
            leaf != null && matches(leaf)
        } catch (_: SSLPeerUnverifiedException) {
            false
        }
    }

    fun apply(builder: OkHttpClient.Builder): OkHttpClient.Builder =
        builder.sslSocketFactory(sslSocketFactory, trustManager).hostnameVerifier(hostnameVerifier)

    companion object {
        fun sha256(bytes: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(bytes)

        fun fingerprintOf(cert: Certificate): ByteArray = sha256(cert.encoded)

        fun fingerprintMatches(cert: Certificate, fingerprint: ByteArray): Boolean = try {
            MessageDigest.isEqual(fingerprintOf(cert), fingerprint)
        } catch (_: Exception) {
            false
        }
    }
}
