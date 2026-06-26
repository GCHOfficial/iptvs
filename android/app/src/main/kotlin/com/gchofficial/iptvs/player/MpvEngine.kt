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
) : PlaybackEngine {

    private val controller = MpvController(context, state, post)

    override val view: View = SurfaceView(context).apply {
        // 10-bit surface reduces banding for the tone-mapped SDR output.
        holder.setFormat(PixelFormat.RGBA_1010102)
        holder.addCallback(controller)
        keepScreenOn = true
    }

    init {
        controller.create(headers)
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
    override fun release() = controller.destroy()
}
