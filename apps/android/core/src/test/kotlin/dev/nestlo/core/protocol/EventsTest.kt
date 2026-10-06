package dev.nestlo.core.protocol

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertNull

class EventsTest {
    @Test fun hello() {
        val e = assertIs<ServerEvent.Hello>(EventCodec.decode("""{"type":"hello","server_name":"n","version":"1"}"""))
        assertEquals("n", e.serverName)
    }

    @Test fun agent() {
        val e = assertIs<ServerEvent.AgentChanged>(
            EventCodec.decode("""{"type":"agent","agent":{"id":"a","agent":"c","workspace":"w","status":"working","spend_usd":1,"budget_usd":2,"started_at":"t"}}"""),
        )
        assertEquals("a", e.agent.id)
        assertEquals(AgentStatus.WORKING, e.agent.state)
    }

    @Test fun agentGoneAndNeedsInput() {
        assertEquals("a", assertIs<ServerEvent.AgentGone>(EventCodec.decode("""{"type":"agent_gone","id":"a"}""")).id)
        val n = assertIs<ServerEvent.NeedsInput>(
            EventCodec.decode("""{"type":"needs_input","id":"a","agent":"claude","workspace":"w","since":"t"}"""),
        )
        assertEquals("claude", n.agent)
        assertEquals("t", n.since)
    }

    @Test fun approvals() {
        val a = assertIs<ServerEvent.ApprovalRequested>(
            EventCodec.decode("""{"type":"approval","approval":{"id":"p","kind":"k","summary":"s","requested_by":"r","created_at":"t"}}"""),
        )
        assertEquals("p", a.approval.id)
        assertEquals("p", assertIs<ServerEvent.ApprovalDone>(EventCodec.decode("""{"type":"approval_done","id":"p"}""")).id)
    }

    @Test fun spendAndPing() {
        val s = assertIs<ServerEvent.SpendChanged>(EventCodec.decode("""{"type":"spend","today_usd":1.5,"budget_usd":9}"""))
        assertEquals(9.0, s.budgetUsd)
        assertIs<ServerEvent.Ping>(EventCodec.decode("""{"type":"ping"}"""))
    }

    @Test fun unknownAndMalformed() {
        assertEquals("zzz", assertIs<ServerEvent.Unknown>(EventCodec.decode("""{"type":"zzz"}""")).type)
        assertNull(EventCodec.decodeOrNull("not json"))
        assertNull(EventCodec.decodeOrNull("""{"type":"agent"}"""))
    }

    @Test fun pongFrame() = assertEquals("""{"type":"pong"}""", EventCodec.PONG)
}
