package com.gchofficial.iptvs.player

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackException
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.common.Tracks
import androidx.media3.common.VideoSize
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.DecoderCounters
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.exoplayer.video.VideoFrameMetadataListener
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView
import java.util.Locale

/**
 * How much media to hold ahead of playback — a user-facing, per-source choice.
 *
 * Exists because the right answer is a property of the *link*, not of the app:
 * a clean wired connection wants short buffers and instant zapping, a flaky or
 * throttled one wants depth, and no single default serves both. It is a
 * three-way preset rather than raw millisecond fields on purpose — four
 * interacting durations are a knob people copy from forum posts, and an invalid
 * combination (a resume threshold above the stall watchdog's patience) is a
 * reconnect loop we would then have to explain.
 *
 * Note what it cannot do: a deeper buffer converts frequent short stalls into
 * rarer long ones. It does not add bandwidth, so it is not a fix for a
 * saturated or throttled link.
 */
enum class BufferPreset {
    LOW,
    NORMAL,
    HIGH;

    /**
     * `cache-secs` for the libmpv fallback, or null to leave mpv's own default.
     *
     * Mirrors Dart's `mpvBufferOptions`, including `NORMAL` meaning "change
     * nothing": mpv's default is what this surface has always run, and writing
     * a number that merely resembles it would change the default install while
     * claiming to preserve it.
     */
    val mpvCacheSecs: Int?
        get() = when (this) {
            LOW -> 3
            NORMAL -> null
            HIGH -> 30
        }

    companion object {
        /** Parses the name Dart sends; anything unrecognised is [NORMAL]. */
        fun fromName(name: String?): BufferPreset = when (name?.lowercase(Locale.US)) {
            "low" -> LOW
            "high" -> HIGH
            else -> NORMAL
        }
    }
}

/**
 * Buffering policy for [ExoPlayerEngine] — the numbers media3's
 * `DefaultLoadControl` would otherwise default to are tuned for on-demand video,
 * not for zapping around live IPTV.
 *
 * The one that matters is [BUFFER_FOR_PLAYBACK_MS]: media3 defaults it to
 * **2500 ms**, so *every* Android open (channel zap, EPG-grid play, and the
 * `SharedEngine` preview, which runs through this same engine) shows 2.5 s of
 * black before the first frame, and 5 s (`DEFAULT_BUFFER_FOR_PLAYBACK_AFTER_
 * REBUFFER_MS`) after every rebuffer.
 *
 * **Floor, not a target.** These start thresholds must stay well under
 * [ReconnectPolicy.STALL_RECONNECT_MS] (8 s), because a stream that can't reach
 * the resume threshold keeps ExoPlayer in `STATE_BUFFERING`, and once that lasts
 * 8 s the Activity's watchdog reloads the source. Set the resume threshold too
 * close to it and a genuine underrun turns into a reconnect loop instead of a
 * short rebuffer. Roughly 1 s to start / 2 s to resume keeps a ≥4x margin while
 * still holding enough media to ride out normal jitter, and the *sustained*
 * cushion ([MIN_BUFFER_MS]/[MAX_BUFFER_MS]) is what actually absorbs network
 * variance once playing. Pinned by `ExoBufferPolicyTest`.
 */
object ExoBufferPolicy {
    /**
     * The four `DefaultLoadControl` durations, as one value.
     *
     * @param minBufferMs below this much buffered media the loader resumes filling
     * @param maxBufferMs ceiling on how far ahead the loader buffers
     * @param forPlaybackMs buffered media required before playback *starts*
     *   (media3 default: 2500)
     * @param afterRebufferMs buffered media required to resume after an underrun
     *   (media3 default: 5000)
     */
    data class Durations(
        val minBufferMs: Int,
        val maxBufferMs: Int,
        val forPlaybackMs: Int,
        val afterRebufferMs: Int,
    )

    /**
     * The user-selectable buffering presets.
     *
     * **Only the sustained cushion moves between them, not the start gates**,
     * and that is the whole design rather than an oversight. What absorbs
     * network variance once playing is [Durations.minBufferMs] /
     * [Durations.maxBufferMs]; the start gates decide how long a zap stares at
     * black. Raising the gates to "buffer more" would therefore cost the thing
     * users actually notice while barely helping the thing they are trying to
     * fix — and it cannot go far anyway, because a stream stuck below the
     * resume threshold sits in `STATE_BUFFERING`, and
     * [ReconnectPolicy.STALL_RECONNECT_MS] (8 s) of that reloads the source.
     * The 4x margin that guards against turning an ordinary underrun into a
     * reconnect loop caps the resume threshold at 2 s, which `HIGH` already
     * sits on.
     *
     * `NORMAL` is exactly the previously hardcoded tuning, so an install that
     * never touches the setting plays identically to before.
     */
    fun forPreset(preset: BufferPreset): Durations = when (preset) {
        // Zapping-first: a shallower cushion refills sooner after a channel
        // change and starts fractionally faster, at the cost of riding out
        // less jitter.
        BufferPreset.LOW -> Durations(
            minBufferMs = 8_000,
            maxBufferMs = 25_000,
            forPlaybackMs = 750,
            afterRebufferMs = 1_500,
        )
        BufferPreset.NORMAL -> Durations(
            minBufferMs = 15_000,
            maxBufferMs = 50_000,
            forPlaybackMs = 1_000,
            afterRebufferMs = 2_000,
        )
        // A deep cushion for a link that stutters. Same start gates as NORMAL
        // on purpose — see above; this buys stall resistance, not latency, and
        // it costs memory, which is why the ceiling is not higher still on
        // hardware that is routinely a 2 GiB TV box.
        BufferPreset.HIGH -> Durations(
            minBufferMs = 40_000,
            maxBufferMs = 90_000,
            forPlaybackMs = 1_000,
            afterRebufferMs = 2_000,
        )
    }

    /**
     * Judge the buffer by duration rather than by allocated bytes: IPTV bitrates
     * vary wildly between providers/channels, and a byte-based threshold makes
     * time-to-first-frame a function of the bitrate instead of a fixed budget.
     */
    const val PRIORITIZE_TIME_OVER_SIZE = true

    /**
     * Hard floor for [BUFFER_FOR_PLAYBACK_MS]/[BUFFER_FOR_PLAYBACK_AFTER_REBUFFER_MS]
     * — going below this trades a barely-perceptible startup win for constant
     * micro-rebuffering, which is what actually feeds the stall watchdog.
     */
    const val MIN_PLAYBACK_BUFFER_FLOOR_MS = 750
}

/**
 * Default [PlaybackEngine]: ExoPlayer/MediaCodec hardware decode into a
 * [PlayerView] (SurfaceView-backed), which gives true HDR on capable
 * devices/displays. When the video track can't be decoded here (e.g. Dolby Vision
 * Profile 5 on non-DV hardware), [onUnsupportedVideo] fires so the host can fall
 * back to libmpv.
 */
@UnstableApi
class ExoPlayerEngine(
    context: Context,
    private val state: PlayerUiState,
    private val headers: Map<String, String>,
    /**
     * Chosen per source and fixed at construction: `LoadControl` is a
     * build-time argument to `ExoPlayer.Builder`, so a preset change reaches
     * playback on the next engine, not the current one. [SharedEngine] treats
     * a changed preset the way it treats changed headers — by building a fresh
     * engine — so returning to a source applies its own setting.
     */
    private val bufferPreset: BufferPreset = BufferPreset.NORMAL,
) : PlaybackEngine {

    // Rebindable callbacks (not constructor params) because the engine can outlive
    // its host: the shared preview engine is adopted by the fullscreen Activity,
    // which must route these to *its* handlers (mpv fallback / live reconnect) and
    // hand them back to the preview's on exit. See [SharedEngine].
    var onUnsupportedVideo: (() -> Unit)? = null
    var onRecoverableError: (() -> Unit)? = null
    var onVideoSizeChanged: ((Int, Int) -> Unit)? = null

    /**
     * Short, **credential-free** notes for the host's exportable diagnostics
     * log: how the fullscreen surface was claimed, when the first frame landed,
     * and the shape of the stream that produced it.
     *
     * These exist because the preview→fullscreen handoff was, from an exported
     * log, entirely opaque past `adopted=true` — the reports it had to explain
     * ("high-bitrate channels stay black after going fullscreen") name exactly
     * the variables none of them recorded. Rebindable for the same reason the
     * callbacks above are: the shared preview engine outlives its host.
     *
     * Anything passed here is relayed verbatim into a log the user can share.
     * Never a URL, a header, or a provider reply.
     */
    var onDiagnostic: ((String) -> Unit)? = null

    /**
     * Fired once per [claimViewSurface] when the **claimed** surface renders
     * its first frame. Bound by the fullscreen Activity so
     * [FrameLivenessWatch.markHandoffFirstFrame] learns it from the renderer
     * rather than inferring it from a surface-agnostic frame counter that is
     * still advancing on the preview's texture while the claim is deferred.
     * Delivered on the main thread, like every other listener here.
     */
    var onClaimedSurfaceFirstFrame: (() -> Unit)? = null

    private val playerView = PlayerView(context).apply {
        useController = false
        resizeMode = AspectRatioFrameLayout.RESIZE_MODE_FIT
        setShowBuffering(PlayerView.SHOW_BUFFERING_NEVER)
        keepScreenOn = true
    }
    private val contentFrame: AspectRatioFrameLayout? =
        playerView.findViewById(androidx.media3.ui.R.id.exo_content_frame)

    private val player: ExoPlayer
    // Held because it is the only handle on the video renderer instance
    // ([rebuildVideoDecoder] addresses a PlayerMessage at it).
    private val renderersFactory: HdrRenderersFactory
    private val audioOverrides = mutableMapOf<String, TrackSelectionOverride>()
    private val subtitleOverrides = mutableMapOf<String, TrackSelectionOverride>()
    private var volumeBeforeMute = 1f
    private var fellBack = false
    // Guards release() against a double-decrement of DebugCounters (and a
    // clearPreviewSurface call landing after release, e.g. a disposing preview
    // platform view racing the shared engine's own teardown).
    private var released = false
    private val mainHandler = Handler(Looper.getMainLooper())

    // A [claimViewSurface] waiting for the PlayerView's surface to exist, and
    // the backstop that claims anyway if it never does. See claimViewSurface.
    private var pendingClaim: Pair<SurfaceHolder, SurfaceHolder.Callback>? = null
    // When the deferred claim started, so its outcome can report how long the
    // SurfaceView actually took — the number the 1s backstop is a bet against.
    private var claimRequestedAtMs = 0L
    private val pendingClaimFallback = Runnable {
        pendingClaim?.let { (holder, callback) -> holder.removeCallback(callback) }
        pendingClaim = null
        if (!released) {
            // The surface never arrived within the backstop, so this claims a
            // holder that still has none: ExoPlayer parks the video output at
            // null and waits for its own surfaceCreated, i.e. an *extra* output
            // transition — on a codecNeedsSetOutputSurfaceWorkaround device, an
            // extra codec re-init and IDR wait. Worth seeing in a report.
            reportClaim("backstop", CLAIM_FALLBACK_MS)
            attachOwnSurface()
        }
    }
    // Set when the video output is (re)claimed for fullscreen, so the first
    // frame after it can be reported as a handoff latency rather than a bare
    // timestamp. 0 = no claim yet (a cold open measures from load instead).
    private var claimedAtMs = 0L
    private var loadedAtMs = 0L

    /// When the video output was handed **back** to the preview texture, so the
    /// first frame after that swap can be measured the way a claim's is.
    private var reattachedAtMs = 0L
    private var reportedFirstFrame = false

    /// One decoder rebuild per return leg — see [previewFrameWatch].
    private var previewRebuildAttempted = false

    /**
     * The **return** leg's liveness watch: the mirror of the forward leg's
     * `FrameLivenessWatch.armHandoff` / `tryHandoffDecoderRebuild`.
     *
     * Coming back from fullscreen is the same output-surface transition as the
     * claim, on the same hardware that re-instantiates the codec for one — but
     * it had no watchdog and no recovery, because the forward leg's lives in
     * `HdrPlayerActivity` and that Activity is finishing by the time this runs.
     * So a `setOutputSurface` that failed to produce frames left the preview
     * black *permanently*, with nothing in the log but silence where a
     * `first frame sinceReattachMs=` should be.
     *
     * The case it was found on: a live stream that changed codec mid-session
     * (HEVC -> H.264 across a `kind=ended` reconnect) had its decoder rebuilt
     * **while in fullscreen**, so the codec instance handed back to the preview
     * was one created against the Activity's SurfaceView rather than one the
     * preview had created and lent out. Nothing about that is specific to a
     * channel or a provider — any reconnect during a long fullscreen session
     * reaches the same state, and live IPTV reconnects routinely.
     *
     * Deliberately a one-shot rebuild, matching the forward leg: a rebuild is
     * the cheap local recovery, and the evidence there says a decoder is what
     * breaks, not the connection. If it does not take, [previewRebuildVerify]
     * says so in the exported log rather than the failure being silent again.
     */
    private val previewFrameWatch = Runnable {
        if (released || reportedFirstFrame || previewRebuildAttempted) {
            return@Runnable
        }
        previewRebuildAttempted = true
        onDiagnostic?.invoke(
            "preview no frame ${PREVIEW_NO_FRAME_REBUILD_MS}ms after reattach; " +
                "rebuilding decoder" + (videoFrameCounters?.let { " $it" } ?: ""),
        )
        rebuildVideoDecoder()
        mainHandler.postDelayed(previewRebuildVerify, PREVIEW_REBUILD_VERIFY_MS)
    }

    /// Log-only: did the [previewFrameWatch] rebuild actually produce a frame?
    private val previewRebuildVerify = Runnable {
        if (released || reportedFirstFrame) return@Runnable
        onDiagnostic?.invoke(
            "preview still blank ${PREVIEW_REBUILD_VERIFY_MS}ms after decoder " +
                "rebuild" + (videoFrameCounters?.let { " $it" } ?: ""),
        )
    }

    /// Stops the return-leg watch (a frame arrived, fullscreen re-claimed, or
    /// the engine is going away).
    private fun cancelPreviewFrameWatch() {
        mainHandler.removeCallbacks(previewFrameWatch)
        mainHandler.removeCallbacks(previewRebuildVerify)
    }
    private var reportedStreamShape = false
    // Dynamic range as reported by the decoder's output MediaFormat (VUI + in-band
    // SEI). Authoritative when set; we fall back to Format.colorInfo until then.
    // Reset per load so a new stream re-derives instead of inheriting the last one.
    private var decoderDynamicRange: String? = null
    // Measured-FPS: many IPTV streams don't carry frameRate in their Format
    // (stays NO_VALUE). Primary method: a short burst of actual frame
    // *presentation* timestamps (via setVideoFrameMetadataListener), median'd
    // into a single value and then frozen (fpsLocked) — not a live,
    // continuously-redisplayed number, and not vulnerable to playback-thread
    // scheduling/GC jitter or rebuffer stalls the way wall-clock sampling is.
    // Falls back to the older rendered-frame-count/wall-clock heuristic
    // (measureFps) only while this hasn't converged, e.g. a device/decoder
    // that never invokes the frame-metadata listener.
    private val frameIntervalsUs = mutableListOf<Long>()
    private var lastFramePresentationUs = Long.MIN_VALUE
    private var fpsLocked = false
    // clearVideoFrameMetadataListener needs the exact registered instance back
    // (there's no bare "unset"), so we hold onto it to stop the measurement.
    private var frameMetadataListener: VideoFrameMetadataListener? = null
    // Fallback wall-clock sampling state (see measureFps).
    private var lastRenderedFrames = 0
    private var lastFpsSampleNs = 0L

    override val view: View get() = playerView

    /**
     * Frames the video renderer has put on screen since the last load. Null
     * counters (no video renderer — an audio-only channel, or a released
     * engine) report -1, which [FrameLivenessWatch] treats as "can't judge"
     * rather than "frozen". Read through [videoCounters], for the cross-thread
     * barrier this number's whole meaning depends on.
     */
    override val renderedFrameCount: Int
        get() = videoCounters()?.renderedOutputBufferCount ?: -1

    override val droppedFrameCount: Int
        get() = videoCounters()?.droppedBufferCount ?: -1

    /**
     * The video renderer's counters, safe to read from **this** thread.
     *
     * `DecoderCounters`' fields are plain `int`s written on the playback
     * thread, and `ensureUpdated()` is the volatile read media3 documents as
     * the way to get a happens-before edge from there ("any other thread should
     * call this method before reading the counters"). Skipping it is not a
     * theoretical race here: [FrameLivenessWatch] decides a renderer is
     * *frozen* purely from this number failing to change between polls, so a
     * stale read is indistinguishable from a wedged decoder — and the recovery
     * that arms rebuilds a decoder which was never broken, spending a fresh IDR
     * wait and a dropped-frame catch-up that desyncs audio. An exported log
     * caught exactly that shape: a rebuild fired against
     * `dropped=0 skipped=0 toKeyframe=0 inits=1`, a decoder reporting no
     * distress of any kind.
     *
     * The [released] guard is for the window where a poll can outlive the
     * engine: the Activity's ticker holds `engine`, and an mpv fallback
     * releases this one mid-session. Reading a released ExoPlayer is not worth
     * finding out about the hard way for a number whose only job is a
     * heuristic.
     */
    private fun videoCounters(): DecoderCounters? {
        if (released) return null
        return player.videoDecoderCounters?.also { it.ensureUpdated() }
    }

    /**
     * Sends [HdrMediaCodecVideoRenderer.MSG_REBUILD_CODEC] to this player's own
     * video renderer. Asynchronous by construction — the message is applied on
     * the playback thread — so `true` means "asked", and the answer arrives as
     * frames (or as the next stall, which escalates to a reload).
     */
    override fun rebuildVideoDecoder(): Boolean {
        if (released) return false
        val renderer = renderersFactory.videoRenderer ?: return false
        return runCatching {
            player.createMessage(renderer)
                .setType(HdrMediaCodecVideoRenderer.MSG_REBUILD_CODEC)
                .send()
            true
        }.getOrElse {
            Log.w(TAG, "video decoder rebuild could not be sent", it)
            false
        }
    }

    override val videoFrameCounters: String?
        get() {
            val c = videoCounters() ?: return null
            return "rendered=${c.renderedOutputBufferCount} " +
                "dropped=${c.droppedBufferCount} " +
                "toKeyframe=${c.droppedToKeyframeCount} " +
                "skipped=${c.skippedOutputBufferCount} " +
                "inits=${c.decoderInitCount}"
        }

    /// Reported once per engine, from [load] rather than from `init`.
    ///
    /// `onDiagnostic` is a rebindable `var` the *host* assigns after
    /// construction — `HdrPlayerActivity.startWithExoPlayer` two lines later,
    /// `SharedEngine` in `bindPreviewCallbacks` — so anything logged in the
    /// constructor goes to a null callback and never reaches the exportable
    /// log. This line is the only evidence a user's export carries that the
    /// preset arrived at all, which is exactly what would have surfaced the
    /// missing Intent extra without a code read.
    private var reportedBuffers = false

    private fun reportBufferPolicy() {
        if (reportedBuffers) return
        reportedBuffers = true
        val buffers = ExoBufferPolicy.forPreset(bufferPreset)
        onDiagnostic?.invoke(
            "buffer preset=${bufferPreset.name.lowercase(Locale.US)} " +
                "min=${buffers.minBufferMs} max=${buffers.maxBufferMs} " +
                "start=${buffers.forPlaybackMs} resume=${buffers.afterRebufferMs}",
        )
    }

    override fun load(url: String, subtitles: List<SubtitleSpec>) {
        reportBufferPolicy()
        val item = MediaItem.Builder()
            .setUri(url)
            .setSubtitleConfigurations(
                subtitles.filter { it.url.isNotBlank() }.map { sub ->
                    MediaItem.SubtitleConfiguration.Builder(Uri.parse(sub.url))
                        .setMimeType(subtitleMimeType(sub.url))
                        .setLabel(sub.label.ifBlank { null })
                        .setLanguage(sub.language.ifBlank { null })
                        .build()
                },
            )
            .build()
        // stop() first so a reload (go-to-live) starts from a clean idle state
        // instead of inheriting a paused / mid-flush decoder, which left the
        // first go-to-live stuck paused. No-op on the initial (idle) load.
        player.stop()
        player.setMediaItem(item)
        player.prepare()
        player.playWhenReady = true
        lastFpsSampleNs = 0L
        lastRenderedFrames = 0
        frameIntervalsUs.clear()
        lastFramePresentationUs = Long.MIN_VALUE
        fpsLocked = false
        loadedAtMs = SystemClock.elapsedRealtime()
        // A reload builds a new decoder against whatever surface it already
        // has, so neither the last claim nor the last re-attach describes its
        // first frame any more — without clearing these, a reload after an
        // adopted handoff reported `sinceClaimMs` measured from a claim that
        // happened minutes and several surfaces ago.
        claimedAtMs = 0L
        reattachedAtMs = 0L
        reportedFirstFrame = false
        reportedStreamShape = false
        // Re-armed per load — locking unregisters it (see stopFrameMetadataMeasurement).
        stopFrameMetadataMeasurement()
        val listener = VideoFrameMetadataListener { presentationTimeUs, _, _, _ ->
            mainHandler.post { onVideoFrameMetadata(presentationTimeUs) }
        }
        frameMetadataListener = listener
        player.setVideoFrameMetadataListener(listener)
        decoderDynamicRange = null
    }

    private val playerListener = object : Player.Listener {
        override fun onIsPlayingChanged(isPlaying: Boolean) {
            state.isPlaying = isPlaying
        }

        override fun onPlaybackStateChanged(playbackState: Int) {
            state.isBuffering = playbackState == Player.STATE_BUFFERING
            state.ended = playbackState == Player.STATE_ENDED
            if (playbackState == Player.STATE_READY || playbackState == Player.STATE_ENDED) {
                updateStreamInfo()
            }
            syncProgress()
        }

        override fun onTracksChanged(tracks: Tracks) {
            if (detectUnsupportedVideo(tracks)) return
            rebuildTracks(tracks)
            updateStreamInfo()
        }

        override fun onVideoSizeChanged(videoSize: VideoSize) {
            if (videoSize.width > 0) state.videoWidth = videoSize.width
            if (videoSize.height > 0) state.videoHeight = videoSize.height
            if (videoSize.width > 0 && videoSize.height > 0) {
                this@ExoPlayerEngine.onVideoSizeChanged
                    ?.invoke(videoSize.width, videoSize.height)
            }
            updateStreamInfo()
            playerView.post { applyAspect(state.aspect) }
        }

        override fun onVolumeChanged(volume: Float) {
            state.volume = volume
            state.muted = volume == 0f
        }

        override fun onPlaybackParametersChanged(parameters: PlaybackParameters) {
            state.speed = parameters.speed
        }

        /**
         * The only honest "the picture is up" signal ExoPlayer gives. Reported
         * against the fullscreen surface claim when there was one, because
         * that — not the load — is the interval the preview→fullscreen handoff
         * is judged on; a cold open falls back to measuring from load.
         */
        override fun onRenderedFirstFrame() {
            if (reportedFirstFrame) return
            reportedFirstFrame = true
            // The picture is up, whichever leg produced it.
            cancelPreviewFrameWatch()
            // Only a *claim's* first frame says anything about the handoff, and
            // media3 re-notifies this only when the output surface really
            // changed — which is exactly the proof FrameLivenessWatch needs to
            // stop judging first-frame latency and start judging a freeze.
            if (claimedAtMs > 0L) onClaimedSurfaceFirstFrame?.invoke()
            val (since, from) = when {
                claimedAtMs > 0L -> "sinceClaimMs" to claimedAtMs
                // The handoff's return leg. Measured because it is the same
                // output-surface transition as the claim, on hardware that
                // re-instantiates the codec for one — and until now it reported
                // nothing at all, so a preview that came back frozen or drawing
                // once a second was indistinguishable in an exported log from
                // one that came back perfectly.
                reattachedAtMs > 0L -> "sinceReattachMs" to reattachedAtMs
                else -> "sinceLoadMs" to loadedAtMs
            }
            if (from > 0L) {
                onDiagnostic?.invoke(
                    "first frame $since=${SystemClock.elapsedRealtime() - from}",
                )
            }
        }

        override fun onPlayerError(error: PlaybackException) {
            Log.e(TAG, "playback error code=${error.errorCode}", error)
            // A decode error means this device can't play the video -> mpv fallback.
            // Anything else (network/source) is transient -> let the host reconnect;
            // ExoPlayer otherwise stops in STATE_IDLE, which the stall watchdog can't
            // see (it's neither buffering nor ended).
            if (isVideoDecodeError(error)) triggerFallback() else onRecoverableError?.invoke()
        }
    }

    init {
        val httpFactory = DefaultHttpDataSource.Factory()
            .setAllowCrossProtocolRedirects(true)
            .setDefaultRequestProperties(headers)
        val mediaSourceFactory = DefaultMediaSourceFactory(context)
            .setDataSourceFactory(httpFactory)
        renderersFactory = HdrRenderersFactory(
            context,
            onDynamicRange = { label ->
                // Reported on the playback thread; marshal to main for Compose state.
                mainHandler.post {
                    decoderDynamicRange = label
                    state.dynamicRange = label
                }
            },
            onCodecName = { name ->
                // Which decoder actually got built. `enableDecoderFallback` is on
                // below, so a hardware decoder that fails to configure lands
                // silently on the platform's software one — which cannot sustain
                // 4K50 and plays the stream in slow motion while every health flag
                // still reads healthy. The name is the only place that shows.
                mainHandler.post {
                    val kind = if (isSoftwareDecoder(name)) "software" else "hardware"
                    onDiagnostic?.invoke("video decoder=$name kind=$kind")
                }
            },
        )
        renderersFactory.setEnableDecoderFallback(true)

        // Without this the media3 DefaultLoadControl defaults apply, which hold
        // the first frame back by 2.5s on every open — see [ExoBufferPolicy].
        val buffers = ExoBufferPolicy.forPreset(bufferPreset)
        val loadControl = DefaultLoadControl.Builder()
            .setBufferDurationsMs(
                buffers.minBufferMs,
                buffers.maxBufferMs,
                buffers.forPlaybackMs,
                buffers.afterRebufferMs,
            )
            .setPrioritizeTimeOverSizeThresholds(ExoBufferPolicy.PRIORITIZE_TIME_OVER_SIZE)
            .build()

        player = ExoPlayer.Builder(context, renderersFactory)
            .setMediaSourceFactory(mediaSourceFactory)
            .setLoadControl(loadControl)
            .build()
            .also {
                playerView.player = it
                it.addListener(playerListener)
            }
        state.volume = player.volume
        state.muted = player.volume == 0f
        DebugCounters.incExoEngine()
    }

    /** True (and triggers fallback) when the stream's only video track is undecodable. */
    private fun detectUnsupportedVideo(tracks: Tracks): Boolean {
        val videoGroups = tracks.groups.filter { it.type == C.TRACK_TYPE_VIDEO }
        if (videoGroups.isEmpty()) return false
        val anySupported = videoGroups.any { g ->
            (0 until g.length).any { g.isTrackSupported(it) }
        }
        if (!anySupported) {
            Log.w(TAG, "no supported video decoder for track -> mpv fallback")
            triggerFallback()
            return true
        }
        return false
    }

    private fun isVideoDecodeError(error: PlaybackException): Boolean = when (error.errorCode) {
        PlaybackException.ERROR_CODE_DECODER_INIT_FAILED,
        PlaybackException.ERROR_CODE_DECODER_QUERY_FAILED,
        PlaybackException.ERROR_CODE_DECODING_FAILED,
        PlaybackException.ERROR_CODE_DECODING_FORMAT_UNSUPPORTED,
        -> true
        else -> false
    }

    private fun triggerFallback() {
        if (fellBack) return
        fellBack = true
        onUnsupportedVideo?.invoke()
    }

    // ---- Tracks -------------------------------------------------------------

    private fun rebuildTracks(tracks: Tracks) {
        audioOverrides.clear()
        subtitleOverrides.clear()

        val audio = mutableListOf<TrackOption>()
        var selectedAudio: String? = null
        tracks.groups.filter { it.type == C.TRACK_TYPE_AUDIO }.forEachIndexed { gi, group ->
            for (ti in 0 until group.length) {
                if (!group.isTrackSupported(ti)) continue
                val id = "a$gi-$ti"
                audio.add(TrackOption(id, audioLabel(group.getTrackFormat(ti), audio.size)))
                audioOverrides[id] = TrackSelectionOverride(group.mediaTrackGroup, ti)
                if (group.isTrackSelected(ti)) selectedAudio = id
            }
        }
        state.audioTracks = audio
        state.selectedAudioId = selectedAudio ?: audio.firstOrNull()?.id

        val subs = mutableListOf(TrackOption(SUBTITLE_OFF_ID, "Off"))
        var selectedSub: String? = null
        tracks.groups.filter { it.type == C.TRACK_TYPE_TEXT }.forEachIndexed { gi, group ->
            for (ti in 0 until group.length) {
                if (!group.isTrackSupported(ti)) continue
                val id = "s$gi-$ti"
                subs.add(TrackOption(id, subtitleLabel(group.getTrackFormat(ti), subs.size - 1)))
                subtitleOverrides[id] = TrackSelectionOverride(group.mediaTrackGroup, ti)
                if (group.isTrackSelected(ti)) selectedSub = id
            }
        }
        state.subtitleTracks = subs
        state.selectedSubtitleId = selectedSub ?: SUBTITLE_OFF_ID
    }

    override fun selectAudio(id: String) {
        val override = audioOverrides[id] ?: return
        player.trackSelectionParameters = player.trackSelectionParameters.buildUpon()
            .setOverrideForType(override)
            .build()
        state.selectedAudioId = id
    }

    override fun selectSubtitle(id: String) {
        val builder = player.trackSelectionParameters.buildUpon()
        if (id == SUBTITLE_OFF_ID) {
            builder.clearOverridesOfType(C.TRACK_TYPE_TEXT)
            builder.setTrackTypeDisabled(C.TRACK_TYPE_TEXT, true)
        } else {
            val override = subtitleOverrides[id] ?: return
            builder.setTrackTypeDisabled(C.TRACK_TYPE_TEXT, false)
            builder.setOverrideForType(override)
        }
        player.trackSelectionParameters = builder.build()
        state.selectedSubtitleId = id
    }

    private fun audioLabel(format: Format, index: Int): String {
        format.label?.takeIf { it.isNotBlank() }?.let { return it }
        languageLabel(format.language)?.let { return it }
        return "Audio ${index + 1}"
    }

    private fun subtitleLabel(format: Format, index: Int): String {
        format.label?.takeIf { it.isNotBlank() }?.let { return it }
        languageLabel(format.language)?.let { return it }
        return "Subtitle ${index + 1}"
    }

    private fun languageLabel(language: String?): String? {
        val code = language?.takeIf { it.isNotBlank() && it != "und" } ?: return null
        return runCatching {
            Locale.forLanguageTag(code).getDisplayName(Locale.getDefault()).takeIf { it.isNotBlank() }
        }.getOrNull() ?: code
    }

    // ---- Stream info --------------------------------------------------------

    private fun updateStreamInfo() {
        player.videoFormat?.let { v ->
            if (v.width != Format.NO_VALUE) state.videoWidth = v.width
            if (v.height != Format.NO_VALUE) state.videoHeight = v.height
            // The container-declared rate, when present, is authoritative —
            // prefer it outright and skip/cancel the measurement below so it
            // can't later overwrite a good value with a merely-measured one.
            if (v.frameRate != Format.NO_VALUE.toFloat() && v.frameRate > 0f) {
                state.fps = v.frameRate
                if (!fpsLocked) {
                    fpsLocked = true
                    stopFrameMetadataMeasurement()
                }
            }
            state.videoCodec = codecLabel(v.sampleMimeType)
            state.dynamicRange = dynamicRangeLabel(v)
            reportStreamShape()
        }
        player.audioFormat?.let { a ->
            state.audioCodec = codecLabel(a.sampleMimeType)
            if (a.channelCount != Format.NO_VALUE) state.audioChannels = a.channelCount
        }
    }

    /**
     * Reports the shape of the stream once, as soon as the decoder has told us
     * what it is.
     *
     * The reports this instrumentation serves all describe the *same* class of
     * channel — "the 4K ones", "the 50fps ones", "the high-bitrate ones" — and
     * nothing in an exported log ever said which channel was which. Resolution,
     * rate and codec are the closest proxy for bitrate available without
     * measuring the socket, and they are all already on screen as badges.
     * Purely descriptive: no locator, no header, nothing provider-derived.
     */
    private fun reportStreamShape() {
        if (reportedStreamShape) return
        if (state.videoWidth <= 0 || state.videoHeight <= 0) return
        reportedStreamShape = true
        onDiagnostic?.invoke(
            "stream ${state.videoWidth}x${state.videoHeight} " +
                "fps=${state.fpsBadge() ?: "?"} " +
                "codec=${state.videoCodec.ifBlank { "?" }} " +
                "range=${state.dynamicRange.ifBlank { "?" }}",
        )
    }

    private fun dynamicRangeLabel(format: Format): String {
        // The decoder's output MediaFormat (when it's reported one) is authoritative —
        // it sees the in-band HDR signalling Format.colorInfo often misses.
        decoderDynamicRange?.let { return it }
        if (format.sampleMimeType == MimeTypes.VIDEO_DOLBY_VISION) return "Dolby Vision"
        val color = format.colorInfo
        if (color != null) {
            when (color.colorTransfer) {
                C.COLOR_TRANSFER_ST2084 -> return "HDR10 · PQ"
                C.COLOR_TRANSFER_HLG -> return "HLG"
            }
            if (color.colorSpace == C.COLOR_SPACE_BT2020) return "HDR · BT.2020"
        }
        return "SDR"
    }

    private fun codecLabel(mime: String?): String = when (mime) {
        MimeTypes.VIDEO_H265 -> "HEVC"
        MimeTypes.VIDEO_H264 -> "H.264"
        MimeTypes.VIDEO_DOLBY_VISION -> "Dolby Vision"
        MimeTypes.VIDEO_AV1 -> "AV1"
        MimeTypes.VIDEO_VP9 -> "VP9"
        MimeTypes.VIDEO_MPEG2 -> "MPEG-2"
        MimeTypes.AUDIO_AAC -> "AAC"
        MimeTypes.AUDIO_AC3 -> "AC-3"
        MimeTypes.AUDIO_E_AC3 -> "E-AC-3"
        MimeTypes.AUDIO_E_AC3_JOC -> "E-AC-3 JOC"
        MimeTypes.AUDIO_AC4 -> "AC-4"
        MimeTypes.AUDIO_DTS -> "DTS"
        MimeTypes.AUDIO_DTS_HD -> "DTS-HD"
        MimeTypes.AUDIO_OPUS -> "Opus"
        MimeTypes.AUDIO_MPEG -> "MP3"
        else -> mime?.substringAfter('/')?.uppercase(Locale.ROOT) ?: ""
    }

    // ---- Actions ------------------------------------------------------------

    override fun playPause() {
        if (player.isPlaying) player.pause() else player.play()
    }

    override fun seekBy(deltaMs: Long) {
        player.seekTo((player.currentPosition + deltaMs).coerceAtLeast(0))
        syncProgress()
    }

    override fun seekTo(positionMs: Long) {
        player.seekTo(positionMs.coerceAtLeast(0))
        syncProgress()
    }

    override fun setVolume(value: Float) {
        val v = value.coerceIn(0f, 1f)
        player.volume = v
        if (v > 0f) volumeBeforeMute = v
    }

    override fun toggleMute() {
        if (player.volume > 0f) {
            volumeBeforeMute = player.volume
            player.volume = 0f
        } else {
            player.volume = volumeBeforeMute.coerceAtLeast(0.1f)
        }
    }

    override fun setSpeed(value: Float) = player.setPlaybackSpeed(value)

    override fun applyAspect(mode: AspectMode) {
        val frame = contentFrame ?: return
        val videoRatio = if (state.videoHeight > 0) {
            state.videoWidth.toFloat() / state.videoHeight.toFloat()
        } else {
            16f / 9f
        }
        val ratio = when (mode) {
            AspectMode.Fit, AspectMode.Fill -> videoRatio
            AspectMode.Ratio16x9 -> 16f / 9f
            AspectMode.Ratio4x3 -> 4f / 3f
        }
        frame.setAspectRatio(ratio)
        frame.resizeMode = if (mode == AspectMode.Fill) {
            AspectRatioFrameLayout.RESIZE_MODE_ZOOM
        } else {
            AspectRatioFrameLayout.RESIZE_MODE_FIT
        }
    }

    override fun syncProgress() {
        state.positionMs = player.currentPosition.coerceAtLeast(0)
        state.durationMs = if (player.duration == C.TIME_UNSET) 0 else player.duration
        state.bufferedMs = player.bufferedPosition.coerceAtLeast(0)
        measureFps()
    }

    /**
     * Fallback: derive FPS from the rendered-frame delta over wall-clock time.
     * Only runs until [onVideoFrameMetadata] locks in a timestamp-derived
     * value — see the field doc comment for why that's preferred.
     */
    private fun measureFps() {
        if (fpsLocked) return
        val rendered = videoCounters()?.renderedOutputBufferCount ?: return
        val now = System.nanoTime()
        if (lastFpsSampleNs == 0L) {
            lastFpsSampleNs = now
            lastRenderedFrames = rendered
            return
        }
        val dtSec = (now - lastFpsSampleNs) / 1_000_000_000.0
        val dFrames = rendered - lastRenderedFrames
        if (dtSec >= 0.75 && dFrames > 0) {
            lastFpsSampleNs = now
            lastRenderedFrames = rendered
            state.fps = snapFps((dFrames / dtSec).toFloat())
        }
    }

    /**
     * Accumulates real frame-presentation-timestamp intervals (called on the
     * main thread — see the listener registration in [load]) and, once a
     * clean burst of [FRAME_SAMPLE_TARGET] is collected, locks in their
     * median as the final FPS reading and stops listening for more.
     */
    private fun onVideoFrameMetadata(presentationTimeUs: Long) {
        if (fpsLocked) return
        val last = lastFramePresentationUs
        lastFramePresentationUs = presentationTimeUs
        if (last == Long.MIN_VALUE) return
        val deltaUs = presentationTimeUs - last
        // Discard non-positive/huge gaps — seeks, the live edge jumping
        // forward, and stream discontinuities produce garbage intervals that
        // would corrupt the median. A real frame interval at any broadcast
        // rate is well under this (worst case ~24fps film -> ~42ms).
        if (deltaUs <= 0 || deltaUs > MAX_FRAME_INTERVAL_US) return
        frameIntervalsUs.add(deltaUs)
        if (frameIntervalsUs.size < FRAME_SAMPLE_TARGET) return
        val medianUs = frameIntervalsUs.sorted()[frameIntervalsUs.size / 2]
        fpsLocked = true
        state.fps = snapFps(1_000_000f / medianUs)
        stopFrameMetadataMeasurement()
    }

    private fun stopFrameMetadataMeasurement() {
        frameMetadataListener?.let { player.clearVideoFrameMetadataListener(it) }
        frameMetadataListener = null
    }

    override fun pause() {
        player.pause()
    }

    /** Resume playback (non-toggling) — a preview/adopted engine may be paused. */
    fun play() {
        player.play()
    }

    /**
     * Route video into [texture] — the embedded preview platform view. Detaches
     * the engine's own [view] first so the two never fight over the output; the
     * audio pipeline and buffer are untouched.
     */
    fun attachPreviewSurface(view: SurfaceView) {
        cancelPendingClaim()
        // This is an output-surface transition exactly like [claimViewSurface],
        // just in the other direction, so it is measured the same way: the
        // codec can be released and re-instantiated under it, and the next
        // frame then waits for an IDR. `claimedAtMs` is cleared so an engine
        // coming back from fullscreen stops reporting against its old claim.
        claimedAtMs = 0L
        reattachedAtMs = SystemClock.elapsedRealtime()
        reportedFirstFrame = false
        onDiagnostic?.invoke(
            "reattach preview surface" + (videoFrameCounters?.let { " $it" } ?: ""),
        )
        playerView.player = null
        player.setVideoSurfaceView(view)
        // Arm the return-leg watch *after* the transition is requested, so its
        // window measures the surface swap rather than the work above it.
        previewRebuildAttempted = false
        cancelPreviewFrameWatch()
        mainHandler.postDelayed(previewFrameWatch, PREVIEW_NO_FRAME_REBUILD_MS)
    }

    /**
     * Detaches [texture] as the video output if it's still the one attached
     * (ExoPlayer verifies identity itself, so this is a no-op if the surface
     * already moved elsewhere — e.g. a newer preview texture, or fullscreen's
     * own [claimViewSurface]). Called when a preview `PlatformView` disposes,
     * so the engine can't keep a reference to its destroyed `SurfaceView`.
     */
    fun clearPreviewSurface(view: SurfaceView) {
        if (released) return
        player.clearVideoSurfaceView(view)
    }

    /**
     * (Re)claim the engine's own [view] (SurfaceView-backed [PlayerView]) as the
     * video output — used when the fullscreen Activity adopts a preview-owned
     * engine. The null/reset dance forces [PlayerView] to re-take the surface
     * even though the player instance hasn't changed.
     *
     * **Deferred until the [PlayerView]'s surface actually exists.** Adoption
     * runs in `HdrPlayerActivity.onCreate`, before the Compose tree that hosts
     * [view] has been attached to a window, so the SurfaceView has no surface
     * yet — and `ExoPlayer.setVideoSurfaceView` answers that by setting the
     * video output to **null** and waiting for `surfaceCreated`. The decoder
     * therefore made *two* output transitions across the handoff (preview
     * texture → placeholder → the Activity's surface) instead of one, and on
     * any device in media3's `codecNeedsSetOutputSurfaceWorkaround` list — which
     * is thick with TV/set-top chipsets — each transition releases and
     * re-instantiates the video codec, i.e. two waits for the next IDR on a live
     * MPEG-TS stream. That is the black/stuttering "it reloads the stream when I
     * go fullscreen" beat reported on Android TV and not on phones (whose narrow
     * layout skips the preview handoff entirely).
     *
     * Waiting for `surfaceCreated` collapses it back to the single
     * texture → real-surface swap the handoff is supposed to be. The delayed
     * fallback is a safety net only: if the view is never attached (the Activity
     * finished under us) nothing else would ever claim the output back.
     */
    fun claimViewSurface() {
        // Fullscreen owns the output now; the return-leg watch would otherwise
        // rebuild a decoder mid-claim, which is the forward leg's job and its
        // own (armed, instrumented) decision.
        cancelPreviewFrameWatch()
        claimedAtMs = SystemClock.elapsedRealtime()
        reattachedAtMs = 0L
        // An output-surface change makes MediaCodecVideoRenderer re-announce its
        // first frame, which on an *adopted* engine is the only first frame that
        // describes the handoff — the preview's own already fired seconds ago.
        reportedFirstFrame = false
        // Same problem, opposite fix. An adopted engine never calls [load], so
        // its stream shape was reported during the preview — to a null sink,
        // since the preview binds none. Re-report it here rather than clearing
        // the flag and hoping for another state transition: a steadily playing
        // stream may not produce one, and the adopted handoff is exactly the
        // case the shape was added to describe. Self-guards on the size being
        // known, which for a running preview it is.
        reportedStreamShape = false
        reportStreamShape()
        val holder = (playerView.videoSurfaceView as? SurfaceView)?.holder
        if (holder == null || holder.surface?.isValid == true) {
            reportClaim("immediate", 0L)
            attachOwnSurface()
            return
        }
        cancelPendingClaim()
        claimRequestedAtMs = claimedAtMs
        val callback = object : SurfaceHolder.Callback {
            override fun surfaceCreated(created: SurfaceHolder) {
                val waited = SystemClock.elapsedRealtime() - claimRequestedAtMs
                cancelPendingClaim()
                if (!released) {
                    reportClaim("deferred", waited)
                    attachOwnSurface()
                }
            }

            override fun surfaceChanged(h: SurfaceHolder, format: Int, width: Int, height: Int) = Unit
            override fun surfaceDestroyed(h: SurfaceHolder) = Unit
        }
        pendingClaim = holder to callback
        holder.addCallback(callback)
        mainHandler.postDelayed(pendingClaimFallback, CLAIM_FALLBACK_MS)
    }

    /**
     * How the fullscreen surface was taken, and how long it took.
     *
     * `mode=deferred` with a `waitMs` approaching [CLAIM_FALLBACK_MS] is the
     * measurement that decides whether that 1 s backstop is the right bet on
     * real hardware — every number behind it so far came from an emulator
     * allocating emulated buffers. `mode=backstop` means the bet was lost and
     * the decoder took an extra output transition it didn't need.
     */
    private fun reportClaim(mode: String, waitMs: Long) {
        onDiagnostic?.invoke("surface claim mode=$mode waitMs=$waitMs")
    }

    /**
     * Point the video output at [playerView]'s own SurfaceView — the last step
     * of [claimViewSurface].
     *
     * **Both lines are load-bearing, and it is not the "extra output
     * transition" it looks like.** By the time an adopted handoff gets here
     * `playerView.player` is already `null`: [attachPreviewSurface] clears it
     * on every preview so the PlayerView stops driving the output while the
     * texture owns it. `PlayerView.setPlayer(null)` therefore early-returns on
     * an unchanged (null) player, and only the second line does any work — one
     * `setVideoSurfaceView`, one `MediaCodec.setOutputSurface`.
     *
     * Calling `player.setVideoSurfaceView(...)` directly instead would move the
     * video output and leave the PlayerView player-less, which is worse than it
     * sounds: `setPlayer(null)` ran `closeShutter()` (`keepContentOnPlayerReset`
     * defaults false) and the opaque `exo_shutter` sits *above* the SurfaceView,
     * reopened only by the PlayerView's own `onRenderedFirstFrame` — which is
     * unregistered while it has no player. The decoder would render, the frame
     * counter would advance, and the screen would stay black forever. The
     * PlayerView also owns the `AspectRatioFrameLayout` resize and the
     * `SubtitleView` cues, both of which go with it.
     */
    private fun attachOwnSurface() {
        playerView.player = null
        playerView.player = player
    }

    /** Drops a deferred [claimViewSurface] without claiming (and its timer). */
    private fun cancelPendingClaim() {
        mainHandler.removeCallbacks(pendingClaimFallback)
        val (holder, callback) = pendingClaim ?: return
        pendingClaim = null
        holder.removeCallback(callback)
    }

    override fun release() {
        if (released) return
        released = true
        cancelPreviewFrameWatch()
        cancelPendingClaim()
        playerView.player = null
        player.removeListener(playerListener)
        player.release()
        DebugCounters.decExoEngine()
    }

    /** Snap a noisy measured rate to a nearby standard frame rate for a clean readout. */
    private fun snapFps(measured: Float): Float {
        val common = floatArrayOf(
            23.976f, 24f, 25f, 29.97f, 30f, 48f, 50f, 59.94f, 60f, 100f, 120f,
        )
        for (c in common) if (kotlin.math.abs(measured - c) <= 0.6f) return c
        return Math.round(measured * 100f) / 100f
    }

    private fun subtitleMimeType(url: String): String {
        val clean = url.substringBefore('?').substringBefore('#').lowercase()
        return when {
            clean.endsWith(".vtt") || clean.endsWith(".webvtt") -> MimeTypes.TEXT_VTT
            clean.endsWith(".ssa") || clean.endsWith(".ass") -> MimeTypes.TEXT_SSA
            clean.endsWith(".ttml") || clean.endsWith(".dfxp") -> MimeTypes.APPLICATION_TTML
            else -> MimeTypes.APPLICATION_SUBRIP
        }
    }

    companion object {
        private const val TAG = "iptvs.exo"

        // ~30 consecutive frame intervals is enough for a stable median even
        // with a stray dropped/duplicated frame or two mixed in, while still
        // converging in roughly a second at typical broadcast rates.
        private const val FRAME_SAMPLE_TARGET = 30

        // 200ms (5fps) — no real broadcast video runs this slow; a gap wider
        // than this between two frames is a seek/live-edge jump/stall.
        private const val MAX_FRAME_INTERVAL_US = 200_000L

        // Backstop for a deferred [claimViewSurface]: comfortably longer than
        // the frame or two an attached SurfaceView takes to produce its
        // surface, short enough that a view which never attaches doesn't leave
        // the adopted engine rendering nowhere. See claimViewSurface.
        private const val CLAIM_FALLBACK_MS = 1_000L

        // The return leg's no-frame budget. Matches the forward leg's
        // HANDOFF_NO_FRAME_STALL_MS (3 s) and for the same reason: a first
        // frame after an output-surface transition waits for the next IDR,
        // which on broadcast MPEG-TS is a whole GOP. Measured healthy returns
        // land at tens of milliseconds to under a second, so 3 s is generous
        // on purpose — a false rebuild costs another codec release, another
        // IDR wait and a catch-up against a running audio clock, while a late
        // one costs only latency.
        private const val PREVIEW_NO_FRAME_REBUILD_MS = 3_000L

        // How long after the rebuild to check whether it worked. Log-only:
        // the point is that a preview which stays black leaves evidence
        // instead of silence.
        private const val PREVIEW_REBUILD_VERIFY_MS = 3_000L
    }
}
