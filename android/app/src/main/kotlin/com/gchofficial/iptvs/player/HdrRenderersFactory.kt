package com.gchofficial.iptvs.player

import android.content.Context
import android.media.MediaFormat
import android.os.Build
import android.os.Handler
import androidx.media3.common.Format
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.Renderer
import androidx.media3.exoplayer.mediacodec.MediaCodecAdapter
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector
import androidx.media3.exoplayer.video.MediaCodecVideoRenderer
import androidx.media3.exoplayer.video.VideoRendererEventListener

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
        )
        videoRenderer = renderer
        out.add(renderer)
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
