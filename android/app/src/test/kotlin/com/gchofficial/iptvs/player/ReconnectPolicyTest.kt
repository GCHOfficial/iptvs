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
    fun `an armed handoff judges a renderer that never draws its first frame`() {
        // The hole the arm closes: the surface claim froze the renderer before
        // it drew anything, so the counter never moves under this watch's own
        // observation and the unarmed rule leaves it inert forever. The
        // preview's frames are the proof it was waiting for.
        val watch = FrameLivenessWatch()
        assertTrue(watch.armHandoff(0, renderedFrames = 4_210))
        val handoff = ReconnectPolicy.HANDOFF_NO_FRAME_STALL_MS
        for (t in 500 until handoff step 500) {
            assertFalse(watch.sample(t, playingNormally = true, renderedFrames = 4_210))
        }
        assertTrue(watch.sample(handoff, playingNormally = true, renderedFrames = 4_210))
    }

    @Test
    fun `an armed handoff also judges a renderer that draws and then stops`() {
        // The other observed shape, and the one an exported log has now caught
        // exactly: the claim's first frame lands a quarter-second in and the
        // counter never moves again. Because that frame proves the new surface
        // works, the first-frame latency HANDOFF_NO_FRAME_STALL_MS is being
        // generous about has already been paid — so the freeze is decided on
        // the shorter post-frame clock.
        val watch = FrameLivenessWatch()
        watch.armHandoff(0, renderedFrames = 4_210)
        assertFalse(watch.drewSinceArm())
        // The renderer reports the claimed surface's first frame; the counter
        // moves with it.
        watch.markHandoffFirstFrame()
        assertFalse(watch.sample(250, playingNormally = true, renderedFrames = 4_211))
        assertTrue(watch.drewSinceArm())
        val stallAt = 250 + ReconnectPolicy.HANDOFF_POST_FRAME_STALL_MS
        assertFalse(watch.sample(stallAt - 1, playingNormally = true, renderedFrames = 4_211))
        assertTrue(watch.sample(stallAt, playingNormally = true, renderedFrames = 4_211))
    }

    @Test
    fun `frames drawn during a deferred claim do not shorten the clock`() {
        // The counter is surface-agnostic and the claim is deferred until
        // `surfaceCreated` (~117 ms measured), so the frames still landing on
        // the preview texture in that gap say nothing about the new surface.
        // Inferring the first frame from them dropped a *healthy* handoff onto
        // the 500 ms clock and rebuilt a decoder that was merely waiting for an
        // IDR.
        val watch = FrameLivenessWatch()
        watch.armHandoff(0, renderedFrames = 4_210)
        var frames = 4_210
        for (t in 125L..375L step 125) {
            frames += 7
            assertFalse(watch.sample(t, playingNormally = true, renderedFrames = frames))
        }
        assertFalse(watch.drewSinceArm())
        // Frozen from here: still judged on the long first-frame clock.
        val postFrame = 375 + ReconnectPolicy.HANDOFF_POST_FRAME_STALL_MS
        assertFalse(watch.sample(postFrame, playingNormally = true, renderedFrames = frames))
        val stallAt = 375 + ReconnectPolicy.HANDOFF_NO_FRAME_STALL_MS
        assertFalse(watch.sample(stallAt - 1, playingNormally = true, renderedFrames = frames))
        assertTrue(watch.sample(stallAt, playingNormally = true, renderedFrames = frames))
    }

    @Test
    fun `a first frame outside any handoff window is not remembered`() {
        // A cold open's first frame must not leave the flag set for a later
        // arm to inherit.
        val watch = FrameLivenessWatch()
        watch.markHandoffFirstFrame()
        assertFalse(watch.drewSinceArm())
    }

    @Test
    fun `a handoff that has not drawn yet keeps the longer first-frame clock`() {
        // The two clocks must not be confused: before the new surface has drawn
        // anything, the shorter one would be judging first-frame latency — a
        // healthy handoff measured 251 ms and a deferred surface claim can add
        // more — rather than a freeze.
        val watch = FrameLivenessWatch()
        watch.armHandoff(0, renderedFrames = 4_210)
        val postFrame = ReconnectPolicy.HANDOFF_POST_FRAME_STALL_MS
        assertFalse(watch.sample(postFrame, playingNormally = true, renderedFrames = 4_210))
        assertFalse(watch.drewSinceArm())
        val stallAt = ReconnectPolicy.HANDOFF_NO_FRAME_STALL_MS
        assertFalse(watch.sample(stallAt - 1, playingNormally = true, renderedFrames = 4_210))
        assertTrue(watch.sample(stallAt, playingNormally = true, renderedFrames = 4_210))
    }

    @Test
    fun `a buffering tick does not un-draw the frame the new surface got`() {
        // Progress is a fact about the surface, not an observation a moment of
        // buffering revokes — unlike the frame *window*, which the tick clears.
        val watch = FrameLivenessWatch()
        watch.armHandoff(0, renderedFrames = 4_210)
        watch.markHandoffFirstFrame()
        assertFalse(watch.sample(250, playingNormally = true, renderedFrames = 4_211))
        assertFalse(watch.sample(500, playingNormally = false, renderedFrames = 4_211))
        assertTrue(watch.drewSinceArm())
        assertFalse(watch.sample(750, playingNormally = true, renderedFrames = 4_211))
        val stallAt = 750 + ReconnectPolicy.HANDOFF_POST_FRAME_STALL_MS
        assertFalse(watch.sample(stallAt - 1, playingNormally = true, renderedFrames = 4_211))
        assertTrue(watch.sample(stallAt, playingNormally = true, renderedFrames = 4_211))
    }

    @Test
    fun `reset forgets that the new surface had drawn`() {
        // A rebuild re-arms against a decoder that has drawn nothing yet, so it
        // must get the first-frame clock back rather than inherit the short one.
        val watch = FrameLivenessWatch()
        watch.armHandoff(0, renderedFrames = 4_210)
        watch.markHandoffFirstFrame()
        assertTrue(watch.drewSinceArm())
        watch.reset()
        assertFalse(watch.drewSinceArm())
        watch.armHandoff(300, renderedFrames = 4_211)
        assertFalse(watch.drewSinceArm())
    }

    @Test
    fun `the post-frame clock is several polls wide`() {
        // A threshold the ticker can only sample once is a threshold decided by
        // one unlucky scheduling gap. Inside the handoff window the ticker runs
        // at HANDOFF_POLL_MS precisely so this holds.
        assertTrue(
            ReconnectPolicy.HANDOFF_POST_FRAME_STALL_MS >= ReconnectPolicy.HANDOFF_POLL_MS * 3,
        )
        assertTrue(ReconnectPolicy.HANDOFF_POLL_MS < ReconnectPolicy.PROGRESS_TICK_MS)
        assertTrue(
            ReconnectPolicy.HANDOFF_POST_FRAME_STALL_MS <
                ReconnectPolicy.HANDOFF_NO_FRAME_STALL_MS,
        )
    }

    @Test
    fun `a preview that reports no frames is not proof and does not arm`() {
        // -1 (no video renderer / mpv) and 0 (nothing ever drawn) are exactly
        // the cases inert rule 3 exists for: the arm must refuse them, and say
        // so, rather than manufacture proof out of an absent counter.
        val watch = FrameLivenessWatch()
        assertFalse(watch.armHandoff(0, renderedFrames = 0))
        assertFalse(watch.armHandoff(0, renderedFrames = -1))
        for (t in 0..(stall * 2) step 500) {
            assertFalse(watch.sample(t, playingNormally = true, renderedFrames = 0))
        }
    }

    @Test
    fun `past the handoff window the ordinary threshold applies again`() {
        // A stream that survived the claim for five seconds is no longer being
        // judged on the surface switch, so it gets the full, conservative
        // window back — including for a freeze that starts inside the window
        // and is only decided outside it.
        val watch = FrameLivenessWatch()
        watch.armHandoff(0, renderedFrames = 4_210)
        val window = ReconnectPolicy.HANDOFF_WINDOW_MS
        var frames = 4_210
        for (t in 500..window step 500) {
            frames += 30
            assertFalse(watch.sample(t, playingNormally = true, renderedFrames = frames))
        }
        assertFalse(watch.inHandoffWindow(window))
        assertFalse(
            watch.sample(window + ReconnectPolicy.HANDOFF_NO_FRAME_STALL_MS, true, frames),
        )
        assertTrue(watch.sample(window + stall, playingNormally = true, renderedFrames = frames))
    }

    @Test
    fun `a buffering tick during the claim does not disarm the handoff`() {
        // The handoff is exactly when a buffering tick is most likely, and the
        // proof being held is the preview's frames — not an observation of this
        // watch's own that a moment of buffering could revoke. Disarming there
        // would put the freeze straight back out of reach.
        val watch = FrameLivenessWatch()
        watch.armHandoff(0, renderedFrames = 4_210)
        assertFalse(watch.sample(500, playingNormally = false, renderedFrames = 4_210))
        assertTrue(watch.inHandoffWindow(500))
        assertFalse(watch.sample(1_000, playingNormally = true, renderedFrames = 4_210))
        val stallAt = 1_000 + ReconnectPolicy.HANDOFF_NO_FRAME_STALL_MS
        assertFalse(watch.sample(stallAt - 1, playingNormally = true, renderedFrames = 4_210))
        assertTrue(watch.sample(stallAt, playingNormally = true, renderedFrames = 4_210))
    }

    @Test
    fun `an engine that stops counting mid-handoff disarms completely`() {
        // -1 is the mpv fallback (and an audio-only channel) arriving: there is
        // nothing left to be armed against, proof or no proof.
        val watch = FrameLivenessWatch()
        watch.armHandoff(0, renderedFrames = 4_210)
        assertFalse(watch.sample(500, playingNormally = true, renderedFrames = -1))
        assertFalse(watch.inHandoffWindow(500))
    }

    @Test
    fun `reset drops the handoff window so a reload is judged normally`() {
        // A reload builds its own decoder against the surface it keeps, so the
        // claim it was armed for no longer describes anything.
        val watch = FrameLivenessWatch()
        watch.armHandoff(0, renderedFrames = 4_210)
        assertTrue(watch.inHandoffWindow(0))
        watch.reset()
        assertFalse(watch.inHandoffWindow(0))
    }

    @Test
    fun `the handoff window is decided well before the reload watchdog`() {
        // The whole point of the cheap rung: it must resolve, and be able to
        // escalate, inside the time the buffering watchdog would still be
        // waiting.
        assertTrue(
            ReconnectPolicy.HANDOFF_NO_FRAME_STALL_MS < ReconnectPolicy.NO_FRAME_STALL_MS,
        )
        assertTrue(
            ReconnectPolicy.HANDOFF_NO_FRAME_STALL_MS * 2 < ReconnectPolicy.STALL_RECONNECT_MS,
        )
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
