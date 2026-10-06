package dev.nestlo.core.net

import java.net.URLDecoder
import java.util.Base64

class PairingUriException(message: String) : Exception(message)

/**
 * Parsed `nestlo://pair?v=1&name=..&port=7443&fp=..&code=..&host=..&host=..` link.
 * [fingerprint] is the SHA-256 of the server certificate's DER encoding (32 bytes);
 * [code] is the single-use pairing code in its wire (base64url) form.
 */
class PairingUri(
    val version: Int,
    val name: String,
    val port: Int,
    val fingerprint: ByteArray,
    val code: String,
    val hosts: List<String>,
    /** Full base URLs from repeated `url` parameters, tried before [hosts]. */
    val urls: List<String> = emptyList(),
) {
    /** Endpoints in the order to try: `url` entries first, then pinned `host` entries. */
    val endpoints: List<Endpoint> by lazy {
        urls.mapNotNull { Endpoint.fromUrl(it) } + hosts.mapNotNull { Endpoint.parseHost(it, port) }
    }

    val fingerprintB64: String get() = b64(fingerprint)

    override fun toString(): String = "PairingUri(name=$name, port=$port, urls=$urls, hosts=$hosts)"

    companion object {
        const val SUPPORTED_VERSION = 1
        const val DEFAULT_PORT = 7443
        private const val PREFIX = "nestlo://pair"

        fun b64(bytes: ByteArray): String = Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)

        /** Decodes base64url, requiring no padding characters. */
        fun decodeB64(s: String): ByteArray? {
            if (s.isEmpty() || s.any { !(it.isLetterOrDigit() && it.code < 128 || it == '-' || it == '_') }) return null
            return try {
                Base64.getUrlDecoder().decode(s)
            } catch (_: IllegalArgumentException) {
                null
            }
        }

        fun parseOrNull(raw: String): PairingUri? = try {
            parse(raw)
        } catch (_: PairingUriException) {
            null
        }

        @Throws(PairingUriException::class)
        fun parse(raw: String): PairingUri {
            val text = raw.trim()
            val query: String
            if (text.regionMatches(0, PREFIX, 0, PREFIX.length, ignoreCase = true)) {
                // nestlo://pair?...  (parameters in the query)
                var rest = text.substring(PREFIX.length)
                if (rest.startsWith("/")) rest = rest.substring(1)
                if (!rest.startsWith("?")) throw PairingUriException("Pairing link has no parameters")
                val hash = rest.indexOf('#')
                query = if (hash >= 0) rest.substring(1, hash) else rest.substring(1)
            } else if (text.startsWith("http://", ignoreCase = true) || text.startsWith("https://", ignoreCase = true)) {
                // http(s)://<host>[:port]/pair#...  (parameters in the fragment)
                val hash = text.indexOf('#')
                if (hash < 0) throw PairingUriException("Pairing link has no parameters")
                val beforeHash = text.substring(0, hash)
                val pathStart = beforeHash.indexOf('/', beforeHash.indexOf("://") + 3)
                val path = if (pathStart < 0) "" else beforeHash.substring(pathStart).substringBefore('?').trimEnd('/')
                if (!path.endsWith("/pair")) throw PairingUriException("Not a nestlo pairing link")
                query = text.substring(hash + 1)
            } else {
                throw PairingUriException("Not a nestlo pairing link")
            }

            val single = HashMap<String, String>()
            val hosts = ArrayList<String>()
            val urls = ArrayList<String>()
            for (pair in query.split('&')) {
                if (pair.isEmpty()) continue
                val eq = pair.indexOf('=')
                val key = decode(if (eq < 0) pair else pair.substring(0, eq))
                val value = if (eq < 0) "" else decode(pair.substring(eq + 1))
                if (key == "url") {
                    if (value.isNotBlank()) urls += value.trim()
                } else if (key == "host") {
                    if (value.isNotBlank()) hosts += value.trim()
                } else if (key !in single) {
                    single[key] = value
                }
            }

            val version = single["v"]?.toIntOrNull() ?: throw PairingUriException("Missing version")
            if (version != SUPPORTED_VERSION) throw PairingUriException("Unsupported pairing version $version")

            val port = single["port"]?.let {
                it.toIntOrNull()?.takeIf { p -> p in 1..65535 } ?: throw PairingUriException("Invalid port")
            } ?: DEFAULT_PORT

            val fp = single["fp"]?.let { decodeB64(it) } ?: throw PairingUriException("Invalid certificate fingerprint")
            if (fp.size != 32) throw PairingUriException("Fingerprint must be 32 bytes")

            val codeRaw = single["code"] ?: throw PairingUriException("Missing pairing code")
            val code = decodeB64(codeRaw) ?: throw PairingUriException("Invalid pairing code")
            if (code.size != 16) throw PairingUriException("Pairing code must be 16 bytes")

            if (hosts.isEmpty() && urls.isEmpty()) throw PairingUriException("No host addresses")
            val goodUrls = urls.filter { Endpoint.fromUrl(it) != null }
            if (urls.isNotEmpty() && goodUrls.isEmpty() && hosts.isEmpty()) {
                throw PairingUriException("Only https URLs are supported")
            }
            for (h in hosts) {
                if (h.any { it.isWhitespace() || it == '/' || it == '?' || it == '#' || it == '@' }) {
                    throw PairingUriException("Invalid host '$h'")
                }
                if (Endpoint.parseHost(h, port) == null) throw PairingUriException("Invalid host '$h'")
            }

            return PairingUri(
                version = version,
                name = single["name"]?.takeIf { it.isNotBlank() } ?: (hosts.firstOrNull() ?: goodUrls.first()),
                port = port,
                fingerprint = fp,
                code = codeRaw,
                hosts = hosts.toList(),
                urls = goodUrls,
            )
        }

        private fun decode(s: String): String = try {
            URLDecoder.decode(s, "UTF-8")
        } catch (_: IllegalArgumentException) {
            throw PairingUriException("Malformed percent-encoding")
        }
    }
}
