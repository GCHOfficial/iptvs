package com.gchofficial.iptvs.player

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Locale

/**
 * Pins the pure half of [MpvController] — the mapping that used to run inline on
 * the main thread between `mpv_get_property` calls, and now runs on the
 * controller's reader thread with only the result posted back.
 */
class MpvTrackMappingTest {

    private fun audio(id: Int, title: String? = null, lang: String? = null) =
        RawMpvTrack("audio", id, title, lang)

    private fun sub(id: Int, title: String? = null, lang: String? = null) =
        RawMpvTrack("sub", id, title, lang)

    @Test
    fun `subtitles always lead with Off and default to it`() {
        val snapshot = mapMpvTracks(emptyList(), currentAid = null, currentSid = null)
        assertEquals(listOf(TrackOption(SUBTITLE_OFF_ID, "Off")), snapshot.subtitleTracks)
        assertEquals(SUBTITLE_OFF_ID, snapshot.selectedSubtitleId)
        // No audio track to fall back to, so nothing is selected.
        assertTrue(snapshot.audioTracks.isEmpty())
        assertNull(snapshot.selectedAudioId)
    }

    @Test
    fun `label precedence is title then language then numbering`() {
        val snapshot = mapMpvTracks(
            listOf(
                audio(1, title = "Director commentary", lang = "eng"),
                audio(2, lang = "fr"),
                audio(3, lang = "und"),
                audio(4),
            ),
            currentAid = null,
            currentSid = null,
            locale = Locale.ENGLISH,
        )
        assertEquals(
            listOf("Director commentary", "French", "Audio 3", "Audio 4"),
            snapshot.audioTracks.map { it.label },
        )
        assertEquals(listOf("1", "2", "3", "4"), snapshot.audioTracks.map { it.id })
    }

    @Test
    fun `a blank title is not a label`() {
        val snapshot = mapMpvTracks(
            listOf(audio(1, title = "   ", lang = "de")),
            currentAid = null,
            currentSid = null,
            locale = Locale.ENGLISH,
        )
        assertEquals("German", snapshot.audioTracks.single().label)
    }

    @Test
    fun `an unresolvable language code degrades to the code itself`() {
        // Never to "Audio 1": the code is still more identifying than a number.
        assertEquals("qqq", mpvLanguageLabel("qqq", Locale.ENGLISH))
        assertNull(mpvLanguageLabel("und", Locale.ENGLISH))
        assertNull(mpvLanguageLabel("  ", Locale.ENGLISH))
        assertNull(mpvLanguageLabel(null, Locale.ENGLISH))
    }

    @Test
    fun `subtitle numbering ignores the Off row`() {
        val snapshot = mapMpvTracks(
            listOf(sub(5), sub(6)),
            currentAid = null,
            currentSid = null,
        )
        assertEquals(
            listOf("Off", "Subtitle 1", "Subtitle 2"),
            snapshot.subtitleTracks.map { it.label },
        )
    }

    @Test
    fun `tracks mpv answered incompletely are skipped, never guessed`() {
        // A row with no id can't be sent back to `aid`/`sid`, so it would be a
        // dead menu entry; a row with no type can't be filed under either list.
        val snapshot = mapMpvTracks(
            listOf(
                audio(1),
                RawMpvTrack(type = "audio", id = null, title = "nameless", language = "eng"),
                RawMpvTrack(type = null, id = 9, title = null, language = null),
                RawMpvTrack(type = "video", id = 7, title = null, language = null),
            ),
            currentAid = null,
            currentSid = null,
        )
        assertEquals(listOf("1"), snapshot.audioTracks.map { it.id })
        assertEquals(1, snapshot.subtitleTracks.size)
    }

    @Test
    fun `selection follows mpv when it reports one, else falls back`() {
        val tracks = listOf(audio(1), audio(2), sub(3))
        val reported = mapMpvTracks(tracks, currentAid = 2, currentSid = 3)
        assertEquals("2", reported.selectedAudioId)
        assertEquals("3", reported.selectedSubtitleId)

        val unreported = mapMpvTracks(tracks, currentAid = null, currentSid = null)
        assertEquals("1", unreported.selectedAudioId)
        assertEquals(SUBTITLE_OFF_ID, unreported.selectedSubtitleId)
    }

    @Test
    fun `dynamic range - Dolby Vision outranks its PQ base layer`() {
        assertEquals("Dolby Vision", mpvDynamicRangeLabel("pq", "dolbyvision", "bt.2020"))
        assertEquals("Dolby Vision", mpvDynamicRangeLabel("dolbyvision", "bt.2020nc", "bt.2020"))
    }

    @Test
    fun `dynamic range - transfer wins over primaries, and unknown is not SDR`() {
        assertEquals("HDR10 · PQ", mpvDynamicRangeLabel("pq", "bt.2020nc", "bt.2020"))
        assertEquals("HLG", mpvDynamicRangeLabel("hlg", "bt.2020nc", "bt.2020"))
        assertEquals("HDR · BT.2020", mpvDynamicRangeLabel("bt.1886", "bt.2020nc", "bt.2020"))
        assertEquals("SDR", mpvDynamicRangeLabel("bt.1886", "bt.709", "bt.709"))
        // Nothing configured yet: no badge at all, rather than a wrong one.
        assertEquals("", mpvDynamicRangeLabel(null, null, null))
        assertEquals("", mpvDynamicRangeLabel("", "", ""))
    }

    @Test
    fun `dynamic range tolerates mpv's raw casing`() {
        assertEquals("HDR10 · PQ", mpvDynamicRangeLabel("PQ", "BT.2020NC", "BT.2020"))
    }

    @Test
    fun `every HDR label reads as HDR and SDR does not`() {
        val hdr = listOf(
            mpvDynamicRangeLabel("pq", "dolbyvision", ""),
            mpvDynamicRangeLabel("pq", "", ""),
            mpvDynamicRangeLabel("hlg", "", ""),
            mpvDynamicRangeLabel("bt.1886", "", "bt.2020"),
        )
        hdr.forEach { assertTrue(it, isHdrRangeLabel(it)) }
        assertFalse(isHdrRangeLabel(mpvDynamicRangeLabel("bt.1886", "bt.709", "bt.709")))
        assertFalse(isHdrRangeLabel(""))
    }

    @Test
    fun `codec labels are the compact badge names, uppercased otherwise`() {
        assertEquals("HEVC", mpvCodecLabel("hevc"))
        assertEquals("HEVC", mpvCodecLabel("H265"))
        assertEquals("H.264", mpvCodecLabel("h264"))
        assertEquals("MPEG-2", mpvCodecLabel("mpeg2video"))
        assertEquals("E-AC-3", mpvCodecLabel("eac3"))
        assertEquals("VORBIS", mpvCodecLabel("vorbis"))
    }
}
