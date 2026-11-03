package com.gchofficial.iptvs.player

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The formatter half is a **cross-surface contract**: Dart, Swift, C++ and Lua
 * assert the same six vectors against their own mirrors, because nothing at
 * runtime would ever reveal a disagreement — the surfaces are chosen by dynamic
 * range and platform, so no user ever sees two of them side by side.
 */
class LiveLatencyFormatTest {
    @Test
    fun `parity vector - no drift, a twelve second cushion`() {
        assertEquals("LIVE", LiveLatency.badgeLabel(0))
        assertEquals("0:00 · buffer 12s", LiveLatency.infoValue(0, 12_400))
    }

    @Test
    fun `parity vector - eight seconds behind with an unknown cushion`() {
        assertEquals("LIVE", LiveLatency.badgeLabel(7_999))
        assertEquals("0:07", LiveLatency.infoValue(7_999, -1))
    }

    @Test
    fun `parity vector - one millisecond under the warning threshold`() {
        assertEquals("LIVE", LiveLatency.badgeLabel(29_999))
        assertEquals("0:29 · buffer 1s", LiveLatency.infoValue(29_999, 500))
    }

    @Test
    fun `parity vector - exactly at the warning threshold`() {
        assertEquals("LIVE -0:30", LiveLatency.badgeLabel(30_000))
        assertEquals("0:30 · buffer 25s", LiveLatency.infoValue(30_000, 24_600))
    }

    @Test
    fun `parity vector - a minute and a half behind`() {
        assertEquals("LIVE -1:23", LiveLatency.badgeLabel(83_000))
        assertEquals("1:23 · buffer 24s", LiveLatency.infoValue(83_000, 24_000))
    }

    @Test
    fun `parity vector - past an hour, with an empty cushion`() {
        assertEquals("LIVE -1:02:03", LiveLatency.badgeLabel(3_723_000))
        assertEquals("1:02:03 · buffer 0s", LiveLatency.infoValue(3_723_000, 0))
    }

    @Test
    fun `the badge sign is an ASCII hyphen-minus, not a typographic one`() {
        // Drawn verbatim by the Windows GDI overlay and the Linux ASS renderer,
        // whose fonts are not guaranteed to carry U+2212.
        assertTrue(LiveLatency.badgeLabel(60_000).contains('-'))
        assertFalse(LiveLatency.badgeLabel(60_000).contains('−'))
    }

    @Test
    fun `the info row uses a spaced middle dot`() {
        assertTrue(LiveLatency.infoValue(0, 1_000).contains(" · "))
    }

    @Test
    fun `delays floor to the second`() {
        assertEquals("0:00", LiveLatency.fmtDelay(0))
        assertEquals("0:00", LiveLatency.fmtDelay(999))
        assertEquals("0:01", LiveLatency.fmtDelay(1_000))
        assertEquals("0:59", LiveLatency.fmtDelay(59_999))
        assertEquals("1:00", LiveLatency.fmtDelay(60_000))
        assertEquals("59:59", LiveLatency.fmtDelay(3_599_999))
        assertEquals("1:00:00", LiveLatency.fmtDelay(3_600_000))
        assertEquals("12:05", LiveLatency.fmtDelay(725_000))
    }

    @Test
    fun `a negative delay cannot be printed`() {
        // Drift never goes negative, but a renderer handed one must not print
        // `-1:-1`.
        assertEquals("0:00", LiveLatency.fmtDelay(-5_000))
    }

    @Test
    fun `the cushion rounds half away from zero`() {
        assertEquals("0:00 · buffer 1s", LiveLatency.infoValue(0, 500))
        assertEquals("0:00 · buffer 0s", LiveLatency.infoValue(0, 499))
        assertEquals("0:00 · buffer 25s", LiveLatency.infoValue(0, 24_600))
        assertEquals("0:00 · buffer 12s", LiveLatency.infoValue(0, 12_400))
    }

    @Test
    fun `log lines carry the whole attribution set`() {
        assertEquals(
            "live latency drift=7000ms ahead=2500ms stalls=2 stalled=1800ms disc=1",
            LiveLatency.statsLine(7_000, 2_500, 2, 1_800, 1),
        )
        assertEquals(
            "live latency reset reason=golive drift=42000ms stalls=3",
            LiveLatency.resetLine(LiveLatencyReset.GO_LIVE, 42_000, 3),
        )
    }

    @Test
    fun `the reset vocabulary is the one the contract names`() {
        assertEquals("load", LiveLatencyReset.LOAD)
        assertEquals("reconnect", LiveLatencyReset.RECONNECT)
        assertEquals("zap", LiveLatencyReset.ZAP)
        assertEquals("golive", LiveLatencyReset.GO_LIVE)
        assertEquals("engine", LiveLatencyReset.ENGINE)
        assertEquals("claim", LiveLatencyReset.CLAIM)
    }
}

class LiveLatencyTrackerTest {
    /** The two ticks every test needs before it can measure anything. */
    private fun LiveLatencyTracker.baseline(): LiveLatencyTracker {
        sample(nowMs = 0, positionMs = 0, isPlaying = true, isBuffering = false, aheadMs = -1)
        sample(nowMs = 500, positionMs = 500, isPlaying = true, isBuffering = false, aheadMs = -1)
        return this
    }

    private fun LiveLatencyTracker.tick(
        nowMs: Long,
        positionMs: Long,
        isPlaying: Boolean = true,
        isBuffering: Boolean = false,
        aheadMs: Long = -1,
    ): String? = sample(nowMs, positionMs, isPlaying, isBuffering, aheadMs)

    // ── Baseline ────────────────────────────────────────────────────────────

    @Test
    fun `the first sample is a reference point, not a measurement`() {
        val t = LiveLatencyTracker()
        assertNull(t.tick(0, 0))
        assertFalse(t.baselined)
        assertEquals(0L, t.driftMs)
    }

    @Test
    fun `a stream that never starts accrues no drift`() {
        // The wait for a first frame is the open, not the lag — and a stream
        // that never plays is a failure the reconnect watchdog owns, not a
        // delay figure to show the user.
        val t = LiveLatencyTracker()
        t.tick(0, 0, isPlaying = false)
        t.tick(1_000, 0, isPlaying = false)
        t.tick(60_000, 0, isPlaying = false)
        assertFalse(t.baselined)
        assertEquals(0L, t.driftMs)
        assertFalse(t.behind)
    }

    @Test
    fun `playing with a frozen playhead does not baseline`() {
        val t = LiveLatencyTracker()
        t.tick(0, 0)
        t.tick(1_000, 0)
        t.tick(2_000, 0)
        assertFalse(t.baselined)
        assertEquals(0L, t.driftMs)
    }

    @Test
    fun `the baselining tick itself banks nothing`() {
        val t = LiveLatencyTracker()
        t.tick(0, 0)
        t.tick(1_000, 0) // playing, but not yet advancing
        t.tick(3_000, 500) // first progress: baselines here
        assertTrue(t.baselined)
        // 2 s of wall clock against 500 ms of media would be 1.5 s of drift if
        // this tick counted — but it is the origin, so there is nothing to
        // measure it against.
        assertEquals(0L, t.driftMs)
    }

    // ── Steady state ────────────────────────────────────────────────────────

    @Test
    fun `media keeping up with the clock accrues nothing`() {
        val t = LiveLatencyTracker().baseline()
        var now = 500L
        var pos = 500L
        repeat(120) {
            now += 500
            pos += 500
            t.tick(now, pos)
        }
        assertEquals(0L, t.driftMs)
        assertFalse(t.behind)
    }

    @Test
    fun `media running slightly ahead never subtracts banked drift`() {
        val t = LiveLatencyTracker().baseline()
        t.tick(5_500, 500) // a 5 s freeze
        assertEquals(5_000L, t.driftMs)
        t.tick(6_000, 1_400) // 500 ms of clock, 900 ms of media
        assertEquals(5_000L, t.driftMs)
    }

    // ── Stalls and pauses are drift ─────────────────────────────────────────

    @Test
    fun `a rebuffer adds its own duration to the delay, permanently`() {
        val t = LiveLatencyTracker().baseline()
        // 4 s of buffering with the playhead frozen.
        t.tick(1_000, 500, isBuffering = true)
        t.tick(2_000, 500, isBuffering = true)
        t.tick(4_500, 500, isBuffering = true)
        assertEquals(4_000L, t.driftMs)
        // …and playing normally afterwards never gives it back.
        var now = 4_500L
        var pos = 500L
        repeat(60) {
            now += 500
            pos += 500
            t.tick(now, pos)
        }
        assertEquals(4_000L, t.driftMs)
    }

    @Test
    fun `a long pause is real lag - there is no cap on the wall gap`() {
        val t = LiveLatencyTracker().baseline()
        // Two minutes paused (or backgrounded: the ticker stops, so one sample
        // spans the whole gap). The contract is explicit that this is not a
        // sampling artefact to be clamped away.
        t.tick(120_500, 500, isPlaying = false)
        assertEquals(120_000L, t.driftMs)
        assertTrue(t.behind)
    }

    @Test
    fun `buffering transitions and time are counted for attribution`() {
        val t = LiveLatencyTracker().baseline()
        t.tick(1_000, 1_000, isBuffering = true)
        t.tick(1_500, 1_000, isBuffering = true)
        t.tick(2_000, 1_000, isBuffering = false)
        assertEquals(1, t.stalls)
        assertEquals(1_000L, t.stalledMs)
        // A second rebuffer is a second transition, not a continuation.
        t.tick(2_500, 1_500, isBuffering = true)
        t.tick(3_000, 1_500, isBuffering = false)
        assertEquals(2, t.stalls)
        assertEquals(1_500L, t.stalledMs)
    }

    @Test
    fun `a stream that opens buffering has already stalled once`() {
        val t = LiveLatencyTracker()
        t.tick(0, 0, isPlaying = false, isBuffering = true)
        assertEquals(1, t.stalls)
    }

    // ── Discontinuities ─────────────────────────────────────────────────────

    @Test
    fun `a backwards jump re-baselines instead of banking a tick`() {
        val t = LiveLatencyTracker()
        t.tick(0, 10_000)
        t.tick(500, 10_500) // baselined
        t.tick(1_000, 200) // a reload: the playhead describes a new timeline
        assertEquals(1, t.discontinuities)
        assertEquals(0L, t.driftMs)
        // The next tick measures against the *new* position, not the old one.
        t.tick(1_500, 700)
        assertEquals(0L, t.driftMs)
        assertEquals(1, t.discontinuities)
    }

    @Test
    fun `a small backwards wobble is still measured, not discarded`() {
        val t = LiveLatencyTracker().baseline()
        // Exactly at the boundary: `< -500` is a discontinuity, `-500` is not.
        t.tick(1_000, 0)
        assertEquals(0, t.discontinuities)
        assertEquals(1_000L, t.driftMs)
    }

    @Test
    fun `a forward seek re-baselines rather than erasing banked drift`() {
        val t = LiveLatencyTracker().baseline()
        t.tick(10_500, 500) // 10 s of freeze
        assertEquals(10_000L, t.driftMs)
        t.tick(11_000, 60_000) // the live window jumped forward under us
        assertEquals(1, t.discontinuities)
        // Banked drift survives: a discontinuity means "this tick measured
        // nothing", never "the delay was imaginary".
        assertEquals(10_000L, t.driftMs)
    }

    @Test
    fun `media exactly two seconds ahead of the clock is slack, not a seek`() {
        val t = LiveLatencyTracker().baseline()
        // dWall 500, dMedia 2500 == dWall + 2000 — the boundary is exclusive.
        t.tick(1_000, 3_000)
        assertEquals(0, t.discontinuities)
        assertEquals(0L, t.driftMs)
    }

    // ── The liveSynced gate ─────────────────────────────────────────────────

    @Test
    fun `behind flips exactly at the warning threshold and never back`() {
        val t = LiveLatencyTracker().baseline()
        t.tick(30_499, 500, isPlaying = false) // 29 999 ms of drift
        assertEquals(29_999L, t.driftMs)
        assertFalse(t.behind)
        t.tick(30_500, 500, isPlaying = false)
        assertEquals(30_000L, t.driftMs)
        assertTrue(t.behind)
        // Drift is monotonic between resets, so the gate it feeds cannot
        // oscillate — which is what stops the "Go to live" chip flickering
        // under a focused D-pad.
        var now = 30_500L
        var pos = 500L
        repeat(200) {
            now += 500
            pos += 500
            t.tick(now, pos)
        }
        assertTrue(t.behind)
    }

    // ── Reset ───────────────────────────────────────────────────────────────

    @Test
    fun `a reset that discards a real measurement reports it`() {
        val t = LiveLatencyTracker().baseline()
        t.tick(1_000, 1_000, isBuffering = true)
        t.tick(42_500, 1_000, isBuffering = true)
        assertEquals(41_500L, t.driftMs)
        assertEquals(
            "live latency reset reason=reconnect drift=41500ms stalls=1",
            t.reset(LiveLatencyReset.RECONNECT),
        )
        assertEquals(0L, t.driftMs)
        assertEquals(0, t.stalls)
        assertEquals(0L, t.stalledMs)
        assertEquals(0, t.discontinuities)
        assertFalse(t.baselined)
        assertFalse(t.behind)
    }

    @Test
    fun `a reset with nothing to lose says nothing`() {
        val t = LiveLatencyTracker().baseline()
        assertNull(t.reset(LiveLatencyReset.LOAD))
    }

    @Test
    fun `a reset drops the reference point, so the gap across it is not drift`() {
        val t = LiveLatencyTracker().baseline()
        t.tick(5_500, 500)
        t.reset(LiveLatencyReset.ZAP)
        // An hour later (a resolve round trip, in practice): the first sample
        // after a reset is a reference point again, not a 55-minute stall.
        t.tick(3_600_000, 0)
        t.tick(3_600_500, 500)
        assertEquals(0L, t.driftMs)
        assertTrue(t.baselined)
    }

    @Test
    fun `the behind line can fire again after a reset`() {
        val t = LiveLatencyTracker().baseline()
        assertTrue(t.tick(40_500, 500, isPlaying = false)!!.startsWith("live latency behind "))
        t.reset(LiveLatencyReset.GO_LIVE)
        t.tick(50_000, 0)
        t.tick(50_500, 500)
        assertTrue(t.tick(90_500, 500, isPlaying = false)!!.startsWith("live latency behind "))
    }

    // ── Diagnostics ─────────────────────────────────────────────────────────

    @Test
    fun `the first crossing is reported whatever the stream is doing`() {
        val t = LiveLatencyTracker().baseline()
        // Paused, so the periodic line would be suppressed — but this is the
        // moment the session stopped being live, and an export needs it.
        assertEquals(
            "live latency behind live latency drift=30000ms ahead=2000ms " +
                "stalls=0 stalled=0ms disc=0",
            t.tick(30_500, 500, isPlaying = false, aheadMs = 2_000),
        )
    }

    @Test
    fun `the crossing is reported once per session`() {
        val t = LiveLatencyTracker().baseline()
        assertTrue(t.tick(40_500, 500, isPlaying = false)!!.startsWith("live latency behind "))
        assertNull(t.tick(41_000, 500, isPlaying = false))
        assertNull(t.tick(60_000, 500, isPlaying = false))
    }

    @Test
    fun `a healthy session writes nothing to the log`() {
        val t = LiveLatencyTracker().baseline()
        var now = 500L
        var pos = 500L
        // Ten minutes at 500 ms ticks, no drift and a shallow cushion.
        repeat(1_200) {
            now += 500
            pos += 500
            assertNull(t.tick(now, pos, aheadMs = 4_000))
        }
    }

    @Test
    fun `a drifting session writes one line a minute`() {
        val t = LiveLatencyTracker().baseline()
        // 6 s of drift: past the reporting floor, well under the warning.
        t.tick(1_000, 1_000)
        t.tick(7_000, 1_000)
        assertEquals(6_000L, t.driftMs)
        // Not yet a minute since the tracker's first sample.
        assertNull(t.tick(59_999, 53_999, aheadMs = 1_000))
        assertEquals(
            "live latency drift=6000ms ahead=12000ms stalls=0 stalled=0ms disc=0",
            t.tick(60_000, 54_000, aheadMs = 12_000),
        )
        // …and not again until the next minute is up.
        assertNull(t.tick(119_000, 113_000, aheadMs = 12_000))
        assertEquals(
            "live latency drift=6000ms ahead=12000ms stalls=0 stalled=0ms disc=0",
            t.tick(120_000, 114_000, aheadMs = 12_000),
        )
    }

    @Test
    fun `a deep cushion alone is worth reporting`() {
        // No drift at all, but 35 s of buffered media: the other half of "why
        // is this channel behind" — a preset that buffers deeply is a delay the
        // viewer chose, and an export should be able to tell the two apart.
        val t = LiveLatencyTracker().baseline()
        assertEquals(
            "live latency drift=0ms ahead=35000ms stalls=0 stalled=0ms disc=0",
            t.tick(60_000, 60_000, aheadMs = 35_000),
        )
    }

    @Test
    fun `the periodic line is suppressed while not playing`() {
        val t = LiveLatencyTracker().baseline()
        t.tick(1_000, 1_000)
        t.tick(7_000, 1_000) // 6 s of drift
        assertNull(t.tick(60_000, 54_000, isPlaying = false, aheadMs = 40_000))
        assertNull(t.tick(61_000, 55_000, isBuffering = true, aheadMs = 40_000))
    }
}
