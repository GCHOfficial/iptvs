package com.gchofficial.iptvs.player

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FrameLivenessWatchTest {
    private val stall = ReconnectPolicy.NO_FRAME_STALL_MS

    @Test
    fun `a renderer producing frames is never stalled`() {
        val watch = FrameLivenessWatch()
        var frames = 0
        for (t in 0..(stall * 3) step 500) {
            frames += 25
            assertFalse(watch.sample(t, playingNormally = true, renderedFrames = frames))
        }
    }

    @Test
    fun `playing normally with a frozen frame count stalls at the threshold`() {
        val watch = FrameLivenessWatch()
        // Rendering, then frozen — the shape the preview to fullscreen handoff
        // produces, and the only shape this is allowed to act on.
        assertFalse(watch.sample(0, playingNormally = true, renderedFrames = 900))
        assertFalse(watch.sample(500, playingNormally = true, renderedFrames = 925))
        assertFalse(watch.sample(500 + stall - 1, playingNormally = true, renderedFrames = 925))
        assertTrue(watch.sample(500 + stall, playingNormally = true, renderedFrames = 925))
    }

    @Test
    fun `a counter that never moves is never judged`() {
        // Indistinguishable from a decode path that simply doesn't report one.
        // Reconnecting a healthy stream every few seconds would be far worse
        // than the freeze this exists to catch — and a stream that genuinely
        // never renders never leaves STATE_BUFFERING, which the buffering
        // watchdog already owns.
        val watch = FrameLivenessWatch()
        for (t in 0..(stall * 4) step 500) {
            assertFalse(watch.sample(t, playingNormally = true, renderedFrames = 0))
        }
    }

    @Test
    fun `a state the engine does not call healthy is not this watch's business`() {
        // Buffering and ended already have their own thresholds; double-counting
        // them here would shorten those instead of adding a case.
        val watch = FrameLivenessWatch()
        watch.sample(0, playingNormally = true, renderedFrames = 900)
        watch.sample(100, playingNormally = true, renderedFrames = 905)
        assertFalse(watch.sample(stall, playingNormally = false, renderedFrames = 905))
        // ...and the window restarts from the moment it claims health again,
        // needing fresh proof the renderer works before it can be judged.
        assertFalse(watch.sample(stall, playingNormally = true, renderedFrames = 905))
        assertFalse(watch.sample(stall + 100, playingNormally = true, renderedFrames = 910))
        assertFalse(watch.sample(stall * 2 + 99, playingNormally = true, renderedFrames = 910))
        assertTrue(watch.sample(stall * 2 + 100, playingNormally = true, renderedFrames = 910))
    }

    @Test
    fun `an engine that cannot count frames stays inert`() {
        // -1 is what an audio-only channel (no video renderer) and mpv both
        // report. Failing inert is the whole contract: this must never invent a
        // stall on a stream it can't see.
        val watch = FrameLivenessWatch()
        for (t in 0..(stall * 4) step 500) {
            assertFalse(watch.sample(t, playingNormally = true, renderedFrames = -1))
        }
    }

    @Test
    fun `reset forgets the window so a reload starts clean`() {
        val watch = FrameLivenessWatch()
        watch.sample(0, playingNormally = true, renderedFrames = 900)
        watch.sample(100, playingNormally = true, renderedFrames = 925)
        watch.reset()
        // The reload restarts the counter from 0, which must read as a fresh
        // window rather than as more of the same freeze — including the proof
        // requirement, so a reload that renders nothing is left to the
        // buffering watchdog instead of being reconnected on this one's clock.
        assertFalse(watch.sample(stall, playingNormally = true, renderedFrames = 0))
        assertFalse(watch.sample(stall * 2, playingNormally = true, renderedFrames = 0))
        assertFalse(watch.sample(stall * 2 + 100, playingNormally = true, renderedFrames = 30))
        assertTrue(watch.sample(stall * 3 + 100, playingNormally = true, renderedFrames = 30))
    }

    @Test
    fun `it fires sooner than the buffering watchdog it supplements`() {
        // A frozen renderer is not an underrun that might still recover, so it
        // deliberately doesn't wait out STALL_RECONNECT_MS.
        assertTrue(ReconnectPolicy.NO_FRAME_STALL_MS < ReconnectPolicy.STALL_RECONNECT_MS)
    }
}

class ReconnectPolicyTest {
    @Test
    fun `first attempt waits one stall interval`() {
        assertEquals(
            ReconnectPolicy.STALL_RECONNECT_MS,
            ReconnectPolicy.minGapMs(priorAttempts = 0, force = false),
        )
    }

    @Test
    fun `backoff grows with each prior attempt`() {
        assertEquals(
            ReconnectPolicy.STALL_RECONNECT_MS * 2,
            ReconnectPolicy.minGapMs(priorAttempts = 1, force = false),
        )
        assertEquals(
            ReconnectPolicy.STALL_RECONNECT_MS * 3,
            ReconnectPolicy.minGapMs(priorAttempts = 2, force = false),
        )
    }

    @Test
    fun `backoff is capped at the maximum`() {
        assertEquals(
            ReconnectPolicy.MAX_BACKOFF_MS,
            ReconnectPolicy.minGapMs(priorAttempts = 3, force = false),
        )
        assertEquals(
            ReconnectPolicy.MAX_BACKOFF_MS,
            ReconnectPolicy.minGapMs(priorAttempts = 10, force = false),
        )
    }

    @Test
    fun `a forced reconnect always uses the base stall threshold`() {
        assertEquals(
            ReconnectPolicy.STALL_RECONNECT_MS,
            ReconnectPolicy.minGapMs(priorAttempts = 5, force = true),
        )
    }
}
