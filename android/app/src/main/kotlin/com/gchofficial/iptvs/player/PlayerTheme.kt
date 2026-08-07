package com.gchofficial.iptvs.player

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.gchofficial.iptvs.R

/**
 * Design tokens for the native player's Compose control overlay.
 *
 * These mirror `lib/theme.dart` `AppColors` exactly so the Android player shares
 * the app's (and the Windows native overlay's) visual language: dark surfaces,
 * a purple accent, and the Inter typeface.
 *
 * `lib/theme.dart` `AppColors` is the source of truth — these are hand-copied,
 * not generated, so re-check every value here against it whenever either file
 * changes.
 */
object PlayerColors {
    val Ink = Color(0xFF0E0F13) // app background / scrims
    val Panel = Color(0xFF16181F) // cards / surfaces
    val PanelHi = Color(0xFF272B36) // hover / focus lift
    val Line = Color(0xFF353B49) // hairlines / borders
    val TextHi = Color(0xFFF2F4F8)
    val TextLo = Color(0xFF9AA3B2)
    val Accent = Color(0xFF7B6CF6) // brand / progress
    val Live = Color(0xFFFF4D6D) // "on air" signal

    // Overlay-only tints derived from the tokens above.
    val ButtonBg = Color(0x33FFFFFF) // translucent chip behind controls
    val ButtonBgFocused = Accent
    val ScrimTop = Color(0xCC000000)
    val ScrimBottom = Color(0xE6000000)
    val TrackInactive = Color(0x4DFFFFFF)
}

/** Inter, bundled in `res/font`, matching the Windows overlay typography. */
val InterFontFamily = FontFamily(
    Font(R.font.inter_regular, FontWeight.Normal),
    Font(R.font.inter_semibold, FontWeight.SemiBold),
    Font(R.font.inter_bold, FontWeight.Bold),
)

/** Shared geometry so the overlay reads consistently across phone and TV. */
object PlayerDimens {
    val ButtonSize = 44.dp
    val ButtonCorner = 10.dp
    val BarCorner = 14.dp
    val MenuCorner = 14.dp
    val MenuWidth = 240.dp
    val MenuMaxHeight = 320.dp
    val InfoPanelWidth = 260.dp

    /**
     * Horizontal inset from the window edge for overlay chrome, on a phone or
     * tablet. Also the anchor inset for the list-menu and the info panel, which
     * hang off the same edge.
     */
    val EdgePadding = 24.dp

    /**
     * Horizontal edge inset on Android TV — the ten-foot variant of [EdgePadding].
     *
     * **Why a TV-only value at all.** `safeDrawingPadding()` insets the overlay
     * against system bars and display cutouts, and an Android TV reports *zero*
     * of both, so on a TV the chrome sits exactly [EdgePadding] from the physical
     * panel edge. Nothing else in the layout compensates.
     *
     * **Why 40dp and not Google's 48dp.** A 1080p Android TV renders at density
     * 2.0, i.e. a 960 x 540dp layout, so the classic 5%-per-axis overscan safe
     * area is 48dp horizontal / 27dp vertical — the numbers the TV design
     * guidelines quote. But that 5% figure assumes the *legacy* worst case
     * (roughly 2.5% cropped per side, = 24dp here) plus a comfortable margin, and
     * modern panels overwhelmingly ship with overscan disabled, so paying the
     * full 48dp spends 96dp of a 960dp-wide layout to protect a shrinking
     * minority of sets. 40dp is derived rather than picked: 24dp covers the
     * worst realistic per-side crop — which is *exactly* where the phone value
     * lands today, i.e. a cropping set clips the chrome flush against the crop
     * line — and the remaining 16dp is a real, visible margin on the (usual)
     * uncropped panel. It is 8dp inside the guideline and 16dp outside the
     * status quo.
     *
     * **Needs on-device confirmation** on a real Android TV (and ideally one set
     * with overscan deliberately enabled): nothing in CI or on a phone can show
     * whether 40dp actually clears a given panel's crop.
     */
    val TvEdgePadding = 40.dp

    /**
     * Extra inset added on Android TV to the **outer vertical edge only** — the
     * top of the top bar and the bottom of the bottom bar — on top of whatever
     * vertical rhythm each bar already uses (12/16/18dp).
     *
     * Same reasoning as [TvEdgePadding] on the other axis: 2.5% of a 540dp-tall
     * layout is ~13.5dp of crop, which the current 16/18dp only just clears with
     * no visible margin left. +14dp brings the outer edges to 30/32dp, past the
     * 27dp the guidelines quote for the vertical axis, while the *inner* padding
     * (between a bar's content and the middle of the screen) is deliberately left
     * alone so the bars don't grow taller than they need to on a 540dp-tall
     * layout. Also needs on-device confirmation.
     */
    val TvEdgeExtraVertical = 14.dp

    /** Horizontal edge inset for the current form factor. */
    fun edgePadding(isTv: Boolean): Dp = if (isTv) TvEdgePadding else EdgePadding

    /**
     * Extra outer-vertical inset for the current form factor. Zero off TV, so
     * phone/tablet geometry is byte-identical to before.
     */
    fun edgeExtraVertical(isTv: Boolean): Dp = if (isTv) TvEdgeExtraVertical else 0.dp
}
