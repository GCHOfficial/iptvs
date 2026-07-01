package com.gchofficial.iptvs

import android.app.PictureInPictureParams
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.os.Bundle
import android.util.Log
import android.util.Rational
import android.view.KeyEvent
import android.view.View
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.runtime.mutableStateOf
import androidx.lifecycle.lifecycleScope
import androidx.media3.common.util.UnstableApi
import com.gchofficial.iptvs.player.AspectMode
import com.gchofficial.iptvs.player.ExoPlayerEngine
import com.gchofficial.iptvs.player.MpvEngine
import com.gchofficial.iptvs.player.PlaybackEngine
import com.gchofficial.iptvs.player.PlayerCallbacks
import com.gchofficial.iptvs.player.PlayerMenu
import com.gchofficial.iptvs.player.PlayerScreen
import com.gchofficial.iptvs.player.PlayerUiState
import com.gchofficial.iptvs.player.SubtitleSpec
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * Native HDR player. Hosts a [PlaybackEngine] behind the Jetpack Compose control
 * overlay ([PlayerScreen]). Starts on [ExoPlayerEngine] (MediaCodec hardware decode
 * → true HDR); if ExoPlayer can't decode the video track (e.g. Dolby Vision
 * Profile 5 on non-DV hardware) it falls back once to [MpvEngine] (libmpv, which
 * software-reshapes DV and tone-maps). The engine swap is device-aware: on
 * DV-capable hardware ExoPlayer handles everything and the fallback never fires.
 */
@UnstableApi
class HdrPlayerActivity : ComponentActivity() {
    private lateinit var uiState: PlayerUiState
    private lateinit var url: String
    private lateinit var headers: Map<String, String>
    private lateinit var subtitles: List<SubtitleSpec>

    private val engineState = mutableStateOf<PlaybackEngine?>(null)
    private var engine: PlaybackEngine? = null
    private var progressTicker: Job? = null

    // Live reconnect watchdog: when a live stream stalls (buffering) or drops
    // (ended / error), reload it with capped backoff until playback resumes.
    private var stalledSinceMs = 0L
    private var lastReconnectMs = 0L
    private var reconnectAttempt = 0

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        hideSystemUi()

        val streamUrl = intent.getStringExtra(EXTRA_URL)
        if (streamUrl.isNullOrBlank()) {
            finish()
            return
        }
        url = streamUrl
        headers = requestHeaders()
        subtitles = subtitleSpecs()
        uiState = PlayerUiState(
            title = intent.getStringExtra(EXTRA_TITLE).orEmpty(),
            isLive = intent.getBooleanExtra(EXTRA_IS_LIVE, false),
            sourceName = intent.getStringExtra(EXTRA_SOURCE_NAME),
            isTv = isTelevision(),
            epgNow = epgEntry(EXTRA_EPG_NOW_TITLE, EXTRA_EPG_NOW_START, EXTRA_EPG_NOW_STOP, EXTRA_EPG_NOW_DESC),
            epgNext = epgEntry(EXTRA_EPG_NEXT_TITLE, EXTRA_EPG_NEXT_START, EXTRA_EPG_NEXT_STOP, null),
        )
        // Android TV's PiP framework restricts entry to communication/smartHome/health/ticker
        // use cases via a required manifest category — general media playback isn't an
        // approved category there, so FEATURE_PICTURE_IN_PICTURE is intentionally left
        // unused/absent for our purposes on most TVs. That's a platform limitation, not a bug:
        // the button below simply won't show on devices that report the feature missing.
        uiState.supportsPip = supportsPip()

        startWithExoPlayer()

        setContent {
            engineState.value?.let { active ->
                PlayerScreen(
                    state = uiState,
                    videoView = active.view,
                    callbacks = playerCallbacks(),
                )
            }
        }
    }

    private fun startWithExoPlayer() {
        val exo = ExoPlayerEngine(
            context = this,
            state = uiState,
            headers = headers,
            onUnsupportedVideo = { runOnUiThread { fallbackToMpv() } },
            onRecoverableError = { runOnUiThread { reconnectLive(force = true) } },
        )
        setEngine(exo)
        exo.load(url, subtitles)
    }

    /** One-way fallback: ExoPlayer couldn't decode the video → switch to libmpv. */
    private fun fallbackToMpv() {
        if (engine is MpvEngine || isFinishing) return
        Log.i(TAG, "falling back to libmpv (video unsupported by ExoPlayer)")
        engine?.release()
        // Reset stale stream info before the new engine repopulates it.
        uiState.videoUnsupported = false
        val mpv = MpvEngine(
            context = this,
            state = uiState,
            headers = headers,
            post = { action -> if (!isFinishing) runOnUiThread(action) },
        )
        setEngine(mpv)
        mpv.load(url, subtitles)
    }

    private fun setEngine(next: PlaybackEngine) {
        engine = next
        engineState.value = next
    }

    /** Watchdog: reconnect a live stream that has stalled (buffering) or dropped (ended). */
    private fun pollLiveReconnect() {
        if (!uiState.isLive) return
        val stalled = uiState.isBuffering || uiState.ended
        if (!stalled) {
            // Healthy playback: clear the stall clock and any reconnecting state.
            stalledSinceMs = 0L
            reconnectAttempt = 0
            if (uiState.reconnecting) uiState.reconnecting = false
            return
        }
        val now = System.currentTimeMillis()
        if (stalledSinceMs == 0L) stalledSinceMs = now
        val threshold = if (uiState.ended) ENDED_RECONNECT_MS else STALL_RECONNECT_MS
        if (now - stalledSinceMs >= threshold) reconnectLive(force = false)
    }

    /**
     * Reload the live source to reconnect, with capped backoff between attempts.
     * [force] (a hard error) skips the stall threshold but still rate-limits.
     */
    private fun reconnectLive(force: Boolean) {
        if (!uiState.isLive || isFinishing) return
        val now = System.currentTimeMillis()
        val sinceLast = now - lastReconnectMs
        val minGap = if (force) STALL_RECONNECT_MS else
            minOf((reconnectAttempt + 1) * STALL_RECONNECT_MS, MAX_BACKOFF_MS)
        if (lastReconnectMs != 0L && sinceLast < minGap) return
        reconnectAttempt++
        lastReconnectMs = now
        stalledSinceMs = now
        uiState.reconnecting = true
        uiState.ended = false
        Log.i(TAG, "live reconnect attempt=$reconnectAttempt force=$force")
        engine?.load(url, subtitles)
    }

    private fun playerCallbacks() = PlayerCallbacks(
        onPlayPause = {
            // Pausing a live stream drops you behind the live edge.
            if (uiState.isLive && uiState.isPlaying) uiState.liveSynced = false
            engine?.playPause()
        },
        onSeekTo = { engine?.seekTo(it) },
        onSeekBy = { if (!uiState.isLive) engine?.seekBy(it) },
        onSetVolume = { engine?.setVolume(it) },
        onToggleMute = { engine?.toggleMute() },
        onSelectAudio = { engine?.selectAudio(it) },
        onSelectSubtitle = { engine?.selectSubtitle(it) },
        onSetSpeed = { engine?.setSpeed(it) },
        onCycleAspect = {
            uiState.aspect = AspectMode.entries[(uiState.aspect.ordinal + 1) % AspectMode.entries.size]
            engine?.applyAspect(uiState.aspect)
        },
        // Live streams are typically non-seekable, so "go to live" reloads the
        // source — reconnecting drops the buffer and resumes at the live edge.
        onGoLive = {
            if (uiState.isLive) {
                engine?.load(url, subtitles)
                uiState.liveSynced = true
            }
        },
        onBack = { finish() },
        onEnterPip = { enterPip() },
    )

    override fun onStart() {
        super.onStart()
        progressTicker = lifecycleScope.launch {
            while (isActive) {
                engine?.syncProgress()
                pollLiveReconnect()
                delay(500)
            }
        }
    }

    override fun onStop() {
        super.onStop()
        progressTicker?.cancel()
        progressTicker = null
        // Keep playing while in PiP (onStop can fire around the PiP window on
        // some devices); only pause when actually backgrounded.
        if (!uiState.inPip) engine?.pause()
    }

    /** Home / recents while playing → enter picture-in-picture instead of
     *  backgrounding. No-op on devices without PiP (e.g. some Android TVs). */
    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        enterPip()
    }

    /** Enters PiP if currently eligible; also invoked from a manual overlay button so entry
     *  doesn't depend solely on the OS calling [onUserLeaveHint] (inconsistent across OEMs). */
    private fun enterPip() {
        if (uiState.inPip || isFinishing || !uiState.isPlaying) return
        if (!supportsPip()) return
        try {
            enterPictureInPictureMode(pipParams())
        } catch (e: Exception) {
            Log.e(TAG, "enterPictureInPictureMode failed", e)
        }
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration,
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        uiState.inPip = isInPictureInPictureMode
        if (isInPictureInPictureMode) {
            // Collapse all chrome so the PiP window is video-only.
            uiState.controlsVisible = false
            uiState.openMenu = PlayerMenu.None
            uiState.infoOpen = false
        }
    }

    private fun supportsPip(): Boolean =
        packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)

    private fun pipParams(): PictureInPictureParams {
        val w = uiState.videoWidth
        val h = uiState.videoHeight
        // Android rejects extreme ratios; clamp to its allowed band, default 16:9.
        val ratio = if (w > 0 && h > 0) {
            Rational(w, h).coerceRatio()
        } else {
            Rational(16, 9)
        }
        return PictureInPictureParams.Builder().setAspectRatio(ratio).build()
    }

    /** Clamp to Android's accepted aspect band (~0.418..2.39) to avoid a crash. */
    private fun Rational.coerceRatio(): Rational {
        val value = numerator.toDouble() / denominator.toDouble()
        return when {
            value < 0.42 -> Rational(42, 100)
            value > 2.39 -> Rational(239, 100)
            else -> this
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) hideSystemUi()
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        when (keyCode) {
            KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE,
            KeyEvent.KEYCODE_MEDIA_PLAY,
            KeyEvent.KEYCODE_MEDIA_PAUSE -> { engine?.playPause(); return true }
            KeyEvent.KEYCODE_MEDIA_FAST_FORWARD -> {
                if (!uiState.isLive) engine?.seekBy(10_000); return true
            }
            KeyEvent.KEYCODE_MEDIA_REWIND -> {
                if (!uiState.isLive) engine?.seekBy(-10_000); return true
            }
        }
        return super.onKeyDown(keyCode, event)
    }

    override fun onDestroy() {
        engine?.release()
        engine = null
        super.onDestroy()
    }

    private fun requestHeaders(): Map<String, String> {
        val keys = intent.getStringArrayListExtra(EXTRA_HEADER_KEYS).orEmpty()
        val values = intent.getStringArrayListExtra(EXTRA_HEADER_VALUES).orEmpty()
        return keys.mapIndexedNotNull { index, key ->
            val value = values.getOrNull(index)
            if (key.isBlank() || value.isNullOrBlank()) null else key to value
        }.toMap()
    }

    private fun subtitleSpecs(): List<SubtitleSpec> {
        val urls = intent.getStringArrayListExtra(EXTRA_SUBTITLE_URLS).orEmpty()
        val labels = intent.getStringArrayListExtra(EXTRA_SUBTITLE_LABELS).orEmpty()
        val languages = intent.getStringArrayListExtra(EXTRA_SUBTITLE_LANGUAGES).orEmpty()
        return urls.mapIndexedNotNull { index, subUrl ->
            if (subUrl.isBlank()) {
                null
            } else {
                SubtitleSpec(
                    url = subUrl,
                    label = labels.getOrNull(index).orEmpty(),
                    language = languages.getOrNull(index).orEmpty(),
                )
            }
        }
    }

    private fun isTelevision(): Boolean {
        val uiModeManager = getSystemService(UI_MODE_SERVICE) as? android.app.UiModeManager
        return uiModeManager?.currentModeType ==
            android.content.res.Configuration.UI_MODE_TYPE_TELEVISION
    }

    /** Builds an [com.gchofficial.iptvs.player.EpgEntry] from intent extras, or null if absent/invalid. */
    private fun epgEntry(
        titleKey: String,
        startKey: String,
        stopKey: String,
        descKey: String?,
    ): com.gchofficial.iptvs.player.EpgEntry? {
        val title = intent.getStringExtra(titleKey)?.takeIf { it.isNotBlank() } ?: return null
        val start = intent.getLongExtra(startKey, -1L)
        val stop = intent.getLongExtra(stopKey, -1L)
        if (start < 0L || stop <= start) return null
        return com.gchofficial.iptvs.player.EpgEntry(
            title = title,
            startMs = start,
            stopMs = stop,
            description = descKey?.let { intent.getStringExtra(it) }?.takeIf { it.isNotBlank() },
        )
    }

    private fun hideSystemUi() {
        window.decorView.systemUiVisibility =
            View.SYSTEM_UI_FLAG_FULLSCREEN or
                View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or
                View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY or
                View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or
                View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION or
                View.SYSTEM_UI_FLAG_LAYOUT_STABLE
    }

    companion object {
        const val EXTRA_URL = "url"
        const val EXTRA_TITLE = "title"
        const val EXTRA_IS_LIVE = "is_live"
        const val EXTRA_SOURCE_NAME = "source_name"
        const val EXTRA_EPG_NOW_TITLE = "epg_now_title"
        const val EXTRA_EPG_NOW_START = "epg_now_start"
        const val EXTRA_EPG_NOW_STOP = "epg_now_stop"
        const val EXTRA_EPG_NOW_DESC = "epg_now_desc"
        const val EXTRA_EPG_NEXT_TITLE = "epg_next_title"
        const val EXTRA_EPG_NEXT_START = "epg_next_start"
        const val EXTRA_EPG_NEXT_STOP = "epg_next_stop"
        const val EXTRA_HEADER_KEYS = "header_keys"
        const val EXTRA_HEADER_VALUES = "header_values"
        const val EXTRA_SUBTITLE_URLS = "subtitle_urls"
        const val EXTRA_SUBTITLE_LABELS = "subtitle_labels"
        const val EXTRA_SUBTITLE_LANGUAGES = "subtitle_languages"
        private const val TAG = "iptvs.hdr"

        // Live reconnect watchdog thresholds.
        private const val STALL_RECONNECT_MS = 8_000L // buffering this long -> reconnect
        private const val ENDED_RECONNECT_MS = 2_000L // a live drop is faster to retry
        private const val MAX_BACKOFF_MS = 30_000L // cap between repeated attempts
    }
}
