package com.example.iptvs.player

import android.content.Context
import android.net.Uri
import android.util.Log
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
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView
import java.util.Locale

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
    private val onUnsupportedVideo: () -> Unit,
) : PlaybackEngine {

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
    // Measured-FPS sampling: many IPTV streams don't carry frameRate in their
    // Format (stays NO_VALUE), so we derive it from the rendered-frame counter.
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
            if (isVideoDecodeError(error)) triggerFallback()
        }
    }

    init {
        val httpFactory = DefaultHttpDataSource.Factory()
            .setAllowCrossProtocolRedirects(true)
            .setDefaultRequestProperties(headers)
        val mediaSourceFactory = DefaultMediaSourceFactory(context)
            .setDataSourceFactory(httpFactory)
        val renderersFactory = DefaultRenderersFactory(context)
            .setEnableDecoderFallback(true)

        player = ExoPlayer.Builder(context, renderersFactory)
            .setMediaSourceFactory(mediaSourceFactory)
            .build()
            .also {
                playerView.player = it
                it.addListener(playerListener)
            }
        state.volume = player.volume
        state.muted = player.volume == 0f
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
        onUnsupportedVideo()
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
            if (v.frameRate != Format.NO_VALUE.toFloat() && v.frameRate > 0f) state.fps = v.frameRate
            state.videoCodec = codecLabel(v.sampleMimeType)
            state.dynamicRange = dynamicRangeLabel(v)
        }
        player.audioFormat?.let { a ->
            state.audioCodec = codecLabel(a.sampleMimeType)
            if (a.channelCount != Format.NO_VALUE) state.audioChannels = a.channelCount
        }
    }

    private fun dynamicRangeLabel(format: Format): String {
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

    /** Derive FPS from the rendered-frame delta when the Format doesn't report it. */
    private fun measureFps() {
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

    override fun pause() {
        player.pause()
    }

    override fun release() {
        playerView.player = null
        player.removeListener(playerListener)
        player.release()
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
    }
}
