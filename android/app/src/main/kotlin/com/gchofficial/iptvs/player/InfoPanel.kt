package com.gchofficial.iptvs.player

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import java.util.Locale

/**
 * Minimal stream-info card (resolution / fps / dynamic range / codecs), toggled
 * by the info button. Mirrors the Windows overlay's info panel — fields that are
 * unavailable (or meaningless on live) are simply omitted.
 */
@Composable
fun InfoPanel(
    state: PlayerUiState,
    modifier: Modifier = Modifier,
) {
    val rows = buildList {
        if (state.videoWidth > 0 && state.videoHeight > 0) {
            add("Resolution" to "${state.videoWidth} × ${state.videoHeight}")
        }
        if (state.fps > 0f) add("Frame rate" to formatFps(state.fps))
        if (state.dynamicRange.isNotBlank()) add("Dynamic range" to state.dynamicRange)
        if (state.videoCodec.isNotBlank()) add("Video" to state.videoCodec)
        if (state.audioCodec.isNotBlank()) {
            val channels = channelsLabel(state.audioChannels)
            val value = if (channels.isNotBlank()) "${state.audioCodec} · $channels" else state.audioCodec
            add("Audio" to value)
        }
    }
    if (rows.isEmpty()) return

    Column(
        modifier
            .width(PlayerDimens.InfoPanelWidth)
            .clip(RoundedCornerShape(PlayerDimens.MenuCorner))
            .background(PlayerColors.Panel)
            .padding(horizontal = 16.dp, vertical = 14.dp),
    ) {
        Text(
            text = "Stream info",
            color = PlayerColors.TextLo,
            fontFamily = InterFontFamily,
            fontWeight = FontWeight.SemiBold,
            fontSize = 12.sp,
        )
        Spacer(Modifier.height(8.dp))
        rows.forEach { (label, value) ->
            Row(
                Modifier.fillMaxWidth().padding(vertical = 4.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Text(
                    text = label,
                    color = PlayerColors.TextLo,
                    fontFamily = InterFontFamily,
                    fontWeight = FontWeight.SemiBold,
                    fontSize = 13.sp,
                )
                Spacer(Modifier.width(16.dp))
                Text(
                    text = value,
                    color = PlayerColors.TextHi,
                    fontFamily = InterFontFamily,
                    fontWeight = FontWeight.Bold,
                    fontSize = 13.sp,
                    modifier = Modifier.weight(1f, fill = false),
                    textAlign = androidx.compose.ui.text.style.TextAlign.End,
                    maxLines = 2,
                )
            }
        }
        // Live programme synopsis (wraps), shown under the rows when available.
        val synopsis = state.epgNow?.description
        if (state.isLive && !synopsis.isNullOrBlank()) {
            Spacer(Modifier.height(8.dp))
            Text(
                text = synopsis,
                color = PlayerColors.TextLo,
                fontFamily = InterFontFamily,
                fontSize = 12.sp,
                maxLines = 4,
            )
        }
    }
}

private fun formatFps(fps: Float): String {
    val rounded = Math.round(fps * 1000f) / 1000f
    val text = if (rounded == rounded.toLong().toFloat()) {
        rounded.toLong().toString()
    } else {
        String.format(Locale.ROOT, "%.3f", rounded).trimEnd('0').trimEnd('.')
    }
    return "$text fps"
}

private fun channelsLabel(channels: Int): String = when {
    channels <= 0 -> ""
    channels == 1 -> "Mono"
    channels == 2 -> "Stereo"
    channels == 6 -> "5.1"
    channels == 8 -> "7.1"
    else -> "${channels}ch"
}
