package com.gchofficial.iptvs.player

/**
 * Network/demuxer tuning for live streams on the mpv fallback engine — the Kotlin
 * mirror of Dart's `kLiveMpvOptions` (`lib/player/mpv_options.dart`). Keep the two
 * in sync: they configure the same libmpv against the same providers.
 *
 * `reconnect_at_eof` must stay out of [STREAM_LAVF_O]. An HLS live stream's manifest
 * is a *finite* HTTP resource, and with that flag ffmpeg (verified on FFmpeg 8 /
 * mpv 0.41) treats its EOF as an error and reconnects forever, so the demuxer probe
 * never completes and the stream never opens at all. A clean server-side
 * end-of-stream instead surfaces as an mpv eof/error `end-file`, which
 * [MpvController] relays to the host watchdog ([ReconnectPolicy]) as a drop.
 */
object MpvLiveOptions {
    /**
     * Bound stalls so the host watchdog reloads the source instead of hanging
     * forever on a dead connection.
     */
    const val NETWORK_TIMEOUT = "10"

    /**
     * Let ffmpeg reconnect a transient HTTP drop — but **not** a streamed body,
     * and never at EOF.
     *
     * `reconnect_streamed=0` is the wave-2 correction, and it is specifically
     * about live TS. Providers answer with a close-delimited body (no
     * `Content-Length`), so ffmpeg judges *every* end as premature and
     * reconnects on its own — to the post-redirect URL, whose per-connection
     * `play_token` is single-use, so the retry is dead on arrival. Worse, on
     * the providers that send a connect backlog it sometimes *succeeds*, and
     * splices older content in behind the playhead: the audio timestamps reset
     * and the stream desyncs, reproduced locally. Live recovery belongs to the
     * host watchdog's reload, which **re-resolves** first and therefore has a
     * locator that can actually open.
     *
     * A non-streamed body (a finite file, i.e. VOD) keeps the benefit, and VOD
     * does not take these options at all — so what is being given up here is
     * only the broken half.
     *
     * Deliberately omits `reconnect_at_eof` — see the object comment.
     */
    const val STREAM_LAVF_O = "reconnect=1,reconnect_streamed=0,reconnect_delay_max=5"
}
