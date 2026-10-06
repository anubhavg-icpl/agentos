package dev.nestlo.core.net

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.withTimeoutOrNull
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import java.io.IOException

/** How the server certificate is validated for an endpoint. */
enum class Trust {
    /** Only the certificate whose SHA-256 equals the pairing fingerprint; no host name check. */
    PINNED,

    /** Normal system trust store and host name verification (tunnels, public reverse proxies). */
    WEBPKI,
}

/** One way to reach the machine: scheme, host, port and the trust rule that goes with it. */
data class Endpoint(val host: String, val port: Int, val trust: Trust) {
    val authority: String get() = if (host.contains(':') && !host.startsWith("[")) "[$host]:$port" else "$host:$port"

    /** Base URL without trailing slash. Pairing and API traffic is always HTTPS. */
    val baseUrl: String get() = "https://$authority"

    fun url(path: String): HttpUrl = (baseUrl + path).toHttpUrl()

    /** Applies this endpoint's trust rule to [builder]. */
    fun applyTrust(builder: OkHttpClient.Builder, fingerprint: ByteArray): OkHttpClient.Builder = when (trust) {
        Trust.PINNED -> PinnedTls(fingerprint).apply(builder)
        Trust.WEBPKI -> builder
    }

    override fun toString(): String = "$baseUrl [${trust.name.lowercase()}]"

    companion object {
        /** A bare `host` entry: pinned. */
        fun pinned(host: String, port: Int): Endpoint = Endpoint(host.trim('[', ']'), port, Trust.PINNED)

        /**
         * Parses a `host` entry: `name`, `name:port`, `ipv4:port`, `[v6]` or `[v6]:port`.
         * A bare IPv6 literal (two or more colons, no brackets) carries no port.
         * Returns null for a malformed entry or an out-of-range port.
         */
        fun parseHost(entry: String, defaultPort: Int): Endpoint? {
            val e = entry.trim()
            if (e.isEmpty()) return null
            val host: String
            var port = defaultPort
            if (e.startsWith("[")) {
                val close = e.indexOf(']')
                if (close < 2) return null
                host = e.substring(1, close)
                val rest = e.substring(close + 1)
                if (rest.isNotEmpty()) {
                    if (!rest.startsWith(":")) return null
                    port = rest.substring(1).toIntOrNull() ?: return null
                }
            } else {
                val colons = e.count { it == ':' }
                if (colons == 1) {
                    host = e.substringBefore(':')
                    port = e.substringAfter(':').toIntOrNull() ?: return null
                } else {
                    host = e
                }
            }
            if (host.isEmpty() || port !in 1..65535) return null
            return Endpoint(host, port, Trust.PINNED)
        }

        /**
         * An `url` entry. Only https is supported. A non-IP host name is validated through the
         * system trust store; an IP literal can have no public certificate, so it stays pinned.
         * Returns null for anything else (http, no host, garbage).
         */
        fun fromUrl(raw: String): Endpoint? {
            val url = raw.trim().toHttpUrlOrNull() ?: return null
            if (url.scheme != "https") return null
            val host = url.host
            return Endpoint(host, url.port, if (isIpLiteral(host)) Trust.PINNED else Trust.WEBPKI)
        }

        /** True for IPv4 dotted quads and IPv6 literals (bare or bracketed). */
        fun isIpLiteral(host: String): Boolean {
            val h = host.trim()
            if (h.contains(':')) return true
            val parts = h.split('.')
            return parts.size == 4 && parts.all { p -> p.isNotEmpty() && p.length <= 3 && p.all { it in '0'..'9' } && p.toInt() <= 255 }
        }
    }
}

/** Outcome of walking an endpoint list. */
sealed interface Resolution {
    data class Found(val endpoint: Endpoint) : Resolution

    /** Nothing answered. [tunnelExpired] is true when a WebPKI (tunnel) entry was among those that failed. */
    data class Failed(val tried: List<Endpoint>, val tunnelExpired: Boolean) : Resolution

    /** The server answered 401 on some endpoint. */
    data object Unauthorized : Resolution
}

object EndpointResolver {
    const val TUNNEL_EXPIRED_MESSAGE = "TUNNEL EXPIRED — RE-PAIR OR USE LAN"

    /**
     * Probes [endpoints] in order with `GET /v1/info` and returns the first that answers.
     * [preferred] (the one used last) is tried first when present in the list.
     */
    suspend fun resolve(
        endpoints: List<Endpoint>,
        fingerprint: ByteArray,
        token: String,
        timeoutMs: Long = 2_500,
        base: OkHttpClient? = null,
        preferred: Endpoint? = null,
    ): Resolution {
        val ordered = if (preferred != null && preferred in endpoints) listOf(preferred) + (endpoints - preferred) else endpoints
        val failed = ArrayList<Endpoint>()
        for (ep in ordered) {
            val client = NestloClient(ep, fingerprint, token, base)
            try {
                val ok = withTimeoutOrNull(timeoutMs) { client.info() }
                if (ok != null) return Resolution.Found(ep)
                failed += ep
            } catch (e: UnauthorizedException) {
                return Resolution.Unauthorized
            } catch (e: CancellationException) {
                throw e
            } catch (e: IOException) {
                failed += ep
            } finally {
                client.shutdown()
            }
        }
        return Resolution.Failed(failed, failed.any { it.trust == Trust.WEBPKI })
    }
}
