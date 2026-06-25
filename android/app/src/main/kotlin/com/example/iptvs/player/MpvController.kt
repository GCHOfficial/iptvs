package com.example.iptvs.player

import android.content.Context
import android.util.Log
import android.view.SurfaceHolder
import dev.jdtech.mpv.MPVLib
import java.util.Locale

/**
 * Wraps libmpv (gpu-next / libplacebo) for the native HDR player — the same engine
 * as the Windows path. Unlike ExoPlayer/MediaCodec, mpv can software-reshape Dolby
 * Vision Profile 5 (single-layer, no HDR10 base) and tone-map to the display, so
 * DV titles render on non-DV hardware (e.g. Samsung Galaxy).
 *
 * Owns the MPVLib instance, mirrors mpv property changes into [PlayerUiState] (on
 * the main thread via [post]), and exposes the playback actions the Compose overlay
 * invokes through [PlayerCallbacks].
 */
class MpvController(
    private val context: Context,
    private val state: PlayerUiState,
    private val post: (() -> Unit) -> Unit,
    private val onHdrChanged: (Boolean) -> Unit = {},
) : MPVLib.EventObserver, SurfaceHolder.Callback {

    private var mpv: MPVLib? = null
    private var pendingSubtitles: List<SubtitleSpec> = emptyList()

    fun create(headers: Map<String, String>) {
        val instance = MPVLib.create(context) ?: run {
            Log.e(TAG, "MPVLib.create returned null")
            return
        }
        mpv = instance
        with(instance) {
            setOptionString("config", "no")
            setOptionString("idle", "yes")
            setOptionString("force-window", "no")
            setOptionString("vo", "gpu-next")
            setOptionString("gpu-context", "android")
            // Software decode: this engine only runs for video ExoPlayer couldn't
            // hardware-decode (chiefly Dolby Vision Profile 5). MediaCodec mangles DV
            // P5 colors; software decode gives libplacebo (built with libdovi) clean
            // frames to reshape, so DV renders correctly instead of green/magenta.
            setOptionString("hwdec", "no")
            setOptionString("vid", "auto")
            // HDR / Dolby Vision: libplacebo reshapes DV, then tone-maps HDR→SDR for
            // the display. We deliberately do NOT set target-colorspace-hint: a custom
            // Android SurfaceView doesn't reliably switch the panel into true HDR, and
            // with the hint on mpv passes PQ through unchanged → a dark picture. A
            // high-quality tone-map looks correct and bright instead.
            setOptionString("tone-mapping", "auto")
            setOptionString("hdr-compute-peak", "yes")
            setOptionString("gamut-mapping-mode", "perceptual")
            // Housekeeping: never read user config, never touch yt-dlp, keep quiet.
            // Silence libav's non-fatal decode/demux chatter (alternating
            // `hevc: Could not find ref with POC …` etc. from poorly-muxed DV P5)
            // at the source so it doesn't flood the shared av_log callback that
            // media_kit relays into the Dart diagnostics log.
            setOptionString("msg-level", "ffmpeg=fatal")
            setOptionString("ytdl", "no")
            setOptionString("save-position-on-quit", "no")
            setOptionString("sub-auto", "no")
            applyHeaders(this, headers)
            init()
        }
        instance.addObserver(this)
        observeProperties(instance)
    }

    private fun applyHeaders(mpv: MPVLib, headers: Map<String, String>) {
        if (headers.isEmpty()) return
        headers.entries.firstOrNull { it.key.equals("user-agent", true) }?.let {
            mpv.setOptionString("user-agent", it.value)
        }
        headers.entries.firstOrNull {
            it.key.equals("referer", true) || it.key.equals("referrer", true)
        }?.let { mpv.setOptionString("referrer", it.value) }
        val rest = headers.entries.filter {
            !it.key.equals("user-agent", true) &&
                !it.key.equals("referer", true) &&
                !it.key.equals("referrer", true)
        }
        if (rest.isNotEmpty()) {
            mpv.setOptionString(
                "http-header-fields",
                rest.joinToString(",") { "${it.key}: ${it.value}" },
            )
        }
    }

    private fun observeProperties(mpv: MPVLib) {
        mpv.observeProperty("time-pos", MPVLib.MpvFormat.MPV_FORMAT_DOUBLE)
        mpv.observeProperty("duration", MPVLib.MpvFormat.MPV_FORMAT_DOUBLE)
        mpv.observeProperty("demuxer-cache-time", MPVLib.MpvFormat.MPV_FORMAT_DOUBLE)
        mpv.observeProperty("pause", MPVLib.MpvFormat.MPV_FORMAT_FLAG)
        mpv.observeProperty("paused-for-cache", MPVLib.MpvFormat.MPV_FORMAT_FLAG)
        mpv.observeProperty("eof-reached", MPVLib.MpvFormat.MPV_FORMAT_FLAG)
        mpv.observeProperty("volume", MPVLib.MpvFormat.MPV_FORMAT_INT64)
        mpv.observeProperty("mute", MPVLib.MpvFormat.MPV_FORMAT_FLAG)
        mpv.observeProperty("speed", MPVLib.MpvFormat.MPV_FORMAT_DOUBLE)
        mpv.observeProperty("track-list/count", MPVLib.MpvFormat.MPV_FORMAT_INT64)
    }

    fun load(url: String, subtitles: List<SubtitleSpec>) {
        pendingSubtitles = subtitles
        mpv?.command(arrayOf("loadfile", url))
    }

    // ---- Playback actions (invoked from the Compose overlay) ----------------

    fun playPause() = mpv?.command(arrayOf("cycle", "pause")) ?: Unit
    fun seekBy(deltaMs: Long) =
        mpv?.command(arrayOf("seek", (deltaMs / 1000.0).toString(), "relative")) ?: Unit
    fun seekTo(positionMs: Long) =
        mpv?.command(arrayOf("seek", (positionMs / 1000.0).toString(), "absolute")) ?: Unit
    fun setVolume(value: Float) {
        mpv?.setPropertyInt("volume", (value.coerceIn(0f, 1f) * 100).toInt())
    }
    fun toggleMute() = mpv?.command(arrayOf("cycle", "mute")) ?: Unit
    fun setSpeed(value: Float) = mpv?.setPropertyDouble("speed", value.toDouble()) ?: Unit

    fun selectAudio(id: String) {
        id.toIntOrNull()?.let { mpv?.setPropertyInt("aid", it) }
    }

    fun selectSubtitle(id: String) {
        if (id == SUBTITLE_OFF_ID) {
            mpv?.setPropertyString("sid", "no")
        } else {
            id.toIntOrNull()?.let { mpv?.setPropertyInt("sid", it) }
        }
    }

    /** Applies the aspect/zoom mode — mirrors the Windows `_cycleNativeAspect` mapping. */
    fun applyAspect(mode: AspectMode) {
        val mpv = mpv ?: return
        when (mode) {
            AspectMode.Fit -> {
                mpv.setPropertyString("panscan", "0")
                mpv.setPropertyString("video-aspect-override", "-1")
            }
            AspectMode.Fill -> {
                mpv.setPropertyString("video-aspect-override", "-1")
                mpv.setPropertyString("panscan", "1.0")
            }
            AspectMode.Ratio16x9 -> {
                mpv.setPropertyString("panscan", "0")
                mpv.setPropertyString("video-aspect-override", "16:9")
            }
            AspectMode.Ratio4x3 -> {
                mpv.setPropertyString("panscan", "0")
                mpv.setPropertyString("video-aspect-override", "4:3")
            }
        }
    }

    // ---- Surface lifecycle --------------------------------------------------

    override fun surfaceCreated(holder: SurfaceHolder) {
        mpv?.attachSurface(holder.surface)
        // Let mpv create its renderer now that there's a surface to draw into.
        mpv?.setOptionString("force-window", "yes")
        mpv?.setPropertyString("vo", "gpu-next")
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
        mpv?.setPropertyString("android-surface-size", "${width}x$height")
    }

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        mpv?.setPropertyString("vo", "null")
        mpv?.setOptionString("force-window", "no")
        mpv?.detachSurface()
    }

    fun pause() = mpv?.setPropertyBoolean("pause", true) ?: Unit

    fun destroy() {
        val instance = mpv ?: return
        mpv = null
        runCatching {
            instance.removeObserver(this)
            instance.command(arrayOf("stop"))
            instance.detachSurface()
            instance.destroy()
        }
    }

    // ---- Property/event observation (mpv thread → main thread) ---------------

    override fun eventProperty(property: String) {}

    override fun eventProperty(property: String, value: Long) = post {
        when (property) {
            "volume" -> {
                state.volume = (value / 100f).coerceIn(0f, 1f)
            }
            "track-list/count" -> refreshTracks()
        }
    }

    override fun eventProperty(property: String, value: Double) = post {
        when (property) {
            "time-pos" -> state.positionMs = (value * 1000).toLong().coerceAtLeast(0)
            "duration" -> state.durationMs = (value * 1000).toLong().coerceAtLeast(0)
            "demuxer-cache-time" -> if (value >= 0) {
                state.bufferedMs = (value * 1000).toLong()
            }
            "speed" -> state.speed = value.toFloat()
        }
    }

    override fun eventProperty(property: String, value: Boolean) = post {
        when (property) {
            "pause" -> state.isPlaying = !value
            "paused-for-cache" -> state.isBuffering = value
            "eof-reached" -> state.ended = value
            "mute" -> state.muted = value
        }
    }

    override fun eventProperty(property: String, value: String) {}

    override fun event(eventId: Int) {
        when (eventId) {
            MPVLib.MpvEvent.MPV_EVENT_FILE_LOADED -> post {
                addPendingSubtitles()
                refreshMediaInfo()
                refreshTracks()
            }
            MPVLib.MpvEvent.MPV_EVENT_VIDEO_RECONFIG,
            MPVLib.MpvEvent.MPV_EVENT_AUDIO_RECONFIG,
            -> post { refreshMediaInfo() }
            MPVLib.MpvEvent.MPV_EVENT_END_FILE -> post { state.ended = true }
        }
    }

    private fun addPendingSubtitles() {
        val mpv = mpv ?: return
        for (sub in pendingSubtitles) {
            if (sub.url.isBlank()) continue
            mpv.command(arrayOf("sub-add", sub.url, "auto", sub.label, sub.language))
        }
        pendingSubtitles = emptyList()
    }

    private fun refreshMediaInfo() {
        val mpv = mpv ?: return
        (mpv.getPropertyInt("dwidth") ?: mpv.getPropertyInt("width"))?.let {
            if (it > 0) state.videoWidth = it
        }
        (mpv.getPropertyInt("dheight") ?: mpv.getPropertyInt("height"))?.let {
            if (it > 0) state.videoHeight = it
        }
        (mpv.getPropertyDouble("container-fps")
            ?: mpv.getPropertyDouble("estimated-vf-fps"))?.let {
            if (it > 0) state.fps = it.toFloat()
        }
        mpv.getPropertyString("video-format")?.let { state.videoCodec = codecLabel(it) }
        mpv.getPropertyString("audio-codec-name")?.let { state.audioCodec = codecLabel(it) }
        mpv.getPropertyInt("audio-params/channel-count")?.let { state.audioChannels = it }
        val range = dynamicRangeLabel(mpv)
        state.dynamicRange = range
        onHdrChanged(range.isHdr())
    }

    private fun String.isHdr(): Boolean =
        contains("HDR") || contains("Dolby", ignoreCase = true) || contains("HLG")

    private fun dynamicRangeLabel(mpv: MPVLib): String {
        val gamma = mpv.getPropertyString("video-params/gamma").orEmpty().lowercase(Locale.ROOT)
        val matrix = mpv.getPropertyString("video-params/colormatrix").orEmpty().lowercase(Locale.ROOT)
        val primaries = mpv.getPropertyString("video-params/primaries").orEmpty().lowercase(Locale.ROOT)
        return when {
            matrix.contains("dolby") || gamma.contains("dolby") -> "Dolby Vision"
            gamma == "pq" -> "HDR10 · PQ"
            gamma == "hlg" -> "HLG"
            primaries.contains("2020") -> "HDR · BT.2020"
            gamma.isNotEmpty() -> "SDR"
            else -> ""
        }
    }

    private fun refreshTracks() {
        val mpv = mpv ?: return
        val count = mpv.getPropertyInt("track-list/count") ?: return
        val currentAid = mpv.getPropertyInt("aid")
        val currentSid = mpv.getPropertyInt("sid")

        val audio = mutableListOf<TrackOption>()
        val subs = mutableListOf(TrackOption(SUBTITLE_OFF_ID, "Off"))

        for (i in 0 until count) {
            val type = mpv.getPropertyString("track-list/$i/type") ?: continue
            val id = mpv.getPropertyInt("track-list/$i/id") ?: continue
            val title = mpv.getPropertyString("track-list/$i/title")
            val lang = mpv.getPropertyString("track-list/$i/lang")
            when (type) {
                "audio" -> audio.add(TrackOption(id.toString(), trackLabel(title, lang, "Audio", audio.size)))
                "sub" -> subs.add(TrackOption(id.toString(), trackLabel(title, lang, "Subtitle", subs.size - 1)))
            }
        }

        state.audioTracks = audio
        state.selectedAudioId = currentAid?.toString() ?: audio.firstOrNull()?.id
        state.subtitleTracks = subs
        state.selectedSubtitleId = currentSid?.toString() ?: SUBTITLE_OFF_ID
    }

    private fun trackLabel(title: String?, lang: String?, fallback: String, index: Int): String {
        title?.takeIf { it.isNotBlank() }?.let { return it }
        languageLabel(lang)?.let { return it }
        return "$fallback ${index + 1}"
    }

    private fun languageLabel(lang: String?): String? {
        val code = lang?.takeIf { it.isNotBlank() && it != "und" } ?: return null
        return runCatching {
            Locale.forLanguageTag(code).getDisplayName(Locale.getDefault()).takeIf { it.isNotBlank() }
        }.getOrNull() ?: code
    }

    private fun codecLabel(format: String): String = when (format.lowercase(Locale.ROOT)) {
        "hevc", "h265" -> "HEVC"
        "h264", "avc" -> "H.264"
        "av1" -> "AV1"
        "vp9" -> "VP9"
        "mpeg2video" -> "MPEG-2"
        "aac" -> "AAC"
        "ac3" -> "AC-3"
        "eac3" -> "E-AC-3"
        "truehd" -> "TrueHD"
        "dts" -> "DTS"
        "flac" -> "FLAC"
        "opus" -> "Opus"
        "mp3" -> "MP3"
        else -> format.uppercase(Locale.ROOT)
    }

    companion object {
        private const val TAG = "iptvs.mpv"
    }
}
