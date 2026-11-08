package com.gchofficial.iptvs.player

import java.util.Locale

/**
 * Who closed the connection, and how long the picture outlived it.
 *
 * `kind=ended` in the reconnect line is a *late* signal: it is the renderer
 * reaching `STATE_ENDED`, which on a live stream happens only once the whole
 * buffer has drained. The export that prompted this showed a Stalker session
 * ending every ~26–29 s of wall clock with ~24–27 s of media played — figures
 * that are consistent either with a server that closed at ~26 s, or with one
 * that closed much earlier and a cushion that took the rest of the time to run
 * dry. Nothing in the log separated them.
 *
 * `onLoadCompleted` on a **progressive** media period is the earlier signal:
 * media3 dispatches it from `ProgressiveMediaPeriod.onLoadCompleted`, i.e. the
 * instant the extracting loadable reaches end of input — the HTTP body ended.
 * (media3 1.11.1,
 * `libraries/exoplayer/src/main/java/androidx/media3/exoplayer/source/ProgressiveMediaPeriod.java`,
 * which dispatches `C.DATA_TYPE_MEDIA` with `C.TRACK_TYPE_UNKNOWN`.)
 *
 * Pure so it can be unit-tested without an Android SDK — the repo's Kotlin
 * tests are plain JUnit (`android/app/src/test/kotlin`).
 */
object StreamEofPolicy {
    /** Most `stream source eof` lines per load. */
    const val MAX_LINES_PER_LOAD = 3

    /**
     * Whether a completed media load is the "the source reached end of stream"
     * event this diagnostic is about.
     *
     * [trackType] is the discriminator and it is doing real work: a progressive
     * (MPEG-TS / unbounded HTTP body) period reports `C.TRACK_TYPE_UNKNOWN`
     * because the load is the whole stream, while every chunked format — HLS,
     * DASH — reports a real track type once per segment. Without the filter an
     * HLS channel would write one of these every few seconds and evict the
     * exportable log it was added to fill.
     *
     * @param trackType `mediaLoadData.trackType`
     * @param trackTypeUnknown `C.TRACK_TYPE_UNKNOWN` (passed in so this file
     *   needs no media3 import)
     * @param isLive the host's own liveness flag — provider metadata, never
     *   inferred from duration
     * @param linesSoFar how many lines this load has already written
     */
    fun shouldReport(
        trackType: Int,
        trackTypeUnknown: Int,
        isLive: Boolean,
        linesSoFar: Int,
    ): Boolean = isLive &&
        trackType == trackTypeUnknown &&
        linesSoFar < MAX_LINES_PER_LOAD

    /**
     * The line itself. Credential-free by construction: three durations and a
     * byte count, no URI and no headers.
     *
     * `sinceLoadMs` is measured from this engine's own `load()` — a reconnect
     * reloads, so it reads as the age of the connection that just ended.
     * `ahead` is what is still buffered at this instant, which is exactly how
     * much longer the picture will survive the close; `played` is the media
     * position, so `played + ahead` against `sinceLoadMs` says whether the
     * provider was feeding faster than real time (a connect backlog — see
     * docs/player.md "Live latency").
     */
    fun line(sinceLoadMs: Long, aheadMs: Long, playedMs: Long, bytes: Long): String =
        String.format(
            Locale.US,
            "stream source eof sinceLoadMs=%d ahead=%d played=%d bytes=%d",
            sinceLoadMs,
            aheadMs,
            playedMs,
            bytes,
        )
}
