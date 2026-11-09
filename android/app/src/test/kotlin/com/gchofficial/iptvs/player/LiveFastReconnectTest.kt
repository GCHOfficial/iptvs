package com.gchofficial.iptvs.player

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the pre-resolved live reconnect's decisions, the shape of the exported
 * lines, and the one invariant the whole path rests on: **a stored locator is
 * spent at most once.**
 */
class LiveFastReconnectTest {
    private val locator =
        LiveLocator("http://portal.example/ch?token=TOKEN-ABC123", mapOf("User-Agent" to "MAG-250"))
    private val other =
        LiveLocator("http://portal.example/ch?token=TOKEN-DEF456", mapOf("User-Agent" to "MAG-250"))

    // ── The pure decisions ───────────────────────────────────────────────────

    @Test
    fun `a live source EOF with nothing held asks for a locator`() {
        assertTrue(
            LiveFastReconnectPolicy.shouldPreResolve(
                isLive = true,
                enabled = true,
                holdsLocator = false,
                resolveInFlight = false,
                zapSettling = false,
            ),
        )
    }

    @Test
    fun `every other condition refuses the request`() {
        // VOD never pre-resolves (it has no reconnect watchdog at all), a
        // second EOF on the same connection must not spend a second token, the
        // single-connection gate is respected, and a settling zap is already
        // replacing this stream with a different channel.
        val refusals = listOf(
            LiveFastReconnectPolicy.shouldPreResolve(false, true, false, false, false),
            LiveFastReconnectPolicy.shouldPreResolve(true, false, false, false, false),
            LiveFastReconnectPolicy.shouldPreResolve(true, true, true, false, false),
            LiveFastReconnectPolicy.shouldPreResolve(true, true, false, true, false),
            LiveFastReconnectPolicy.shouldPreResolve(true, true, false, false, true),
        )
        for (refused in refusals) assertFalse(refused)
    }

    @Test
    fun `freshness spans the observed drain and stops at the bound`() {
        // The evidence: body closes at ~6 s, buffer runs dry at ~26 s, so the
        // locator is ~20 s old when it is used.
        assertTrue(LiveFastReconnectPolicy.isFresh(0L))
        assertTrue(LiveFastReconnectPolicy.isFresh(20_183L))
        assertTrue(LiveFastReconnectPolicy.isFresh(LiveFastReconnectPolicy.FRESH_MS))
        assertFalse(LiveFastReconnectPolicy.isFresh(LiveFastReconnectPolicy.FRESH_MS + 1))
        // -1 is "nothing held", never "brand new".
        assertFalse(LiveFastReconnectPolicy.isFresh(-1L))
    }

    @Test
    fun `the bound clears the observed drain and the low preset ceiling`() {
        // The drain is the size of the backlog the connection delivered, which
        // is capped by the preset's maxBufferMs (25 / 50 / 90 / 120 s). This
        // must clear the observed ~21 s and the whole of `low`; it deliberately
        // does *not* stretch to `max`, where a 120 s-old single-use token is a
        // likelier failure than the round trip it would have saved. Both bounds
        // are asserted so neither can drift without this test saying so.
        assertTrue(LiveFastReconnectPolicy.FRESH_MS >= 26_000L)
        assertTrue(LiveFastReconnectPolicy.FRESH_MS < 50_000L)
    }

    @Test
    fun `only a clean drop uses a stored locator`() {
        fun use(endedDrop: Boolean, forced: Boolean, enabled: Boolean, held: Boolean, age: Long) =
            LiveFastReconnectPolicy.shouldUsePreResolved(endedDrop, forced, enabled, held, age)

        assertTrue(use(endedDrop = true, forced = false, enabled = true, held = true, age = 100L))
        // A buffering or frozen-renderer stall is not a server close: the
        // connection is still open, and a locator minted at an earlier EOF is
        // not what that failure needs.
        assertFalse(use(endedDrop = false, forced = false, enabled = true, held = true, age = 100L))
        assertFalse(use(endedDrop = true, forced = true, enabled = true, held = true, age = 100L))
        assertFalse(use(endedDrop = true, forced = false, enabled = false, held = true, age = 100L))
        assertFalse(use(endedDrop = true, forced = false, enabled = true, held = false, age = 100L))
        assertFalse(
            use(
                endedDrop = true,
                forced = false,
                enabled = true,
                held = true,
                age = LiveFastReconnectPolicy.FRESH_MS + 1,
            ),
        )
    }

    @Test
    fun `a short-lived pre-resolved connection is a failure, a long one is not`() {
        assertTrue(LiveFastReconnectPolicy.isFastPathFailure(0L))
        assertTrue(
            LiveFastReconnectPolicy.isFastPathFailure(
                LiveFastReconnectPolicy.FAILURE_WINDOW_MS - 1,
            ),
        )
        assertFalse(
            LiveFastReconnectPolicy.isFastPathFailure(LiveFastReconnectPolicy.FAILURE_WINDOW_MS),
        )
        // The healthy cycle in the evidence, which must never count against it.
        assertFalse(LiveFastReconnectPolicy.isFastPathFailure(26_000L))
    }

    @Test
    fun `the failure window stays well inside the healthy cycle`() {
        // It has to separate "the portal refused the link" from "a short but
        // working connection"; the observed healthy connection is ~26 s.
        assertTrue(LiveFastReconnectPolicy.FAILURE_WINDOW_MS < 26_000L / 3)
    }

    @Test
    fun `back-off needs a streak, not one bad connection`() {
        assertFalse(LiveFastReconnectPolicy.shouldBackOff(0))
        assertFalse(LiveFastReconnectPolicy.shouldBackOff(1))
        assertFalse(
            LiveFastReconnectPolicy.shouldBackOff(
                LiveFastReconnectPolicy.MAX_CONSECUTIVE_FAILURES - 1,
            ),
        )
        assertTrue(
            LiveFastReconnectPolicy.shouldBackOff(
                LiveFastReconnectPolicy.MAX_CONSECUTIVE_FAILURES,
            ),
        )
    }

    @Test
    fun `no existing reconnect constant moves`() {
        // This is an additional path, not a retune: an export that shows
        // `path=resolve` must behave exactly as 0.1.80 did.
        assertEquals(2_000L, ReconnectPolicy.ENDED_RECONNECT_MS)
        assertEquals(8_000L, ReconnectPolicy.STALL_RECONNECT_MS)
        assertEquals(30_000L, ReconnectPolicy.MAX_BACKOFF_MS)
    }

    // ── The exported vocabulary ──────────────────────────────────────────────

    @Test
    fun `the diagnostics lines read as specified and carry no locator`() {
        assertEquals(
            "live pre-resolve requested sinceLoadMs=6032",
            LiveFastReconnectPolicy.requestedLine(6032L),
        )
        assertEquals(
            "live pre-resolve ready ageMs=412 ok=true",
            LiveFastReconnectPolicy.readyLine(412L, ok = true),
        )
        assertEquals(
            "live pre-resolve ready ageMs=10000 ok=false",
            LiveFastReconnectPolicy.readyLine(10_000L, ok = false),
        )
        assertEquals(
            "live pre-resolve disabled failures=3 playedMs=1204",
            LiveFastReconnectPolicy.backOffLine(failures = 3, playedMs = 1204L),
        )
        assertEquals(
            "path=preresolved ageMs=20183",
            LiveFastReconnectPolicy.reconnectPath(usedPreResolved = true, ageMs = 20_183L),
        )
        assertEquals(
            "path=resolve ageMs=-1",
            LiveFastReconnectPolicy.reconnectPath(usedPreResolved = false, ageMs = -1L),
        )
        // A declined *stale* locator still reports its age — that is the field
        // that says the freshness bound, not the absence of a pre-resolve, is
        // why the slow path ran.
        assertEquals(
            "path=resolve ageMs=41000",
            LiveFastReconnectPolicy.reconnectPath(usedPreResolved = false, ageMs = 41_000L),
        )
        val every = listOf(
            LiveFastReconnectPolicy.requestedLine(1L),
            LiveFastReconnectPolicy.readyLine(1L, ok = true),
            LiveFastReconnectPolicy.backOffLine(1, 1L),
            LiveFastReconnectPolicy.reconnectPath(true, 1L),
        )
        for (line in every) {
            assertFalse(line.contains("TOKEN-ABC123"))
            assertFalse(line.contains("portal.example"))
            assertFalse(line.contains("MAG-250"))
        }
    }

    // ── The session state ────────────────────────────────────────────────────

    @Test
    fun `the evidence's cycle takes the fast path`() {
        val fast = LiveFastReconnect()
        // Source EOF at 6032 ms into the load, reply 412 ms later.
        val token = fast.noteRequested(6_032L)
        assertTrue(fast.store(token, locator))
        // The age includes the round trip: the token was minted inside it.
        assertEquals(412L, fast.ageMs(6_444L))
        // Buffer runs dry at ~26 s; the locator is ~20 s old.
        assertEquals(20_183L, fast.ageMs(26_215L))
        assertTrue(fast.readyFor(26_215L, endedDrop = true, forced = false))
        assertEquals(
            locator,
            fast.takeForReload(26_215L, endedDrop = true, forced = false),
        )
    }

    @Test
    fun `a stored locator is spent at most once`() {
        val fast = LiveFastReconnect()
        fast.store(fast.noteRequested(0L), locator)
        assertNotNull(fast.takeForReload(1_000L, endedDrop = true, forced = false))
        // Stalker `play_token`s are single-use; a second reload must re-resolve.
        assertNull(fast.takeForReload(1_100L, endedDrop = true, forced = false))
        assertFalse(fast.holdsLocator)
        assertEquals(-1L, fast.ageMs(1_100L))
    }

    @Test
    fun `a stall or a forced reconnect discards rather than spends`() {
        for (args in listOf(false to false, true to true)) {
            val fast = LiveFastReconnect()
            fast.store(fast.noteRequested(0L), locator)
            assertNull(fast.takeForReload(1_000L, endedDrop = args.first, forced = args.second))
            // Cleared either way: any reload supersedes the locator, and one
            // left behind would only age toward being loaded dead later.
            assertFalse(fast.holdsLocator)
        }
    }

    @Test
    fun `a stale locator is dropped and the ordinary path runs`() {
        val fast = LiveFastReconnect()
        fast.store(fast.noteRequested(0L), locator)
        val tooLate = LiveFastReconnectPolicy.FRESH_MS + 1
        assertFalse(fast.readyFor(tooLate, endedDrop = true, forced = false))
        assertNull(fast.takeForReload(tooLate, endedDrop = true, forced = false))
    }

    @Test
    fun `a stale locator is dropped whatever the clock's origin`() {
        // The same guarantee one hour in, where no value involved is zero. It
        // is a separate case because the one above starts its clock at 0, and a
        // `requestedAtMs == 0L` sentinel read as "no request recorded" made
        // exactly that case — and only that case — report a 30-second-stale
        // locator as fresh.
        val fast = LiveFastReconnect()
        val requestedAt = 3_600_000L
        fast.store(fast.noteRequested(requestedAt), locator)
        val lastUsableMs = requestedAt + LiveFastReconnectPolicy.FRESH_MS
        assertTrue(fast.readyFor(lastUsableMs, endedDrop = true, forced = false))
        assertFalse(fast.readyFor(lastUsableMs + 1, endedDrop = true, forced = false))
        assertNull(fast.takeForReload(lastUsableMs + 1, endedDrop = true, forced = false))
        assertFalse(fast.holdsLocator)
    }

    @Test
    fun `the age clock is the request, not the reply`() {
        // A slow round trip: requested at 1 s, settled 9 s later. Those 9 s are
        // age the portal's token has already spent, so the locator may be used
        // for 30 s from the *request* — not from the reply. Re-stamping at the
        // store hid the round trip and bought the fast path time it never had.
        val fast = LiveFastReconnect()
        fast.store(fast.noteRequested(1_000L), locator)
        assertEquals(9_000L, fast.ageMs(10_000L))
        val lastUsableMs = 1_000L + LiveFastReconnectPolicy.FRESH_MS
        assertTrue(fast.readyFor(lastUsableMs, endedDrop = true, forced = false))
        assertFalse(fast.readyFor(lastUsableMs + 1, endedDrop = true, forced = false))
    }

    @Test
    fun `a reply with no new locator stores nothing`() {
        val fast = LiveFastReconnect()
        assertFalse(fast.store(fast.noteRequested(0L), null))
        assertFalse(fast.holdsLocator)
        assertNull(fast.takeForReload(1_000L, endedDrop = true, forced = false))
    }

    @Test
    fun `a discard cancels a pre-resolve still in flight`() {
        val fast = LiveFastReconnect()
        val token = fast.noteRequested(0L)
        // A zap, an engine fallback or a finish between the request and its
        // reply: the locator describes a stream this session has left.
        fast.discard()
        assertFalse(fast.store(token, locator))
        assertFalse(fast.holdsLocator)
    }

    @Test
    fun `a newer request supersedes an older reply`() {
        val fast = LiveFastReconnect()
        val stale = fast.noteRequested(0L)
        val current = fast.noteRequested(100L)
        assertFalse(fast.store(stale, locator))
        assertTrue(fast.store(current, other))
        assertEquals(other, fast.takeForReload(1_000L, endedDrop = true, forced = false))
    }

    @Test
    fun `three short-lived fast reconnects in a row stand the path down`() {
        val fast = LiveFastReconnect()
        var now = 0L
        val outcomes = mutableListOf<FastReconnectOutcome>()
        repeat(3) {
            fast.store(fast.noteRequested(now), locator)
            assertNotNull(fast.takeForReload(now, endedDrop = true, forced = false))
            // The pre-resolved connection dies 1.2 s later.
            now += 1_200L
            outcomes += fast.noteReconnect(now)
        }
        assertEquals(
            listOf(
                FastReconnectOutcome.FAILED,
                FastReconnectOutcome.FAILED,
                FastReconnectOutcome.BACKED_OFF,
            ),
            outcomes,
        )
        assertFalse(fast.enabled)
        assertEquals(3, fast.failures())
        assertEquals(1_200L, fast.lastJudgedPlayedMs)
        // Off for the rest of the session: no further pre-resolve, and nothing
        // to spend even if one were somehow stored.
        assertFalse(
            LiveFastReconnectPolicy.shouldPreResolve(
                isLive = true,
                enabled = fast.enabled,
                holdsLocator = false,
                resolveInFlight = false,
                zapSettling = false,
            ),
        )
        assertFalse(fast.store(fast.noteRequested(now), locator))
        assertNull(fast.takeForReload(now, endedDrop = true, forced = false))
    }

    @Test
    fun `a connection that survives the window clears the streak`() {
        val fast = LiveFastReconnect()
        var now = 0L
        repeat(9) {
            fast.store(fast.noteRequested(now), locator)
            assertNotNull(fast.takeForReload(now, endedDrop = true, forced = false))
            // Two bad connections, then a healthy ~26 s one — forever.
            now += if (it % 3 == 2) 26_000L else 1_000L
            fast.noteReconnect(now)
        }
        assertTrue(fast.enabled)
        assertEquals(0, fast.failures())
    }

    @Test
    fun `a reconnect that took the ordinary path judges nothing`() {
        val fast = LiveFastReconnect()
        assertEquals(FastReconnectOutcome.NONE, fast.noteReconnect(1_000L))
        // And a take that refused is not a fast load either, so the reconnect
        // after it must not be blamed on the fast path.
        fast.store(fast.noteRequested(0L), locator)
        assertNull(fast.takeForReload(1_000L, endedDrop = false, forced = false))
        assertEquals(FastReconnectOutcome.NONE, fast.noteReconnect(1_100L))
        assertTrue(fast.enabled)
    }

    @Test
    fun `judging happens once per fast load`() {
        val fast = LiveFastReconnect()
        fast.store(fast.noteRequested(0L), locator)
        fast.takeForReload(0L, endedDrop = true, forced = false)
        assertEquals(FastReconnectOutcome.FAILED, fast.noteReconnect(1_000L))
        // A second reconnect with no intervening fast load adds nothing to the
        // streak, or a session that reconnects often would back off on noise.
        assertEquals(FastReconnectOutcome.NONE, fast.noteReconnect(2_000L))
        assertEquals(1, fast.failures())
    }
}
