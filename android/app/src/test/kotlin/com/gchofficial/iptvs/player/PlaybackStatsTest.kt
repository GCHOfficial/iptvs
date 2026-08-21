package com.gchofficial.iptvs.player

import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PlaybackStatsSamplerTest {
    private val interval = PlaybackStatsSampler.DEFAULT_INTERVAL_MS

    @Test
    fun `the first sample only establishes a baseline`() {
        val sampler = PlaybackStatsSampler()
        // A rate needs two samples; reporting the running total as if it were a
        // rate would be worse than reporting nothing.
        assertNull(sampler.sample(nowMs = 1_000, rendered = 500, dropped = 3))
    }

    @Test
    fun `nothing is emitted before the interval elapses`() {
        val sampler = PlaybackStatsSampler()
        sampler.sample(nowMs = 1_000, rendered = 0, dropped = 0)
        assertNull(sampler.sample(nowMs = 1_000 + interval - 1, rendered = 50, dropped = 0))
    }

    @Test
    fun `a healthy 50fps stream reports its rate`() {
        val sampler = PlaybackStatsSampler()
        sampler.sample(nowMs = 0, rendered = 0, dropped = 0)
        val line = sampler.sample(nowMs = interval, rendered = (50 * interval / 1000).toInt(), dropped = 0)
        assertNotNull(line)
        assertTrue(line!!, line.contains("fps=50.0"))
        assertTrue(line, line.contains("dropped=+0"))
    }

    @Test
    fun `a decoder that cannot keep up shows a low rate and rising drops`() {
        val sampler = PlaybackStatsSampler()
        sampler.sample(nowMs = 0, rendered = 0, dropped = 0)
        // 12fps rendered, 190 frames thrown away: the software-fallback shape.
        val line = sampler.sample(nowMs = interval, rendered = 60, dropped = 190)
        assertNotNull(line)
        assertTrue(line!!, line.contains("fps=12.0"))
        assertTrue(line, line.contains("dropped=+190"))
    }

    @Test
    fun `a low rate with no drops is distinguishable from one with drops`() {
        // The two look identical on screen and have opposite causes: frames
        // arriving late, versus frames being discarded to catch up.
        val sampler = PlaybackStatsSampler()
        sampler.sample(nowMs = 0, rendered = 0, dropped = 0)
        val line = sampler.sample(nowMs = interval, rendered = 60, dropped = 0)!!
        assertTrue(line, line.contains("fps=12.0"))
        assertTrue(line, line.contains("dropped=+0"))
    }

    @Test
    fun `an engine that does not count frames is inert`() {
        val sampler = PlaybackStatsSampler()
        // mpv, or an audio-only channel: -1 is never a measurement, so it must
        // not become a baseline either.
        assertNull(sampler.sample(nowMs = 0, rendered = -1, dropped = -1))
        assertNull(sampler.sample(nowMs = interval, rendered = -1, dropped = -1))
    }

    @Test
    fun `counters going backwards re-baseline instead of reporting a negative rate`() {
        val sampler = PlaybackStatsSampler()
        sampler.sample(nowMs = 0, rendered = 1_000, dropped = 10)
        // A new decoder resets the tallies.
        assertNull(sampler.sample(nowMs = interval, rendered = 5, dropped = 0))
        val line = sampler.sample(nowMs = interval * 2, rendered = 5 + 250, dropped = 0)
        assertNotNull(line)
        assertTrue(line!!, line.contains("fps=50.0"))
    }

    @Test
    fun `a paused interval cannot be counted as playback time`() {
        // Regression: the caller skipped sampling while paused/buffering but
        // kept the baseline, so the idle time went into the denominator. A 60s
        // pause then reported ~3.8fps with zero drops on resume — precisely the
        // "low rate, no drops" signature this feature exists to detect. The
        // caller now resets; this pins what reset must then do.
        val sampler = PlaybackStatsSampler()
        sampler.sample(nowMs = 0, rendered = 0, dropped = 0)
        sampler.reset() // what the caller does on the not-playing edge
        // 60s of pause, then 5s of healthy 50fps playback.
        assertNull(sampler.sample(nowMs = 60_000, rendered = 250, dropped = 0))
        val line = sampler.sample(nowMs = 65_000, rendered = 500, dropped = 0)
        assertNotNull(line)
        assertTrue(line!!, line.contains("fps=50.0"))
    }

    @Test
    fun `reset forgets the baseline`() {
        val sampler = PlaybackStatsSampler()
        sampler.sample(nowMs = 0, rendered = 0, dropped = 0)
        sampler.reset()
        assertNull(sampler.sample(nowMs = interval, rendered = 250, dropped = 0))
    }
}

class SoftwareDecoderTest {
    @Test
    fun `platform software decoders are recognised`() {
        assertTrue(isSoftwareDecoder("c2.android.hevc.decoder"))
        assertTrue(isSoftwareDecoder("OMX.google.h264.decoder"))
        assertTrue(isSoftwareDecoder("c2.google.av1.decoder"))
    }

    @Test
    fun `vendor decoders are treated as hardware`() {
        assertFalse(isSoftwareDecoder("OMX.amlogic.hevc.decoder"))
        assertFalse(isSoftwareDecoder("c2.mtk.hevc.decoder"))
        assertFalse(isSoftwareDecoder("OMX.MTK.VIDEO.DECODER.HEVC"))
        assertFalse(isSoftwareDecoder("c2.qti.hevc.decoder"))
    }
}
