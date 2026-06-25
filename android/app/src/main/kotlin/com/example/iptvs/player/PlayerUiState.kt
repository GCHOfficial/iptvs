package com.example.iptvs.player

import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

/** A selectable row in one of the player's list-menus (audio / subtitles / speed). */
data class TrackOption(val id: String, val label: String)

/** Which list-menu, if any, is currently open. Mirrors the Windows single-menu model. */
enum class PlayerMenu { None, Audio, Subtitles, Speed }

/** Aspect/zoom modes, cycled by the aspect button — same set as the Windows overlay. */
enum class AspectMode(val label: String) {
    Fit("Fit"),
    Fill("Fill"),
    Ratio16x9("16:9"),
    Ratio4x3("4:3"),
}

/** Sentinel id for the "Off" subtitle option. */
const val SUBTITLE_OFF_ID = "off"

/** Playback speeds offered in the speed menu (VOD only) — mirrors Windows. */
val SPEED_OPTIONS = listOf(0.5f, 0.75f, 1.0f, 1.25f, 1.5f, 2.0f)

/**
 * Observable state backing the Compose control overlay. The Activity owns one
 * instance and mutates it from ExoPlayer's `Player.Listener`; the overlay reads
 * it and recomposes. Kept deliberately UI-shaped (labels, ids) so the Compose
 * layer stays free of ExoPlayer types.
 */
@Stable
class PlayerUiState(
    val title: String,
    val isLive: Boolean,
) {
    var isPlaying by mutableStateOf(false)
    var isBuffering by mutableStateOf(true)
    var ended by mutableStateOf(false)

    var positionMs by mutableStateOf(0L)
    var durationMs by mutableStateOf(0L)
    var bufferedMs by mutableStateOf(0L)

    var volume by mutableStateOf(1f) // 0..1
    var muted by mutableStateOf(false)
    var speed by mutableStateOf(1.0f)

    var aspect by mutableStateOf(AspectMode.Fit)

    var audioTracks by mutableStateOf<List<TrackOption>>(emptyList())
    var selectedAudioId by mutableStateOf<String?>(null)
    var subtitleTracks by mutableStateOf<List<TrackOption>>(emptyList())
    var selectedSubtitleId by mutableStateOf<String?>(SUBTITLE_OFF_ID)

    // Stream-info readout (resolution / fps / HDR / codecs).
    var videoWidth by mutableStateOf(0)
    var videoHeight by mutableStateOf(0)
    var fps by mutableStateOf(0f)
    var dynamicRange by mutableStateOf("") // already-formatted label, e.g. "HDR10 · PQ"
    var videoCodec by mutableStateOf("")
    var audioCodec by mutableStateOf("")
    var audioChannels by mutableStateOf(0)

    var openMenu by mutableStateOf(PlayerMenu.None)
    var infoOpen by mutableStateOf(false)
    var controlsVisible by mutableStateOf(true)

    // Set when the stream carries a video track the device can't decode (e.g.
    // Dolby Vision Profile 5 on non-DV hardware): audio plays but there's no
    // picture, so we surface why instead of leaving a blank/artwork screen.
    var videoUnsupported by mutableStateOf(false)
    var videoUnsupportedReason by mutableStateOf("")

    /** Controls must stay pinned (no auto-hide) while a menu or the info panel is open. */
    val pinned: Boolean get() = openMenu != PlayerMenu.None || infoOpen

    /** Audio button only when there's a real choice to make. */
    val showAudioButton: Boolean get() = audioTracks.size > 1
    /** Subtitle button only when there's at least one subtitle track to enable. */
    val showSubtitleButton: Boolean get() = subtitleTracks.any { it.id != SUBTITLE_OFF_ID }
    /** Speed / scrubber / ±10s are VOD-only. */
    val showSpeedButton: Boolean get() = !isLive

    /** Compact resolution badge for the top bar (matches Windows `ResolutionBadge`). */
    fun resolutionBadge(): String? {
        val h = videoHeight
        val w = videoWidth
        if (h <= 0 || w <= 0) return null
        return when {
            h >= 2000 || w >= 3500 -> "4K"
            h >= 1400 || w >= 2400 -> "1440p"
            h >= 1000 || w >= 1800 -> "1080p"
            h >= 700 || w >= 1200 -> "720p"
            else -> "SD"
        }
    }

    /** Compact HDR badge for the top bar (matches Windows `HdrBadge`); null when SDR/unknown. */
    fun hdrBadge(): String? = when {
        dynamicRange.contains("Dolby", ignoreCase = true) -> "DV"
        dynamicRange.contains("HDR10") -> "HDR10"
        dynamicRange.contains("HLG") -> "HLG"
        dynamicRange.startsWith("HDR") -> "HDR"
        else -> null
    }

    fun speedLabel(): String {
        val r = speed
        return if (r == r.toLong().toFloat()) "${r.toLong()}×" else "${r}×".replace(".0×", "×")
    }
}
