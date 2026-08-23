package com.gchofficial.iptvs.player

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.SurfaceView
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

    /**
     * How long after the video output returns to the preview texture the
     * rendered-frame delta is sampled. Long enough that a healthy decoder shows
     * an unmistakable count (~150 frames at 50fps) and a re-initialising one
     * has had a full broadcast GOP to produce its first, so the two can't be
     * confused; short enough to still be running when a user glances at the
     * panel and presses Back.
     */
    private const val REATTACH_SAMPLE_MS = 3_000L

    /**
     * Poll cadence for the preview's decode-health line. The sampler emits at
     * its own interval (5 s); polling at that rate is enough to drive it and
     * costs one counter read per tick.
     */
    private const val PREVIEW_STATS_POLL_MS = 5_000L

    /**
     * How many decode-health lines a preview may emit unconditionally after
     * each (re)start, before it goes quiet unless something is wrong.
     *
     * The sampler needs one tick to baseline, so this covers roughly the first
     * 20 seconds — which is the window the question is actually about: what
     * the preview does when it starts, and what it does when fullscreen hands
     * the surface back.
     */
    private const val PREVIEW_STATS_BURST = 3

    private val previewStats = PlaybackStatsSampler()
    private var previewStatsTick: Runnable? = null
    private var previewStatsEmitted = 0
    private var previewStatsLastDropped = -1

    var engine: ExoPlayerEngine? = null
        private set(value) {
            // Balances DebugCounters.sharedEngineLive across every assignment
            // site, including the adoption handoff (which never reassigns this
            // field, so it stays at 1 throughout — see docs/player.md).
            if (value == null && field != null) DebugCounters.decSharedEngineLive()
            if (value != null && field == null) DebugCounters.incSharedEngineLive()
            field = value
        }
    var uiState: PlayerUiState? = null
        private set

    /** URL the engine currently plays; fullscreen adoption is keyed on it. */
    var url: String? = null
        private set
    private var headers: Map<String, String> = emptyMap()
    // The preset the live engine was built with, so a change forces a
    // rebuild rather than being silently ignored.
    private var preset: BufferPreset = BufferPreset.NORMAL

    /** True while `HdrPlayerActivity` owns the engine's video output. */
    var adoptedByFullscreen = false
        private set

    /** Set when Dart asked to stop while fullscreen owned the engine — honoured
     *  at [fullscreenDetached] instead of releasing under the Activity. */
    private var stopAfterDetach = false

    // The preview platform view's surface, when one is on screen.
    private var previewSurface: SurfaceView? = null
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
        bufferPreset: BufferPreset = BufferPreset.NORMAL,
    ) {
        if (adoptedByFullscreen) {
            // Dart flows never preview while fullscreen owns the engine; refuse
            // rather than steal the surface out from under the Activity.
            Log.w(TAG, "openPreview ignored: engine adopted by fullscreen")
            return
        }
        val existing = engine
        // A changed preset needs a fresh engine for the same reason changed
        // headers do: `LoadControl` is baked in at construction, so reusing the
        // engine would silently keep the previous source's buffering.
        if (existing != null && headers == requestHeaders && preset == bufferPreset) {
            url = streamUrl
            bindPreviewCallbacks(existing)
            previewSurface?.let { existing.attachPreviewSurface(it) }
            existing.load(streamUrl, emptyList())
        } else {
            existing?.release()
            engine = null
            // Headers are baked into the engine's HTTP data-source factory, so a
            // different set (source switch) needs a fresh engine.
            val state = PlayerUiState(title = "", isLive = true)
            val fresh = ExoPlayerEngine(
                context.applicationContext,
                state,
                requestHeaders,
                bufferPreset,
            )
            bindPreviewCallbacks(fresh)
            engine = fresh
            uiState = state
            headers = requestHeaders
            preset = bufferPreset
            url = streamUrl
            previewSurface?.let { fresh.attachPreviewSurface(it) }
            fresh.load(streamUrl, emptyList())
        }
        engine?.setVolume(if (muted) 0f else 1f)
        engine?.play()
        startPreviewStats()
    }

    /**
     * Periodic decode health for the **preview**, the same measurement
     * `HdrPlayerActivity` already emits for fullscreen.
     *
     * It exists because an export showed the same codec instance, on the same
     * stream, holding 49.3 fps rendering into fullscreen while a mostly-preview
     * window managed about 11.7 fps — and nothing in the log could say how much
     * of that gap was the preview's own rendering path and how much was the two
     * spurious decoder rebuilds inside the same window. The preview now renders
     * into a `SurfaceView` like fullscreen does, and the rebuilds no longer fire
     * on a decoder that is merely behind, so this line is what says whether
     * either change actually landed.
     */
    private fun startPreviewStats() {
        stopPreviewStats()
        previewStats.reset()
        previewStatsEmitted = 0
        previewStatsLastDropped = -1
        val tick = object : Runnable {
            override fun run() {
                val e = engine
                // Not rescheduled: fullscreen owns the measurement while it
                // holds the engine, and `fullscreenDetached` starts a fresh
                // ticker on the way back.
                if (e == null || adoptedByFullscreen) return
                val dropped = e.droppedFrameCount
                val line = previewStats.sample(
                    System.currentTimeMillis(),
                    e.renderedFrameCount,
                    dropped,
                )
                // **A healthy preview goes quiet.** The exportable log is an
                // 800-entry ring buffer, and a line every 5 s is 720 an hour —
                // an idle browse would flush every other diagnostic out of the
                // export, destroying exactly the evidence these lines exist to
                // provide. So: the opening burst always (that is the interval
                // the question is about), and after that only while the decoder
                // is visibly losing frames, which is the shape worth reporting
                // and the one that would otherwise be a *silent* degradation
                // over a long preview.
                val degraded = dropped > previewStatsLastDropped
                previewStatsLastDropped = dropped
                if (line != null && (previewStatsEmitted < PREVIEW_STATS_BURST || degraded)) {
                    previewStatsEmitted++
                    previewDiagnostics("playback $line")
                }
                mainHandler.postDelayed(this, PREVIEW_STATS_POLL_MS)
            }
        }
        previewStatsTick = tick
        mainHandler.postDelayed(tick, PREVIEW_STATS_POLL_MS)
    }

    private fun stopPreviewStats() {
        previewStatsTick?.let { mainHandler.removeCallbacks(it) }
        previewStatsTick = null
    }

    /**
     * Routes the preview engine's own reports into the exportable log, tagged
     * so they are not mistaken for the fullscreen Activity's. Credential-free
     * by construction, like every other line on this channel.
     */
    private val previewDiagnostics: (String) -> Unit = { note ->
        mainHandler.post {
            com.gchofficial.iptvs.MainActivity.instance?.get()
                ?.logPlaybackDiagnostic("preview $note")
        }
    }

    private fun bindPreviewCallbacks(target: ExoPlayerEngine) {
        target.onUnsupportedVideo = { handlePreviewUnsupported() }
        target.onRecoverableError = { onPreviewError?.invoke("stream error") }
        target.onVideoSizeChanged = { w, h -> applyPreviewAspect(w, h) }
        // This is the path a detaching fullscreen returns through, so it must
        // drop the Activity closure `adoptForFullscreen` installed. A
        // preview-owned sink does that just as well as null while keeping the
        // one report the preview genuinely owns: **which video decoder it
        // built**. The engine carries into fullscreen on adoption, so a
        // software fallback that happened at preview start is still the decoder
        // running fullscreen — and with this nulled, that case logged nothing
        // at all and its absence was indistinguishable from a healthy
        // hardware decode.
        target.onDiagnostic = previewDiagnostics
        target.onClaimedSurfaceFirstFrame = null
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
        stopPreviewStats()
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
    fun adoptForFullscreen(
        streamUrl: String,
        diagnostics: ((String) -> Unit)? = null,
        onClaimedSurfaceFirstFrame: (() -> Unit)? = null,
    ): Pair<ExoPlayerEngine, PlayerUiState>? {
        val e = engine ?: return null
        val s = uiState ?: return null
        if (streamUrl != url) {
            Log.w(TAG, "adopt refused: fullscreen URL differs from preview")
            return null
        }
        adoptedByFullscreen = true
        stopAfterDetach = false
        // The Activity samples from here (`native playback fps=…`); two tickers
        // on one engine would interleave two baselines and report nonsense.
        stopPreviewStats()
        // Bound *before* the claim: how that claim goes is the single most
        // useful thing the handoff can report, and it happens on the next line.
        // Only on the success path, so a refused adoption never leaves the
        // preview engine holding an Activity's closure (bindPreviewCallbacks
        // clears it again on the way back).
        e.onDiagnostic = diagnostics
        e.onClaimedSurfaceFirstFrame = onClaimedSurfaceFirstFrame
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
        val surface = previewSurface
        previewDiagnostics("fullscreen detached surface=${surface != null}")
        if (surface == null) return
        e.attachPreviewSurface(surface)
        sampleAfterReattach(e)
        // Back on the preview's own surface, so the preview owns the
        // measurement again.
        startPreviewStats()
    }

    /**
     * One delayed frame-count sample after the video output goes back to the
     * preview texture.
     *
     * The forward leg of this handoff had a watchdog and a report; the return
     * leg has neither, and "the preview comes back flickering on one frame"
     * is a report that no exported log could confirm or refute. This is the
     * cheapest thing that separates the two candidates: a decoder that came
     * back and is rendering (a large delta), versus one that re-initialised
     * under the surface swap and is emitting a frame at a time (a delta of a
     * handful, or zero).
     *
     * Deliberately a **report, not a recovery.** The last time a recovery was
     * added to this handoff on a plausible-sounding theory, the recovery turned
     * out to be the bug — it fired on healthy decoders and cost a codec
     * re-init, an IDR wait and a dropped-frame catch-up every time. So this
     * measures, and the fix waits for the measurement.
     */
    private fun sampleAfterReattach(target: ExoPlayerEngine) {
        val before = target.renderedFrameCount
        mainHandler.postDelayed({
            // Anything that moved the output on since then (a new fullscreen
            // adoption, a channel change, a released engine) makes the delta
            // describe something other than the re-attach.
            if (engine !== target || adoptedByFullscreen) return@postDelayed
            val after = target.renderedFrameCount
            val delta = if (before < 0 || after < 0) -1 else after - before
            previewDiagnostics(
                "reattach sample renderedDelta=$delta over ${REATTACH_SAMPLE_MS}ms" +
                    (target.videoFrameCounters?.let { " $it" } ?: ""),
            )
        }, REATTACH_SAMPLE_MS)
    }

    /** Fullscreen swapped the adopted engine for mpv (unsupported video): the
     *  shared engine is dead; tell Dart so the preview side resets. */
    fun invalidateFromFullscreen() {
        invalidate()
        onPreviewLost?.invoke()
    }

    fun registerPreviewView(surface: SurfaceView, aspectFrame: AspectRatioFrameLayout) {
        previewSurface = surface
        previewAspectFrame = aspectFrame
        val s = uiState
        if (s != null && s.videoWidth > 0 && s.videoHeight > 0) {
            aspectFrame.setAspectRatio(s.videoWidth.toFloat() / s.videoHeight.toFloat())
        }
        previewDiagnostics("surface registered adopted=$adoptedByFullscreen")
        if (!adoptedByFullscreen) engine?.attachPreviewSurface(surface)
    }

    fun unregisterPreviewView(surface: SurfaceView) {
        // The one line that would explain a black flash during the transparent
        // handoff. That handoff leaves the channel list — and this surface's
        // frozen last frame — on screen while the fullscreen Activity starts,
        // for however long `first frame sinceClaimMs` reports. A SurfaceView
        // holds its last buffer, so the frame survives *unless the view itself
        // is torn down*; if Flutter ever disposes the platform view across the
        // route push, this line landing between `adopted=true` and the
        // Activity's first frame is the proof, and nothing else in the log
        // would show it.
        previewDiagnostics("surface unregistered adopted=$adoptedByFullscreen")
        if (previewSurface === surface) {
            previewSurface = null
            previewAspectFrame = null
        }
        // Release the engine's reference to this now-destroyed SurfaceView.
        // Skipped while fullscreen has adopted the engine: it owns/re-attaches
        // the video output for that handoff (claimViewSurface /
        // fullscreenDetached), so clearing here would fight that transparent
        // handoff instead of just tidying up a torn-down preview.
        if (!adoptedByFullscreen) engine?.clearPreviewSurface(surface)
    }

    private fun applyPreviewAspect(width: Int, height: Int) {
        if (width <= 0 || height <= 0) return
        previewAspectFrame?.setAspectRatio(width.toFloat() / height.toFloat())
    }
}
