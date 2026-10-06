package dev.nestlo.app.data

import android.content.Context
import dev.nestlo.core.net.Endpoint
import dev.nestlo.core.net.PairingUri
import dev.nestlo.core.net.Trust

/** Everything needed to talk to the paired machine. */
class Credentials(
    val serverName: String,
    val deviceId: String,
    val token: String,
    val fingerprint: ByteArray,
    /** Endpoints in the order to try. */
    val endpoints: List<Endpoint>,
    /** Index of the endpoint that answered last. */
    val active: Int,
) {
    val endpoint: Endpoint get() = endpoints[active.coerceIn(0, endpoints.lastIndex)]

    val fingerprintB64: String get() = PairingUri.b64(fingerprint)

    fun withActive(e: Endpoint): Credentials {
        val i = endpoints.indexOf(e)
        return if (i < 0 || i == active) this else Credentials(serverName, deviceId, token, fingerprint, endpoints, i)
    }
}

class CredentialStore(context: Context) {
    private val prefs = context.getSharedPreferences("nestlo", Context.MODE_PRIVATE)

    fun load(): Credentials? {
        val enc = prefs.getString(K_TOKEN, null) ?: return null
        val token = SecretBox.decrypt(enc) ?: return null
        val fp = PairingUri.decodeB64(prefs.getString(K_FP, "") ?: "") ?: return null
        val eps = (prefs.getString(K_ENDPOINTS, "") ?: "").lines().mapNotNull { decodeEndpoint(it) }
        if (eps.isEmpty() || fp.size != 32) return null
        return Credentials(
            serverName = prefs.getString(K_NAME, "") ?: "",
            deviceId = prefs.getString(K_DEVICE, "") ?: "",
            token = token,
            fingerprint = fp,
            endpoints = eps,
            active = prefs.getInt(K_ACTIVE, 0),
        )
    }

    fun save(c: Credentials) {
        prefs.edit()
            .putString(K_TOKEN, SecretBox.encrypt(c.token))
            .putString(K_FP, c.fingerprintB64)
            .putString(K_NAME, c.serverName)
            .putString(K_DEVICE, c.deviceId)
            .putString(K_ENDPOINTS, c.endpoints.joinToString("\n") { encodeEndpoint(it) })
            .putInt(K_ACTIVE, c.active)
            .apply()
    }

    fun clear() {
        prefs.edit().remove(K_TOKEN).remove(K_FP).remove(K_NAME).remove(K_DEVICE).remove(K_ENDPOINTS).remove(K_ACTIVE).apply()
    }

    var alertsEnabled: Boolean
        get() = prefs.getBoolean(K_ALERTS, false)
        set(v) = prefs.edit().putBoolean(K_ALERTS, v).apply()

    var terminalFontSp: Float
        get() = prefs.getFloat(K_FONT, 12f)
        set(v) = prefs.edit().putFloat(K_FONT, v).apply()

    private fun encodeEndpoint(e: Endpoint) = "${e.trust.name}|${e.port}|${e.host}"

    private fun decodeEndpoint(s: String): Endpoint? {
        val parts = s.split('|', limit = 3)
        if (parts.size != 3) return null
        val trust = runCatching { Trust.valueOf(parts[0]) }.getOrNull() ?: return null
        val port = parts[1].toIntOrNull() ?: return null
        return Endpoint(parts[2], port, trust)
    }

    private companion object {
        const val K_TOKEN = "token_enc"
        const val K_FP = "fp"
        const val K_NAME = "server_name"
        const val K_DEVICE = "device_id"
        const val K_ENDPOINTS = "endpoints"
        const val K_ACTIVE = "active"
        const val K_ALERTS = "alerts"
        const val K_FONT = "term_font_sp"
    }
}
