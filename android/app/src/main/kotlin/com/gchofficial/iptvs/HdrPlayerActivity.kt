package com.gchofficial.iptvs

import android.app.PictureInPictureParams
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.util.Log
import android.util.Rational
import android.view.KeyEvent
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedCallback
import androidx.activity.compose.setContent
import androidx.compose.runtime.mutableStateOf
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.lifecycle.lifecycleScope
import androidx.media3.common.util.UnstableApi
import com.gchofficial.iptvs.player.AspectMode
import com.gchofficial.iptvs.player.DebugCounters
import com.gchofficial.iptvs.player.ExoPlayerEngine
import com.gchofficial.iptvs.player.FrameLivenessWatch
import com.gchofficial.iptvs.player.LiveLocator
import com.gchofficial.iptvs.player.MpvEngine
import com.gchofficial.iptvs.player.PlaybackEngine
import com.gchofficial.iptvs.player.PlaybackStatsSampler
import com.gchofficial.iptvs.player.PlayerCallbacks
import com.gchofficial.iptvs.player.PlayerBackAction
import com.gchofficial.iptvs.player.PlayerBackGuard
import com.gchofficial.iptvs.player.PlayerMenu
import com.gchofficial.iptvs.player.PlayerScreen
import com.gchofficial.iptvs.player.PlayerUiState
import com.gchofficial.iptvs.player.ReconnectPolicy
import com.gchofficial.iptvs.player.ResolveAgainReply
import com.gchofficial.iptvs.player.ResolveGate
import com.gchofficial.iptvs.player.SharedEngine
import com.gchofficial.iptvs.player.SubtitleSpec
import com.gchofficial.iptvs.player.nextPlayerBackAction
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

    // Debug-only: lets an integration-test soak cycle this Activity without a
    // human closing it each time. Inert (never scheduled) outside BuildConfig.DEBUG.
    private var soakAutoCloseJob: Job? = null

    // True while this Activity plays through the *adopted* shared preview engine
    // (see [SharedEngine]): it never releases that engine — on exit it hands the
    // video output back to the preview instead.
    private var adoptedShared = false

    // Live reconnect watchdog: when a live stream stalls (buffering) or drops
    // (ended / error), reload it with capped backoff until playback resumes.
    private var stalledSinceMs = 0L
    private var lastReconnectMs = 0L
    private var reconnectAttempt = 0

    // The third stall shape, and the one that used to be invisible: playing
    // normally by every flag the engine exposes, with nothing reaching the
    // screen. See [FrameLivenessWatch].
    private val frameLiveness = FrameLivenessWatch()

    // Cheap recoveries spent on this session's handoff. One is the budget: if a
    // fresh decoder on the same surface still draws nothing, the surface switch
    // wasn't the problem and the reload watchdog owns it from there.
    private var handoffRebuilds = 0

    // Why the current reconnect fired, for the diagnostics line. Set at the
    // point of decision so the log distinguishes an underrun from a drop from
    // a frozen renderer, which otherwise all read as "reconnect attempt=1".
    private var stallKind = "none"

    // Wall clock for this Activity's own timeline: every diagnostic it emits is
    // stamped with ms since onCreate, so a report shows where in the handoff the
    // time went instead of only that it went.
    private var startedAtMs = 0L

    // Live re-resolve round trip (see [withFreshLiveLocator]). The gate keeps
    // the watchdog and "Go to live" to one in-flight `create_link` between them
    // and settles the reply-vs-timeout race exactly once.
    private val resolveGate = ResolveGate()
    private var resolveTimeoutJob: Job? = null
    private val backGuard = PlayerBackGuard()
    // Entering PiP moves MainActivity's task behind the launcher so the pinned
    // window is unobstructed.  When the restored player is then closed, the
    // player task would otherwise finish into the launcher instead of the
    // Flutter streams route.  Remember that this Activity has used PiP so its
    // finish path can restore the existing MainActivity task first.
    private var enteredPip = false

    /**
     * TV remotes and three-button navigation arrive as key events. Consume both
     * key-down and key-up at the Activity boundary so Compose focus handlers and
     * the Back dispatcher cannot process the same physical press again.
     */
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (event.keyCode != KeyEvent.KEYCODE_BACK) return super.dispatchKeyEvent(event)
        if (event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0) {
            handleSystemBack()
        }
        return true
    }

    /** One press closes one layer: menu, info, controls, then Activity. */
    private fun handleSystemBack() {
        if (!backGuard.shouldHandle(SystemClock.elapsedRealtime())) return
        if (!::uiState.isInitialized) {
            finish()
            return
        }
        when (
            nextPlayerBackAction(
                menuOpen = uiState.openMenu != PlayerMenu.None,
                infoOpen = uiState.infoOpen,
                controlsVisible = uiState.controlsVisible,
            )
        ) {
            PlayerBackAction.CloseMenu -> uiState.openMenu = PlayerMenu.None
            PlayerBackAction.CloseInfo -> uiState.infoOpen = false
            PlayerBackAction.HideControls -> uiState.controlsVisible = false
            PlayerBackAction.Exit -> finish()
        }
    }

    /**
     * Relays one short, credential-free note into Dart's **exportable**
     * diagnostics log, stamped with ms since this Activity started.
     *
     * Past `adopted=…` the whole native player used to be silent in an exported
     * log: no first frame, no stall, no reconnect, no engine swap. A user
     * reporting "high-bitrate channels stay black after going fullscreen" could
     * therefore send a complete, healthy-looking export of the exact session
     * that failed. Everything routed through here is chosen to be safe to
     * export verbatim — never a URL, header or provider reply.
     */
    private val playbackStats = PlaybackStatsSampler()

    /**
     * Periodic frame-rate/drop line while playing.
     *
     * Rides the existing ticker rather than adding a timer, and only while the
     * engine says it is playing: a paused or buffering player renders nothing,
     * and reporting 0fps for it would bury the case this exists to catch.
     */
    private fun samplePlaybackStats() {
        if (!uiState.isPlaying || uiState.isBuffering) {
            return
        }
        val active = engine ?: return
        playbackStats.sample(
            nowMs = System.currentTimeMillis(),
            rendered = active.renderedFrameCount,
            dropped = active.droppedFrameCount,
        )?.let { logNative("playback $it") }
    }

    private fun logNative(note: String) {
        MainActivity.instance?.get()?.logPlaybackDiagnostic(
            "native $note ms=${SystemClock.elapsedRealtime() - startedAtMs}",
        )
    }

    /**
     * The sink handed to whichever [ExoPlayerEngine] this Activity drives —
     * one it built, or the shared preview engine it adopted. Engines report
     * from the playback thread as well as the main one, so it hops.
     */
    private val diagnosticSink: (String) -> Unit = { note ->
        runOnUiThread { logNative(note) }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        startedAtMs = SystemClock.elapsedRealtime()
        // Gesture navigation and Android's system Back dispatcher terminate at
        // this same Activity boundary as remote key events. Do not register a
        // second Compose BackHandler: some TV images deliver one press through
        // both paths.
        onBackPressedDispatcher.addCallback(
            this,
            object : OnBackPressedCallback(true) {
                override fun handleOnBackPressed() = handleSystemBack()
            },
        )
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        // Let the video reach the physical screen edge on a notched phone rather
        // than being letterboxed away from the cutout (the DEFAULT mode letterboxes
        // in landscape, which is exactly the orientation a player is used in). The
        // Compose overlay insets itself via safeDrawingPadding, so only the video
        // extends under the cutout — no control is ever placed there.
        // `ALWAYS` from API 30, `SHORT_EDGES` on 28–29. Android 15 deprecated
        // DEFAULT/SHORT_EDGES/NEVER (Play Console flags the use): with
        // edge-to-edge enforced from targetSdk 35 the window already extends
        // into the cutout, so the three modes that describe *not* doing that no
        // longer describe anything, and `ALWAYS` is the one that survives.
        // `ALWAYS` is public API from 30 only, so the older constant stays for
        // 28–29 — where it is not deprecated and is still the correct value.
        // Behaviour is unchanged either way: the video reaches the physical edge
        // instead of being letterboxed away from the cutout in landscape, and
        // the Compose overlay still insets itself via `safeDrawingPadding`, so
        // no control is ever placed under the cutout.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            window.attributes = window.attributes.apply {
                layoutInDisplayCutoutMode =
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
                    } else {
                        @Suppress("DEPRECATION")
                        WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
                    }
            }
        }
        hideSystemUi()

        val streamUrl = intent.getStringExtra(EXTRA_URL)
        if (streamUrl.isNullOrBlank()) {
            finish()
            return
        }
        url = streamUrl
        headers = requestHeaders()
        subtitles = subtitleSpecs()

        // Seamless handoff: when the live preview is already playing this exact
        // stream, adopt its running engine — only the video output moves to this
        // Activity's surface; audio, decoder and buffer carry over untouched.
        val shared = if (intent.getBooleanExtra(EXTRA_ADOPT_SHARED, false)) {
            SharedEngine.adoptForFullscreen(
                streamUrl,
                diagnosticSink,
                // Bound with the diagnostics, i.e. *before* the claim: it is
                // the claimed surface's own first frame that moves
                // FrameLivenessWatch off the first-frame clock, and inferring
                // it from the frame counter would fire during the deferred
                // claim, while the preview texture is still the output.
                onClaimedSurfaceFirstFrame = { frameLiveness.markHandoffFirstFrame() },
            )
        } else {
            null
        }
        adoptedShared = shared != null
        // The handoff's outcome, in the *exportable* log rather than logcat: a
        // refused adoption is a full stream reload, which is exactly what a user
        // reporting a slow, "reconnecting" preview→fullscreen transition sees.
        // Both halves are credential-free booleans.
        MainActivity.instance?.get()?.logPlaybackDiagnostic(
            "native fullscreen adoptShared=" +
                "${intent.getBooleanExtra(EXTRA_ADOPT_SHARED, false)} adopted=$adoptedShared",
        )

        uiState = shared?.second
            ?: PlayerUiState(
                title = intent.getStringExtra(EXTRA_TITLE).orEmpty(),
                isLive = intent.getBooleanExtra(EXTRA_IS_LIVE, false),
                sourceName = intent.getStringExtra(EXTRA_SOURCE_NAME),
                isTv = isTelevision(),
                epgNow = epgEntry(EXTRA_EPG_NOW_TITLE, EXTRA_EPG_NOW_START, EXTRA_EPG_NOW_STOP, EXTRA_EPG_NOW_DESC),
                epgNext = epgEntry(EXTRA_EPG_NEXT_TITLE, EXTRA_EPG_NEXT_START, EXTRA_EPG_NEXT_STOP, null),
            )
        if (shared != null) {
            // The adopted state was born for the faceless preview — fill in this
            // stream's presentation fields and reset any stale overlay state.
            uiState.title = intent.getStringExtra(EXTRA_TITLE).orEmpty()
            uiState.isLive = intent.getBooleanExtra(EXTRA_IS_LIVE, false)
            uiState.sourceName = intent.getStringExtra(EXTRA_SOURCE_NAME)
            uiState.isTv = isTelevision()
            uiState.epgNow = epgEntry(EXTRA_EPG_NOW_TITLE, EXTRA_EPG_NOW_START, EXTRA_EPG_NOW_STOP, EXTRA_EPG_NOW_DESC)
            uiState.epgNext = epgEntry(EXTRA_EPG_NEXT_TITLE, EXTRA_EPG_NEXT_START, EXTRA_EPG_NEXT_STOP, null)
            uiState.controlsVisible = true
            uiState.openMenu = PlayerMenu.None
            uiState.infoOpen = false
            uiState.inPip = false
        }
        // Android TV's PiP framework restricts entry to communication/smartHome/health/ticker
        // use cases via a required manifest category — general media playback isn't an
        // approved category there, so FEATURE_PICTURE_IN_PICTURE is intentionally left
        // unused/absent for our purposes on most TVs. That's a platform limitation, not a bug:
        // the button below simply won't show on devices that report the feature missing.
        uiState.supportsPip = supportsPip()
        // Favorite toggle (live only): seeded from the Dart store, read back on
        // exit (see finish) so the channel list reflects it on return.
        uiState.canFavorite = intent.getBooleanExtra(EXTRA_CAN_FAVORITE, false)
        uiState.isFavorite = intent.getBooleanExtra(EXTRA_IS_FAVORITE, false)

        if (shared != null) {
            val sharedEngine = shared.first
            sharedEngine.onUnsupportedVideo = { runOnUiThread { fallbackToMpv() } }
            sharedEngine.onRecoverableError = { runOnUiThread { reconnectLive(force = true) } }
            sharedEngine.onVideoSizeChanged = null
            setEngine(sharedEngine)
            // Fullscreen always plays unmuted, and resumes a paused preview.
            sharedEngine.setVolume(1f)
            sharedEngine.play()
            // The surface claim happened inside adoptForFullscreen above, and
            // the frames the preview drew before it are the proof
            // FrameLivenessWatch otherwise has to wait to observe — which, when
            // the handoff freezes the renderer before its first frame, never
            // arrives. Arming here is what turns that permanent silent freeze
            // into a stall the watchdog can act on. armed=false means the
            // engine reported no frames at all, so the inert rule still stands.
            val armed = frameLiveness.armHandoff(
                System.currentTimeMillis(),
                sharedEngine.renderedFrameCount,
            )
            logNative("handoff frame watch armed=$armed")
        } else {
            startWithExoPlayer()
            // VOD resume: jump to the saved position once the engine loads.
            // ExoPlayer remembers a seek issued right after load/prepare.
            val resumeMs = intent.getLongExtra(EXTRA_RESUME_MS, 0L)
            if (resumeMs > 0L && !uiState.isLive) engine?.seekTo(resumeMs)
        }

        if (BuildConfig.DEBUG) {
            val soakAutoCloseMs = intent.getLongExtra(EXTRA_SOAK_AUTOCLOSE_MS, -1L)
            if (soakAutoCloseMs > 0L) {
                soakAutoCloseJob = lifecycleScope.launch {
                    delay(soakAutoCloseMs)
                    finish()
                }
            }
        }

        // The video view is hosted *by Compose* (`AndroidView` in [PlayerScreen]),
        // not attached here in `onCreate`. That was measured, not assumed: hoisting
        // it into a FrameLayout under the ComposeView changed nothing, because
        // `AndroidView` adds the SurfaceView during the first **composition**,
        // which happens inside the window's first traversal — the same traversal
        // that would lay out a pre-attached view. There is no second traversal to
        // save, and the ~150 ms between composition and `surfaceCreated` is
        // surface allocation, not scheduling. See docs/player.md.
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
        )
        exo.onUnsupportedVideo = { runOnUiThread { fallbackToMpv() } }
        exo.onRecoverableError = { runOnUiThread { reconnectLive(force = true) } }
        exo.onDiagnostic = diagnosticSink
        setEngine(exo)
        exo.load(url, subtitles)
    }

    /** One-way fallback: ExoPlayer couldn't decode the video → switch to libmpv. */
    private fun fallbackToMpv() {
        if (engine is MpvEngine || isFinishing) return
        Log.i(TAG, "falling back to libmpv (video unsupported by ExoPlayer)")
        // An engine swap mid-session is a full stream reload on a channel the
        // user was already watching — very much part of "it stopped working
        // when I went fullscreen", and previously logcat-only.
        logNative("engine fallback from=exo to=mpv adopted=$adoptedShared")
        frameLiveness.reset()
        if (adoptedShared) {
            // The adopted engine can't decode this stream, so the shared preview
            // engine is dead too: release it through the holder, which tells the
            // Dart side to reset its preview state (it falls back to media_kit).
            adoptedShared = false
            SharedEngine.invalidateFromFullscreen()
        } else {
            engine?.release()
        }
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
        // A re-resolve in flight *is* the reconnect, still in progress. Without
        // this the round trip would read as healthy and reset the backoff: the
        // engine sits in its terminal state (no further transition callback) and
        // `reconnectLive` already cleared `ended`, so both flags are false until
        // the reload actually starts.
        if (resolveGate.inFlight) return
        val now = System.currentTimeMillis()
        // "Playing normally" by the engine's own account. When that is true and
        // no frame has reached the screen for NO_FRAME_STALL_MS, the account is
        // wrong — see [FrameLivenessWatch] for the failure it catches.
        val claimsHealthy =
            uiState.isPlaying && !uiState.isBuffering && !uiState.ended
        val frameStalled = frameLiveness.sample(
            nowMs = now,
            playingNormally = claimsHealthy,
            renderedFrames = engine?.renderedFrameCount ?: -1,
        )
        val stalled = uiState.isBuffering || uiState.ended || frameStalled
        if (!stalled) {
            // Healthy playback: clear the stall clock and any reconnecting state.
            stalledSinceMs = 0L
            reconnectAttempt = 0
            stallKind = "none"
            if (uiState.reconnecting) uiState.reconnecting = false
            return
        }
        // A renderer frozen this soon after the fullscreen surface claim gets
        // the local fix first — reloading the stream to repair a decoder is
        // both slower and more expensive than repairing the decoder.
        if (frameStalled && tryHandoffDecoderRebuild(now)) return
        if (stalledSinceMs == 0L) stalledSinceMs = now
        // A frozen renderer needs no further grace period: the watch has
        // already waited out its own window while everything read healthy, so
        // requiring the stall threshold on top would double it.
        val threshold = when {
            frameStalled -> 0L
            uiState.ended -> ReconnectPolicy.ENDED_RECONNECT_MS
            else -> ReconnectPolicy.STALL_RECONNECT_MS
        }
        stallKind = when {
            frameStalled -> "noframes"
            uiState.ended -> "ended"
            else -> "buffering"
        }
        if (now - stalledSinceMs >= threshold) reconnectLive(force = false)
    }

    /**
     * First rung of the recovery ladder for the preview→fullscreen handoff:
     * rebuild the video decoder in place instead of reloading the stream.
     *
     * The reports this answers are all the same session shape — an adopted
     * handoff, a claimed surface, and then either no picture at all or a
     * picture that stops within a second — and the exported logs behind them
     * all end the same way: the reload that eventually fired *fixed* it, on the
     * same URL (`refreshed=false`), on the same surface, after which the same
     * channel played for minutes without a drop. A stream and a device that
     * demonstrably work, through a decoder that stopped when its output surface
     * was switched under it. Nothing about that needs the network re-touched:
     * a reload spends a provider round trip and the whole buffer to build the
     * one thing that was actually broken, while carrying the risk that a
     * single-connection account refuses the new connection.
     *
     * Bounded to one attempt inside the handoff window ([FrameLivenessWatch]);
     * everything past that is the reload watchdog's, unchanged. Re-arms the
     * watch so a rebuild that *doesn't* restore the picture escalates on the
     * short handoff clock rather than the full six-second one.
     */
    private fun tryHandoffDecoderRebuild(nowMs: Long): Boolean {
        if (!frameLiveness.inHandoffWindow(nowMs)) return false
        if (handoffRebuilds >= MAX_HANDOFF_REBUILDS) return false
        val active = engine ?: return false
        // Counters first: after the rebuild they describe the new decoder, and
        // it is the frozen one's tallies that say *which* failure this was —
        // frames decoded and thrown away to catch up, or a decoder that had
        // stopped emitting entirely.
        val counters = active.videoFrameCounters
        // Which of the two handoff failures this was: a picture that never
        // arrived on the claimed surface, or one that arrived and stopped. They
        // are indistinguishable in the tallies (a single rendered frame is lost
        // in a preview's running total) and they are the two shapes the reports
        // keep alternating between, so the watch's own answer is worth a word.
        val phase = if (frameLiveness.drewSinceArm()) "afterFirstFrame" else "noFirstFrame"
        if (!active.rebuildVideoDecoder()) return false
        handoffRebuilds++
        logNative(
            "handoff decoder rebuild attempt=$handoffRebuilds phase=$phase" +
                (counters?.let { " $it" } ?: ""),
        )
        stalledSinceMs = 0L
        stallKind = "none"
        frameLiveness.armHandoff(nowMs, active.renderedFrameCount)
        return true
    }

    /**
     * Reload the live source to reconnect, with capped backoff between attempts.
     * [force] (a hard error) skips the stall threshold but still rate-limits.
     *
     * The reload goes through a **fresh locator** ([withFreshLiveLocator]):
     * Stalker `create_link` URLs carry single-use `play_token`s, so after a
     * portal-side kill the URL this Activity was launched with is permanently
     * dead and retrying it can never reconnect.
     */
    private fun reconnectLive(force: Boolean) {
        if (!uiState.isLive || isFinishing) return
        // Single-flight: a re-resolve already in flight (this watchdog or the
        // user's "Go to live") owns the next reload. Bail *before* the attempt
        // bookkeeping so a suppressed attempt can't inflate the backoff; the
        // 500ms progress ticker re-enters once the in-flight request settles.
        if (resolveGate.inFlight) return
        val now = System.currentTimeMillis()
        val sinceLast = now - lastReconnectMs
        val minGap = ReconnectPolicy.minGapMs(reconnectAttempt, force)
        if (lastReconnectMs != 0L && sinceLast < minGap) return
        reconnectAttempt++
        lastReconnectMs = now
        stalledSinceMs = now
        uiState.reconnecting = true
        uiState.ended = false
        Log.i(TAG, "live reconnect attempt=$reconnectAttempt force=$force")
        // Rate-limited above, so this is once per real attempt rather than once
        // per 500 ms tick. `kind` is what makes it worth exporting: an underrun,
        // a drop and a frozen renderer want completely different answers, and
        // all three used to arrive as the same silent black screen.
        logNative(
            "live reconnect attempt=$reconnectAttempt force=$force " +
                "kind=${if (force) "error" else stallKind}" +
                // Frame tallies at the moment of the decision: they are what
                // separate a decoder throwing frames away to catch up from one
                // that has stopped emitting, which read identically from every
                // health flag the engine exposes.
                (engine?.videoFrameCounters?.let { " $it" } ?: ""),
        )
        frameLiveness.reset()
        withFreshLiveLocator {
            // The round trip is asynchronous, so restart the stall clock when
            // the reload actually begins rather than when it was requested.
            stalledSinceMs = System.currentTimeMillis()
            engine?.load(url, subtitles)
        }
    }

    /**
     * Re-resolves the live locator through Dart, then runs [onFresh] with [url]
     * / [headers] updated in place. Returns false — doing nothing — when a
     * request is already in flight: provider accounts are single-connection, so
     * two overlapping `create_link` calls would fight over the one slot.
     *
     * Settlement is a race between the MethodChannel reply and a
     * [ResolveGate.TIMEOUT_MS] backstop, arbitrated by the gate's monotonic
     * token so exactly one of them applies an outcome and the loser is dropped.
     * The timeout is deliberately long: falling back early just reloads the
     * spent locator we already know is dead, which is strictly worse than
     * waiting. Any answer we can't use falls back to the current locator
     * ([ResolveAgainReply]), so this always ends in a reload attempt.
     */
    private fun withFreshLiveLocator(onFresh: () -> Unit): Boolean {
        val token = resolveGate.begin() ?: return false
        resolveTimeoutJob = lifecycleScope.launch {
            delay(ResolveGate.TIMEOUT_MS)
            resolveTimeoutJob = null
            settleFreshLiveLocator(token, reply = null, timedOut = true, onFresh = onFresh)
        }
        val host = MainActivity.instance?.get()
        if (host == null) {
            // No Flutter host to ask (it was destroyed under us) — settle now on
            // the current locator instead of waiting out the whole timeout.
            settleFreshLiveLocator(token, reply = null, timedOut = false, onFresh = onFresh)
        } else {
            host.requestFreshLiveLocator { reply ->
                settleFreshLiveLocator(token, reply, timedOut = false, onFresh = onFresh)
            }
        }
        return true
    }

    private fun settleFreshLiveLocator(
        token: Long,
        reply: Any?,
        timedOut: Boolean,
        onFresh: () -> Unit,
    ) {
        // Lost the race (or belongs to an already-settled request): discard.
        if (!resolveGate.settle(token)) return
        resolveTimeoutJob?.cancel()
        resolveTimeoutJob = null
        // A reply can still land after teardown (the channel callback outlives
        // this Activity); nothing to reload then.
        if (isFinishing || isDestroyed) return
        val next = ResolveAgainReply.parse(reply, LiveLocator(url, headers))
        val refreshed = next.url != url
        url = next.url
        // Headers are baked into an engine's data-source factory at construction
        // (see SharedEngine.openPreview / MpvEngine), so this only takes effect
        // for a later engine build — an mpv fallback. Re-resolving the same
        // channel on the same source can't change them in practice; the
        // never-blank rule in ResolveAgainReply is what keeps a MAG User-Agent
        // from being dropped if a reply ever omits them.
        headers = next.headers
        // Never log the locator itself — provider URLs embed credentials. The
        // two booleans are safe and are what separate "the portal gave us a new
        // link and it still didn't play" from "we retried a locator we already
        // knew was dead because the round trip timed out".
        Log.i(TAG, "live re-resolve settled refreshed=$refreshed timedOut=$timedOut")
        logNative("live re-resolve refreshed=$refreshed timedOut=$timedOut")
        onFresh()
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
        // Re-resolves first, through the same single-flight gate the reconnect
        // watchdog uses: the locator may already be spent, and two concurrent
        // `create_link` calls would exceed a single-connection account.
        onGoLive = {
            if (uiState.isLive) {
                val started = withFreshLiveLocator { engine?.load(url, subtitles) }
                if (started) uiState.liveSynced = true
            }
        },
        // Toggle locally; the final state is returned to Dart on finish, which
        // persists it (no live channel exists from this Activity to Dart).
        onToggleFavorite = { uiState.isFavorite = !uiState.isFavorite },
        onBack = { finish() },
        onEnterPip = { enterPip() },
    )

    override fun onStart() {
        super.onStart()
        progressTicker = lifecycleScope.launch {
            while (isActive) {
                engine?.syncProgress()
                pollLiveReconnect()
                samplePlaybackStats()
                // Faster while a frozen renderer is still attributable to the
                // fullscreen surface claim: that window is judged on
                // HANDOFF_POST_FRAME_STALL_MS, which the base cadence cannot
                // resolve (a single tick gap would decide it). Bounded by
                // HANDOFF_WINDOW_MS, so it costs five seconds per handoff and
                // nothing for the rest of the session.
                delay(
                    if (frameLiveness.inHandoffWindow(System.currentTimeMillis())) {
                        ReconnectPolicy.HANDOFF_POLL_MS
                    } else {
                        ReconnectPolicy.PROGRESS_TICK_MS
                    },
                )
            }
        }.also { job ->
            DebugCounters.incProgressTicker()
            // Fires exactly once whether the job is cancelled (onStop) or
            // completes on its own, so the counter can't double-decrement.
            job.invokeOnCompletion { DebugCounters.decProgressTicker() }
        }
    }

    override fun onStop() {
        super.onStop()
        progressTicker?.cancel()
        progressTicker = null
        // Keep playing while in PiP (onStop can fire around the PiP window on
        // some devices); only pause when actually backgrounded. An adopted engine
        // on its way back to the preview keeps playing too — pausing here would
        // put an audio gap in an otherwise seamless return.
        if (!uiState.inPip && !(isFinishing && adoptedShared)) engine?.pause()
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
        if (isInPictureInPictureMode) enteredPip = true
        uiState.inPip = isInPictureInPictureMode
        if (isInPictureInPictureMode) {
            // Collapse all chrome so the PiP window is video-only.
            uiState.controlsVisible = false
            uiState.openMenu = PlayerMenu.None
            uiState.infoOpen = false
            // Behind the PiP window sits MainActivity's task showing the black
            // Flutter handoff route — recede *that* task so the launcher shows
            // instead. It must be moved via MainActivity: entering PiP reparents
            // this Activity into its own pinned task, so moveTaskToBack(false)
            // from here would send the PiP window itself to the back (black
            // screen all around — the original 0.1.13 bug).
            MainActivity.instance?.get()?.moveTaskToBack(true)
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

    /**
     * Every exit path funnels through finish() (including system Back via the
     * dispatcher), so report the final playback position here — the Dart side
     * persists it as the VOD resume point when [MainActivity] relays it on
     * `nativeClosed`.
     */
    override fun finish() {
        if (::uiState.isInitialized) {
            val result = Intent()
            var hasResult = false
            if (!uiState.isLive) {
                result.putExtra(RESULT_POSITION_MS, uiState.positionMs)
                result.putExtra(RESULT_DURATION_MS, uiState.durationMs)
                hasResult = true
            }
            // Report the final favorite state (live or VOD) so Dart can persist
            // it — this is the only channel back to the store from this Activity.
            if (uiState.canFavorite) {
                result.putExtra(RESULT_FAVORITE, uiState.isFavorite)
                hasResult = true
            }
            if (hasResult) setResult(RESULT_OK, result)
        }
        if (enteredPip) restoreMainTaskAfterPip()
        super.finish()
    }

    /**
     * PiP places this Activity in a pinned task and the Flutter task is moved
     * behind the launcher on entry.  Reorder the already-running MainActivity
     * task before finishing so nativeClosed is delivered into the visible
     * Flutter route rather than leaving the user at the home screen.
     */
    private fun restoreMainTaskAfterPip() {
        if (MainActivity.instance?.get() == null) return
        try {
            startActivity(
                Intent(this, MainActivity::class.java).addFlags(
                    Intent.FLAG_ACTIVITY_REORDER_TO_FRONT,
                ),
            )
        } catch (e: Exception) {
            Log.w(TAG, "could not restore Flutter task after PiP", e)
        }
    }

    override fun onDestroy() {
        soakAutoCloseJob?.cancel()
        soakAutoCloseJob = null
        // lifecycleScope cancels this anyway; dropping the reference here also
        // releases the captured reload callback immediately.
        resolveTimeoutJob?.cancel()
        resolveTimeoutJob = null
        if (adoptedShared) {
            // Not ours to release: hand the video output back to the preview
            // surface; the engine keeps playing across the return.
            adoptedShared = false
            SharedEngine.fullscreenDetached()
        } else {
            engine?.release()
        }
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

    /**
     * Immersive fullscreen, via the supported inset API.
     *
     * The old `systemUiVisibility` flag set has been deprecated since API 30, and
     * from targetSdk 35 its `LAYOUT_*` half is meaningless anyway: edge-to-edge is
     * enforced and `setDecorFitsSystemWindows` is disabled, so the window already
     * extends behind the bars. [WindowInsetsControllerCompat] is the replacement;
     * `BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE` reproduces `IMMERSIVE_STICKY` — a
     * swipe reveals the bars transiently and they hide themselves again.
     *
     * [WindowCompat.setDecorFitsSystemWindows] is kept for API 26–34, where it is
     * still what makes the window lay out edge-to-edge (it is the no-op on 35+,
     * not the other way round).
     */
    private fun hideSystemUi() {
        WindowCompat.setDecorFitsSystemWindows(window, false)
        WindowInsetsControllerCompat(window, window.decorView).apply {
            systemBarsBehavior =
                WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            hide(WindowInsetsCompat.Type.systemBars())
        }
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

        /** Adopt the shared preview engine instead of loading fresh (see [SharedEngine]). */
        const val EXTRA_ADOPT_SHARED = "adopt_shared"

        /** VOD resume: start playback at this position (ms), 0 = from the top. */
        const val EXTRA_RESUME_MS = "resume_ms"

        /**
         * Debug-only: auto-`finish()` this many ms after open, so an
         * integration-test soak can cycle the Activity unattended. Read only
         * when [BuildConfig.DEBUG]; absent/non-positive means never scheduled.
         */
        const val EXTRA_SOAK_AUTOCLOSE_MS = "soak_autoclose_ms"

        /** Favorite toggle (live channels): whether to show the star + its seed state. */
        const val EXTRA_CAN_FAVORITE = "can_favorite"
        const val EXTRA_IS_FAVORITE = "is_favorite"

        /** Result extras: final position/duration + favorite, for the Dart stores. */
        const val RESULT_POSITION_MS = "position_ms"
        const val RESULT_DURATION_MS = "duration_ms"
        const val RESULT_FAVORITE = "favorite"

        /**
         * Local decoder rebuilds allowed per handoff. One: a second would be a
         * loop with a stall threshold, and the failure it treats is a
         * one-time event (a surface switch) that a rebuild either survives or
         * doesn't. See [tryHandoffDecoderRebuild].
         */
        private const val MAX_HANDOFF_REBUILDS = 1
        private const val TAG = "iptvs.hdr"
    }
}
