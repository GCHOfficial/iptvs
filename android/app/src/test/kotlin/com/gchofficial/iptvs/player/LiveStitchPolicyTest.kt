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
    fun `the deadline clears a wedged candidate's own timeouts`() {
        // The "never two connections" margin. An abort cannot interrupt a
        // blocking socket read, so the longest a candidate can still be open
        // after the deadline is raised is one of its own timeouts — and both
        // have to finish before the drained player's reload opens the next
        // connection, which is STITCH_ABORT_AHEAD_MS of cushion away.
        assertTrue(
            LiveStitchPolicy.STITCH_ABORT_AHEAD_MS >
                LiveStitchPolicy.CANDIDATE_READ_TIMEOUT_MS.toLong(),
        )
        assertTrue(
            LiveStitchPolicy.STITCH_ABORT_AHEAD_MS >
                LiveStitchPolicy.CANDIDATE_CONNECT_TIMEOUT_MS.toLong(),
        )
    }

    @Test
    fun `the pre-resolve trigger leaves room for the whole evaluation`() {
        // The offer lands at roughly PRE_RESOLVE_AHEAD_MS minus the round
        // trip; everything from there to STITCH_ABORT_AHEAD_MS is the budget
        // the candidate has to prove itself in. A trigger at or below the
        // deadline would mean the handover was aborted before it was armed.
        assertTrue(
            LiveFastReconnectPolicy.PRE_RESOLVE_AHEAD_MS >
                LiveStitchPolicy.STITCH_ABORT_AHEAD_MS,
        )
        // And the locator must still be fresh when the reconnect falls back to
        // it, which it trivially is now the trigger is the cushion rather than
        // the EOF.
        assertTrue(LiveFastReconnectPolicy.FRESH_MS > LiveFastReconnectPolicy.PRE_RESOLVE_AHEAD_MS)
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
                "aheadAtCommitMs=9210 trimmedMs=180 skippedMs=40 repeatedMs=0 droppedBytes=37600",
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
            ),
        )
    }

    @Test
    fun `a fallback prints the same fields with nothing invented`() {
        assertEquals(
            "live handover link=3 mechanism=fallback reason=gap durationMs=1904 " +
                "aheadAtCommitMs=-1 trimmedMs=0 skippedMs=0 repeatedMs=0 droppedBytes=0",
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
