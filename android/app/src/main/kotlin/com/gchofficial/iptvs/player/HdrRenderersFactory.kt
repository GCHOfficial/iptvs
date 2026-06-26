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
        out.add(
            HdrMediaCodecVideoRenderer(
                context,
                getCodecAdapterFactory(),
                mediaCodecSelector,
                allowedVideoJoiningTimeMs,
                enableDecoderFallback,
                eventHandler,
                eventListener,
                MAX_DROPPED_FRAMES_TO_NOTIFY,
                onDynamicRange,
            ),
        )
    }

    private companion object {
        // Matches DefaultRenderersFactory's own default.
        const val MAX_DROPPED_FRAMES_TO_NOTIFY = 50
    }
}

@UnstableApi
private class HdrMediaCodecVideoRenderer(
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
}
