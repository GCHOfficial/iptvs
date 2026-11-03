package com.gchofficial.iptvs.player

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MpvLiveOptionsTest {
    /**
     * Regression guard: `reconnect_at_eof` makes ffmpeg treat an HLS manifest's
     * finite EOF as an error and reconnect forever, so the demuxer probe never
     * completes and the stream never opens. It shipped here once; keep it out.
     */
    @Test
    fun `stream-lavf-o never enables reconnect_at_eof`() {
        assertFalse(MpvLiveOptions.STREAM_LAVF_O.contains("reconnect_at_eof"))
    }

    @Test
    fun `stream-lavf-o keeps transparent reconnect for transient drops`() {
        assertTrue(MpvLiveOptions.STREAM_LAVF_O.contains("reconnect=1"))
        assertTrue(MpvLiveOptions.STREAM_LAVF_O.contains("reconnect_delay_max=5"))
    }

    /**
     * …but never for a **streamed** body, which on live TS is all of them.
     *
     * A close-delimited response has no length to reach, so ffmpeg reads every
     * end as premature and retries the post-redirect URL — whose single-use
     * `play_token` is already spent, making the retry useless — or, on a
     * backlog provider, succeeds and splices older content in behind the
     * playhead, resetting the audio timestamps. The host watchdog's
     * re-resolving reload owns live recovery for exactly that reason.
     */
    @Test
    fun `stream-lavf-o never reconnects a streamed body`() {
        assertTrue(MpvLiveOptions.STREAM_LAVF_O.contains("reconnect_streamed=0"))
        assertFalse(MpvLiveOptions.STREAM_LAVF_O.contains("reconnect_streamed=1"))
    }

    /**
     * Parity with Dart's `kLiveMpvOptions['stream-lavf-o']`
     * (`lib/player/mpv_options.dart`): the same libmpv, the same providers, and
     * nothing at runtime that would ever reveal the two having drifted apart.
     */
    @Test
    fun `stream-lavf-o matches the Dart mirror verbatim`() {
        assertEquals(
            "reconnect=1,reconnect_streamed=0,reconnect_delay_max=5",
            MpvLiveOptions.STREAM_LAVF_O,
        )
    }

    /**
     * The stall watchdog can only reload a dead connection if ffmpeg gives up on
     * it first, so the network timeout has to stay well under the backoff.
     */
    @Test
    fun `network timeout stays below the stall reconnect threshold`() {
        val timeoutMs = MpvLiveOptions.NETWORK_TIMEOUT.toLong() * 1000
        assertTrue(timeoutMs < ReconnectPolicy.MAX_BACKOFF_MS)
    }
}
