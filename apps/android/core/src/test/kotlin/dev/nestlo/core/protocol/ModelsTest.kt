package dev.nestlo.core.protocol

import kotlinx.serialization.builtins.ListSerializer
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ModelsTest {
    @Test fun pairRequestUsesSnakeCase() {
        val s = NestloJson.encodeToString(PairRequest.serializer(), PairRequest("c", "Pixel 9", "google/tokay"))
        assertEquals("""{"code":"c","device_name":"Pixel 9","device_model":"google/tokay"}""", s)
    }

    @Test fun pairResponse() {
        val r = NestloJson.decodeFromString(
            PairResponse.serializer(),
            """{"device_id":"d_0123456789ab","token":"tok","server_name":"nestlo","server_version":"0.5.0","extra":1}""",
        )
        assertEquals("d_0123456789ab", r.deviceId)
        assertEquals("tok", r.token)
        assertEquals("0.5.0", r.serverVersion)
    }

    @Test fun info() {
        val i = NestloJson.decodeFromString(
            ServerInfo.serializer(),
            """{"name":"n","version":"1","nixos":"24.11","uptime_s":12.5,"features":["agents","terminal"]}""",
        )
        assertTrue(i.has(Feature.AGENTS))
        assertFalse(i.has(Feature.DESKTOP))
        assertEquals(12.5, i.uptimeS)
    }

    @Test fun infoNixosBooleanAndIntUptime() {
        val i = NestloJson.decodeFromString(ServerInfo.serializer(), """{"nixos":true,"uptime_s":42,"features":[]}""")
        assertEquals(42.0, i.uptimeS)
    }

    @Test fun overview() {
        val o = NestloJson.decodeFromString(
            Overview.serializer(),
            """{"agents":{"total":5,"working":2,"blocked":1,"idle":1,"done":1},"spend":{"today_usd":3.5,"budget_usd":10},"health":{"redis":true,"gateway":true,"daemon":false}}""",
        )
        assertEquals(2, o.agents.working)
        assertEquals(10.0, o.spend.budgetUsd)
        assertFalse(o.health.daemon)
    }

    @Test fun agentsAndStatus() {
        val l = NestloJson.decodeFromString(
            ListSerializer(Agent.serializer()),
            """[{"id":"a1","agent":"claude","workspace":"/w","status":"blocked","spend_usd":1.25,"budget_usd":5.0,"started_at":"2025-01-01T00:00:00Z"},
               {"id":7,"agent":"x","workspace":"","status":"weird","spend_usd":0,"budget_usd":null,"started_at":null}]""",
        )
        assertEquals(AgentStatus.BLOCKED, l[0].state)
        assertTrue(l[0].isLive)
        assertEquals("7", l[1].id)
        assertEquals(AgentStatus.UNKNOWN, l[1].state)
        assertNull(l[1].startedAt)
    }

    @Test fun allStatusesParse() {
        for (s in listOf("working", "blocked", "idle", "done", "failed", "killed")) {
            assertEquals(s, AgentStatus.parse(s).wire)
        }
    }

    @Test fun requestsApprovalsSessionsDevices() {
        val r = NestloJson.decodeFromString(
            ListSerializer(RequestLogEntry.serializer()),
            """[{"ts":"t","provider":"anthropic","model":"m","input_tokens":10,"output_tokens":20,"cost_usd":0.01,"status":"ok"}]""",
        )
        assertEquals(20, r[0].outputTokens)
        val a = NestloJson.decodeFromString(
            ListSerializer(Approval.serializer()),
            """[{"id":"p1","kind":"deploy","summary":"s","requested_by":"bob","created_at":"t"}]""",
        )
        assertEquals("bob", a[0].requestedBy)
        val s = NestloJson.decodeFromString(
            ListSerializer(TermSession.serializer()),
            """[{"id":"tuios:u:main","title":"main","kind":"tuios","user":"u"}]""",
        )
        assertEquals(SessionKind.TUIOS, s[0].kind)
        val d = NestloJson.decodeFromString(
            ListSerializer(Device.serializer()),
            """[{"device_id":"d_1","device_name":"Pixel","device_model":"m","paired_at":"t","last_seen":"t","current":true}]""",
        )
        assertTrue(d[0].current)
    }

    @Test fun decisionBody() {
        assertEquals("""{"decision":"approve"}""", NestloJson.encodeToString(ApprovalDecision.serializer(), ApprovalDecision.APPROVE))
        assertEquals("""{"decision":"deny"}""", NestloJson.encodeToString(ApprovalDecision.serializer(), ApprovalDecision.DENY))
    }

    @Test fun controlFrames() {
        assertEquals("""{"cols":80,"rows":24,"type":"resize"}""", NestloJson.encodeToString(ResizeFrame.serializer(), ResizeFrame(80, 24)))
        val e = NestloJson.decodeFromString(ExitFrame.serializer(), """{"type":"exit","code":3}""")
        assertEquals(3, e.code)
    }

    @Test fun errorBody() {
        assertEquals("nope", NestloJson.decodeFromString(ErrorResponse.serializer(), """{"error":"nope"}""").error)
    }
}
