package com.gchofficial.iptvs.player

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Every invariant here is asserted for **every** preset, not for one tuning.
 *
 * That is the point of the file now that the durations are user-selectable: the
 * dangerous edit is no longer "someone changed a constant", it is "someone added
 * a preset that looks reasonable in isolation and quietly violates the stall
 * margin". `DefaultLoadControl.Builder.setBufferDurationsMs` asserts some of the
 * orderings itself, but only at build time on a real device — this catches them
 * on CI instead of as a native crash on the first Android open.
 */
class ExoBufferPolicyTest {
    private val presets = BufferPreset.entries

    /**
     * The whole point of the tuning: start playback well before media3's
     * 2500ms `DEFAULT_BUFFER_FOR_PLAYBACK_MS`, which was 2.5s of black on
     * every zap, EPG-grid play and preview start.
     */
    @Test
    fun `every preset beats the media3 start defaults`() {
        for (preset in presets) {
            val b = ExoBufferPolicy.forPreset(preset)
            assertTrue("$preset", b.forPlaybackMs < 2_500)
            assertTrue("$preset", b.afterRebufferMs < 5_000)
        }
    }

    /**
     * Regression guard on the reason this can't simply be pushed up: a stream
     * stuck below the resume threshold stays in `STATE_BUFFERING`, and
     * `ReconnectPolicy.STALL_RECONNECT_MS` (8s) of that reloads the source. The
     * resume threshold must keep a wide margin under it, or ordinary underruns
     * become a reconnect loop.
     *
     * This is the constraint that shapes the presets: it caps the resume
     * threshold at 2 s, which is why "high" buys its stall resistance from the
     * sustained cushion instead of from the start gates.
     */
    @Test
    fun `every preset stays far below the stall reconnect threshold`() {
        val stall = ReconnectPolicy.STALL_RECONNECT_MS
        for (preset in presets) {
            val b = ExoBufferPolicy.forPreset(preset)
            assertTrue("$preset", b.forPlaybackMs * 4L <= stall)
            assertTrue("$preset", b.afterRebufferMs * 4L <= stall)
        }
    }

    /** …and equally can't be pushed so low that it micro-rebuffers instead. */
    @Test
    fun `every preset respects the anti-micro-rebuffer floor`() {
        for (preset in presets) {
            val b = ExoBufferPolicy.forPreset(preset)
            assertTrue("$preset", b.forPlaybackMs >= ExoBufferPolicy.MIN_PLAYBACK_BUFFER_FLOOR_MS)
            assertTrue("$preset", b.afterRebufferMs >= ExoBufferPolicy.MIN_PLAYBACK_BUFFER_FLOOR_MS)
            // Resuming after an underrun should hold *more* than a cold start,
            // so a flapping connection doesn't restart into an immediate second
            // stall.
            assertTrue("$preset", b.afterRebufferMs >= b.forPlaybackMs)
        }
    }

    /**
     * `DefaultLoadControl.Builder.setBufferDurationsMs` itself asserts these
     * orderings at build time — catch a bad edit here rather than as a native
     * crash on the first Android open.
     */
    @Test
    fun `every preset brackets its playback thresholds`() {
        for (preset in presets) {
            val b = ExoBufferPolicy.forPreset(preset)
            assertTrue("$preset", b.minBufferMs >= b.forPlaybackMs)
            assertTrue("$preset", b.minBufferMs >= b.afterRebufferMs)
            assertTrue("$preset", b.maxBufferMs >= b.minBufferMs)
        }
    }

    /**
     * The presets have to be ordered to mean anything: picking "high" must
     * actually hold more media than "normal", which must hold more than "low".
     * Asserted on the *sustained* cushion, because that is the axis the presets
     * move — see [ExoBufferPolicy.forPreset].
     */
    @Test
    fun `the sustained cushion grows with the preset`() {
        val low = ExoBufferPolicy.forPreset(BufferPreset.LOW)
        val normal = ExoBufferPolicy.forPreset(BufferPreset.NORMAL)
        val high = ExoBufferPolicy.forPreset(BufferPreset.HIGH)
        assertTrue(low.minBufferMs < normal.minBufferMs)
        assertTrue(normal.minBufferMs < high.minBufferMs)
        assertTrue(low.maxBufferMs < normal.maxBufferMs)
        assertTrue(normal.maxBufferMs < high.maxBufferMs)
    }

    /**
     * An install that never touches the setting must play exactly as it did
     * before the setting existed — these four numbers are the previously
     * hardcoded tuning.
     */
    @Test
    fun `normal is the previously hardcoded tuning`() {
        val b = ExoBufferPolicy.forPreset(BufferPreset.NORMAL)
        assertEquals(15_000, b.minBufferMs)
        assertEquals(50_000, b.maxBufferMs)
        assertEquals(1_000, b.forPlaybackMs)
        assertEquals(2_000, b.afterRebufferMs)
    }

    /** Anything Dart sends that this build doesn't know falls back to normal. */
    @Test
    fun `an unknown preset name is normal`() {
        assertEquals(BufferPreset.NORMAL, BufferPreset.fromName(null))
        assertEquals(BufferPreset.NORMAL, BufferPreset.fromName(""))
        assertEquals(BufferPreset.NORMAL, BufferPreset.fromName("enormous"))
        assertEquals(BufferPreset.LOW, BufferPreset.fromName("low"))
        assertEquals(BufferPreset.LOW, BufferPreset.fromName("LOW"))
        assertEquals(BufferPreset.HIGH, BufferPreset.fromName("high"))
    }
}
