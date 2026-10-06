package dev.nestlo.core.protocol

import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonDecoder
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonPrimitive

/** Shared JSON configuration: tolerant of unknown keys so newer servers keep working. */
val NestloJson: Json = Json {
    ignoreUnknownKeys = true
    coerceInputValues = true
    explicitNulls = false
    encodeDefaults = true
    isLenient = true
}

/** Accepts a JSON string or a bare number/boolean and yields its text. Used for ids. */
object LenientStringSerializer : KSerializer<String> {
    override val descriptor: SerialDescriptor =
        PrimitiveSerialDescriptor("dev.nestlo.LenientString", PrimitiveKind.STRING)

    override fun deserialize(decoder: Decoder): String {
        val el = (decoder as? JsonDecoder)?.decodeJsonElement() ?: return decoder.decodeString()
        return if (el is JsonPrimitive && el !is JsonNull) el.content else ""
    }

    override fun serialize(encoder: Encoder, value: String) = encoder.encodeString(value)
}

// ---------------------------------------------------------------- pairing

@Serializable
data class PairRequest(
    val code: String,
    @SerialName("device_name") val deviceName: String,
    @SerialName("device_model") val deviceModel: String,
)

@Serializable
data class PairResponse(
    @SerialName("device_id") val deviceId: String,
    val token: String,
    @SerialName("server_name") val serverName: String = "",
    @SerialName("server_version") val serverVersion: String = "",
)

@Serializable
data class Device(
    @SerialName("device_id") val deviceId: String,
    @SerialName("device_name") val deviceName: String = "",
    @SerialName("device_model") val deviceModel: String = "",
    @SerialName("paired_at") val pairedAt: String? = null,
    @SerialName("last_seen") val lastSeen: String? = null,
    val current: Boolean = false,
)

@Serializable
data class OkResponse(val ok: Boolean = false)

@Serializable
data class ErrorResponse(val error: String = "")

// ---------------------------------------------------------------- REST

object Feature {
    const val AGENTS = "agents"
    const val TERMINAL = "terminal"
    const val DESKTOP = "desktop"
    const val APPROVALS = "approvals"
}

@Serializable
data class ServerInfo(
    val name: String = "",
    val version: String = "",
    /** Free-form: the server may report a version string or a boolean. */
    val nixos: JsonElement? = null,
    @SerialName("uptime_s") val uptimeS: Double = 0.0,
    val features: List<String> = emptyList(),
) {
    fun has(feature: String): Boolean = feature in features
}

@Serializable
data class AgentCounts(
    val total: Int = 0,
    val working: Int = 0,
    val blocked: Int = 0,
    val idle: Int = 0,
    val done: Int = 0,
)

@Serializable
data class SpendInfo(
    @SerialName("today_usd") val todayUsd: Double = 0.0,
    @SerialName("budget_usd") val budgetUsd: Double = 0.0,
)

@Serializable
data class Health(
    val redis: Boolean = false,
    val gateway: Boolean = false,
    val daemon: Boolean = false,
)

@Serializable
data class Overview(
    val agents: AgentCounts = AgentCounts(),
    val spend: SpendInfo = SpendInfo(),
    val health: Health = Health(),
)

enum class AgentStatus(val wire: String) {
    WORKING("working"), BLOCKED("blocked"), IDLE("idle"), DONE("done"), FAILED("failed"), KILLED("killed"), UNKNOWN("");

    companion object {
        fun parse(s: String?): AgentStatus = entries.firstOrNull { it.wire == s && it != UNKNOWN } ?: UNKNOWN
    }
}

@Serializable
data class Agent(
    @Serializable(with = LenientStringSerializer::class) val id: String,
    val agent: String = "",
    val workspace: String = "",
    val status: String = "",
    @SerialName("spend_usd") val spendUsd: Double = 0.0,
    @SerialName("budget_usd") val budgetUsd: Double = 0.0,
    @SerialName("started_at") val startedAt: String? = null,
) {
    val state: AgentStatus get() = AgentStatus.parse(status)

    /** True while the process may still be acted on (kill makes sense). */
    val isLive: Boolean get() = state == AgentStatus.WORKING || state == AgentStatus.BLOCKED || state == AgentStatus.IDLE
}

@Serializable
data class RequestLogEntry(
    val ts: String = "",
    val provider: String = "",
    val model: String = "",
    @SerialName("input_tokens") val inputTokens: Long = 0,
    @SerialName("output_tokens") val outputTokens: Long = 0,
    @SerialName("cost_usd") val costUsd: Double = 0.0,
    val status: String = "",
)

@Serializable
data class Approval(
    @Serializable(with = LenientStringSerializer::class) val id: String,
    val kind: String = "",
    val summary: String = "",
    @SerialName("requested_by") val requestedBy: String = "",
    @SerialName("created_at") val createdAt: String? = null,
)

@Serializable
data class ApprovalDecision(val decision: String) {
    companion object {
        val APPROVE = ApprovalDecision("approve")
        val DENY = ApprovalDecision("deny")
    }
}

object SessionKind {
    const val TUIOS = "tuios"
    const val SHELL = "shell"
}

@Serializable
data class TermSession(
    @Serializable(with = LenientStringSerializer::class) val id: String,
    val title: String = "",
    val kind: String = SessionKind.SHELL,
    val user: String = "",
)

// ---------------------------------------------------------------- terminal control frames

@Serializable
data class ResizeFrame(val cols: Int, val rows: Int, val type: String = "resize")

@Serializable
data class ExitFrame(val code: Int = 0, val type: String = "exit")
