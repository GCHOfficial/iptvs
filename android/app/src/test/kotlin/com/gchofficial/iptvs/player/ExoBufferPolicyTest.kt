package com.gchofficial.iptvs.player

import org.junit.Assert.assertTrue
import org.junit.Test

class ExoBufferPolicyTest {
    /**
     * The whole point of the tuning: start playback well before media3's
     * 2500ms `DEFAULT_BUFFER_FOR_PLAYBACK_MS`, which was 2.5s of black on
     * every zap, EPG-grid play and preview start.
     */
    @Test
    fun `playback start threshold beats the media3 default`() {
        assertTrue(ExoBufferPolicy.BUFFER_FOR_PLAYBACK_MS < 2_500)
        assertTrue(ExoBufferPolicy.BUFFER_FOR_PLAYBACK_AFTER_REBUFFER_MS < 5_000)
    }

    /**
     * Regression guard on the reason this can't simply be pushed to zero: a
     * stream stuck below the resume threshold stays in `STATE_BUFFERING`, and
     * `ReconnectPolicy.STALL_RECONNECT_MS` (8s) of that reloads the source. The
     * resume threshold must keep a wide margin under it, or ordinary underruns
     * become a reconnect loop.
     */
    @Test
    fun `playback buffers stay far below the stall reconnect threshold`() {
        val stall = ReconnectPolicy.STALL_RECONNECT_MS
        assertTrue(ExoBufferPolicy.BUFFER_FOR_PLAYBACK_MS * 4L <= stall)
        assertTrue(ExoBufferPolicy.BUFFER_FOR_PLAYBACK_AFTER_REBUFFER_MS * 4L <= stall)
    }

    /** …and equally can't be pushed so low that it micro-rebuffers instead. */
    @Test
    fun `playback buffers respect the anti-micro-rebuffer floor`() {
        assertTrue(
            ExoBufferPolicy.BUFFER_FOR_PLAYBACK_MS >=
                ExoBufferPolicy.MIN_PLAYBACK_BUFFER_FLOOR_MS,
        )
        assertTrue(
            ExoBufferPolicy.BUFFER_FOR_PLAYBACK_AFTER_REBUFFER_MS >=
                ExoBufferPolicy.MIN_PLAYBACK_BUFFER_FLOOR_MS,
        )
        // Resuming after an underrun should hold *more* than a cold start, so a
        // flapping connection doesn't restart into an immediate second stall.
        assertTrue(
            ExoBufferPolicy.BUFFER_FOR_PLAYBACK_AFTER_REBUFFER_MS >=
                ExoBufferPolicy.BUFFER_FOR_PLAYBACK_MS,
        )
    }

    /**
     * `DefaultLoadControl.Builder.setBufferDurationsMs` itself asserts these
     * orderings at build time — catch a bad edit here rather than as a native
     * crash on the first Android open.
     */
    @Test
    fun `sustained buffer window brackets the playback thresholds`() {
        assertTrue(ExoBufferPolicy.MIN_BUFFER_MS >= ExoBufferPolicy.BUFFER_FOR_PLAYBACK_MS)
        assertTrue(
            ExoBufferPolicy.MIN_BUFFER_MS >=
                ExoBufferPolicy.BUFFER_FOR_PLAYBACK_AFTER_REBUFFER_MS,
        )
        assertTrue(ExoBufferPolicy.MAX_BUFFER_MS >= ExoBufferPolicy.MIN_BUFFER_MS)
    }
}
