package com.example.iptvs.player

import android.view.View

/** A sideloaded (external) subtitle track passed from Dart. */
data class SubtitleSpec(val url: String, val label: String, val language: String)

/**
 * A pluggable playback engine behind the native player's Compose overlay. Both
 * implementations drive the same [PlayerUiState] and respond to the same actions,
 * so the overlay is engine-agnostic:
 *
 * - [ExoPlayerEngine] (default) — MediaCodec hardware decode into a SurfaceView,
 *   giving true HDR (HDR10/HDR10+/HLG/DV-P8) on capable devices/displays.
 * - [MpvEngine] (fallback) — libmpv/libplacebo, used when ExoPlayer can't decode
 *   the video track (chiefly Dolby Vision Profile 5 on non-DV hardware); plays it
 *   tone-mapped to SDR.
 */
interface PlaybackEngine {
    /** The Android view that renders video; hosted by Compose via `AndroidView`. */
    val view: View

    fun load(url: String, subtitles: List<SubtitleSpec>)

    fun playPause()
    fun seekBy(deltaMs: Long)
    fun seekTo(positionMs: Long)
    fun setVolume(value: Float)
    fun toggleMute()
    fun setSpeed(value: Float)
    fun selectAudio(id: String)
    fun selectSubtitle(id: String)
    fun applyAspect(mode: AspectMode)

    /** Jump a live stream to the live edge. No-op for VOD / engines without it. */
    fun goLive() {}

    fun pause()
    fun release()

    /** Poll-driven progress refresh (ExoPlayer). mpv pushes via observers, so no-op. */
    fun syncProgress() {}
}
