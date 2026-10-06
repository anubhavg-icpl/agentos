package dev.nestlo.core.protocol

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/** A decoded frame from `WS /v1/events`. */
sealed interface ServerEvent {
    data class Hello(val serverName: String, val version: String) : ServerEvent
    data class AgentChanged(val agent: Agent) : ServerEvent
    data class AgentGone(val id: String) : ServerEvent
    data class NeedsInput(val id: String, val agent: String, val workspace: String, val since: String?) : ServerEvent
    data class ApprovalRequested(val approval: Approval) : ServerEvent
    data class ApprovalDone(val id: String) : ServerEvent
    data class SpendChanged(val todayUsd: Double, val budgetUsd: Double) : ServerEvent
    data object Ping : ServerEvent
    data class Unknown(val type: String) : ServerEvent
}

@Serializable
private data class AgentEnvelope(val agent: Agent)

@Serializable
private data class ApprovalEnvelope(val approval: Approval)

@Serializable
private data class NeedsInputFrame(
    @Serializable(with = LenientStringSerializer::class) val id: String,
    val agent: String = "",
    val workspace: String = "",
    val since: String? = null,
)

@Serializable
private data class IdFrame(@Serializable(with = LenientStringSerializer::class) val id: String)

@Serializable
private data class HelloFrame(
    @SerialName("server_name") val serverName: String = "",
    val version: String = "",
)

@Serializable
private data class SpendFrame(
    @SerialName("today_usd") val todayUsd: Double = 0.0,
    @SerialName("budget_usd") val budgetUsd: Double = 0.0,
)

object EventCodec {
    /** Client reply to a server `ping`. */
    const val PONG: String = """{"type":"pong"}"""

    /** Decodes one text frame. Malformed JSON throws; unknown types yield [ServerEvent.Unknown]. */
    fun decode(text: String): ServerEvent {
        val obj: JsonObject = NestloJson.parseToJsonElement(text).jsonObject
        val type = obj["type"]?.jsonPrimitive?.contentOrNull ?: ""
        return when (type) {
            "hello" -> NestloJson.decodeFromJsonElement(HelloFrame.serializer(), obj)
                .let { ServerEvent.Hello(it.serverName, it.version) }
            "agent" -> ServerEvent.AgentChanged(
                NestloJson.decodeFromJsonElement(AgentEnvelope.serializer(), obj).agent,
            )
            "agent_gone" -> ServerEvent.AgentGone(NestloJson.decodeFromJsonElement(IdFrame.serializer(), obj).id)
            "needs_input" -> NestloJson.decodeFromJsonElement(NeedsInputFrame.serializer(), obj)
                .let { ServerEvent.NeedsInput(it.id, it.agent, it.workspace, it.since) }
            "approval" -> ServerEvent.ApprovalRequested(
                NestloJson.decodeFromJsonElement(ApprovalEnvelope.serializer(), obj).approval,
            )
            "approval_done" -> ServerEvent.ApprovalDone(NestloJson.decodeFromJsonElement(IdFrame.serializer(), obj).id)
            "spend" -> NestloJson.decodeFromJsonElement(SpendFrame.serializer(), obj)
                .let { ServerEvent.SpendChanged(it.todayUsd, it.budgetUsd) }
            "ping" -> ServerEvent.Ping
            else -> ServerEvent.Unknown(type)
        }
    }

    /** Decodes a frame and returns null instead of throwing on malformed input. */
    fun decodeOrNull(text: String): ServerEvent? = try {
        decode(text)
    } catch (_: Exception) {
        null
    }
}
