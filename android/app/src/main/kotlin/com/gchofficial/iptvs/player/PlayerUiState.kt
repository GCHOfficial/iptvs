package com.gchofficial.iptvs.player

import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import java.util.Locale

/** A selectable row in one of the player's list-menus (audio / subtitles / speed). */
data class TrackOption(val id: String, val label: String)

/** A live EPG programme snapshot (now or next), captured at play time. */
data class EpgEntry(
    val title: String,
    val startMs: Long,
    val stopMs: Long,
    val description: String? = null,
) {
    /** Fraction elapsed at [atMs] within [startMs]..[stopMs], clamped to 0..1. */
    fun progressAt(atMs: Long): Float {
        val span = (stopMs - startMs).coerceAtLeast(1L)
        return ((atMs - startMs).toFloat() / span).coerceIn(0f, 1f)
    }
}

/** Which list-menu, if any, is currently open. Mirrors the Windows single-menu model. */
enum class PlayerMenu { None, Audio, Subtitles, Speed }

/**
 * Aspect/zoom modes, cycled by the aspect button — the same set, in the same
 * order, on every surface (Windows GDI, the shared Flutter overlay, the Linux
 * Lua OSD and iOS), because the label is just text those surfaces render and
 * the sequence is what a user learns.
 *
 * [Fill] and [Stretch] are different things and the distinction is the whole
 * reason both exist. `Fill` **crops** to fill while keeping the picture's
 * shape; `Stretch` **distorts** to fill and keeps every pixel. Neither is
 * strictly better: on a 20:9 handset, 16:9 content loses about a fifth of its
 * width to `Fill`, and 4:3 content loses far more — which is why a user who
 * wants the whole frame on screen asks for "stretch" and is not served by a
 * zoom.
 */
enum class AspectMode(val label: String) {
    Fit("Fit"),
    Fill("Fill"),
    Stretch("Stretch"),
    Ratio16x9("16:9"),
    Ratio4x3("4:3"),
}

/**
 * How long the zap banner stays up after a press, before it fades.
 *
 * Long enough to read a channel name and its now/next after a single press,
 * short enough not to sit over the picture once the user has stopped zapping.
 * A half-typed number or a transient note keeps it up regardless
 * ([PlayerUiState.showZapBanner]).
 */
const val ZAP_BANNER_VISIBLE_MS = 3_000L

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
    title: String,
    isLive: Boolean,
    sourceName: String? = null,
    isTv: Boolean = false,
    epgNow: EpgEntry? = null,
    epgNext: EpgEntry? = null,
) {
    // Presentation fields are mutable (not constructor vals) because a state can
    // outlive its first host: the shared preview engine's state is created
    // "faceless" (no title/EPG) and adopted by the fullscreen Activity, which
    // fills these in from its Intent extras. All observable for Compose.
    var title by mutableStateOf(title)
    var isLive by mutableStateOf(isLive)

    /** Active source's display name, shown as a top-bar badge. */
    var sourceName by mutableStateOf(sourceName)

    /** True on Android TV (drives the clock badge, hidden on phones). */
    var isTv by mutableStateOf(isTv)

    /** Live EPG now/next snapshot; null for VOD. */
    var epgNow by mutableStateOf(epgNow)
    var epgNext by mutableStateOf(epgNext)

    var isPlaying by mutableStateOf(false)
    var isBuffering by mutableStateOf(true)
    var ended by mutableStateOf(false)

    // True while the live reconnect watchdog is re-establishing a dropped stream.
    var reconnecting by mutableStateOf(false)

    var positionMs by mutableStateOf(0L)
    var durationMs by mutableStateOf(0L)
    var bufferedMs by mutableStateOf(0L)

    var volume by mutableStateOf(1f) // 0..1
    var muted by mutableStateOf(false)
    var speed by mutableStateOf(1.0f)

    // Fill, matching every other surface (Dart `_aspectModeIndex`, Swift
    // `.fill`). Crops to fill rather than letterboxing — identical to Fit
    // whenever the picture and the screen share a shape, which is most viewing.
    var aspect by mutableStateOf(AspectMode.Fill)

    // Live-edge sync: true while at the live edge, false once the user has paused
    // (and thus fallen behind). Drives the grey LIVE badge + the go-to-live button.
    var liveSynced by mutableStateOf(true)

    // Favorite toggle (live channels only). `canFavorite` gates the overlay star
    // button; `isFavorite` is its current state. The Dart host owns the store —
    // it seeds the initial value via an Intent extra and reads the final value
    // back on exit (see HdrPlayerActivity.finish), so the channel list reflects
    // the toggle on return without a live method channel from this Activity.
    var canFavorite by mutableStateOf(false)
    var isFavorite by mutableStateOf(false)

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

    // ── Live zapping (see `lib/player/live_zap_controller.dart`) ─────────────
    //
    // Pushed from Dart on `setZapBanner`. Dart owns the channel list and the
    // cursor; these fields are presentation only, and none of them decides
    // anything about playback.

    /** The cursor channel's provider number, when it has one. */
    var channelNumber by mutableStateOf<Int?>(null)

    /** The cursor channel's name — ahead of [title] while a zap is settling. */
    var channelName by mutableStateOf<String?>(null)

    /** Half-typed channel number, shown as a digit readout. */
    var digitBuffer by mutableStateOf("")

    /** Transient note ("No channel 123", a failed zap). */
    var zapMessage by mutableStateOf<String?>(null)

    /** 1-based cursor position in the zap range, and its size. */
    var zapPosition by mutableStateOf(0)
    var zapTotal by mutableStateOf(0)

    /** True while Dart is stopping/resolving/opening the settled channel. */
    var zapSettling by mutableStateOf(false)

    /**
     * Whether the zap banner is on screen. Set true by each `setZapBanner`
     * push and cleared by the overlay's own timer
     * ([ZAP_BANNER_VISIBLE_MS]) — **not** by [controlsVisible], because the
     * banner is the only acknowledgement a keypress gets while the chrome is
     * hidden, which is exactly when zapping is used.
     */
    var zapBannerVisible by mutableStateOf(false)

    /**
     * When the last banner push arrived. Keys the overlay's auto-hide effect,
     * so each new press restarts the timer rather than stacking timers.
     */
    var zapBannerAtMs by mutableStateOf(0L)

    /**
     * The banner is drawn whenever there is something to acknowledge. A
     * half-typed number and a transient note outlive the plain banner timer
     * on purpose: both are mid-interaction states, and hiding them would take
     * the feedback away while the user is still typing.
     */
    val showZapBanner: Boolean
        get() = isLive &&
            !inPip &&
            (zapBannerVisible || digitBuffer.isNotEmpty() || zapMessage != null)

    /**
     * Whether the bottom bar should draw the identity run.
     *
     * Only when it says something the top bar's title does not: a channel
     * number, a half-typed number, or a transient note. A session that never
     * zaps therefore renders byte-identically to before — nothing sets
     * [channelNumber] until Dart pushes a banner, which it does only on a
     * cursor move.
     */
    val showsChannelIdentity: Boolean
        get() = isLive &&
            (channelNumber != null || digitBuffer.isNotEmpty() || zapMessage != null)

    /** `12 · BBC One`, or just the name when the provider gave no number. */
    fun channelIdentityLabel(): String? {
        val name = channelName?.trim().orEmpty().ifEmpty { title.trim() }
        if (name.isEmpty()) return null
        val number = channelNumber
        return if (number != null) "$number · $name" else name
    }

    var openMenu by mutableStateOf(PlayerMenu.None)
    var infoOpen by mutableStateOf(false)
    var controlsVisible by mutableStateOf(true)

    /** In Android picture-in-picture: the overlay hides all chrome (video only). */
    var inPip by mutableStateOf(false)

    /** Whether the device supports PiP at all — gates the manual "Enter PiP" button. */
    var supportsPip by mutableStateOf(false)

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
        dynamicRange.contains("HDR10+") -> "HDR10+"
        dynamicRange.contains("HDR10") -> "HDR10"
        dynamicRange.contains("HLG") -> "HLG"
        dynamicRange.startsWith("HDR") -> "HDR"
        else -> null
    }

    /** Compact frame-rate badge for the top bar, e.g. "50fps" / "23.976fps"; null when unknown. */
    fun fpsBadge(): String? {
        if (fps <= 0f) return null
        val rounded = Math.round(fps * 1000f) / 1000f
        val n = if (rounded == rounded.toLong().toFloat()) {
            rounded.toLong().toString()
        } else {
            String.format(Locale.ROOT, "%.3f", rounded).trimEnd('0').trimEnd('.')
        }
        return "${n}fps"
    }

    /** Short source-name badge, truncated so a long provider label can't crowd the bar. */
    fun sourceBadge(): String? {
        val name = sourceName?.trim().orEmpty()
        if (name.isEmpty()) return null
        return if (name.length > 20) name.take(19) + "…" else name
    }

    fun speedLabel(): String {
        val r = speed
        return if (r == r.toLong().toFloat()) "${r.toLong()}×" else "${r}×".replace(".0×", "×")
    }
}
