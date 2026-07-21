package com.gchofficial.iptvs.player

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.TextureView
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
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.exoplayer.video.VideoFrameMetadataListener
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView
import java.util.Locale

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
    /** Below this much buffered media the loader resumes filling. */
    const val MIN_BUFFER_MS = 15_000

    /** Ceiling on how far ahead the loader buffers. */
    const val MAX_BUFFER_MS = 50_000

    /** Buffered media required before playback *starts* (media3 default: 2500). */
    const val BUFFER_FOR_PLAYBACK_MS = 1_000

    /** Buffered media required to resume after an underrun (media3 default: 5000). */
    const val BUFFER_FOR_PLAYBACK_AFTER_REBUFFER_MS = 2_000

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
) : PlaybackEngine {

    // Rebindable callbacks (not constructor params) because the engine can outlive
    // its host: the shared preview engine is adopted by the fullscreen Activity,
    // which must route these to *its* handlers (mpv fallback / live reconnect) and
    // hand them back to the preview's on exit. See [SharedEngine].
    var onUnsupportedVideo: (() -> Unit)? = null
    var onRecoverableError: (() -> Unit)? = null
    var onVideoSizeChanged: ((Int, Int) -> Unit)? = null

    private val playerView = PlayerView(context).apply {
        useController = false
        resizeMode = AspectRatioFrameLayout.RESIZE_MODE_FIT
        setShowBuffering(PlayerView.SHOW_BUFFERING_NEVER)
        keepScreenOn = true
    }
    private val contentFrame: AspectRatioFrameLayout? =
        playerView.findViewById(androidx.media3.ui.R.id.exo_content_frame)

    private val player: ExoPlayer
    private val audioOverrides = mutableMapOf<String, TrackSelectionOverride>()
    private val subtitleOverrides = mutableMapOf<String, TrackSelectionOverride>()
    private var volumeBeforeMute = 1f
    private var fellBack = false
    // Guards release() against a double-decrement of DebugCounters (and a
    // clearPreviewTexture call landing after release, e.g. a disposing preview
    // platform view racing the shared engine's own teardown).
    private var released = false
    private val mainHandler = Handler(Looper.getMainLooper())
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

    override fun load(url: String, subtitles: List<SubtitleSpec>) {
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
        val renderersFactory = HdrRenderersFactory(context) { label ->
            // Reported on the playback thread; marshal to main for Compose state.
            mainHandler.post {
                decoderDynamicRange = label
                state.dynamicRange = label
            }
        }.setEnableDecoderFallback(true)

        // Without this the media3 DefaultLoadControl defaults apply, which hold
        // the first frame back by 2.5s on every open — see [ExoBufferPolicy].
        val loadControl = DefaultLoadControl.Builder()
            .setBufferDurationsMs(
                ExoBufferPolicy.MIN_BUFFER_MS,
                ExoBufferPolicy.MAX_BUFFER_MS,
                ExoBufferPolicy.BUFFER_FOR_PLAYBACK_MS,
                ExoBufferPolicy.BUFFER_FOR_PLAYBACK_AFTER_REBUFFER_MS,
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
        }
        player.audioFormat?.let { a ->
            state.audioCodec = codecLabel(a.sampleMimeType)
            if (a.channelCount != Format.NO_VALUE) state.audioChannels = a.channelCount
        }
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
        val rendered = player.videoDecoderCounters?.renderedOutputBufferCount ?: return
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
    fun attachPreviewTexture(texture: TextureView) {
        playerView.player = null
        player.setVideoTextureView(texture)
    }

    /**
     * Detaches [texture] as the video output if it's still the one attached
     * (ExoPlayer verifies identity itself, so this is a no-op if the surface
     * already moved elsewhere — e.g. a newer preview texture, or fullscreen's
     * own [claimViewSurface]). Called when a preview `PlatformView` disposes,
     * so the engine can't keep a reference to its destroyed `TextureView`.
     */
    fun clearPreviewTexture(texture: TextureView) {
        if (released) return
        player.clearVideoTextureView(texture)
    }

    /**
     * (Re)claim the engine's own [view] (SurfaceView-backed [PlayerView]) as the
     * video output — used when the fullscreen Activity adopts a preview-owned
     * engine. The null/reset dance forces [PlayerView] to re-take the surface
     * even though the player instance hasn't changed.
     */
    fun claimViewSurface() {
        playerView.player = null
        playerView.player = player
    }

    override fun release() {
        if (released) return
        released = true
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
    }
}
