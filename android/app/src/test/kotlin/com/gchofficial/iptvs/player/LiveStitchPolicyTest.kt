package com.gchofficial.iptvs.player

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the stitched handover's decisions, its constant relationships, and the
 * exported vocabulary.
 *
 * The vocabulary half matters as much as the decisions: an export is grepped by
 * column, and the whole feature is invisible to the user — a line whose field
 * set drifts is the only way a silently-not-working handover would be reported.
 */
class LiveStitchPolicyTest {
    // ── Failure classification ───────────────────────────────────────────────

    @Test
    fun `every splicer reject reason is structural`() {
        // Forward-pinning: a new SpliceRejectReason must land on one side of
        // the session rule, and this is the side it lands on by construction —
        // the splicer only ever rejects on bytes it read, which is a statement
        // about the stream's shape rather than about the network.
        for (reason in SpliceRejectReason.entries) {
            assertTrue(reason.token, LiveStitchPolicy.isStructuralFailure(reason.token))
            assertFalse(reason.token, LiveStitchPolicy.isTransientFailure(reason.token))
            assertTrue(reason.token, LiveStitchPolicy.countsAgainstSession(reason.token))
        }
    }

    @Test
    fun `a candidate that would not open or deliver is transient`() {
        for (reason in listOf(
            LiveStitchPolicy.REASON_OPEN_FAILED,
            LiveStitchPolicy.REASON_CANDIDATE_EOF,
        )) {
            assertTrue(reason, LiveStitchPolicy.isTransientFailure(reason))
            assertFalse(reason, LiveStitchPolicy.isStructuralFailure(reason))
            assertTrue(reason, LiveStitchPolicy.countsAgainstSession(reason))
        }
    }

    @Test
    fun `a deadline or a locator that never arrived counts against nothing`() {
        // None of these is evidence about splicing: the deadline and the three
        // locator-supply reasons are the pre-resolve path's business, and it
        // has its own back-off. Counting them here would stand the handover
        // down on exactly the sessions where the portal is slow.
        for (reason in listOf(
            LiveStitchPolicy.REASON_DEADLINE,
            LiveStitchPolicy.REASON_SAME_URL,
            LiveStitchPolicy.REASON_RESOLVE_FAILED,
            LiveStitchPolicy.REASON_DISABLED,
            LiveStitchPolicy.REASON_CANCELLED,
            LiveStitchPolicy.REASON_NONE,
        )) {
            assertFalse(reason, LiveStitchPolicy.countsAgainstSession(reason))
        }
    }

    // ── Constants ────────────────────────────────────────────────────────────

    @Test
    fun `the deadline clears the longest blocking call a candidate can make`() {
        // The "never two connections" margin, and the real bound rather than
        // half of it. An abort cannot interrupt a blocking call, so the longest
        // a candidate can still be open after the deadline is raised is one
        // whole `open()`: a connect followed by the wait for the response head,
        // i.e. **both** timeouts back to back — not either one alone. That has
        // to finish before the drained player's reload opens the next
        // connection, which is STITCH_ABORT_AHEAD_MS of cushion away, and it is
        // also what keeps end of input reaching the extractor while there is
        // still cushion (so the stream ends rather than buffers).
        assertEquals(
            LiveStitchPolicy.CANDIDATE_CONNECT_TIMEOUT_MS.toLong() +
                LiveStitchPolicy.CANDIDATE_RESPONSE_TIMEOUT_MS.toLong(),
            LiveStitchPolicy.MAX_BLOCKING_CALL_MS,
        )
        assertTrue(
            LiveStitchPolicy.MAX_BLOCKING_CALL_MS < LiveStitchPolicy.STITCH_ABORT_AHEAD_MS,
        )
    }

    @Test
    fun `the pre-resolve trigger leaves room for the whole pre-commit phase`() {
        // The offer lands at roughly PRE_RESOLVE_AHEAD_MS minus the round
        // trip; everything from there to STITCH_ABORT_AHEAD_MS is the budget
        // the candidate has to prove itself in, and the loader's own wall clock
        // has to fit inside it or the host's deadline would always win and the
        // open would never be bounded at all.
        assertTrue(
            LiveFastReconnectPolicy.PRE_RESOLVE_AHEAD_MS - LiveStitchPolicy.STITCH_ABORT_AHEAD_MS >=
                LiveStitchPolicy.PRE_COMMIT_BUDGET_MS,
        )
        // The whole pre-commit phase, open included: the loader's budget plus
        // the one blocking call that can overrun it.
        assertTrue(
            LiveStitchPolicy.PRE_COMMIT_BUDGET_MS + LiveStitchPolicy.MAX_BLOCKING_CALL_MS <
                LiveFastReconnectPolicy.PRE_RESOLVE_AHEAD_MS,
        )
        // And the locator must still be fresh when the reconnect falls back to
        // it, which it trivially is now the trigger is the cushion rather than
        // the EOF.
        assertTrue(LiveFastReconnectPolicy.FRESH_MS > LiveFastReconnectPolicy.PRE_RESOLVE_AHEAD_MS)
    }

    @Test
    fun `the loader's own budget bounds the open as well as the reads`() {
        assertFalse(LiveStitchPolicy.preCommitBudgetSpent(0L))
        assertFalse(
            LiveStitchPolicy.preCommitBudgetSpent(LiveStitchPolicy.PRE_COMMIT_BUDGET_MS - 1),
        )
        assertTrue(LiveStitchPolicy.preCommitBudgetSpent(LiveStitchPolicy.PRE_COMMIT_BUDGET_MS))
    }

    @Test
    fun `a committed link rides out what an unstitched link rides out`() {
        // The promoted candidate still holds the socket it was opened with, and
        // a socket's read timeout cannot be changed afterwards — so media3's
        // own 8 s default is rebuilt out of the short candidate one by
        // retrying. If these two were equal, an ordinary two-second network
        // hiccup would become a load error where the shipped path absorbs it in
        // silence.
        assertEquals(8_000L, LiveStitchPolicy.POST_COMMIT_READ_TIMEOUT_MS)
        assertTrue(
            LiveStitchPolicy.POST_COMMIT_READ_TIMEOUT_MS >
                LiveStitchPolicy.CANDIDATE_RESPONSE_TIMEOUT_MS.toLong(),
        )
        assertTrue(LiveStitchPolicy.shouldRetryStalledRead(0L))
        assertTrue(
            LiveStitchPolicy.shouldRetryStalledRead(
                LiveStitchPolicy.POST_COMMIT_READ_TIMEOUT_MS - 1,
            ),
        )
        assertFalse(
            LiveStitchPolicy.shouldRetryStalledRead(LiveStitchPolicy.POST_COMMIT_READ_TIMEOUT_MS),
        )
    }

    @Test
    fun `the fail-safe re-ask runs only when a locator was actually spent`() {
        // Spending one is the whole reason to ask again: the reconnect a few
        // seconds away would otherwise take a cold `path=resolve`.
        for (reason in SpliceRejectReason.entries.map { it.token } + listOf(
            LiveStitchPolicy.REASON_OPEN_FAILED,
            LiveStitchPolicy.REASON_CANDIDATE_EOF,
            LiveStitchPolicy.REASON_DEADLINE,
        )) {
            assertTrue(
                reason,
                LiveStitchPolicy.shouldRequestFailsafePreResolve(reason, consumedLocator = true),
            )
            assertFalse(
                reason,
                LiveStitchPolicy.shouldRequestFailsafePreResolve(reason, consumedLocator = false),
            )
        }
        // The locator-supply failures: asking the portal that just failed again,
        // milliseconds later, only holds ResolveGate in flight across the drain
        // — which is exactly what stops the ended reconnect from firing. And a
        // cancellation is the session having already replaced the stream, so
        // the link now playing has an **open** body: re-arming the EOF gate
        // there would fire a `create_link` against it, the one thing the gate
        // exists to prevent.
        for (reason in listOf(
            LiveStitchPolicy.REASON_SAME_URL,
            LiveStitchPolicy.REASON_RESOLVE_FAILED,
            LiveStitchPolicy.REASON_DISABLED,
            LiveStitchPolicy.REASON_CANCELLED,
        )) {
            assertFalse(
                reason,
                LiveStitchPolicy.shouldRequestFailsafePreResolve(reason, consumedLocator = true),
            )
            assertFalse(
                reason,
                LiveStitchPolicy.shouldRequestFailsafePreResolve(reason, consumedLocator = false),
            )
        }
    }

    @Test
    fun `structural patience is shorter than transient patience`() {
        assertTrue(
            LiveStitchPolicy.MAX_CONSECUTIVE_STRUCTURAL_FAILURES <
                LiveStitchPolicy.MAX_CONSECUTIVE_TRANSIENT_FAILURES,
        )
    }

    @Test
    fun `the kill switch ships on`() {
        assertTrue(LiveStitchPolicy.ENABLED)
    }

    @Test
    fun `the deadline is a cushion bound, and an unknown cushion trips it`() {
        assertFalse(LiveStitchPolicy.shouldAbortHandover(9_000L))
        assertFalse(LiveStitchPolicy.shouldAbortHandover(LiveStitchPolicy.STITCH_ABORT_AHEAD_MS + 1))
        assertTrue(LiveStitchPolicy.shouldAbortHandover(LiveStitchPolicy.STITCH_ABORT_AHEAD_MS))
        assertTrue(LiveStitchPolicy.shouldAbortHandover(0L))
        // -1 is "the engine can't say". A handover that cannot prove it still
        // has cushion must not be allowed to hold the stream.
        assertTrue(LiveStitchPolicy.shouldAbortHandover(-1L))
    }

    // ── The exported vocabulary ──────────────────────────────────────────────

    @Test
    fun `the handover line keeps a fixed field set`() {
        assertEquals(
            "live handover link=2 mechanism=splice reason=none durationMs=412 " +
                "aheadAtCommitMs=9210 trimmedMs=180 skippedMs=40 repeatedMs=0 " +
                "droppedBytes=37600 audioHeldMs=24",
            LiveStitchPolicy.handoverLine(
                link = 2,
                mechanism = LiveStitchPolicy.MECHANISM_SPLICE,
                reason = LiveStitchPolicy.REASON_NONE,
                durationMs = 412,
                aheadAtCommitMs = 9210,
                trimmedMs = 180,
                skippedMs = 40,
                repeatedMs = 0,
                droppedBytes = 37600,
                // The audio the candidate had to hold back so that no renderer
                // is ever handed a sample twice — `repeatedMs=0` is a claim
                // about every PID, and this is what it costs.
                audioHeldMs = 24,
            ),
        )
    }

    @Test
    fun `a fallback prints the same fields with nothing invented`() {
        assertEquals(
            "live handover link=3 mechanism=fallback reason=gap durationMs=1904 " +
                "aheadAtCommitMs=-1 trimmedMs=0 skippedMs=0 repeatedMs=0 " +
                "droppedBytes=0 audioHeldMs=0",
            LiveStitchPolicy.fallbackLine(
                link = 3,
                reason = SpliceRejectReason.GAP_TOO_LARGE.token,
                durationMs = 1904,
            ),
        )
    }

    @Test
    fun `an export can prove why a session never stitched`() {
        assertEquals(
            "live stitch armed link=1 spliceable=pending",
            LiveStitchPolicy.armedLine(1, "pending"),
        )
        assertEquals(
            "live stitch armed link=2 spliceable=true",
            LiveStitchPolicy.armedLine(2, "true"),
        )
        assertEquals(
            "live stitch link=1 spliceable=false reason=unsupported",
            LiveStitchPolicy.spliceableLine(1, false, SpliceRejectReason.UNSUPPORTED.token),
        )
        assertEquals(
            "live stitch link=1 spliceable=true reason=none",
            LiveStitchPolicy.spliceableLine(1, true, LiveStitchPolicy.REASON_NONE),
        )
        assertEquals(
            "live stitch disabled failures=2 reason=pmt",
            LiveStitchPolicy.disabledLine(2, SpliceRejectReason.PMT_CHANGED.token),
        )
    }

    @Test
    fun `the reconnect line says whether a handover tried and lost`() {
        assertEquals("mechanism=reconnect", LiveStitchPolicy.reconnectMechanism(null))
        assertEquals(
            "mechanism=reconnect after=fallback:deadline",
            LiveStitchPolicy.reconnectMechanism(LiveStitchPolicy.REASON_DEADLINE),
        )
    }
}
