package com.gchofficial.iptvs.player

import java.util.Locale

/**
 * Playing a live stream slightly faster than real time to give back a delay
 * the viewer never chose — ExoPlayer's only lever against a provider's connect
 * backlog.
 *
 * ## Why this exists, and why it is the *only* thing ExoPlayer can do
 *
 * Providers commonly answer a live request with a burst of already-recorded
 * media — one measured portal sent ~76 s of it — and playback begins at that
 * burst's oldest frame. The viewer is a minute behind the broadcast before the
 * first frame is drawn, with no stall, no rebuffer and nothing to fix.
 *
 * Every obvious remedy is closed on this engine:
 *  * **A smaller buffer does not help.** The backlog is held on the provider's
 *    side; a shallower readahead only reduces stall protection, and that is why
 *    wave 2 changes no cache-size default.
 *  * **Seeking forward is not available.** media3's `ProgressiveMediaPeriod`
 *    treats a seek on non-seekable live media as a restart at t=0, so the
 *    in-cache skip the mpv surfaces use (docs/player.md, "Live latency") has no
 *    counterpart here.
 *  * **Reconnecting re-receives the backlog**, which is why the "Go to live"
 *    chip is deliberately not offered for it ([LiveLatencyTracker.driftBehind]).
 *
 * What is left is the playback clock. At **1.05x** a 60 s backlog is gone in
 * twenty minutes of viewing, pitch-corrected (media3 routes
 * `setPlaybackSpeed` through Sonic, which preserves pitch) and — at 5% — below
 * the threshold at which speech sounds hurried. It is deliberately not 1.10x:
 * the ceiling here is not "how fast can we recover" but "what will never be
 * noticed by someone who did not ask for it".
 *
 * ## What governs it
 *
 * The engage threshold is the preset's own sustained cushion
 * ([ExoBufferPolicy.Durations.minBufferMs]) plus [ENGAGE_MARGIN_MS], and it
 * disengages back at the cushion itself. The gap between those two is
 * mandatory rather than tidy: the cushion is what the loader is actively
 * steering towards, so a single threshold would flip the speed several times a
 * minute, and an audibly wavering pitch-corrected rate is far worse than the
 * delay it is fixing.
 *
 * Because the target *is* the preset's cushion, a user who picks "Large" is
 * asking to watch further behind live, and catch-up respects that rather than
 * fighting it: it only ever recovers delay the preset did not ask for.
 *
 * Pure and clock-injected like [ReconnectPolicy] / [LiveLatency], so every veto
 * is covered by plain JUnit rather than by a device.
 */
object CatchUpPolicy {
    /**
     * The one speed above normal this will ever use.
     *
     * Chosen to be inaudible rather than fast. Pitch is corrected, so what
     * remains is tempo: 5% is roughly one syllable in twenty and sits under
     * what listeners reliably detect, while 10% is the point at which speech
     * starts to read as hurried. The recovery rate that buys — 3 s of delay per
     * minute watched — clears any realistic backlog well inside one programme.
     */
    const val SPEED = 1.05f

    /** Real time. The floor: this policy never slows playback down. */
    const val NORMAL_SPEED = 1.0f

    /**
     * How far past the preset's cushion the buffer must run before catch-up
     * engages.
     *
     * Ten seconds is far more than the loader's own overshoot (it stops filling
     * at `maxBufferMs` and resumes below `minBufferMs`, so the cushion
     * oscillates by a second or two) and far less than any real backlog. Below
     * this, speeding up would be chasing measurement noise.
     */
    const val ENGAGE_MARGIN_MS = 10_000L

    /**
     * How long after setting the speed the read-back is believed.
     *
     * Not immediate, and that is the whole point. `Player.setPlaybackSpeed`
     * updates the player's own `PlaybackParameters` synchronously, so reading
     * them in the same call stack only proves the request was *stored*. The
     * answer that matters comes back from the audio sink: media3's
     * `DefaultMediaClock` re-reads the renderer clock's effective parameters on
     * each `doSomeWork` and propagates the real value, which for passthrough or
     * tunnelled audio is `PlaybackParameters.DEFAULT`
     * (`DefaultAudioSink.shouldApplyAudioProcessorPlaybackParameters` refuses
     * to speed up encoded audio it cannot decode). One second is two ticks of
     * the 500 ms host ticker, which is ample for that round trip.
     */
    const val VERIFY_AFTER_MS = 1_000L

    /** Float comparison slack for the read-back; speeds here are exact constants. */
    const val SPEED_EPSILON = 0.005f

    /**
     * Audio the device will be **decoding to PCM**, which is the only case
     * where Sonic can re-time it.
     *
     * Encoded audio sent straight to an AV receiver (AC-3, E-AC-3, DTS, AC-4,
     * TrueHD) cannot be sped up without decoding and re-encoding it, so media3
     * silently ignores the request and reports 1.0 back — and on a device that
     * applied it to the *video* clock only, the result would be a progressive
     * A/V desync on a stream the viewer was enjoying. An allow-list rather than
     * a block-list for exactly that reason: a codec nobody listed is refused,
     * not sped up.
     *
     * Stored lowercase because `Format.sampleMimeType` is normalised through
     * `MimeTypes.normalizeMimeType`, which ASCII-lowercases — so media3's own
     * `AUDIO_MPEG_L2` ("audio/mpeg-L2") reaches us as `audio/mpeg-l2`, and a
     * set built from the constants would never match MPEG-1 Layer II, which is
     * what half of DVB-sourced IPTV carries.
     */
    val PCM_DECODABLE_AUDIO: Set<String> = setOf(
        "audio/mp4a-latm", // MimeTypes.AUDIO_AAC
        "audio/mpeg", // MimeTypes.AUDIO_MPEG
        "audio/mpeg-l1", // MimeTypes.AUDIO_MPEG_L1
        "audio/mpeg-l2", // MimeTypes.AUDIO_MPEG_L2
        "audio/opus", // MimeTypes.AUDIO_OPUS
        "audio/vorbis", // MimeTypes.AUDIO_VORBIS
        "audio/flac", // MimeTypes.AUDIO_FLAC
        "audio/raw", // MimeTypes.AUDIO_RAW
    )

    /**
     * Whether the selected audio track can be re-timed. **Fails closed**: an
     * absent or unrecognised MIME type is a refusal, including the window
     * before the first `onTracksChanged` when nothing is known yet.
     */
    fun audioAllowsSpeedUp(sampleMimeType: String?): Boolean {
        val mime = sampleMimeType?.trim()?.lowercase(Locale.ROOT)
        return !mime.isNullOrEmpty() && PCM_DECODABLE_AUDIO.contains(mime)
    }

    /** The log line for engaging. Credential-free: two durations. */
    fun onLine(aheadMs: Long, targetMs: Long): String =
        "live catchup on ahead=${aheadMs}ms target=${targetMs}ms"

    /** The log line for dropping back to real time, naming which rule did it. */
    fun offLine(reason: String): String = "live catchup off reason=$reason"
}

/**
 * Why catch-up is not running. These strings are the `reason=` vocabulary of
 * the `live catchup off` line, so an exported log says which rule stood it
 * down — the difference between "this device refuses to speed this audio up"
 * and "it was briefly buffering" is the difference between a bug report and a
 * non-event.
 */
object CatchUpVeto {
    /** The buffer came back down to the preset's cushion: the job is done. */
    const val IN_RANGE = "inrange"

    /** VOD. Nothing here applies — the viewer is not chasing a live edge. */
    const val NOT_LIVE = "notlive"

    /** The engine is the shared preview's. A faceless preview never catches up. */
    const val PREVIEW = "preview"

    /**
     * media3 reports the item as a live *stream it can steer itself* (HLS with
     * a declared live offset), where speeding up on top of its own
     * `LivePlaybackSpeedControl` would be two controllers fighting over one
     * clock.
     */
    const val ENGINE_LIVE = "hlslive"

    /** The selected audio cannot be re-timed (passthrough/unknown codec). */
    const val AUDIO = "audio"

    const val PAUSED = "paused"
    const val BUFFERING = "buffering"
    const val RECONNECTING = "reconnecting"
    const val ZAP_SETTLING = "zapsettling"

    /** Inside the preview→fullscreen handoff window ([FrameLivenessWatch]). */
    const val HANDOFF = "handoff"

    /** The read-back said the speed never took. Disabled for the session. */
    const val UNSUPPORTED = "unsupported"
}

/**
 * One tick's worth of everything the decision depends on.
 *
 * Passed as a value rather than read from the host so the whole policy is
 * exercised from a unit test: every veto below is a field here.
 */
data class CatchUpSample(
    val nowMs: Long,
    /** Media buffered ahead of the playhead, or -1 when the engine can't say. */
    val aheadMs: Long,
    /** The preset's sustained cushion — the depth catch-up steers back to. */
    val targetMs: Long,
    val isLive: Boolean,
    val isPlaying: Boolean,
    val isBuffering: Boolean,
    val reconnecting: Boolean,
    val zapSettling: Boolean,
    val inHandoffWindow: Boolean,
    val sharedPreview: Boolean,
    /** `Player.isCurrentMediaItemLive()`. */
    val engineManagesLiveOffset: Boolean,
    /** `Format.sampleMimeType` of the selected audio track, or null. */
    val audioSampleMimeType: String?,
    /** `Player.getPlaybackParameters().speed` — the *effective* rate. */
    val actualSpeed: Float,
)

/**
 * What the host should do this tick.
 *
 * [changed] exists so the host writes a log line and touches the player only
 * when something really moved: this runs twice a second for the life of a
 * session, and a `setPlaybackSpeed` per tick would drain the audio processors
 * repeatedly for no change at all.
 */
data class CatchUpDecision(
    val speed: Float,
    val changed: Boolean,
    val log: String?,
) {
    /** What [LiveLatencyTracker.sample] is told, so the delay can be credited. */
    val catchingUp: Boolean get() = speed > CatchUpPolicy.NORMAL_SPEED
}

/**
 * The catch-up state machine: hysteresis, the vetoes, and the one-shot
 * read-back that takes the whole feature off a device that silently ignores it.
 */
class CatchUpController(
    private val speed: Float = CatchUpPolicy.SPEED,
    private val engageMarginMs: Long = CatchUpPolicy.ENGAGE_MARGIN_MS,
    private val verifyAfterMs: Long = CatchUpPolicy.VERIFY_AFTER_MS,
) {
    /** The speed the host has been told to apply, i.e. what the engine is on. */
    var appliedSpeed = CatchUpPolicy.NORMAL_SPEED
        private set

    /**
     * Set once a read-back proved the speed never took, and never cleared.
     *
     * Session-scoped rather than per-stream on purpose: the thing that failed
     * is the device's audio path, not the channel, and re-probing it on every
     * zap would mean a repeated half-second of sped-up-then-not audio for a
     * user whose hardware was never going to allow it.
     */
    var disabledForSession = false
        private set

    private var engaged = false

    // When the pending read-back becomes due, or 0 when none is outstanding.
    private var verifyAtMs = 0L

    /**
     * One tick. Returns the speed to apply, whether it differs from what the
     * engine is already on, and the line to log when it does.
     */
    fun decide(sample: CatchUpSample): CatchUpDecision {
        if (disabledForSession) return settle(false, CatchUpVeto.UNSUPPORTED, sample)

        val veto = vetoFor(sample)
        if (veto != null) return settle(false, veto, sample)

        // The read-back, judged before this tick's own engage/disengage so a
        // device that ignores the speed is caught on the very first engagement
        // rather than on whichever tick happens to disengage.
        if (engaged && verifyAtMs != 0L && sample.nowMs >= verifyAtMs) {
            verifyAtMs = 0L
            if (kotlin.math.abs(sample.actualSpeed - speed) > CatchUpPolicy.SPEED_EPSILON) {
                disabledForSession = true
                return settle(false, CatchUpVeto.UNSUPPORTED, sample)
            }
        }

        // Hysteresis. An unknown cushion (-1) can neither engage nor disengage:
        // it is "no reading", not "no buffer", and acting on it either way
        // would be acting on nothing.
        if (sample.aheadMs >= 0L) {
            if (!engaged && sample.aheadMs > sample.targetMs + engageMarginMs) {
                engaged = true
            } else if (engaged && sample.aheadMs <= sample.targetMs) {
                engaged = false
                return settle(false, CatchUpVeto.IN_RANGE, sample)
            }
        }
        return settle(engaged, null, sample)
    }

    /**
     * Back to real time and forget the engagement, because the stream under
     * this engine is being replaced (every [LiveLatencyTracker] reset point) or
     * the engine itself is going away.
     *
     * [disabledForSession] deliberately survives: it is a fact about the
     * device, and a zap is not new evidence about it.
     */
    fun reset() {
        engaged = false
        verifyAtMs = 0L
        appliedSpeed = CatchUpPolicy.NORMAL_SPEED
    }

    /** First matching veto, in the order a reader would want to be told them. */
    private fun vetoFor(sample: CatchUpSample): String? = when {
        !sample.isLive -> CatchUpVeto.NOT_LIVE
        sample.sharedPreview -> CatchUpVeto.PREVIEW
        sample.engineManagesLiveOffset -> CatchUpVeto.ENGINE_LIVE
        !CatchUpPolicy.audioAllowsSpeedUp(sample.audioSampleMimeType) -> CatchUpVeto.AUDIO
        !sample.isPlaying -> CatchUpVeto.PAUSED
        sample.isBuffering -> CatchUpVeto.BUFFERING
        sample.reconnecting -> CatchUpVeto.RECONNECTING
        sample.zapSettling -> CatchUpVeto.ZAP_SETTLING
        sample.inHandoffWindow -> CatchUpVeto.HANDOFF
        else -> null
    }

    /**
     * Applies the outcome and produces the at-most-one line it is worth.
     *
     * A veto always clears [engaged], so recovering from one re-crosses the
     * engage threshold rather than resuming silently — which is what keeps a
     * flapping stream from toggling the speed on every buffering blip.
     */
    private fun settle(engage: Boolean, reason: String?, sample: CatchUpSample): CatchUpDecision {
        if (!engage) {
            engaged = false
            verifyAtMs = 0L
        }
        val next = if (engage) speed else CatchUpPolicy.NORMAL_SPEED
        if (next == appliedSpeed) return CatchUpDecision(next, changed = false, log = null)
        appliedSpeed = next
        val line = if (engage) {
            // Arm the read-back against the tick that applies the speed, not
            // the one that decided to.
            verifyAtMs = sample.nowMs + verifyAfterMs
            CatchUpPolicy.onLine(sample.aheadMs, sample.targetMs)
        } else {
            CatchUpPolicy.offLine(reason ?: CatchUpVeto.IN_RANGE)
        }
        return CatchUpDecision(next, changed = true, log = line)
    }
}
