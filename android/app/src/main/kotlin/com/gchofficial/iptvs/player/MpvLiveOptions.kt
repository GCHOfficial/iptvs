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
     * Let ffmpeg transparently reconnect transient HTTP drops. Deliberately omits
     * `reconnect_at_eof` — see the object comment.
     */
    const val STREAM_LAVF_O = "reconnect=1,reconnect_streamed=1,reconnect_delay_max=5"
}
