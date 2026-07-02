package com.gchofficial.iptvs.player

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.TextureView
import androidx.media3.common.util.UnstableApi
import androidx.media3.ui.AspectRatioFrameLayout

/**
 * Process-global holder for the single shared ExoPlayer engine behind the live
 * preview → fullscreen "seamless handoff". The preview (a Flutter platform view)
 * starts the engine; when the user goes fullscreen on the same stream,
 * `HdrPlayerActivity` *adopts* the running engine — re-pointing only its video
 * output at the Activity's surface — instead of reloading the stream. Audio and
 * the demuxer buffer are never interrupted, and only one provider connection
 * ever exists (single-connection IPTV accounts care).
 *
 * All access is main-thread only: method-channel handlers, ExoPlayer listeners
 * (built on the main looper) and Activity lifecycle all run there.
 */
@UnstableApi
object SharedEngine {
    private const val TAG = "iptvs.shared"

    var engine: ExoPlayerEngine? = null
        private set
    var uiState: PlayerUiState? = null
        private set

    /** URL the engine currently plays; fullscreen adoption is keyed on it. */
    var url: String? = null
        private set
    private var headers: Map<String, String> = emptyMap()

    /** True while `HdrPlayerActivity` owns the engine's video output. */
    var adoptedByFullscreen = false
        private set

    /** Set when Dart asked to stop while fullscreen owned the engine — honoured
     *  at [fullscreenDetached] instead of releasing under the Activity. */
    private var stopAfterDetach = false

    // The preview platform view's surface, when one is on screen.
    private var previewTexture: TextureView? = null
    private var previewAspectFrame: AspectRatioFrameLayout? = null

    // Dart-facing preview callbacks (installed by MainActivity per session).
    var onPreviewError: ((String) -> Unit)? = null
    var onPreviewUnsupported: (() -> Unit)? = null
    var onPreviewLost: (() -> Unit)? = null

    private val mainHandler = Handler(Looper.getMainLooper())

    /** Open [streamUrl] for preview, reusing the running engine when the headers
     *  match (they're per-source, so channel zapping stays on one instance). */
    fun openPreview(
        context: Context,
        streamUrl: String,
        requestHeaders: Map<String, String>,
        muted: Boolean,
    ) {
        if (adoptedByFullscreen) {
            // Dart flows never preview while fullscreen owns the engine; refuse
            // rather than steal the surface out from under the Activity.
            Log.w(TAG, "openPreview ignored: engine adopted by fullscreen")
            return
        }
        val existing = engine
        if (existing != null && headers == requestHeaders) {
            url = streamUrl
            bindPreviewCallbacks(existing)
            previewTexture?.let { existing.attachPreviewTexture(it) }
            existing.load(streamUrl, emptyList())
        } else {
            existing?.release()
            engine = null
            // Headers are baked into the engine's HTTP data-source factory, so a
            // different set (source switch) needs a fresh engine.
            val state = PlayerUiState(title = "", isLive = true)
            val fresh = ExoPlayerEngine(context.applicationContext, state, requestHeaders)
            bindPreviewCallbacks(fresh)
            engine = fresh
            uiState = state
            headers = requestHeaders
            url = streamUrl
            previewTexture?.let { fresh.attachPreviewTexture(it) }
            fresh.load(streamUrl, emptyList())
        }
        engine?.setVolume(if (muted) 0f else 1f)
        engine?.play()
    }

    private fun bindPreviewCallbacks(target: ExoPlayerEngine) {
        target.onUnsupportedVideo = { handlePreviewUnsupported() }
        target.onRecoverableError = { onPreviewError?.invoke("stream error") }
        target.onVideoSizeChanged = { w, h -> applyPreviewAspect(w, h) }
    }

    private fun handlePreviewUnsupported() {
        // Fires from inside a player listener; releasing the player there is
        // unsafe, so hop off the callstack first.
        mainHandler.post {
            invalidate()
            onPreviewUnsupported?.invoke()
        }
    }

    /** Release and forget the engine (preview stopped / video unsupported). */
    fun invalidate() {
        engine?.release()
        engine = null
        uiState = null
        url = null
        headers = emptyMap()
        adoptedByFullscreen = false
        stopAfterDetach = false
    }

    fun stopPreview() {
        if (adoptedByFullscreen) {
            // Racy exit path (Dart's stop can land before the Activity's
            // onDestroy): silence now, release once the Activity lets go.
            stopAfterDetach = true
            engine?.pause()
            return
        }
        invalidate()
    }

    // Pause/play/volume act on the engine regardless of adoption: Dart only calls
    // them around handoff boundaries, where they're meant for this stream anyway.
    fun pausePreview() {
        engine?.pause()
    }

    fun playPreview() {
        engine?.play()
    }

    fun setPreviewVolume(volume: Float) {
        engine?.setVolume(volume)
    }

    /**
     * Fullscreen adoption: hands out the engine + its state when [streamUrl]
     * matches the running preview, re-claiming the engine's own view surface.
     * Null → the caller starts a fresh engine (normal cold open).
     */
    fun adoptForFullscreen(streamUrl: String): Pair<ExoPlayerEngine, PlayerUiState>? {
        val e = engine ?: return null
        val s = uiState ?: return null
        if (streamUrl != url) {
            Log.w(TAG, "adopt refused: fullscreen URL differs from preview")
            return null
        }
        adoptedByFullscreen = true
        stopAfterDetach = false
        e.claimViewSurface()
        Log.i(TAG, "fullscreen adopted the shared preview engine")
        return e to s
    }

    /**
     * Fullscreen exited: hand the video output back to the preview texture (when
     * one is still on screen) and restore the preview's callbacks. The engine
     * keeps playing across the switch unless a stop was requested mid-adoption.
     */
    fun fullscreenDetached() {
        if (!adoptedByFullscreen) return
        adoptedByFullscreen = false
        if (stopAfterDetach) {
            invalidate()
            return
        }
        val e = engine ?: return
        bindPreviewCallbacks(e)
        previewTexture?.let { e.attachPreviewTexture(it) }
    }

    /** Fullscreen swapped the adopted engine for mpv (unsupported video): the
     *  shared engine is dead; tell Dart so the preview side resets. */
    fun invalidateFromFullscreen() {
        invalidate()
        onPreviewLost?.invoke()
    }

    fun registerPreviewView(texture: TextureView, aspectFrame: AspectRatioFrameLayout) {
        previewTexture = texture
        previewAspectFrame = aspectFrame
        val s = uiState
        if (s != null && s.videoWidth > 0 && s.videoHeight > 0) {
            aspectFrame.setAspectRatio(s.videoWidth.toFloat() / s.videoHeight.toFloat())
        }
        if (!adoptedByFullscreen) engine?.attachPreviewTexture(texture)
    }

    fun unregisterPreviewView(texture: TextureView) {
        if (previewTexture === texture) {
            previewTexture = null
            previewAspectFrame = null
        }
    }

    private fun applyPreviewAspect(width: Int, height: Int) {
        if (width <= 0 || height <= 0) return
        previewAspectFrame?.setAspectRatio(width.toFloat() / height.toFloat())
    }
}
