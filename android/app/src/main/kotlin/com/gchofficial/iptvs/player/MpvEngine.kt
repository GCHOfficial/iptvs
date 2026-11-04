package com.gchofficial.iptvs.player

import android.content.Context
import android.graphics.PixelFormat
import android.view.SurfaceView
import android.view.View

/**
 * Fallback [PlaybackEngine] backed by libmpv (see [MpvController]). Used only when
 * ExoPlayer can't decode the video track (Dolby Vision Profile 5 on non-DV
 * hardware). Renders into a plain [SurfaceView]; mpv tone-maps HDR/DV→SDR.
 */
class MpvEngine(
    context: Context,
    state: PlayerUiState,
    headers: Map<String, String>,
    post: (() -> Unit) -> Unit,
    /**
     * Per-source buffering, as `cache-secs`.
     *
     * This is the DV-P5 fallback surface, and it was the one mpv path in the
     * app that ignored the setting while the embedded, preview,
     * Windows-native and Linux-native ones all honoured it — a channel that
     * fell back would quietly buffer differently from every other channel on
     * the same source.
     */
    bufferPreset: BufferPreset = BufferPreset.NORMAL,
    /**
     * Short, credential-free notes for the host's exportable diagnostics log,
     * mirroring [ExoPlayerEngine.onDiagnostic].
     *
     * It exists for **parity**: the Exo path reports what audio the stream
     * carried and which decoder it built, so an export from a session that fell
     * back to mpv used to go quiet on exactly the subject the fallback was
     * decided on. Now both engines name the audio they opened.
     */
    onDiagnostic: ((String) -> Unit)? = null,
) : PlaybackEngine {

    private val controller = MpvController(
        context,
        state,
        post,
        cacheSecs = bufferPreset.mpvCacheSecs,
        onDiagnostic = onDiagnostic,
    )
    // MpvController.destroy() is itself idempotent, but this also guards
    // DebugCounters against a double-decrement if release() is called twice.
    private var released = false

    override val view: View = SurfaceView(context).apply {
        // 10-bit surface reduces banding for the tone-mapped SDR output.
        holder.setFormat(PixelFormat.RGBA_1010102)
        holder.addCallback(controller)
        keepScreenOn = true
    }

    init {
        controller.create(headers)
        DebugCounters.incMpvEngine()
    }

    override fun load(url: String, subtitles: List<SubtitleSpec>) =
        controller.load(url, subtitles)

    override fun playPause() = controller.playPause()
    override fun seekBy(deltaMs: Long) = controller.seekBy(deltaMs)
    override fun seekTo(positionMs: Long) = controller.seekTo(positionMs)
    override fun setVolume(value: Float) = controller.setVolume(value)
    override fun toggleMute() = controller.toggleMute()
    override fun setSpeed(value: Float) = controller.setSpeed(value)
    override fun selectAudio(id: String) = controller.selectAudio(id)
    override fun selectSubtitle(id: String) = controller.selectSubtitle(id)
    override fun applyAspect(mode: AspectMode) = controller.applyAspect(mode)
    override fun pause() = controller.pause()

    // Both are latched mpv property events, never a blocking read — see
    // [MpvController]'s threading rules.
    override fun bufferedAheadMs(): Long = controller.bufferedAheadMs()
    override fun mediaPositionMs(): Long = controller.mediaPositionMs()

    override fun release() {
        if (released) return
        released = true
        controller.destroy()
        DebugCounters.decMpvEngine()
    }
}
