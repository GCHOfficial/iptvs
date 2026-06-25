package com.example.iptvs.player

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.example.iptvs.R

/**
 * Design tokens for the native player's Compose control overlay.
 *
 * These mirror `lib/theme.dart` `AppColors` exactly so the Android player shares
 * the app's (and the Windows native overlay's) visual language: dark surfaces,
 * a purple accent, and the Inter typeface.
 */
object PlayerColors {
    val Ink = Color(0xFF0E0F13) // app background / scrims
    val Panel = Color(0xFF16181F) // cards / surfaces
    val PanelHi = Color(0xFF1E212B) // hover / focus lift
    val Line = Color(0xFF262A36) // hairlines / borders
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
    val EdgePadding = 24.dp
}
