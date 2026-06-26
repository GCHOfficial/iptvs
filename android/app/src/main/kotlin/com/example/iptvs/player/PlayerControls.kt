package com.example.iptvs.player

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.focusable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.AspectRatio
import androidx.compose.material.icons.filled.Audiotrack
import androidx.compose.material.icons.filled.ClosedCaption
import androidx.compose.material.icons.filled.Forward10
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.LiveTv
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Replay10
import androidx.compose.material.icons.filled.VolumeOff
import androidx.compose.material.icons.filled.VolumeUp
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import android.view.View
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView

/** Player actions the overlay invokes; implemented by the Activity over ExoPlayer. */
class PlayerCallbacks(
    val onPlayPause: () -> Unit,
    val onSeekTo: (Long) -> Unit,
    val onSeekBy: (Long) -> Unit,
    val onSetVolume: (Float) -> Unit,
    val onToggleMute: () -> Unit,
    val onSelectAudio: (String) -> Unit,
    val onSelectSubtitle: (String) -> Unit,
    val onSetSpeed: (Float) -> Unit,
    val onCycleAspect: () -> Unit,
    val onGoLive: () -> Unit,
    val onBack: () -> Unit,
)

private const val HIDE_DELAY_VOD = 3500L
private const val HIDE_DELAY_LIVE = 4500L

/**
 * Root of the native player UI: the ExoPlayer surface with a Compose control
 * overlay on top. Mirrors the Windows native overlay (top bar + badges, bottom
 * bar with contextual right cluster, list-menus, info panel) and is D-pad
 * navigable for Android TV.
 */
@Composable
fun PlayerScreen(
    state: PlayerUiState,
    videoView: View,
    callbacks: PlayerCallbacks,
) {
    val rootFocus = remember { FocusRequester() }
    val playFocus = remember { FocusRequester() }
    // Bumped on any interaction to (re)arm the auto-hide timer.
    var interaction by remember { mutableIntStateOf(0) }
    // Wall-clock tick driving the clock badge and the live EPG progress (slow —
    // both move on the order of a minute, so 10s granularity is plenty).
    var nowMillis by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(Unit) {
        while (true) {
            nowMillis = System.currentTimeMillis()
            kotlinx.coroutines.delay(10_000)
        }
    }

    fun poke() {
        interaction++
        state.controlsVisible = true
    }

    // Auto-hide: hide after the timeout unless pinned (a menu / info panel open)
    // or playback is paused.
    LaunchedEffect(interaction, state.pinned, state.isPlaying, state.controlsVisible) {
        if (state.controlsVisible && !state.pinned && state.isPlaying) {
            kotlinx.coroutines.delay(if (state.isLive) HIDE_DELAY_LIVE else HIDE_DELAY_VOD)
            state.controlsVisible = false
        }
    }

    // Move focus to the controls when shown; park it on the root when hidden so a
    // D-pad press can reveal them again.
    LaunchedEffect(state.controlsVisible) {
        if (state.controlsVisible) {
            runCatching { playFocus.requestFocus() }
        } else {
            state.openMenu = PlayerMenu.None
            state.infoOpen = false
            runCatching { rootFocus.requestFocus() }
        }
    }

    // Single source of truth for Back: peel one layer per press — close an open
    // menu, then the info panel, then hide the controls — and report whether it
    // handled the press. Returns false only when there's nothing left to dismiss.
    fun handleBack(): Boolean = when {
        state.openMenu != PlayerMenu.None -> {
            state.openMenu = PlayerMenu.None
            true
        }
        state.infoOpen -> {
            state.infoOpen = false
            true
        }
        state.controlsVisible -> {
            state.controlsVisible = false
            true
        }
        else -> false
    }

    // Phones deliver Back through the dispatcher (gesture / nav bar); TV remotes
    // deliver it as a key consumed in onPreviewKeyEvent below. They're mutually
    // exclusive (a consumed key never reaches the dispatcher), so both routing to
    // handleBack() gives a deterministic single press per step.
    BackHandler(enabled = true) {
        if (!handleBack()) callbacks.onBack()
    }

    Box(
        Modifier
            .fillMaxSize()
            .background(PlayerColors.Ink)
            .focusRequester(rootFocus)
            .focusable()
            .onPreviewKeyEvent { event ->
                if (event.type != KeyEventType.KeyDown) return@onPreviewKeyEvent false
                when (event.key) {
                    Key.Back -> {
                        if (!handleBack()) callbacks.onBack()
                        true
                    }
                    else -> {
                        val wasHidden = !state.controlsVisible
                        poke()
                        wasHidden // consume the first key only to reveal controls
                    }
                }
            },
    ) {
        // key() so swapping engines (ExoPlayer -> mpv fallback) rebuilds the host
        // with the new engine's view.
        key(videoView) {
            AndroidView(factory = { videoView }, modifier = Modifier.fillMaxSize())
        }

        // Tap layer (below the controls) toggles visibility on touch devices.
        Box(
            Modifier
                .fillMaxSize()
                .pointerInput(Unit) {
                    detectTapGestures(
                        onTap = {
                            if (state.controlsVisible) {
                                state.controlsVisible = false
                            } else {
                                poke()
                            }
                        },
                    )
                },
        )

        if (state.videoUnsupported) {
            UnsupportedVideoNotice(
                reason = state.videoUnsupportedReason,
                modifier = Modifier.align(Alignment.Center),
            )
        }

        AnimatedVisibility(
            visible = state.controlsVisible,
            enter = fadeIn(),
            exit = fadeOut(),
        ) {
            ControlsOverlay(state, callbacks, playFocus, nowMillis) { poke() }
        }

        // Menus + info panel sit above the bars; they imply controls are visible.
        if (state.controlsVisible) {
            PlayerMenusLayer(state, callbacks) { poke() }
            if (state.infoOpen) {
                InfoPanel(
                    state = state,
                    modifier = Modifier
                        .align(Alignment.TopEnd)
                        .padding(top = 84.dp, end = PlayerDimens.EdgePadding),
                )
            }
        }
    }
}

@Composable
private fun ControlsOverlay(
    state: PlayerUiState,
    callbacks: PlayerCallbacks,
    playFocus: FocusRequester,
    nowMillis: Long,
    onInteract: () -> Unit,
) {
    Column(
        Modifier
            .fillMaxSize()
            .background(
                Brush.verticalGradient(
                    0f to PlayerColors.ScrimTop,
                    0.25f to androidx.compose.ui.graphics.Color.Transparent,
                    0.7f to androidx.compose.ui.graphics.Color.Transparent,
                    1f to PlayerColors.ScrimBottom,
                ),
            ),
    ) {
        TopBar(state, callbacks, nowMillis, onInteract)
        Spacer(Modifier.weight(1f))
        BottomBar(state, callbacks, playFocus, nowMillis, onInteract)
    }
}

@Composable
private fun TopBar(
    state: PlayerUiState,
    callbacks: PlayerCallbacks,
    nowMillis: Long,
    onInteract: () -> Unit,
) {
    Row(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = PlayerDimens.EdgePadding, vertical = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconControlButton(
            icon = Icons.AutoMirrored.Filled.ArrowBack,
            contentDescription = "Back",
            onClick = { onInteract(); callbacks.onBack() },
        )
        Spacer(Modifier.width(14.dp))
        Column(Modifier.weight(1f)) {
            Text(
                text = state.title,
                color = PlayerColors.TextHi,
                fontFamily = InterFontFamily,
                fontWeight = FontWeight.Bold,
                fontSize = 18.sp,
                maxLines = 1,
            )
        }
        Spacer(Modifier.width(8.dp))
        // Right-cluster badges: source, LIVE/resolution/HDR, fps, and (TV only) a
        // date+time clock. The title above takes the remaining width and ellipsizes.
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            state.sourceBadge()?.let { Badge(it) }
            if (state.isLive) LiveBadge()
            state.resolutionBadge()?.let { Badge(it) }
            state.hdrBadge()?.let { Badge(it, accent = true) }
            state.fpsBadge()?.let { Badge(it) }
            if (state.isTv) Badge(formatClock(nowMillis))
        }
    }
}

@Composable
private fun BottomBar(
    state: PlayerUiState,
    callbacks: PlayerCallbacks,
    playFocus: FocusRequester,
    nowMillis: Long,
    onInteract: () -> Unit,
) {
    Column(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = PlayerDimens.EdgePadding, vertical = 18.dp),
    ) {
        if (!state.isLive) {
            Scrubber(state, callbacks, onInteract)
            Spacer(Modifier.height(10.dp))
        } else {
            // Live has no scrubber; surface the EPG now/next + programme progress in
            // its place when available.
            state.epgNow?.let { now ->
                LiveEpgStrip(now, state.epgNext, nowMillis)
                Spacer(Modifier.height(12.dp))
            }
        }
        // Below ~560dp (phone portrait) the transport + right cluster won't fit on
        // one line, so the right cluster wraps onto a second row. Both rows are
        // left-grouped with the same rhythm so they read as a balanced pair.
        BoxWithConstraints {
            val compact = maxWidth < 560.dp
            if (compact) {
                Column(Modifier.fillMaxWidth()) {
                    Row(
                        Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        // Uniform gaps for every control (the parent Row supplies them, so
                        // TransportControls omits its own spacers) — avoids per-spacer
                        // rounding that left a wider forward-10s→mute gap on some devices.
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        // Fixed-width volume so the row stays left-grouped (matching the
                        // cluster row below) instead of the slider stretching to the edge.
                        TransportControls(state, callbacks, playFocus, onInteract, Modifier.width(140.dp), spread = true)
                    }
                    Spacer(Modifier.height(12.dp))
                    Row(
                        Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        // The parent Row supplies the 8dp gaps, so skip the
                        // cluster's own inter-button spacers (`spread = true`).
                        RightCluster(state, callbacks, onInteract, spread = true)
                    }
                }
            } else {
                Row(
                    Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    TransportControls(state, callbacks, playFocus, onInteract, Modifier.width(120.dp))
                    Spacer(Modifier.weight(1f))
                    RightCluster(state, callbacks, onInteract)
                }
            }
        }
    }
}

/** Play/pause, ±10s (VOD), mute + volume. `volumeModifier` sizes the volume slider
 *  (a fixed width in both layouts, so the transport row stays left-grouped). */
@Composable
private fun RowScope.TransportControls(
    state: PlayerUiState,
    callbacks: PlayerCallbacks,
    playFocus: FocusRequester,
    onInteract: () -> Unit,
    volumeModifier: Modifier,
    spread: Boolean = false,
) {
    // When `spread`, the parent Row supplies uniform gaps (`spacedBy`), so we omit
    // the manual spacers; otherwise (landscape) we space the controls ourselves.
    IconControlButton(
        icon = if (state.isPlaying) Icons.Filled.Pause else Icons.Filled.PlayArrow,
        contentDescription = "Play/Pause",
        focusRequester = playFocus,
        onClick = { onInteract(); callbacks.onPlayPause() },
    )
    if (!state.isLive) {
        if (!spread) Spacer(Modifier.width(8.dp))
        IconControlButton(Icons.Filled.Replay10, "Back 10s") {
            onInteract(); callbacks.onSeekBy(-10_000)
        }
        if (!spread) Spacer(Modifier.width(8.dp))
        IconControlButton(Icons.Filled.Forward10, "Forward 10s") {
            onInteract(); callbacks.onSeekBy(10_000)
        }
    }
    if (!spread) Spacer(Modifier.width(8.dp))
    IconControlButton(
        icon = if (state.muted || state.volume == 0f) Icons.Filled.VolumeOff else Icons.Filled.VolumeUp,
        contentDescription = "Mute",
    ) { onInteract(); callbacks.onToggleMute() }
    if (!spread) Spacer(Modifier.width(8.dp))
    SlimSlider(
        value = if (state.muted) 0f else state.volume,
        onValueChange = { onInteract(); callbacks.onSetVolume(it) },
        modifier = volumeModifier,
    )
}

/** Contextual right cluster: speed (VOD), audio, subtitles, aspect, info. */
@Composable
private fun RowScope.RightCluster(
    state: PlayerUiState,
    callbacks: PlayerCallbacks,
    onInteract: () -> Unit,
    spread: Boolean = false,
) {
    // When `spread`, the parent Row supplies the gaps (portrait, `spacedBy`), so we
    // omit the manual spacers; otherwise (landscape) we space the buttons ourselves.
    // Live-only: an unobtrusive "jump to live edge" control (separate from
    // play/pause, which keeps resuming from where you paused).
    if (state.isLive) {
        IconControlButton(Icons.Filled.LiveTv, "Go to live") {
            onInteract(); callbacks.onGoLive()
        }
        if (!spread) Spacer(Modifier.width(8.dp))
    }
    if (state.showSpeedButton) {
        TextControlButton(state.speedLabel(), "Playback speed") {
            onInteract(); state.openMenu =
                if (state.openMenu == PlayerMenu.Speed) PlayerMenu.None else PlayerMenu.Speed
        }
        if (!spread) Spacer(Modifier.width(8.dp))
    }
    if (state.showAudioButton) {
        IconControlButton(Icons.Filled.Audiotrack, "Audio track") {
            onInteract(); state.openMenu =
                if (state.openMenu == PlayerMenu.Audio) PlayerMenu.None else PlayerMenu.Audio
        }
        if (!spread) Spacer(Modifier.width(8.dp))
    }
    if (state.showSubtitleButton) {
        IconControlButton(Icons.Filled.ClosedCaption, "Subtitles") {
            onInteract(); state.openMenu =
                if (state.openMenu == PlayerMenu.Subtitles) PlayerMenu.None else PlayerMenu.Subtitles
        }
        if (!spread) Spacer(Modifier.width(8.dp))
    }
    TextControlButton(state.aspect.label, "Aspect ratio") {
        onInteract(); callbacks.onCycleAspect()
    }
    if (!spread) Spacer(Modifier.width(8.dp))
    IconControlButton(Icons.Filled.Info, "Stream info") {
        onInteract(); state.infoOpen = !state.infoOpen
    }
}

@Composable
private fun Scrubber(
    state: PlayerUiState,
    callbacks: PlayerCallbacks,
    onInteract: () -> Unit,
) {
    val duration = state.durationMs.coerceAtLeast(1)
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(
            formatTime(state.positionMs),
            color = PlayerColors.TextHi,
            fontFamily = InterFontFamily,
            fontSize = 13.sp,
            modifier = Modifier.width(58.dp),
        )
        SlimSlider(
            value = (state.positionMs.toFloat() / duration).coerceIn(0f, 1f),
            onValueChange = { fraction ->
                onInteract()
                callbacks.onSeekTo((fraction * duration).toLong())
            },
            modifier = Modifier.weight(1f),
            step = 0.02f, // ~2% per D-pad press for quicker scrubbing
        )
        Text(
            formatTime(state.durationMs),
            color = PlayerColors.TextLo,
            fontFamily = InterFontFamily,
            fontSize = 13.sp,
            modifier = Modifier.padding(start = 8.dp),
        )
    }
}

// ---- Reusable controls ------------------------------------------------------

@Composable
fun IconControlButton(
    icon: ImageVector,
    contentDescription: String,
    modifier: Modifier = Modifier,
    focusRequester: FocusRequester? = null,
    onClick: () -> Unit,
) {
    var focused by remember { mutableStateOf(false) }
    val base = modifier
        .size(PlayerDimens.ButtonSize)
        .clip(RoundedCornerShape(PlayerDimens.ButtonCorner))
        .background(if (focused) PlayerColors.ButtonBgFocused else PlayerColors.ButtonBg)
    val withFocus = if (focusRequester != null) base.focusRequester(focusRequester) else base
    Box(
        contentAlignment = Alignment.Center,
        modifier = withFocus
            .onFocusChanged { focused = it.isFocused }
            .clickable(onClick = onClick),
    ) {
        Icon(
            imageVector = icon,
            contentDescription = contentDescription,
            tint = PlayerColors.TextHi,
            modifier = Modifier.size(22.dp),
        )
    }
}

@Composable
fun TextControlButton(
    label: String,
    contentDescription: String,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    var focused by remember { mutableStateOf(false) }
    Box(
        contentAlignment = Alignment.Center,
        modifier = modifier
            .height(PlayerDimens.ButtonSize)
            .clip(RoundedCornerShape(PlayerDimens.ButtonCorner))
            .background(if (focused) PlayerColors.ButtonBgFocused else PlayerColors.ButtonBg)
            .onFocusChanged { focused = it.isFocused }
            .clickable(onClick = onClick)
            .padding(horizontal = 14.dp),
    ) {
        Text(
            text = label,
            color = PlayerColors.TextHi,
            fontFamily = InterFontFamily,
            fontWeight = FontWeight.SemiBold,
            fontSize = 14.sp,
            maxLines = 1,
        )
    }
}

@Composable
private fun UnsupportedVideoNotice(reason: String, modifier: Modifier = Modifier) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = modifier
            .padding(32.dp)
            .clip(RoundedCornerShape(PlayerDimens.MenuCorner))
            .background(PlayerColors.Panel)
            .padding(horizontal = 24.dp, vertical = 20.dp),
    ) {
        Text(
            text = reason,
            color = PlayerColors.TextHi,
            fontFamily = InterFontFamily,
            fontWeight = FontWeight.SemiBold,
            fontSize = 15.sp,
        )
        Spacer(Modifier.height(6.dp))
        Text(
            text = "Audio is still playing.",
            color = PlayerColors.TextLo,
            fontFamily = InterFontFamily,
            fontSize = 13.sp,
        )
    }
}

@Composable
fun LiveBadge() {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .clip(RoundedCornerShape(6.dp))
            .background(PlayerColors.Live)
            .padding(horizontal = 10.dp, vertical = 5.dp),
    ) {
        Text(
            "LIVE",
            color = androidx.compose.ui.graphics.Color.White,
            fontFamily = InterFontFamily,
            fontWeight = FontWeight.Bold,
            fontSize = 12.sp,
        )
    }
}

@Composable
fun Badge(text: String, accent: Boolean = false) {
    Box(
        Modifier
            .clip(RoundedCornerShape(6.dp))
            .background(if (accent) PlayerColors.Accent else PlayerColors.PanelHi)
            .padding(horizontal = 9.dp, vertical = 5.dp),
    ) {
        Text(
            text = text,
            color = PlayerColors.TextHi,
            fontFamily = InterFontFamily,
            fontWeight = FontWeight.Bold,
            fontSize = 11.sp,
        )
    }
}

/**
 * A slim slider that's D-pad friendly under the "OK to edit" model: focusing it
 * does nothing, and Left/Right pass through to normal focus traversal — so it's
 * never a trap. Press OK/Center to enter adjust mode (the thumb grows + gains an
 * accent ring); then Left/Right [step] the value and OK/Center or Back exits.
 * Touch keeps drag + tap-to-seek. Used for both the scrubber and volume.
 */
@Composable
fun SlimSlider(
    value: Float,
    onValueChange: (Float) -> Unit,
    modifier: Modifier = Modifier,
    step: Float = 0.05f,
) {
    var focused by remember { mutableStateOf(false) }
    var editing by remember { mutableStateOf(false) }
    var widthPx by remember { mutableFloatStateOf(0f) }
    val f = value.coerceIn(0f, 1f)
    val thumbSize = if (editing) 18.dp else 14.dp

    Box(
        modifier
            .height(28.dp) // comfortable touch / focus target around the thin track
            .onFocusChanged {
                focused = it.isFocused
                if (!it.isFocused) editing = false
            }
            .focusable()
            .onPreviewKeyEvent { e ->
                if (e.type != KeyEventType.KeyDown) return@onPreviewKeyEvent false
                when (e.key) {
                    Key.DirectionCenter, Key.Enter, Key.NumPadEnter -> {
                        editing = !editing
                        true
                    }
                    // Only capture Left/Right (to change the value) while editing;
                    // otherwise let them traverse focus to the neighbouring control.
                    Key.DirectionLeft ->
                        if (editing) { onValueChange((value - step).coerceIn(0f, 1f)); true } else false
                    Key.DirectionRight ->
                        if (editing) { onValueChange((value + step).coerceIn(0f, 1f)); true } else false
                    Key.Back -> if (editing) { editing = false; true } else false
                    else -> false
                }
            }
            .onSizeChanged { widthPx = it.width.toFloat() }
            .pointerInput(Unit) {
                detectTapGestures { offset ->
                    if (widthPx > 0f) onValueChange((offset.x / widthPx).coerceIn(0f, 1f))
                }
            }
            .pointerInput(Unit) {
                detectHorizontalDragGestures { change, _ ->
                    if (widthPx > 0f) onValueChange((change.position.x / widthPx).coerceIn(0f, 1f))
                }
            },
        contentAlignment = Alignment.Center,
    ) {
        // Track + elapsed fill.
        Box(
            Modifier
                .fillMaxWidth()
                .height(4.dp)
                .clip(RoundedCornerShape(2.dp))
                .background(PlayerColors.TrackInactive),
        ) {
            Box(
                Modifier
                    .fillMaxWidth(f)
                    .height(4.dp)
                    .clip(RoundedCornerShape(2.dp))
                    .background(PlayerColors.Accent),
            )
        }
        // Thumb positioned at the fill end via [f : 1-f] weighted spacers (centers
        // it exactly: thumb left = f * (width - thumbWidth)).
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            if (f > 0f) Spacer(Modifier.weight(f))
            Box(
                Modifier
                    .size(thumbSize)
                    .clip(CircleShape)
                    .background(PlayerColors.Accent)
                    .then(
                        if (editing || focused) {
                            Modifier.border(
                                2.dp,
                                androidx.compose.ui.graphics.Color.White.copy(alpha = 0.92f),
                                CircleShape,
                            )
                        } else {
                            Modifier
                        },
                    ),
            )
            if (f < 1f) Spacer(Modifier.weight(1f - f))
        }
    }
}

fun formatTime(ms: Long): String {
    if (ms <= 0) return "0:00"
    val totalSeconds = ms / 1000
    val h = totalSeconds / 3600
    val m = (totalSeconds % 3600) / 60
    val s = totalSeconds % 60
    return if (h > 0) {
        "%d:%02d:%02d".format(h, m, s)
    } else {
        "%d:%02d".format(m, s)
    }
}

/** Date + time clock for the TV top-bar badge, e.g. "Fri 26 Jun · 23:09". */
private fun formatClock(ms: Long): String =
    java.text.SimpleDateFormat("EEE d MMM · HH:mm", java.util.Locale.getDefault())
        .format(java.util.Date(ms))

/** Wall-clock HH:mm for EPG programme start/stop labels. */
private fun clockHm(ms: Long): String =
    java.text.SimpleDateFormat("HH:mm", java.util.Locale.getDefault())
        .format(java.util.Date(ms))

/**
 * Live EPG strip shown where the VOD scrubber sits: the current programme title +
 * its start–stop, a thin elapsed-progress bar, and the next programme.
 */
@Composable
private fun LiveEpgStrip(now: EpgEntry, next: EpgEntry?, nowMillis: Long) {
    Column(Modifier.fillMaxWidth()) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                text = now.title,
                color = PlayerColors.TextHi,
                fontFamily = InterFontFamily,
                fontWeight = FontWeight.SemiBold,
                fontSize = 14.sp,
                maxLines = 1,
                modifier = Modifier.weight(1f),
            )
            Spacer(Modifier.width(8.dp))
            Text(
                text = "${clockHm(now.startMs)} – ${clockHm(now.stopMs)}",
                color = PlayerColors.TextLo,
                fontFamily = InterFontFamily,
                fontSize = 12.sp,
            )
        }
        Spacer(Modifier.height(6.dp))
        Box(
            Modifier
                .fillMaxWidth()
                .height(4.dp)
                .clip(RoundedCornerShape(2.dp))
                .background(PlayerColors.TrackInactive),
        ) {
            Box(
                Modifier
                    .fillMaxWidth(now.progressAt(nowMillis))
                    .height(4.dp)
                    .clip(RoundedCornerShape(2.dp))
                    .background(PlayerColors.Accent),
            )
        }
        next?.let {
            Spacer(Modifier.height(6.dp))
            Text(
                text = "Next · ${it.title}",
                color = PlayerColors.TextLo,
                fontFamily = InterFontFamily,
                fontSize = 12.sp,
                maxLines = 1,
            )
        }
    }
}
