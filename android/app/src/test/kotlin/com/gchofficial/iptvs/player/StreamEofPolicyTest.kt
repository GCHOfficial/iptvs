package com.gchofficial.iptvs.player

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class StreamEofPolicyTest {
    // `C.TRACK_TYPE_UNKNOWN` is -1. The real track types are 0 and up.
    private val unknown = -1

    // `C.DATA_TYPE_MEDIA` is 1 and `C.DATA_TYPE_MANIFEST` is 4; the policy
    // takes them as arguments so it needs no media3 import.
    private val media = 1
    private val manifest = 4

    private fun isSourceEof(
        dataType: Int = media,
        trackType: Int = unknown,
        isLive: Boolean = true,
        progressiveItem: Boolean = true,
    ) = StreamEofPolicy.isSourceEof(
        dataType = dataType,
        dataTypeMedia = media,
        trackType = trackType,
        trackTypeUnknown = unknown,
        isLive = isLive,
        progressiveItem = progressiveItem,
    )

    private fun shouldReport(
        dataType: Int = media,
        trackType: Int = unknown,
        isLive: Boolean = true,
        progressiveItem: Boolean = true,
        linesSoFar: Int = 0,
    ) = StreamEofPolicy.shouldReport(
        dataType = dataType,
        dataTypeMedia = media,
        trackType = trackType,
        trackTypeUnknown = unknown,
        isLive = isLive,
        progressiveItem = progressiveItem,
        linesSoFar = linesSoFar,
    )

    @Test
    fun `a progressive live load that completes is a source EOF`() {
        assertTrue(shouldReport())
        assertTrue(isSourceEof())
    }

    @Test
    fun `an HLS playlist load is not, however it is labelled`() {
        // **The bug this test exists for.** An HLS master or media playlist —
        // and every live playlist *refresh* — completes as DATA_TYPE_MANIFEST
        // with TRACK_TYPE_UNKNOWN, because there is no track for a playlist to
        // belong to. Matching on the track type alone read every one of those
        // as "the live body closed": an emulator run on an HLS live channel
        // produced three `live pre-resolve requested … ahead=0` lines inside
        // 200 ms of opening the stream. On a Stalker HLS channel that is a
        // `create_link` issued while the stream is wide open, which is exactly
        // what the end-of-body gate exists to prevent.
        assertFalse(isSourceEof(dataType = manifest, trackType = unknown))
        assertFalse(shouldReport(dataType = manifest, trackType = unknown))
        // And it is refused twice over, because an HLS *item* is not
        // progressive in the first place.
        assertFalse(isSourceEof(dataType = manifest, progressiveItem = false))
    }

    @Test
    fun `an HLS or DASH media chunk is not`() {
        // Chunked formats dispatch one completion per segment with a real
        // track type. Reporting those would write a line every few seconds and
        // evict the exportable log this diagnostic exists to fill.
        for (trackType in listOf(0, 1, 2, 3)) {
            assertFalse("trackType=$trackType", isSourceEof(trackType = trackType))
            assertFalse("trackType=$trackType", shouldReport(trackType = trackType))
        }
    }

    @Test
    fun `a non-progressive item never reports one`() {
        // The belt to the dataType braces, and the same `inferContentType` test
        // `StitchCoordinator.arm` uses — which is also how
        // `DefaultMediaSourceFactory` chose the MediaSource, so the three
        // cannot disagree about what kind of stream this is. Even a chunk that
        // somehow arrived labelled like a progressive body cannot get through.
        assertFalse(isSourceEof(progressiveItem = false))
        assertFalse(shouldReport(progressiveItem = false))
    }

    @Test
    fun `every other data type is refused`() {
        // MEDIA_INITIALIZATION, DRM, TIME_SYNCHRONIZATION, AD — none of them is
        // the stream's own body ending.
        for (dataType in listOf(0, 2, 3, 4, 5, 6)) {
            assertFalse("dataType=$dataType", isSourceEof(dataType = dataType))
        }
    }

    @Test
    fun `VOD never reports one`() {
        // Liveness is provider metadata, never inferred — and a VOD stream
        // reaching the end of its body is the film ending, not a drop.
        assertFalse(isSourceEof(isLive = false))
        assertFalse(shouldReport(isLive = false))
    }

    @Test
    fun `the log budget bounds the line but not the event`() {
        // The cap is about an exportable log and nothing else. The host reacts
        // to this event by pre-resolving the next locator, and a recovery
        // silently gated on a diagnostics quota would be a trap.
        assertTrue(shouldReport(linesSoFar = StreamEofPolicy.MAX_LINES_PER_LOAD - 1))
        assertFalse(shouldReport(linesSoFar = StreamEofPolicy.MAX_LINES_PER_LOAD))
        assertTrue(isSourceEof())
    }

    @Test
    fun `the line carries four numbers and no locator`() {
        assertEquals(
            "stream source eof sinceLoadMs=6032 ahead=21011 played=4580 bytes=8649536",
            StreamEofPolicy.line(
                sinceLoadMs = 6032,
                aheadMs = 21011,
                playedMs = 4580,
                bytes = 8649536,
            ),
        )
    }
}
