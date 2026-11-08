package com.gchofficial.iptvs.player

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class StreamEofPolicyTest {
    // `C.TRACK_TYPE_UNKNOWN` is -1; the chunked containers report real types.
    private val unknown = -1

    @Test
    fun `a progressive live load that completes is a source EOF`() {
        assertTrue(
            StreamEofPolicy.shouldReport(
                trackType = unknown,
                trackTypeUnknown = unknown,
                isLive = true,
                linesSoFar = 0,
            ),
        )
    }

    @Test
    fun `a chunked load is not`() {
        // HLS and DASH dispatch one onLoadCompleted per segment with a real
        // track type. Reporting those would write a line every few seconds and
        // evict the exportable log this diagnostic exists to fill.
        for (trackType in listOf(0, 1, 2, 3)) {
            assertFalse(
                "trackType=$trackType",
                StreamEofPolicy.shouldReport(
                    trackType = trackType,
                    trackTypeUnknown = unknown,
                    isLive = true,
                    linesSoFar = 0,
                ),
            )
        }
    }

    @Test
    fun `VOD is not reported`() {
        // Liveness is provider metadata, never inferred — and a VOD file
        // finishing its download is not the event this line is about.
        assertFalse(
            StreamEofPolicy.shouldReport(
                trackType = unknown,
                trackTypeUnknown = unknown,
                isLive = false,
                linesSoFar = 0,
            ),
        )
    }

    @Test
    fun `lines are capped per load`() {
        assertTrue(
            StreamEofPolicy.shouldReport(
                trackType = unknown,
                trackTypeUnknown = unknown,
                isLive = true,
                linesSoFar = StreamEofPolicy.MAX_LINES_PER_LOAD - 1,
            ),
        )
        assertFalse(
            StreamEofPolicy.shouldReport(
                trackType = unknown,
                trackTypeUnknown = unknown,
                isLive = true,
                linesSoFar = StreamEofPolicy.MAX_LINES_PER_LOAD,
            ),
        )
    }

    @Test
    fun `the line carries durations and bytes and nothing else`() {
        val line = StreamEofPolicy.line(
            sinceLoadMs = 26_412,
            aheadMs = 2_310,
            playedMs = 24_102,
            bytes = 81_234_567,
        )
        assertEquals(
            "stream source eof sinceLoadMs=26412 ahead=2310 played=24102 bytes=81234567",
            line,
        )
    }

    @Test
    fun `an unknown buffer depth stays -1 rather than being dressed up as zero`() {
        // `bufferedAheadMs()` / `mediaPositionMs()` return -1 for an engine
        // that cannot answer; "unknown" and "nothing buffered" are different
        // readings and the line must not collapse them.
        assertEquals(
            "stream source eof sinceLoadMs=-1 ahead=-1 played=-1 bytes=0",
            StreamEofPolicy.line(sinceLoadMs = -1, aheadMs = -1, playedMs = -1, bytes = 0),
        )
    }
}
