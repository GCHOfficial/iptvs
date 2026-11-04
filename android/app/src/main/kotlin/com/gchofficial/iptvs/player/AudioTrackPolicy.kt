package com.gchofficial.iptvs.player

import java.util.Locale
import kotlin.math.abs
import kotlin.math.log10

/**
 * Why an [ExoPlayerEngine] gave up and handed the stream to libmpv.
 *
 * Carried on the fallback callback and printed as `reason=` on the engine-swap
 * line, because an exported log that only says "fell back" cannot separate the
 * Dolby Vision case the fallback was built for from the DVB-audio case it now
 * also covers — and those want opposite follow-up questions.
 */
object EngineFallbackReason {
    /** No decodable video track (chiefly DV Profile 5 on non-DV hardware). */
    const val VIDEO = "video"

    /** Audio tracks exist and **none** of them can be decoded — see [AudioTrackPolicy]. */
    const val AUDIO = "audio"

    /** ExoPlayer raised a decode error mid-stream. */
    const val DECODE = "decode"

    /** `setMediaItem`/`prepare` threw — a container whose media3 module isn't linked. */
    const val SOURCE = "source"
}

/**
 * The Android-free half of the audio diagnostics: the "is any audio playable?"
 * decision and the strings that describe it.
 *
 * ## Why a fallback on audio exists at all
 *
 * `MediaCodecAudioRenderer.supportsFormat` answers `FORMAT_UNSUPPORTED_SUBTYPE`
 * when the device has no `MediaCodec` for the MIME type, and `DefaultTrackSelector`
 * only ever selects a track whose support is `FORMAT_HANDLED` (or
 * `FORMAT_EXCEEDS_CAPABILITIES`, which it will stretch to when nothing better
 * exists). An undecodable audio track is therefore **silently deselected**: no
 * error, no `PlaybackException`, no state change — the picture plays and there is
 * no sound, forever, and nothing reaches the log.
 *
 * That is not hypothetical. A Xiaomi 11T Pro playing an SD MPEG-TS channel whose
 * audio is DVB MP2 (`audio/mpeg-L2`) has no decoder for it; phones routinely ship
 * MP3 and AAC decoders and no MP2 one. libmpv decodes it through FFmpeg without
 * trouble, and the mpv fallback already exists for exactly "this device cannot
 * decode this stream" — it was simply only ever asked about video.
 *
 * ## The playability rule
 *
 * [AudioTrack.playable] mirrors what the *selector* will do, not what the device
 * advertises: `FORMAT_EXCEEDS_CAPABILITIES` counts as playable because
 * `DefaultTrackSelector.exceedRendererCapabilitiesIfNecessary` defaults to true
 * and will select such a track rather than leave the renderer silent. Treating it
 * as unplayable would throw a working (if strained) stream at mpv.
 */
object AudioTrackPolicy {

    /** One audio track, flattened out of `Tracks.Group` with no media3 types attached. */
    data class AudioTrack(
        /** Will `DefaultTrackSelector` select this track if it needs to? */
        val playable: Boolean,
        /** Is it selected right now? */
        val selected: Boolean,
        /** `Format.sampleMimeType`, e.g. `audio/mpeg-L2`; null when the demuxer didn't say. */
        val mime: String?,
        /** `Format.channelCount`, or 0 when unknown (`Format.NO_VALUE`). */
        val channelCount: Int,
    )

    /**
     * True when the stream carries audio that this device cannot play.
     *
     * Deliberately **not** true for a stream with no audio at all: a video-only
     * channel is a real thing, and mpv would not improve it. That case is
     * reported by [summaryLine] (`tracks=0`) instead, which is what separates
     * "the provider sent no audio" from "the provider sent audio we can't
     * decode" in an export.
     */
    fun shouldFallback(tracks: List<AudioTrack>): Boolean =
        tracks.isNotEmpty() && tracks.none { it.playable }

    /**
     * The one line emitted per load, at the first `onTracksChanged` that carries
     * any track groups.
     *
     * Shape: `audio tracks=N supported=M selected=<label>|none unsupported=<label,…>`
     * — the counts answer "did the provider send audio?", `selected` answers
     * "is something feeding the renderer?", and the unsupported list names the
     * MIME type a missing decoder would have to be found for.
     */
    fun summaryLine(tracks: List<AudioTrack>): String {
        val playable = tracks.count { it.playable }
        val selected = tracks.firstOrNull { it.selected }
        val unsupported = tracks.filter { !it.playable }
        return buildString {
            append("audio tracks=").append(tracks.size)
            append(" supported=").append(playable)
            append(" selected=")
            append(selected?.let { trackLabel(it.mime, it.channelCount) } ?: "none")
            if (unsupported.isNotEmpty()) {
                append(" unsupported=")
                append(unsupported.joinToString(",") { trackLabel(it.mime, it.channelCount) })
            }
        }
    }

    /** `mpeg-L2 2ch`, `ac3 6ch`, `aac`, or `?` — never a URL or a provider string. */
    fun trackLabel(mime: String?, channelCount: Int): String {
        val name = shortMime(mime)
        return if (channelCount > 0) "$name ${channelCount}ch" else name
    }

    /** `audio/mpeg-L2` → `mpeg-L2`; blank/null → `?`. */
    fun shortMime(mime: String?): String {
        val trimmed = mime?.trim().orEmpty()
        if (trimmed.isEmpty()) return "?"
        return trimmed.substringAfter('/', trimmed)
    }

    /**
     * The peak-level readout for the health sample.
     *
     * It is what separates "the decoder ran and produced silence" from "the
     * decoder produced sound and something downstream ate it" — the two halves
     * of a no-audio report that look identical in every counter media3 exposes.
     *
     * @param peak the largest absolute 16-bit sample seen in the window
     * @param sawPcm whether any PCM was measured at all
     * @param passthrough whether the sink is sending encoded audio to the HDMI
     *   receiver, in which case there are no samples to measure by construction
     */
    fun peakLabel(peak: Int, sawPcm: Boolean, passthrough: Boolean): String {
        if (passthrough) return "n/a(passthrough)"
        if (!sawPcm) return "n/a"
        if (peak <= 0) return "-inf"
        val ratio = abs(peak).toDouble() / FULL_SCALE
        return String.format(Locale.US, "%.1fdBFS", 20.0 * log10(ratio))
    }

    /** 16-bit full scale; the sink's user processors always run after `ToInt16Pcm`. */
    const val FULL_SCALE = 32_768.0

    /**
     * How long the peak probe looks at samples, measured from the **first**
     * buffer it sees rather than from arming, so a slow-starting stream is
     * still measured rather than being measured as silence.
     *
     * Five seconds is long enough to clear a quiet passage between words and
     * short enough that the probe is inert for all but the opening of a
     * session.
     */
    const val PEAK_WINDOW_MS = 5_000L

    /**
     * Delay from the first evidence of output (a rendered video frame, or the
     * audio track advancing) to the single health sample. Deliberately past
     * [PEAK_WINDOW_MS] so the peak it prints is a finished measurement.
     */
    const val HEALTH_SAMPLE_DELAY_MS = 6_000L

    /**
     * Cap on audio codec/sink error lines per load. These arrive from a renderer
     * that can retry, so a wedged sink can emit them continuously — and the
     * exportable log is an 800-entry ring that a flood would empty of everything
     * else, which is the opposite of what the instrumentation is for.
     */
    const val MAX_ERROR_LINES = 3
}
