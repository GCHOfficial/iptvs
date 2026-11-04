package com.gchofficial.iptvs.player

import android.content.Context
import android.media.MediaFormat
import android.os.Build
import android.os.Handler
import android.os.SystemClock
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.MimeTypes
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.BaseAudioProcessor
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.Renderer
import androidx.media3.exoplayer.audio.AudioSink
import androidx.media3.exoplayer.audio.DefaultAudioSink
import androidx.media3.exoplayer.mediacodec.MediaCodecAdapter
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector
import androidx.media3.exoplayer.video.MediaCodecVideoRenderer
import androidx.media3.exoplayer.video.VideoRendererEventListener
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * A [DefaultRenderersFactory] whose video renderer reports the *decoder's* view of
 * the stream's dynamic range.
 *
 * We can't trust [Format.colorInfo]: for HEVC over MPEG-TS (the bulk of IPTV) the
 * HDR signalling lives in the in-band VUI/SEI, which the TS extractor often doesn't
 * surface into `colorInfo` — so it stays null and the stream looks SDR even while the
 * hardware decoder switches the HDMI output to HDR10/HDR10+. The decoder's *output*
 * [MediaFormat], by contrast, reflects what it actually parsed (VUI + SEI), which is
 * the same ground truth a system overlay reads off the HDMI InfoFrame. It's also the
 * only place HDR10+ dynamic metadata is visible (`KEY_HDR10_PLUS_INFO`, API 29+),
 * letting us tell HDR10+ from plain HDR10.
 *
 * [onDynamicRange] is invoked on the player's internal playback thread — callers must
 * marshal to their UI thread.
 */
@UnstableApi
class HdrRenderersFactory(
    context: Context,
    private val onDynamicRange: (String) -> Unit,
    private val onCodecName: (String) -> Unit = {},
    /**
     * Measures the decoded signal level for the one-shot audio health line.
     * Null leaves the audio sink exactly as `DefaultRenderersFactory` builds it.
     */
    private val audioPeak: AudioPeakProbe? = null,
) : DefaultRenderersFactory(context) {

    /**
     * The renderer this factory built, so the engine can address a
     * [PlayerMessage][androidx.media3.exoplayer.PlayerMessage] at it —
     * `ExoPlayer` hands out no way to find its own renderers by type.
     * Non-null from the moment the player is constructed (a player builds its
     * renderers eagerly, and this app has exactly one video renderer).
     */
    var videoRenderer: HdrMediaCodecVideoRenderer? = null
        private set

    override fun buildVideoRenderers(
        context: Context,
        extensionRendererMode: Int,
        mediaCodecSelector: MediaCodecSelector,
        enableDecoderFallback: Boolean,
        eventHandler: Handler,
        eventListener: VideoRendererEventListener,
        allowedVideoJoiningTimeMs: Long,
        out: ArrayList<Renderer>,
    ) {
        // Replace the default video renderer entirely with our HDR-reporting one.
        // This app keeps extension renderers off (the default), so the MediaCodec
        // renderer is the only video renderer DefaultRenderersFactory would add.
        val renderer = HdrMediaCodecVideoRenderer(
            context,
            getCodecAdapterFactory(),
            mediaCodecSelector,
            allowedVideoJoiningTimeMs,
            enableDecoderFallback,
            eventHandler,
            eventListener,
            MAX_DROPPED_FRAMES_TO_NOTIFY,
            onDynamicRange,
            onCodecName,
        )
        videoRenderer = renderer
        out.add(renderer)
    }

    /**
     * The stock `DefaultAudioSink`, plus one pass-through processor that reads
     * the decoded signal level.
     *
     * Everything here reproduces `DefaultRenderersFactory.buildAudioSink`
     * verbatim (media3 1.11.1) except the `setAudioProcessors` line.
     * `Builder.setAudioProcessors` wraps the array in media3's own
     * `DefaultAudioProcessorChain`, which still appends
     * `SilenceSkippingAudioProcessor` and `SonicAudioProcessor` after it — so
     * silence skipping and, crucially, the 1.05x `CatchUpPolicy` speed
     * adjustment keep working exactly as before.
     *
     * The probe sees nothing under passthrough or offload: `DefaultAudioSink`
     * builds an empty pipeline for non-PCM input ("Audio processing is not
     * supported in offload or passthrough mode"), which is why
     * [AudioTrackPolicy.peakLabel] reports `n/a(passthrough)` rather than a
     * misleading silence.
     */
    override fun buildAudioSink(
        context: Context,
        enableFloatOutput: Boolean,
        enableAudioOutputPlaybackParams: Boolean,
    ): AudioSink {
        val builder = DefaultAudioSink.Builder(context)
            .setEnableFloatOutput(enableFloatOutput)
            .setEnableAudioOutputPlaybackParameters(enableAudioOutputPlaybackParams)
        // Explicitly typed: Kotlin arrays are invariant, so an
        // `Array<AudioPeakProcessor>` would not satisfy `AudioProcessor[]`.
        audioPeak?.let {
            builder.setAudioProcessors(arrayOf<AudioProcessor>(AudioPeakProcessor(it)))
        }
        return builder.build()
    }

    private companion object {
        // Matches DefaultRenderersFactory's own default.
        const val MAX_DROPPED_FRAMES_TO_NOTIFY = 50
    }
}

@UnstableApi
class HdrMediaCodecVideoRenderer(
    context: Context,
    codecAdapterFactory: MediaCodecAdapter.Factory,
    mediaCodecSelector: MediaCodecSelector,
    allowedJoiningTimeMs: Long,
    enableDecoderFallback: Boolean,
    eventHandler: Handler?,
    eventListener: VideoRendererEventListener?,
    maxDroppedFramesToNotify: Int,
    private val onDynamicRange: (String) -> Unit,
    private val onCodecName: (String) -> Unit = {},
) : MediaCodecVideoRenderer(
    context,
    codecAdapterFactory,
    mediaCodecSelector,
    allowedJoiningTimeMs,
    enableDecoderFallback,
    eventHandler,
    eventListener,
    maxDroppedFramesToNotify,
) {

    private var lastReported: String? = null

    /**
     * Adds one message type to the renderer's vocabulary:
     * [MSG_REBUILD_CODEC], which throws the current `MediaCodec` away and lets
     * the renderer build a fresh one against the surface it is already pointed
     * at, on the next `render` pass.
     *
     * `releaseCodec()` + `maybeInitCodecOrBypass()` is not an improvisation:
     * it is verbatim what `MediaCodecVideoRenderer.setOutput` does for itself
     * on a device it knows mishandles `MediaCodec.setOutputSurface`. The
     * decision it makes there is driven by a hardcoded device list, and this
     * exists because a TV chipset that is *not* on that list still comes back
     * from the preview→fullscreen surface switch as a decoder that reports
     * healthy and emits nothing (see [FrameLivenessWatch], docs/player.md).
     * The demuxer, the loaded buffer and the audio pipeline are untouched, so
     * unlike a reload this costs one wait for the next IDR and no provider
     * connection.
     *
     * Runs on the playback thread, addressed through `ExoPlayer.createMessage`.
     */
    override fun handleMessage(messageType: Int, message: Any?) {
        if (messageType == MSG_REBUILD_CODEC) {
            // No codec = nothing to rebuild; the renderer will initialise one
            // against the current surface on its own.
            if (codec != null) {
                releaseCodec()
                maybeInitCodecOrBypass()
            }
            return
        }
        super.handleMessage(messageType, message)
    }

    /**
     * Reports which `MediaCodec` actually got built.
     *
     * The engine sets `enableDecoderFallback`, so when the hardware decoder
     * fails to configure media3 quietly moves to the next one in the list —
     * which is the platform's *software* decoder. A software HEVC decoder
     * cannot sustain 4K50: the stream plays, but crawls. Nothing else the
     * engine exposes distinguishes that from healthy playback (it is not an
     * error, not a stall, and `isPlaying` stays true), so the decoder's name is
     * the only signal. Fires on every codec init, which is also how a repeated
     * rebuild becomes visible.
     */
    override fun onCodecInitialized(
        name: String,
        configuration: MediaCodecAdapter.Configuration,
        initializedTimestampMs: Long,
        initializationDurationMs: Long,
    ) {
        super.onCodecInitialized(
            name,
            configuration,
            initializedTimestampMs,
            initializationDurationMs,
        )
        onCodecName(name)
    }

    override fun onOutputFormatChanged(format: Format, mediaFormat: MediaFormat?) {
        super.onOutputFormatChanged(format, mediaFormat)
        val label = dynamicRangeLabel(format, mediaFormat)
        // KEY_HDR10_PLUS_INFO is updated per frame, so this can fire often; only
        // report transitions to keep the UI marshalling cheap.
        if (label != lastReported) {
            lastReported = label
            onDynamicRange(label)
        }
    }

    private fun dynamicRangeLabel(format: Format, mediaFormat: MediaFormat?): String {
        if (format.sampleMimeType == MimeTypes.VIDEO_DOLBY_VISION) return "Dolby Vision"
        if (mediaFormat != null) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
                mediaFormat.containsKey(MediaFormat.KEY_HDR10_PLUS_INFO)
            ) {
                val info = mediaFormat.getByteBuffer(MediaFormat.KEY_HDR10_PLUS_INFO)
                if (info != null && info.remaining() > 0) return "HDR10+ · PQ"
            }
            when (intKey(mediaFormat, MediaFormat.KEY_COLOR_TRANSFER)) {
                MediaFormat.COLOR_TRANSFER_ST2084 -> return "HDR10 · PQ"
                MediaFormat.COLOR_TRANSFER_HLG -> return "HLG"
            }
            if (intKey(mediaFormat, MediaFormat.KEY_COLOR_STANDARD) ==
                MediaFormat.COLOR_STANDARD_BT2020
            ) {
                return "HDR · BT.2020"
            }
        }
        return "SDR"
    }

    private fun intKey(mediaFormat: MediaFormat, key: String): Int =
        if (mediaFormat.containsKey(key)) mediaFormat.getInteger(key) else -1

    companion object {
        /**
         * Rebuild the video decoder in place. Numbered from
         * [Renderer.MSG_CUSTOM_BASE] (10_000), the range media3 reserves for
         * exactly this, so it can never collide with a message type a future
         * media3 adds.
         */
        const val MSG_REBUILD_CODEC = Renderer.MSG_CUSTOM_BASE + 1
    }
}

/**
 * Largest absolute PCM sample the audio sink has been handed, over a short
 * window after each load.
 *
 * It exists to answer the one question no media3 counter can: a renderer can
 * report a healthy decoder, a climbing `renderedOutputBufferCount` and an
 * `AudioTrack` that is advancing, and still be feeding the speaker digital
 * silence. `peak=-inf` and `peak=-18.3dBFS` are the two sides of a "no sound"
 * report that otherwise produce byte-identical logs.
 *
 * **Measurement only.** The processor it drives never alters a sample — see
 * [AudioPeakProcessor]. Written on the playback/audio thread and read from the
 * main thread, hence the volatiles; nothing here is a correctness dependency,
 * so a torn read would at worst print a slightly stale number.
 */
class AudioPeakProbe {

    @Volatile
    private var windowMs = 0L

    @Volatile
    private var startedAtMs = 0L

    @Volatile
    private var encoding = C.ENCODING_INVALID

    /** The largest absolute 16-bit sample seen since [arm]. */
    @Volatile
    var peak = 0
        private set

    /** Whether any PCM reached the probe at all (false under passthrough). */
    @Volatile
    var sawPcm = false
        private set

    /** Starts a fresh measurement — called from `load`, before the sink reconfigures. */
    fun arm(windowMs: Long) {
        peak = 0
        sawPcm = false
        startedAtMs = 0L
        this.windowMs = windowMs
    }

    /** Stops measuring (engine released, or the window is no longer wanted). */
    fun disarm() {
        windowMs = 0L
    }

    /** The input format the sink configured this processor with. */
    fun noteEncoding(pcmEncoding: Int) {
        encoding = pcmEncoding
    }

    /**
     * Scans [buffer] without consuming it.
     *
     * Only 16-bit PCM is measured: the sink's user processors run *after*
     * `ToInt16PcmAudioProcessor`, so that is what arrives in every
     * configuration this app builds (float output is off). Anything else is
     * left unmeasured rather than guessed at.
     */
    fun scan(buffer: ByteBuffer) {
        if (windowMs <= 0L) return
        if (encoding != C.ENCODING_PCM_16BIT) return
        val now = SystemClock.elapsedRealtime()
        if (startedAtMs == 0L) {
            startedAtMs = now
        } else if (now - startedAtMs > windowMs) {
            // One window per load; after it the processor is a plain copy.
            windowMs = 0L
            return
        }
        sawPcm = true
        var max = peak
        val shorts = buffer.duplicate().order(ByteOrder.nativeOrder()).asShortBuffer()
        while (shorts.hasRemaining()) {
            val sample = shorts.get().toInt()
            val magnitude = if (sample < 0) -sample else sample
            if (magnitude > max) max = magnitude
        }
        peak = max
    }
}

/**
 * A pass-through [androidx.media3.common.audio.AudioProcessor] that reports the
 * signal level to an [AudioPeakProbe] and otherwise outputs its input unchanged.
 *
 * Modelled on media3's own `TeeAudioProcessor` (same base class, same
 * "output the input" `onConfigure`, same `replaceOutputBuffer(...).put(...)`
 * copy), minus its per-buffer read-only `ByteBuffer` view — the probe reads
 * through a `duplicate()` and never advances the caller's position.
 *
 * Cost is one `memcpy` of an audio buffer (a few KB, roughly fifty times a
 * second) for the life of the session, plus a scan of those same bytes for the
 * first [AudioTrackPolicy.PEAK_WINDOW_MS]. The processor stays *active* rather
 * than going inactive after the window because `isActive()` is latched at
 * `configure` time; keeping it constant means the pipeline is the same shape
 * whether or not a measurement is running.
 */
@UnstableApi
private class AudioPeakProcessor(
    private val probe: AudioPeakProbe,
) : BaseAudioProcessor() {

    override fun onConfigure(
        inputAudioFormat: AudioProcessor.AudioFormat,
    ): AudioProcessor.AudioFormat {
        probe.noteEncoding(inputAudioFormat.encoding)
        // Always active, and output == input: the sink's format negotiation is
        // untouched, exactly as with a TeeAudioProcessor.
        return inputAudioFormat
    }

    override fun queueInput(inputBuffer: ByteBuffer) {
        val remaining = inputBuffer.remaining()
        if (remaining == 0) return
        probe.scan(inputBuffer)
        replaceOutputBuffer(remaining).put(inputBuffer).flip()
    }
}
