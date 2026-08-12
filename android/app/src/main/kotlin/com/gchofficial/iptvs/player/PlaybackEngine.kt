package com.gchofficial.iptvs.player

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

    fun pause()
    fun release()

    /** Poll-driven progress refresh (ExoPlayer). mpv pushes via observers, so no-op. */
    fun syncProgress() {}

    /**
     * Frames the video renderer has actually put on screen since this engine
     * loaded, or **-1** when the engine can't report it (no video renderer, or
     * no counter of its own).
     *
     * The liveness signal behind [FrameLivenessWatch]: every other health flag
     * an engine exposes is a *claim*, and the failure mode that matters here is
     * the one where the claim and the screen disagree. -1 is inert by
     * construction, so an engine that doesn't implement this simply keeps the
     * old buffering/ended-only watchdog.
     */
    val renderedFrameCount: Int get() = -1

    /**
     * Re-create the **video decoder** against the output surface it is already
     * pointed at, keeping everything else running: the demuxer, the loaded
     * buffer, the audio pipeline, and — the one that matters on
     * single-connection provider accounts — the open HTTP connection.
     *
     * This is the recovery for a decoder that survived the preview→fullscreen
     * output-surface switch in name only (see [FrameLivenessWatch]). It is the
     * same thing media3 does for itself when it *knows* a chipset mishandles
     * `MediaCodec.setOutputSurface` (`codecNeedsSetOutputSurfaceWorkaround`) —
     * a device list that is, necessarily, always missing someone.
     *
     * Returns false when the engine has no such lever (libmpv, a released
     * player), leaving the caller's reload as the only recovery.
     */
    fun rebuildVideoDecoder(): Boolean = false

    /**
     * Renderer counters for a stall report — **credential-free by
     * construction**, they are frame tallies — or null when the engine keeps
     * none.
     *
     * They separate the two ways a picture stops while the engine claims to be
     * playing, which want opposite answers and are identical from the outside:
     * frames being *decoded and thrown away* to catch up (dropped/toKeyframe
     * climbing) is a stream/device that can't keep up, while a decoder that has
     * simply stopped emitting (every tally flat) is the surface-switch failure.
     * `inits` counts decoder instantiations, so it also says whether an output
     * change re-created the codec or was applied in place.
     */
    val videoFrameCounters: String? get() = null
}
