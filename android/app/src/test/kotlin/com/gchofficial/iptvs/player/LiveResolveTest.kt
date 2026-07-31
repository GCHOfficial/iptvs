package com.gchofficial.iptvs.player

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ResolveAgainReplyTest {
    private val current = LiveLocator(
        url = "http://portal.example/live/stale?token=spent",
        headers = mapOf("User-Agent" to "Mozilla/5.0 (MAG250; Link)"),
    )

    @Test
    fun `a null reply keeps the current locator`() {
        assertEquals(current, ResolveAgainReply.parse(null, current))
    }

    @Test
    fun `a non-map reply keeps the current locator`() {
        // A superseded ChannelHandlerOwner returns null, but a wrong-shaped
        // reply must be just as inert — never an exception, never a blank URL.
        assertEquals(current, ResolveAgainReply.parse("http://elsewhere/", current))
        assertEquals(current, ResolveAgainReply.parse(listOf("http://elsewhere/"), current))
        assertEquals(current, ResolveAgainReply.parse(42, current))
        assertEquals(current, ResolveAgainReply.parse(true, current))
    }

    @Test
    fun `a map without a usable url keeps the current locator`() {
        assertEquals(current, ResolveAgainReply.parse(emptyMap<String, Any?>(), current))
        assertEquals(current, ResolveAgainReply.parse(mapOf("url" to null), current))
        assertEquals(current, ResolveAgainReply.parse(mapOf("url" to ""), current))
        assertEquals(current, ResolveAgainReply.parse(mapOf("url" to "   "), current))
        assertEquals(current, ResolveAgainReply.parse(mapOf("url" to 7), current))
    }

    @Test
    fun `a url-less reply keeps the current headers too`() {
        // The headers of a reply we can't read a URL out of aren't trustworthy.
        val reply = mapOf("headers" to mapOf("User-Agent" to "replaced"))
        assertEquals(current, ResolveAgainReply.parse(reply, current))
    }

    @Test
    fun `a fresh url replaces the stale one`() {
        val reply = mapOf("url" to "http://portal.example/live/fresh?token=new")
        val next = ResolveAgainReply.parse(reply, current)
        assertEquals("http://portal.example/live/fresh?token=new", next.url)
    }

    @Test
    fun `absent headers preserve the current ones`() {
        // A MAG portal refuses a request without its User-Agent, so an absent
        // or unreadable header map must never blank the ones we already hold.
        val fresh = "http://portal.example/live/fresh?token=new"
        assertEquals(
            current.headers,
            ResolveAgainReply.parse(mapOf("url" to fresh), current).headers,
        )
        assertEquals(
            current.headers,
            ResolveAgainReply.parse(mapOf("url" to fresh, "headers" to null), current).headers,
        )
        assertEquals(
            current.headers,
            ResolveAgainReply.parse(mapOf("url" to fresh, "headers" to "nope"), current).headers,
        )
    }

    @Test
    fun `an empty header map preserves the current ones`() {
        val reply = mapOf(
            "url" to "http://portal.example/live/fresh?token=new",
            "headers" to emptyMap<String, String>(),
        )
        assertEquals(current.headers, ResolveAgainReply.parse(reply, current).headers)
    }

    @Test
    fun `a non-empty header map replaces the current ones`() {
        val reply = mapOf(
            "url" to "http://portal.example/live/fresh?token=new",
            "headers" to mapOf("User-Agent" to "MAG250", "Referer" to "http://portal.example/"),
        )
        val next = ResolveAgainReply.parse(reply, current)
        assertEquals(
            mapOf("User-Agent" to "MAG250", "Referer" to "http://portal.example/"),
            next.headers,
        )
    }

    @Test
    fun `header entries are coerced and unusable ones dropped`() {
        // The channel codec hands over Map<Object?, Object?>: non-String keys
        // and null values can't be used, other values stringify (as the `open`
        // handler in MainActivity already does).
        val reply = mapOf(
            "url" to "http://portal.example/live/fresh?token=new",
            "headers" to mapOf(
                "User-Agent" to "MAG250",
                "" to "blank key",
                "  " to "blank key",
                7 to "non-string key",
                "Dropped" to null,
                "X-Retry" to 3,
            ),
        )
        val next = ResolveAgainReply.parse(reply, current)
        assertEquals(mapOf("User-Agent" to "MAG250", "X-Retry" to "3"), next.headers)
    }

    @Test
    fun `a header map with only unusable entries preserves the current ones`() {
        val reply = mapOf(
            "url" to "http://portal.example/live/fresh?token=new",
            "headers" to mapOf("Dropped" to null),
        )
        assertEquals(current.headers, ResolveAgainReply.parse(reply, current).headers)
    }
}

class ResolveGateTest {
    @Test
    fun `a fresh gate is idle and hands out a token`() {
        val gate = ResolveGate()
        assertFalse(gate.inFlight)
        assertNotNull(gate.begin())
        assertTrue(gate.inFlight)
    }

    @Test
    fun `a second request is refused while one is in flight`() {
        // The in-flight guard: the reconnect watchdog and "Go to live" must
        // never issue two create_link calls at once (single-connection accounts).
        val gate = ResolveGate()
        val first = gate.begin()
        assertNotNull(first)
        assertNull(gate.begin())
        assertNull(gate.begin())
        assertTrue(gate.inFlight)
    }

    @Test
    fun `settling reopens the gate for the next request`() {
        val gate = ResolveGate()
        val first = gate.begin()!!
        assertTrue(gate.settle(first))
        assertFalse(gate.inFlight)
        val second = gate.begin()
        assertNotNull(second)
        assertTrue(second!! > first)
    }

    @Test
    fun `the reply wins and the later timeout is discarded`() {
        val gate = ResolveGate()
        val token = gate.begin()!!
        assertTrue(gate.settle(token)) // reply
        assertFalse(gate.settle(token)) // timeout fires afterwards: no-op
    }

    @Test
    fun `the timeout wins and the late reply is discarded`() {
        val gate = ResolveGate()
        val token = gate.begin()!!
        assertTrue(gate.settle(token)) // timeout
        assertFalse(gate.settle(token)) // reply arrives late: no-op
    }

    @Test
    fun `a stale token cannot settle the request that replaced it`() {
        // The whole point of the monotonic token: a reply belonging to a
        // timed-out request must not settle — and so must not reload for — the
        // request that has since begun.
        val gate = ResolveGate()
        val stale = gate.begin()!!
        assertTrue(gate.settle(stale))
        val current = gate.begin()!!
        assertFalse(gate.settle(stale))
        assertTrue(gate.inFlight)
        assertTrue(gate.settle(current))
    }

    @Test
    fun `tokens are monotonic across cycles`() {
        val gate = ResolveGate()
        var previous = 0L
        repeat(5) {
            val token = gate.begin()!!
            assertTrue(token > previous)
            previous = token
            assertTrue(gate.settle(token))
        }
    }

    @Test
    fun `settling an unissued token is inert`() {
        val gate = ResolveGate()
        assertFalse(gate.settle(1L))
        assertFalse(gate.inFlight)
    }

    @Test
    fun `the resolve timeout stays within the reconnect backoff cap`() {
        // The timeout is a liveness backstop, not reconnect timing policy: a
        // hung resolve must not hold the gate shut longer than the backoff
        // policy already allows between two attempts.
        assertTrue(ResolveGate.TIMEOUT_MS <= ReconnectPolicy.MAX_BACKOFF_MS)
        // …and comfortably longer than a stall threshold, so the fallback to
        // the (already spent) locator is a last resort rather than the norm.
        assertTrue(ResolveGate.TIMEOUT_MS > ReconnectPolicy.ENDED_RECONNECT_MS)
    }

    @Test
    fun `locators are value-compared so an unchanged url is detectable`() {
        // HdrPlayerActivity logs `refreshed=` by comparing the parsed locator's
        // url with the one it holds; the data class must compare by value.
        val a = LiveLocator("http://p/live/1", mapOf("User-Agent" to "MAG250"))
        val b = LiveLocator("http://p/live/1", mapOf("User-Agent" to "MAG250"))
        assertEquals(a, b)
        assertEquals(a.url, b.url)
    }
}
