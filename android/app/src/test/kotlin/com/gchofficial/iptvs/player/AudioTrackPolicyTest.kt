package com.gchofficial.iptvs.player

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The audio half of the mpv fallback, and the three log shapes it has to make
 * distinguishable in an exported diagnostics log:
 *
 *  (a) the provider sent **no audio track**;
 *  (b) it sent audio this device **cannot decode** (the Xiaomi 11T Pro / DVB MP2
 *      report — picture, no sound, nothing in the log);
 *  (c) a decoder ran and produced **silence** (the `peak=` field).
 *
 * Pure on purpose: the decision and the formatting are the parts that can
 * silently regress, and they are the parts a device is not needed to check.
 */
class AudioTrackPolicyTest {

    private fun track(
        playable: Boolean,
        selected: Boolean = false,
        mime: String? = "audio/mp4a-latm",
        channels: Int = 2,
    ) = AudioTrackPolicy.AudioTrack(playable, selected, mime, channels)

    // ---- (b) the fallback decision ------------------------------------------

    @Test
    fun `audio tracks that none can decode fall back`() {
        assertTrue(
            AudioTrackPolicy.shouldFallback(
                listOf(track(playable = false, mime = "audio/mpeg-L2")),
            ),
        )
    }

    /**
     * The MP2 + AC-3 case: one decodable track is enough, and swapping engines
     * would cost a reload plus a tone-mapped SDR surface for nothing.
     */
    @Test
    fun `one decodable track among several is not a fallback`() {
        assertFalse(
            AudioTrackPolicy.shouldFallback(
                listOf(
                    track(playable = false, mime = "audio/mpeg-L2"),
                    track(playable = true, selected = true, mime = "audio/ac3", channels = 6),
                ),
            ),
        )
    }

    /**
     * (a). A video-only channel is a real thing and mpv would not improve it —
     * only the *presence* of undecodable audio is evidence about this device.
     */
    @Test
    fun `no audio at all is not a fallback`() {
        assertFalse(AudioTrackPolicy.shouldFallback(emptyList()))
    }

    /** Audio-only (radio) channels take the same rule: no video group is involved. */
    @Test
    fun `audio-only stream with undecodable audio falls back`() {
        assertTrue(
            AudioTrackPolicy.shouldFallback(
                listOf(track(playable = false, mime = "audio/mpeg-L2", channels = 2)),
            ),
        )
    }

    // ---- the summary line ---------------------------------------------------

    @Test
    fun `summary names the unsupported mime and leaves selected as none`() {
        val line = AudioTrackPolicy.summaryLine(
            listOf(track(playable = false, mime = "audio/mpeg-L2", channels = 2)),
        )
        assertEquals(
            "audio tracks=1 supported=0 selected=none unsupported=mpeg-L2 2ch",
            line,
        )
    }

    @Test
    fun `summary names the selected track and still lists the rejected one`() {
        val line = AudioTrackPolicy.summaryLine(
            listOf(
                track(playable = false, mime = "audio/mpeg-L2", channels = 2),
                track(playable = true, selected = true, mime = "audio/ac3", channels = 6),
            ),
        )
        assertEquals(
            "audio tracks=2 supported=1 selected=ac3 6ch unsupported=mpeg-L2 2ch",
            line,
        )
    }

    /** (a) as it appears in the log: a stream whose groups carry no audio. */
    @Test
    fun `summary says tracks=0 when the stream carries no audio`() {
        assertEquals(
            "audio tracks=0 supported=0 selected=none",
            AudioTrackPolicy.summaryLine(emptyList()),
        )
    }

    @Test
    fun `unknown mime and unknown channel count degrade rather than lie`() {
        assertEquals("?", AudioTrackPolicy.trackLabel(null, 0))
        assertEquals("?", AudioTrackPolicy.trackLabel("   ", 0))
        assertEquals("ac3", AudioTrackPolicy.trackLabel("audio/ac3", 0))
        assertEquals("weird", AudioTrackPolicy.trackLabel("weird", 2).substringBefore(' '))
    }

    // ---- (c) the peak readout ----------------------------------------------

    @Test
    fun `full scale is 0 dBFS and half scale is about -6`() {
        assertEquals(
            "0.0dBFS",
            AudioTrackPolicy.peakLabel(32_768, sawPcm = true, passthrough = false),
        )
        assertEquals(
            "-6.0dBFS",
            AudioTrackPolicy.peakLabel(16_384, sawPcm = true, passthrough = false),
        )
    }

    /** The whole point of (c): decoded digital silence has to be *visible*. */
    @Test
    fun `decoded silence reads as -inf, not as a missing measurement`() {
        assertEquals(
            "-inf",
            AudioTrackPolicy.peakLabel(0, sawPcm = true, passthrough = false),
        )
    }

    /**
     * Passthrough sends an encoded bitstream to the receiver, so
     * `DefaultAudioSink` runs an empty processor pipeline and there is nothing
     * to measure. Reporting `-inf` there would accuse a working HDMI link of
     * being silent.
     */
    @Test
    fun `passthrough and un-measured both say n a rather than silence`() {
        assertEquals(
            "n/a(passthrough)",
            AudioTrackPolicy.peakLabel(0, sawPcm = false, passthrough = true),
        )
        assertEquals(
            "n/a",
            AudioTrackPolicy.peakLabel(0, sawPcm = false, passthrough = false),
        )
    }

    // ---- the log fields are parseable --------------------------------------

    /**
     * Every field a support reader greps for is `key=value` with no spaces in
     * the value, except the deliberate `selected=<mime> <n>ch` pair. A space
     * creeping into `peak=` would split the field in two.
     */
    @Test
    fun `peak labels never contain a space`() {
        val labels = listOf(
            AudioTrackPolicy.peakLabel(32_768, sawPcm = true, passthrough = false),
            AudioTrackPolicy.peakLabel(0, sawPcm = true, passthrough = false),
            AudioTrackPolicy.peakLabel(0, sawPcm = false, passthrough = true),
            AudioTrackPolicy.peakLabel(0, sawPcm = false, passthrough = false),
        )
        for (label in labels) assertFalse(label, label.contains(' '))
    }

    /** The health sample must print a *finished* peak, not one still being taken. */
    @Test
    fun `the health sample lands after the peak window closes`() {
        assertTrue(
            AudioTrackPolicy.HEALTH_SAMPLE_DELAY_MS > AudioTrackPolicy.PEAK_WINDOW_MS,
        )
    }

    /** Fallback reasons must stay distinct, or the engine-swap line says nothing. */
    @Test
    fun `fallback reasons are distinct`() {
        val reasons = listOf(
            EngineFallbackReason.VIDEO,
            EngineFallbackReason.AUDIO,
            EngineFallbackReason.DECODE,
            EngineFallbackReason.SOURCE,
        )
        assertEquals(reasons.size, reasons.toSet().size)
    }
}
