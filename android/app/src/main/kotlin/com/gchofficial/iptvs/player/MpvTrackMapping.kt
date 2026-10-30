package com.gchofficial.iptvs.player

import java.util.Locale

/**
 * Pure (Android-free) mapping from raw libmpv property values to the labels and
 * selections [PlayerUiState] shows — extracted out of [MpvController] so it can
 * be unit-tested under plain JUnit, like `PlayerBackPolicy` / `ReconnectPolicy`.
 *
 * The split is not cosmetic: these functions now run on [MpvController]'s reader
 * thread, off the main thread, and nothing in here may touch mpv, Android, or
 * Compose state. The caller reads the raw values, maps them here, and posts the
 * finished snapshot to the main thread.
 */

/** One `track-list/N/…` entry, exactly as mpv answered it (nulls included). */
data class RawMpvTrack(
    val type: String?,
    val id: Int?,
    val title: String?,
    val language: String?,
)

/** The finished track state: four fields, applied to [PlayerUiState] in one go. */
data class MpvTrackSnapshot(
    val audioTracks: List<TrackOption>,
    val selectedAudioId: String?,
    val subtitleTracks: List<TrackOption>,
    val selectedSubtitleId: String?,
)

/**
 * Video/audio stream shape. Every field is nullable **on purpose**: mpv answers
 * some of these only once the relevant decoder has configured, and a null must
 * leave the previously shown value alone rather than blanking the badge row
 * mid-reconfigure. [dynamicRange] is the exception — it is always a decided
 * label, empty string meaning "nothing known yet", matching what mpv's
 * `video-params` say at that instant.
 */
data class MpvMediaSnapshot(
    val videoWidth: Int?,
    val videoHeight: Int?,
    val fps: Float?,
    val videoCodec: String?,
    val audioCodec: String?,
    val audioChannels: Int?,
    val dynamicRange: String,
)

/**
 * Builds the audio/subtitle option lists from mpv's track list.
 *
 * Subtitles always lead with an explicit "Off" row, and the selection falls back
 * the way the player did before the extraction: audio to the first track when
 * mpv reports no `aid`, subtitles to Off when it reports no `sid`. Entries mpv
 * answered incompletely (no type or no id) are skipped, not guessed — an option
 * whose id can't be sent back to `aid`/`sid` would be a dead menu row.
 */
fun mapMpvTracks(
    tracks: List<RawMpvTrack>,
    currentAid: Int?,
    currentSid: Int?,
    locale: Locale = Locale.getDefault(),
): MpvTrackSnapshot {
    val audio = mutableListOf<TrackOption>()
    val subs = mutableListOf(TrackOption(SUBTITLE_OFF_ID, "Off"))
    for (track in tracks) {
        val type = track.type ?: continue
        val id = track.id ?: continue
        when (type) {
            "audio" -> audio.add(
                TrackOption(
                    id.toString(),
                    mpvTrackLabel(track.title, track.language, "Audio", audio.size, locale),
                ),
            )
            "sub" -> subs.add(
                TrackOption(
                    id.toString(),
                    mpvTrackLabel(track.title, track.language, "Subtitle", subs.size - 1, locale),
                ),
            )
        }
    }
    return MpvTrackSnapshot(
        audioTracks = audio,
        selectedAudioId = currentAid?.toString() ?: audio.firstOrNull()?.id,
        subtitleTracks = subs,
        selectedSubtitleId = currentSid?.toString() ?: SUBTITLE_OFF_ID,
    )
}

/** Track title, else its language's display name, else "Audio 2"-style numbering. */
fun mpvTrackLabel(
    title: String?,
    language: String?,
    fallback: String,
    index: Int,
    locale: Locale = Locale.getDefault(),
): String {
    title?.takeIf { it.isNotBlank() }?.let { return it }
    mpvLanguageLabel(language, locale)?.let { return it }
    return "$fallback ${index + 1}"
}

/** `"eng"` → "English" in [locale]; null for absent/undetermined, the code itself on failure. */
fun mpvLanguageLabel(language: String?, locale: Locale = Locale.getDefault()): String? {
    val code = language?.takeIf { it.isNotBlank() && it != "und" } ?: return null
    return runCatching {
        Locale.forLanguageTag(code).getDisplayName(locale).takeIf { it.isNotBlank() }
    }.getOrNull() ?: code
}

/**
 * The dynamic-range badge, from mpv's `video-params`. Values arrive lowercased
 * by the caller's convention; this function lowercases defensively so a direct
 * caller can't change the answer by passing mpv's raw casing.
 *
 * Order matters: Dolby Vision is signalled on the matrix *or* the gamma, and has
 * to win before the PQ branch, since DV's base layer reads as PQ. An empty gamma
 * means mpv hasn't configured a video track yet — "" (unknown), never "SDR",
 * which would flash a wrong badge on every open.
 */
fun mpvDynamicRangeLabel(gamma: String?, colormatrix: String?, primaries: String?): String {
    val g = gamma.orEmpty().lowercase(Locale.ROOT)
    val matrix = colormatrix.orEmpty().lowercase(Locale.ROOT)
    val prims = primaries.orEmpty().lowercase(Locale.ROOT)
    return when {
        matrix.contains("dolby") || g.contains("dolby") -> "Dolby Vision"
        g == "pq" -> "HDR10 · PQ"
        g == "hlg" -> "HLG"
        prims.contains("2020") -> "HDR · BT.2020"
        g.isNotEmpty() -> "SDR"
        else -> ""
    }
}

/** Whether a [mpvDynamicRangeLabel] result denotes HDR (drives the HDR badge). */
fun isHdrRangeLabel(label: String): Boolean =
    label.contains("HDR") ||
        label.contains("Dolby", ignoreCase = true) ||
        label.contains("HLG")

/** mpv's codec identifiers → the compact badge labels the overlays share. */
fun mpvCodecLabel(format: String): String = when (format.lowercase(Locale.ROOT)) {
    "hevc", "h265" -> "HEVC"
    "h264", "avc" -> "H.264"
    "av1" -> "AV1"
    "vp9" -> "VP9"
    "mpeg2video" -> "MPEG-2"
    "aac" -> "AAC"
    "ac3" -> "AC-3"
    "eac3" -> "E-AC-3"
    "truehd" -> "TrueHD"
    "dts" -> "DTS"
    "flac" -> "FLAC"
    "opus" -> "Opus"
    "mp3" -> "MP3"
    else -> format.uppercase(Locale.ROOT)
}
