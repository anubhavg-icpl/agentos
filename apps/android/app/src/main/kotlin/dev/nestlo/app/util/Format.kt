package dev.nestlo.app.util

import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

object Format {
    private val clock = DateTimeFormatter.ofPattern("HH:mm:ss").withZone(ZoneId.systemDefault())

    fun usd(v: Double): String = String.format(Locale.US, "$%.2f", v)

    fun clock(iso: String): String = try {
        clock.format(Instant.parse(iso))
    } catch (_: Exception) {
        iso.take(8)
    }

    fun tokens(n: Long): String = when {
        n >= 1_000_000 -> String.format(Locale.US, "%.1fM", n / 1_000_000.0)
        n >= 1_000 -> String.format(Locale.US, "%.1fk", n / 1_000.0)
        else -> n.toString()
    }

    fun uptime(seconds: Double): String {
        val s = seconds.toLong()
        val d = s / 86400
        val h = (s % 86400) / 3600
        val m = (s % 3600) / 60
        return if (d > 0) "${d}D ${h}H" else if (h > 0) "${h}H ${m}M" else "${m}M"
    }

    /** SHA-256 bytes as grouped upper-case hex, e.g. "AB:CD:...". */
    fun hex(bytes: ByteArray): String = bytes.joinToString(":") { "%02X".format(it.toInt() and 0xFF) }
}
