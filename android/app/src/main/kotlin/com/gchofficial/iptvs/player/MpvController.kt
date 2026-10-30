package com.gchofficial.iptvs.player

import android.content.Context
import android.util.Log
import android.view.SurfaceHolder
import dev.jdtech.mpv.MPVLib
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Wraps libmpv (gpu-next / libplacebo) for the native HDR player — the same engine
 * as the Windows path. Unlike ExoPlayer/MediaCodec, mpv can software-reshape Dolby
 * Vision Profile 5 (single-layer, no HDR10 base) and tone-map to the display, so
 * DV titles render on non-DV hardware (e.g. Samsung Galaxy).
 *
 * Owns the MPVLib instance, mirrors mpv property changes into [PlayerUiState] (on
 * the main thread via [post]), and exposes the playback actions the Compose overlay
 * invokes through [PlayerCallbacks].
 *
 * ## Threading: every *bulk* property read is off the main thread
 *
 * Each synchronous `getProperty*` is a `mpv_get_property` that **blocks the calling
 * thread until the mpv core answers**, and the core is at its busiest exactly when
 * these fire: `MPV_EVENT_FILE_LOADED` / `*_RECONFIG` land while the demuxer is
 * probing a freshly opened live stream. [refreshTracks] alone is `3 + 4N` of them
 * and [refreshMediaInfo] about ten, so running them on the main thread handed the
 * UI thread a network-bound wait — Play vitals reported it as an
 * `Input dispatching timed out` ANR with [refreshTracks] on top of the stack.
 *
 * They now run on [reader], a single dedicated thread, and only the *finished*
 * values are [post]ed to the main thread, because `state` is Compose state and
 * must only be written there.
 *
 * **Why a thread of our own rather than mpv's event thread.** libmpv's client API
 * is thread-safe and reading from the event thread would not deadlock the core,
 * but it would deadlock *us*: `MPVLib` dispatches `event`/`eventProperty` inside a
 * `synchronized` block over its observer list, and `removeObserver` — which
 * [destroy] calls from the main thread — takes that same monitor. A blocking read
 * inside the callback would therefore move the stall from [refreshTracks] onto
 * [destroy], not remove it. It would also stall every other property event (the
 * position clock, pause state) behind one slow read, and `nativeDestroy` is
 * `mpv_terminate_destroy` + `pthread_join` of that very thread. So the callbacks
 * stay non-blocking: they hand work to [reader] and return immediately.
 *
 * **Use-after-destroy is prevented by ordering, not by locking.** [mpv] is nulled
 * on the main thread and the teardown is then queued onto [reader], which is FIFO:
 * a read already queued re-reads [mpv], finds null and does nothing, and a read
 * already *running* finishes before the teardown task starts. No read can touch a
 * destroyed handle, and [destroy] waits for the teardown rather than racing it
 * (see [destroy] for why it is not simply moved off the main thread).
 */
class MpvController(
    private val context: Context,
    private val state: PlayerUiState,
    private val post: (() -> Unit) -> Unit,
    /** `cache-secs` for this session, or null for mpv's own default. */
    private val cacheSecs: Int? = null,
    private val onHdrChanged: (Boolean) -> Unit = {},
) : MPVLib.EventObserver, SurfaceHolder.Callback {

    /**
     * Written on the main thread ([create] / [destroy]), read from [reader].
     * Volatile so the reader sees the null promptly; the *safety* of a read
     * comes from [reader]'s FIFO ordering, not from this field (see the class
     * doc).
     */
    @Volatile
    private var mpv: MPVLib? = null

    /** Set on the main thread in [load], consumed on [reader] after FILE_LOADED. */
    @Volatile
    private var pendingSubtitles: List<SubtitleSpec> = emptyList()

    /**
     * The one thread every blocking mpv *read* runs on, and the thread the
     * handle is finally destroyed on. Single-threaded on purpose: it serialises
     * reads against teardown for free, and a second reader would only let two
     * `mpv_get_property` calls queue on the same core.
     */
    private val reader = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "iptvs-mpv-read").apply { isDaemon = true }
    }

    private val destroyed = AtomicBoolean(false)

    init {
        DebugCounters.incMpvReader()
    }

    fun create(headers: Map<String, String>) {
        val instance = MPVLib.create(context) ?: run {
            Log.e(TAG, "MPVLib.create returned null")
            return
        }
        mpv = instance
        with(instance) {
            // Per-source buffering, when the user moved off the default.
            // Set with the other options so it is in effect for the first
            // load rather than applied to an already-running demuxer.
            cacheSecs?.let { setOptionString("cache-secs", it.toString()) }
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
            // Network resiliency for live streams: bound stalls and let ffmpeg
            // transparently reconnect transient HTTP drops (the host watchdog
            // reloads if a stall outlasts this). See [MpvLiveOptions] for why
            // `reconnect_at_eof` must stay out of `stream-lavf-o`.
            setOptionString("network-timeout", MpvLiveOptions.NETWORK_TIMEOUT)
            setOptionString("stream-lavf-o", MpvLiveOptions.STREAM_LAVF_O)
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
                MpvOptionEncoding.encodeHeaderFields(rest.map { it.key to it.value }),
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
        // A reload while paused (go-to-live) must resume; loadfile keeps the
        // current pause state otherwise.
        mpv?.setPropertyBoolean("pause", false)
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
                // Every branch restores `keepaspect` explicitly rather than
                // assuming it: the modes are cycled, so leaving Stretch must
                // undo it on the very next press.
                mpv.setPropertyString("keepaspect", "yes")
                mpv.setPropertyString("panscan", "0")
                mpv.setPropertyString("video-aspect-override", "-1")
            }
            AspectMode.Fill -> {
                mpv.setPropertyString("keepaspect", "yes")
                mpv.setPropertyString("video-aspect-override", "-1")
                mpv.setPropertyString("panscan", "1.0")
            }
            // `keepaspect=no` is mpv's stretch: the picture is scaled to the
            // window on both axes independently. Distinct from `panscan`, which
            // crops to fill while preserving the shape.
            AspectMode.Stretch -> {
                mpv.setPropertyString("panscan", "0")
                mpv.setPropertyString("video-aspect-override", "-1")
                mpv.setPropertyString("keepaspect", "no")
            }
            AspectMode.Ratio16x9 -> {
                mpv.setPropertyString("keepaspect", "yes")
                mpv.setPropertyString("panscan", "0")
                mpv.setPropertyString("video-aspect-override", "16:9")
            }
            AspectMode.Ratio4x3 -> {
                mpv.setPropertyString("keepaspect", "yes")
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

    /**
     * Tears the core down. **Deliberately still synchronous from the caller's
     * point of view** (bounded by [DESTROY_WAIT_MS]), even though the blocking
     * work now happens on [reader].
     *
     * Moving it off the main thread outright was considered and rejected: it
     * would be the one change here that can't be reasoned to safety from the
     * code alone.
     *
     * - **Surface lifecycle.** The engine's `SurfaceView` is torn down by the
     *   framework immediately after this returns. `mpv_terminate_destroy` must
     *   have released the `ANativeWindow` by then; letting the Activity's view
     *   teardown race a still-attached VO on a background thread is a native
     *   crash this host can't observe or test.
     * - **Single-connection accounts.** `HdrPlayerActivity.rebuildEngineForZap`
     *   releases the mpv engine and constructs a new one in the same call. If
     *   this returned before the old core was gone, two libmpv cores would hold
     *   two provider connections at once, and the provider refuses the second —
     *   the same "stop → resolve → play" rule the zap settle path obeys.
     *
     * Neither is verifiable off-device, so the bound exists only as an ANR
     * backstop: if the core is so wedged that teardown outlasts it, the thread
     * finishes the job on its own (and does the [DebugCounters] decrement), and
     * the main thread stops waiting rather than being killed.
     *
     * Note the saving that *is* real here: `removeObserver` used to contend with
     * an event dispatch that could be blocked in a read of its own, and the ANR
     * window was dominated by the reads that no longer run here at all.
     */
    fun destroy() {
        if (!destroyed.compareAndSet(false, true)) return
        val instance = mpv
        // Null first: any read still queued on [reader] now no-ops, and the
        // surface callbacks below become no-ops too.
        mpv = null
        // Cheap now that event dispatch only queues work — see the class doc.
        if (instance != null) runCatching { instance.removeObserver(this) }
        runCatching {
            reader.execute {
                runCatching {
                    instance?.command(arrayOf("stop"))
                    instance?.detachSurface()
                    instance?.destroy()
                }.onFailure { Log.w(TAG, "mpv teardown failed", it) }
                DebugCounters.decMpvReader()
            }
        }.onFailure {
            // Executor already shut down (can't happen: `destroyed` guards it),
            // so nothing will run the decrement.
            DebugCounters.decMpvReader()
        }
        reader.shutdown()
        runCatching { reader.awaitTermination(DESTROY_WAIT_MS, TimeUnit.MILLISECONDS) }
    }

    // ---- Off-main-thread property reads -------------------------------------

    /**
     * Runs [block] on [reader] with a live handle, or not at all. The handle is
     * re-read *inside* the task so a read queued before [destroy] cannot reach a
     * destroyed core; it is never passed in from the caller's thread.
     */
    private fun readAsync(block: (MPVLib) -> Unit) {
        if (destroyed.get()) return
        runCatching {
            reader.execute {
                val instance = mpv ?: return@execute
                runCatching { block(instance) }
                    .onFailure { Log.w(TAG, "mpv property read failed", it) }
            }
        }
    }

    // ---- Property/event observation (mpv thread → main thread) ---------------

    override fun eventProperty(property: String) {}

    override fun eventProperty(property: String, value: Long) {
        when (property) {
            // A plain state write: no mpv read, so it goes straight to main.
            "volume" -> post { state.volume = (value / 100f).coerceIn(0f, 1f) }
            // 3 + 4N blocking reads — never on the main thread (class doc).
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
            // One reader task, not three: the `sub-add` commands must land
            // before the track list is read, and a single task keeps that
            // ordering without re-entering the executor.
            MPVLib.MpvEvent.MPV_EVENT_FILE_LOADED -> readAsync { mpv ->
                addPendingSubtitles(mpv)
                readMediaInfo(mpv)
                readTracks(mpv)
            }
            MPVLib.MpvEvent.MPV_EVENT_VIDEO_RECONFIG,
            MPVLib.MpvEvent.MPV_EVENT_AUDIO_RECONFIG,
            -> refreshMediaInfo()
            MPVLib.MpvEvent.MPV_EVENT_END_FILE -> post { state.ended = true }
        }
    }

    /** On [reader]. `sub-add` is a core command, so it blocks like a read does. */
    private fun addPendingSubtitles(mpv: MPVLib) {
        val pending = pendingSubtitles
        if (pending.isEmpty()) return
        pendingSubtitles = emptyList()
        for (sub in pending) {
            if (sub.url.isBlank()) continue
            mpv.command(arrayOf("sub-add", sub.url, "auto", sub.label, sub.language))
        }
    }

    private fun refreshMediaInfo() = readAsync { mpv -> readMediaInfo(mpv) }

    private fun refreshTracks() = readAsync { mpv -> readTracks(mpv) }

    /** On [reader]: ~10 blocking reads, mapped, then one hop to the main thread. */
    private fun readMediaInfo(mpv: MPVLib) {
        val snapshot = MpvMediaSnapshot(
            videoWidth = (mpv.getPropertyInt("dwidth") ?: mpv.getPropertyInt("width"))
                ?.takeIf { it > 0 },
            videoHeight = (mpv.getPropertyInt("dheight") ?: mpv.getPropertyInt("height"))
                ?.takeIf { it > 0 },
            fps = (mpv.getPropertyDouble("container-fps") ?: mpv.getPropertyDouble("estimated-vf-fps"))
                ?.takeIf { it > 0 }?.toFloat(),
            videoCodec = mpv.getPropertyString("video-format")?.let { mpvCodecLabel(it) },
            audioCodec = mpv.getPropertyString("audio-codec-name")?.let { mpvCodecLabel(it) },
            audioChannels = mpv.getPropertyInt("audio-params/channel-count"),
            dynamicRange = mpvDynamicRangeLabel(
                mpv.getPropertyString("video-params/gamma"),
                mpv.getPropertyString("video-params/colormatrix"),
                mpv.getPropertyString("video-params/primaries"),
            ),
        )
        post {
            // Nulls leave the previous value standing — see [MpvMediaSnapshot].
            snapshot.videoWidth?.let { state.videoWidth = it }
            snapshot.videoHeight?.let { state.videoHeight = it }
            snapshot.fps?.let { state.fps = it }
            snapshot.videoCodec?.let { state.videoCodec = it }
            snapshot.audioCodec?.let { state.audioCodec = it }
            snapshot.audioChannels?.let { state.audioChannels = it }
            state.dynamicRange = snapshot.dynamicRange
            onHdrChanged(isHdrRangeLabel(snapshot.dynamicRange))
        }
    }

    /** On [reader]: `3 + 4N` blocking reads — the ANR's stack top before this. */
    private fun readTracks(mpv: MPVLib) {
        val count = mpv.getPropertyInt("track-list/count") ?: return
        val currentAid = mpv.getPropertyInt("aid")
        val currentSid = mpv.getPropertyInt("sid")
        val raw = ArrayList<RawMpvTrack>(count.coerceAtLeast(0))
        for (i in 0 until count) {
            raw.add(
                RawMpvTrack(
                    type = mpv.getPropertyString("track-list/$i/type"),
                    id = mpv.getPropertyInt("track-list/$i/id"),
                    title = mpv.getPropertyString("track-list/$i/title"),
                    language = mpv.getPropertyString("track-list/$i/lang"),
                ),
            )
        }
        val snapshot = mapMpvTracks(raw, currentAid, currentSid)
        post {
            state.audioTracks = snapshot.audioTracks
            state.selectedAudioId = snapshot.selectedAudioId
            state.subtitleTracks = snapshot.subtitleTracks
            state.selectedSubtitleId = snapshot.selectedSubtitleId
        }
    }

    companion object {
        private const val TAG = "iptvs.mpv"

        /**
         * How long [destroy] waits on the main thread for the core to go. Far
         * above any healthy teardown (tens of ms) and far below the 5s input
         * dispatch ANR budget, so it only ever trips on a wedged core.
         */
        private const val DESTROY_WAIT_MS = 1_500L
    }
}
