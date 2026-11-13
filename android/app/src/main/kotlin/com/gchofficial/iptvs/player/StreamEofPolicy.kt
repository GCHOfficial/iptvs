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
 * which dispatches `C.DATA_TYPE_MEDIA` with `C.TRACK_TYPE_UNKNOWN`.) **Both
 * halves of that pair matter** — see [isSourceEof] for the HLS playlist load
 * that matches the track type alone and is not an end of stream at all.
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
     * @param dataType `mediaLoadData.dataType`
     * @param dataTypeMedia `C.DATA_TYPE_MEDIA` (passed in so this file needs no
     *   media3 import)
     * @param trackType `mediaLoadData.trackType`
     * @param trackTypeUnknown `C.TRACK_TYPE_UNKNOWN`
     * @param isLive the host's own liveness flag — provider metadata, never
     *   inferred from duration
     * @param progressiveItem whether the item the engine loaded is one
     *   unbounded progressive body — the host's own
     *   `Util.inferContentType(uri) == C.CONTENT_TYPE_OTHER`, computed once per
     *   `load`
     * @param linesSoFar how many lines this load has already written
     */
    fun shouldReport(
        dataType: Int,
        dataTypeMedia: Int,
        trackType: Int,
        trackTypeUnknown: Int,
        isLive: Boolean,
        progressiveItem: Boolean,
        linesSoFar: Int,
    ): Boolean = isSourceEof(
        dataType = dataType,
        dataTypeMedia = dataTypeMedia,
        trackType = trackType,
        trackTypeUnknown = trackTypeUnknown,
        isLive = isLive,
        progressiveItem = progressiveItem,
    ) && linesSoFar < MAX_LINES_PER_LOAD

    /**
     * The same event without the log budget: whether this completed load *is*
     * a live progressive source reaching end of stream.
     *
     * Split out because the cap is about an exportable log and nothing else.
     * `HdrPlayerActivity` reacts to this event (it pre-resolves the next
     * locator — [LiveFastReconnectPolicy]), and a reaction that stopped on the
     * fourth EOF of a load while the first three were merely *reported* would
     * be a recovery silently gated on a diagnostics quota.
     *
     * ### Three conditions, and the two that were missing until 0.1.82
     *
     * `trackType == TRACK_TYPE_UNKNOWN` alone was the original filter, on the
     * reading that a progressive period reports it "because the load is the
     * whole stream, while every chunked format reports a real track type once
     * per segment". The second half is true of **segments** and false of
     * **manifests**: an HLS master or media playlist — and every live playlist
     * *refresh* — completes as `DATA_TYPE_MANIFEST` with `TRACK_TYPE_UNKNOWN`,
     * because there is no track for a playlist to belong to. So every playlist
     * load read as "the live source's body closed". An emulator run on an HLS
     * live channel shows it plainly: three `live pre-resolve requested
     * sinceLoadMs=114 ahead=0` lines inside 200 ms of opening the stream, each
     * answered `ok=false`. On a stable-URL provider that is a wasted resolve per
     * refresh; on a **Stalker** HLS channel it is a `create_link` issued while
     * the stream is wide open, which is precisely what the end-of-body gate
     * exists to prevent on a single-connection account.
     *
     * [dataType] is therefore the discriminator that actually separates a body
     * from a playlist, and [progressiveItem] is the belt to its braces: it is
     * the **same** `Util.inferContentType` test [StitchCoordinator.arm] uses,
     * which is also how `DefaultMediaSourceFactory` chose the `MediaSource` in
     * the first place — so an HLS or DASH item cannot report a source EOF at
     * all, whatever its loads are labelled.
     *
     * 0.1.81's pre-resolved reconnect shipped with this bug and the 10 s
     * cushion trigger does not mask it: at startup `ahead=0`, so the request is
     * due immediately.
     */
    fun isSourceEof(
        dataType: Int,
        dataTypeMedia: Int,
        trackType: Int,
        trackTypeUnknown: Int,
        isLive: Boolean,
        progressiveItem: Boolean,
    ): Boolean = isLive &&
        progressiveItem &&
        dataType == dataTypeMedia &&
        trackType == trackTypeUnknown

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
