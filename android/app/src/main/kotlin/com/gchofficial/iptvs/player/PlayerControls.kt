package com.gchofficial.iptvs.player

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
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
// Shadows `kotlin.collections.List` inside this file — an explicit import wins
// over a default one. Harmless today (nothing here names the collection type)
// and kept because it is the icon's real name, but anything added below that
// wants a `List<T>` must spell it `kotlin.collections.List`.
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material.icons.filled.AspectRatio
import androidx.compose.material.icons.filled.Audiotrack
import androidx.compose.material.icons.filled.ClosedCaption
import androidx.compose.material.icons.filled.Forward10
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PictureInPictureAlt
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Replay10
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.StarBorder
import androidx.compose.material.icons.filled.VolumeOff
import androidx.compose.material.icons.filled.VolumeUp
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
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
    val onToggleFavorite: () -> Unit,
    val onBack: () -> Unit,
    val onEnterPip: () -> Unit,
    /**
     * One member of the shared zap vocabulary (`lib/player/zap_command.dart`)
     * sent to Dart. The overlay's only use for it is the quick list's
     * *pointer* path: every key that drives the list is claimed at the
     * Activity boundary by [ZapKeyPolicy] and never reaches Compose.
     */
    val onZapCommand: (String) -> Unit,
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

    // The zap banner fades on its own timer, deliberately **not** on
    // `controlsVisible`: it is the only acknowledgement a keypress gets while
    // the chrome is hidden, which is exactly when zapping is used. Keyed on
    // the push timestamp, so each press restarts the countdown instead of
    // stacking timers.
    LaunchedEffect(state.zapBannerAtMs) {
        if (state.zapBannerAtMs == 0L) return@LaunchedEffect
        kotlinx.coroutines.delay(ZAP_BANNER_VISIBLE_MS)
        state.zapBannerVisible = false
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

    Box(
        Modifier
            .fillMaxSize()
            .background(PlayerColors.Ink)
            .focusRequester(rootFocus)
            .focusable()
            .onPreviewKeyEvent { event ->
                if (event.type != KeyEventType.KeyDown) return@onPreviewKeyEvent false
                // With the quick list up, a key that the zap policy declined
                // must not throw the chrome over it: the list has the screen,
                // and reveal-on-any-key would put the control row on top of
                // the thing the user is reading.
                if (state.quickList.open) return@onPreviewKeyEvent false
                val wasHidden = !state.controlsVisible
                poke()
                wasHidden // consume the first key only to reveal controls
            },
    ) {
        // key() so swapping engines (ExoPlayer -> mpv fallback) rebuilds the host
        // with the new engine's view.
        //
        // Hosting the video here rather than attaching it to the Activity's
        // content in `onCreate` costs nothing: `AndroidView` adds the SurfaceView
        // during the first composition, inside the window's first traversal, so
        // a pre-attached view would be laid out in that same traversal. Measured
        // both ways on a TV emulator — see docs/player.md.
        key(videoView) {
            AndroidView(factory = { videoView }, modifier = Modifier.fillMaxSize())
        }

        // Tap layer (below the controls) toggles visibility on touch devices.
        // Skipped in PiP: the tiny window shows video only, no control chrome.
        // Skipped with the quick list up for the same reason the root key
        // handler is: the list owns the screen until it is dismissed.
        if (!state.inPip && !state.quickList.open) {
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
        }

        if (state.videoUnsupported) {
            UnsupportedVideoNotice(
                reason = state.videoUnsupportedReason,
                modifier = Modifier.align(Alignment.Center),
            )
        }

        if (state.reconnecting) {
            ReconnectingNotice(modifier = Modifier.align(Alignment.Center))
        }

        // Below the bars on purpose: the two are mutually exclusive by the
        // `!controlsVisible` gate, but their fades overlap, and the bar (which
        // carries the same information plus the controls) should win.
        AnimatedVisibility(
            visible = state.showZapBanner && !state.controlsVisible,
            enter = fadeIn(),
            exit = fadeOut(),
        ) {
            ZapBanner(state, nowMillis)
        }

        AnimatedVisibility(
            visible = state.controlsVisible && !state.inPip,
            enter = fadeIn(),
            exit = fadeOut(),
        ) {
            ControlsOverlay(state, callbacks, playFocus, nowMillis) { poke() }
        }

        // Above the bars: the quick list is what the user is looking at while
        // it is open, and the Activity hides the chrome as it arrives anyway.
        AnimatedVisibility(
            visible = state.showQuickList,
            enter = fadeIn(),
            exit = fadeOut(),
        ) {
            QuickListPanel(state) { row ->
                // A tap names a row; the cursor is still Dart's to move, so
                // this is "put the cursor here, then OK" rather than a second
                // way to activate — one path, one set of rules.
                val delta = row.index - state.quickList.selectedIndex
                if (delta != 0) callbacks.onZapCommand("zap:move:$delta")
                callbacks.onZapCommand("zap:activate")
            }
        }

        // Menus + info panel sit above the bars; they imply controls are visible.
        // Inset as one group (same reasoning as ControlsOverlay) — their
        // BottomEnd/TopEnd alignment would otherwise put them in the cutout on a
        // notched phone, which the Activity's layoutInDisplayCutoutMode
        // (ALWAYS on API 30+, SHORT_EDGES on 28-29) lets the window extend into.
        if (state.controlsVisible && !state.inPip) {
            Box(Modifier.fillMaxSize().safeDrawingPadding()) {
                PlayerMenusLayer(state, callbacks) { poke() }
                if (state.infoOpen) {
                    InfoPanel(
                        state = state,
                        modifier = Modifier
                            .align(Alignment.TopEnd)
                            // The 84dp clears the top bar; on TV that bar grows by
                            // the overscan inset, so the panel has to follow it
                            // down or it opens *inside* the bar.
                            .padding(
                                top = 84.dp + PlayerDimens.edgeExtraVertical(state.isTv),
                                end = PlayerDimens.edgePadding(state.isTv),
                            ),
                    )
                }
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
    // The scrim stays full-bleed (it has to reach the screen edge to be readable
    // over the video), while the controls themselves are inset: the display
    // cutout is always excluded, and the system bars are excluded whenever a
    // swipe transiently reveals them over our immersive window.
    Box(
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
        Column(Modifier.fillMaxSize().safeDrawingPadding()) {
            TopBar(state, callbacks, nowMillis, onInteract)
            Spacer(Modifier.weight(1f))
            BottomBar(state, callbacks, playFocus, nowMillis, onInteract)
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun TopBar(
    state: PlayerUiState,
    callbacks: PlayerCallbacks,
    nowMillis: Long,
    onInteract: () -> Unit,
) {
    // Same breakpoint as the bottom bar: below ~560dp (phone portrait) the badge
    // cluster would squeeze the title to nothing, so it wraps onto its own row.
    // On a TV the edge inset widens and the *outer* (top) vertical inset grows:
    // `safeDrawingPadding()` reports zero insets there, so nothing else keeps the
    // chrome off the physical panel edge. See `PlayerDimens.TvEdgePadding`.
    val edge = PlayerDimens.edgePadding(state.isTv)
    val outerVertical = PlayerDimens.edgeExtraVertical(state.isTv)
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        val compact = maxWidth < 560.dp
        if (compact) {
            Column(
                Modifier
                    .fillMaxWidth()
                    .padding(
                        start = edge,
                        end = edge,
                        top = 12.dp + outerVertical,
                        bottom = 12.dp,
                    ),
            ) {
                Row(
                    Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    IconControlButton(
                        icon = Icons.AutoMirrored.Filled.ArrowBack,
                        contentDescription = "Back",
                        onClick = { onInteract(); callbacks.onBack() },
                    )
                    Spacer(Modifier.width(14.dp))
                    Text(
                        text = state.title,
                        color = PlayerColors.TextHi,
                        fontFamily = InterFontFamily,
                        fontWeight = FontWeight.Bold,
                        fontSize = 18.sp,
                        maxLines = 1,
                        modifier = Modifier.weight(1f),
                    )
                }
                Spacer(Modifier.height(6.dp))
                // FlowRow so the badges wrap again on very narrow screens instead
                // of overflowing off-screen.
                FlowRow(
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    TopBadges(state, nowMillis)
                }
            }
        } else {
            Row(
                Modifier
                    .fillMaxWidth()
                    .padding(
                        start = edge,
                        end = edge,
                        top = 16.dp + outerVertical,
                        bottom = 16.dp,
                    ),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                IconControlButton(
                    icon = Icons.AutoMirrored.Filled.ArrowBack,
                    contentDescription = "Back",
                    onClick = { onInteract(); callbacks.onBack() },
                )
                Spacer(Modifier.width(14.dp))
                Text(
                    text = state.title,
                    color = PlayerColors.TextHi,
                    fontFamily = InterFontFamily,
                    fontWeight = FontWeight.Bold,
                    fontSize = 18.sp,
                    maxLines = 1,
                    modifier = Modifier.weight(1f),
                )
                Spacer(Modifier.width(8.dp))
                // Right-cluster badges: source, LIVE/resolution/HDR, fps, and (TV
                // only) a date+time clock. The title takes the remaining width and
                // ellipsizes.
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    TopBadges(state, nowMillis)
                }
            }
        }
    }
}

@Composable
private fun TopBadges(state: PlayerUiState, nowMillis: Long) {
    state.sourceBadge()?.let { Badge(it) }
    if (state.isLive) LiveBadge(synced = state.liveSynced)
    state.resolutionBadge()?.let { Badge(it) }
    state.hdrBadge()?.let { Badge(it, accent = true) }
    state.fpsBadge()?.let { Badge(it) }
    if (state.isTv) Badge(formatClock(nowMillis))
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
            // TV overscan: wider sides, and the extra goes on the *bottom* only —
            // that's the physical edge here. See `PlayerDimens.TvEdgePadding`.
            .padding(
                start = PlayerDimens.edgePadding(state.isTv),
                end = PlayerDimens.edgePadding(state.isTv),
                top = 18.dp,
                bottom = 18.dp + PlayerDimens.edgeExtraVertical(state.isTv),
            ),
    ) {
        if (!state.isLive) {
            Scrubber(state, callbacks, onInteract)
            Spacer(Modifier.height(10.dp))
        } else {
            // Live has no scrubber; surface the channel identity + the EPG
            // now/next + programme progress in its place when available.
            //
            // The identity run is drawn only when it says something the top
            // bar's title does not — a channel number, a half-typed number, a
            // transient note — so a session that never zaps looks exactly as
            // it did before.
            if (state.showsChannelIdentity) {
                ChannelIdentityRow(state)
                Spacer(Modifier.height(10.dp))
            }
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
                        RightCluster(state, callbacks, playFocus, onInteract, spread = true)
                    }
                }
            } else {
                Row(
                    Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    TransportControls(state, callbacks, playFocus, onInteract, Modifier.width(120.dp))
                    Spacer(Modifier.weight(1f))
                    RightCluster(state, callbacks, playFocus, onInteract)
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
        // In the transport row it reads as one of the controls, and needs a
        // focus state a remote user can actually see — see [SlimSlider].
        chip = true,
    )
}

/** Contextual right cluster: speed (VOD), audio, subtitles, aspect, info. */
@Composable
private fun RowScope.RightCluster(
    state: PlayerUiState,
    callbacks: PlayerCallbacks,
    playFocus: FocusRequester,
    onInteract: () -> Unit,
    spread: Boolean = false,
) {
    // When `spread`, the parent Row supplies the gaps (portrait, `spacedBy`), so we
    // omit the manual spacers; otherwise (landscape) we space the buttons ourselves.
    //
    // The quick-list opener, **immediately left of "Go to live"** — the slot
    // every surface that draws its own chrome gives it (the Windows GDI
    // `BottomLayout::quick_list`, the shared Flutter cluster, the Linux Lua
    // OSD). A remote reaches the list with Left or GUIDE; a finger and a mouse
    // have no equivalent, which is the whole reason this button exists.
    //
    // Gated on `showQuickListButton` (live **and** a zap controller behind the
    // route), never on `isLive` alone: with no controller Dart declines
    // `zap:list` and the button would be inert. It sends the command through
    // the same `onZapCommand` path the overlay's pointer-driven quick-list rows
    // use — this surface is an input source, never a second copy of the list.
    //
    // It sends `zap:list` and never `zap:close`, unlike the Windows button:
    // `applyQuickList` stands the chrome down on the closed→open edge, so this
    // control is off screen for as long as the list is up and can never be
    // pressed a second time. Back is what closes it here.
    if (state.showQuickListButton) {
        IconControlButton(
            icon = Icons.AutoMirrored.Filled.List,
            contentDescription = "Channel list",
        ) { onInteract(); callbacks.onZapCommand("zap:list") }
        if (!spread) Spacer(Modifier.width(8.dp))
    }
    // Live-only "jump to live edge", shown only once behind (paused) — separate
    // from play/pause, which keeps resuming from where you paused. The label is
    // the action, not the state: this used to read "LIVE", duplicating the LIVE
    // *status* badge in the top bar (which greys at the very moment this button
    // appears) with a word that says nothing about what pressing it does. Every
    // overlay already declared "Go to live" as the accessible name; the visible
    // label now agrees with it. Same wording on Windows, iOS, Linux and the
    // shared Flutter overlay.
    //
    // **It is the one control that removes itself while you are standing on
    // it**, and on a D-pad that used to strand the remote: pressing OK reloads
    // to the live edge, `liveSynced` flips true, the button leaves composition,
    // and Compose's focus went with it — no control in the overlay held focus
    // any more, so no arrow key did anything until Back tore the whole thing
    // down. Focus therefore moves to play/pause on the press, and again from
    // `onDispose` if the button disappears while focused for any *other* reason
    // (the reconnect watchdog reaching the live edge on its own). Both go
    // through `runCatching` because the requester's node is gone when the whole
    // bar is leaving composition — the chrome-hidden case, where
    // `PlayerScreen`'s own effect parks focus on the root instead.
    if (state.isLive && !state.liveSynced) {
        var goLiveFocused by remember { mutableStateOf(false) }
        DisposableEffect(Unit) {
            onDispose {
                if (goLiveFocused) runCatching { playFocus.requestFocus() }
            }
        }
        TextControlButton(
            label = "Go to live",
            contentDescription = "Go to live",
            onFocusChanged = { goLiveFocused = it },
        ) {
            onInteract()
            callbacks.onGoLive()
            runCatching { playFocus.requestFocus() }
        }
        if (!spread) Spacer(Modifier.width(8.dp))
    }
    if (state.canFavorite) {
        IconControlButton(
            icon = if (state.isFavorite) Icons.Filled.Star else Icons.Filled.StarBorder,
            contentDescription = if (state.isFavorite) "Remove from favorites" else "Add to favorites",
        ) { onInteract(); callbacks.onToggleFavorite() }
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
    if (state.supportsPip) {
        if (!spread) Spacer(Modifier.width(8.dp))
        IconControlButton(Icons.Filled.PictureInPictureAlt, "Picture in picture") {
            onInteract(); callbacks.onEnterPip()
        }
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

/**
 * [onFocusChanged] lets a caller observe focus without owning the visual state.
 * It exists for controls that can *remove themselves* while focused — "Go to
 * live" is the only one — so the caller can hand focus somewhere else before it
 * goes; see [RightCluster].
 */
@Composable
fun TextControlButton(
    label: String,
    contentDescription: String,
    modifier: Modifier = Modifier,
    onFocusChanged: ((Boolean) -> Unit)? = null,
    onClick: () -> Unit,
) {
    var focused by remember { mutableStateOf(false) }
    Box(
        contentAlignment = Alignment.Center,
        modifier = modifier
            .height(PlayerDimens.ButtonSize)
            .clip(RoundedCornerShape(PlayerDimens.ButtonCorner))
            .background(if (focused) PlayerColors.ButtonBgFocused else PlayerColors.ButtonBg)
            .onFocusChanged {
                focused = it.isFocused
                onFocusChanged?.invoke(it.isFocused)
            }
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
private fun ReconnectingNotice(modifier: Modifier = Modifier) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier
            .clip(RoundedCornerShape(PlayerDimens.MenuCorner))
            .background(PlayerColors.Panel)
            .padding(horizontal = 20.dp, vertical = 14.dp),
    ) {
        CircularProgressIndicator(
            color = PlayerColors.Accent,
            strokeWidth = 2.dp,
            modifier = Modifier.size(18.dp),
        )
        Spacer(Modifier.width(12.dp))
        Text(
            text = "Reconnecting…",
            color = PlayerColors.TextHi,
            fontFamily = InterFontFamily,
            fontWeight = FontWeight.SemiBold,
            fontSize = 15.sp,
        )
    }
}

@Composable
fun LiveBadge(synced: Boolean = true) {
    // Red at the live edge; grey once behind (paused/seeked). Pairs with the
    // go-to-live button, which appears only while behind.
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .clip(RoundedCornerShape(6.dp))
            .background(if (synced) PlayerColors.Live else PlayerColors.TrackInactive)
            .padding(horizontal = 10.dp, vertical = 5.dp),
    ) {
        Text(
            "LIVE",
            color = if (synced) {
                androidx.compose.ui.graphics.Color.White
            } else {
                PlayerColors.TextLo
            },
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
    chip: Boolean = false,
) {
    var focused by remember { mutableStateOf(false) }
    var editing by remember { mutableStateOf(false) }
    var widthPx by remember { mutableFloatStateOf(0f) }
    val f = value.coerceIn(0f, 1f)
    val thumbSize = if (editing) 18.dp else 14.dp
    // A focused chip is filled with `ButtonBgFocused`, which *is* `Accent` — the
    // same colour as the slider's own fill, so on accent the value has to be
    // drawn in white or it vanishes into its own background.
    val onAccent = chip && (focused || editing)
    val trackColor = if (onAccent) {
        androidx.compose.ui.graphics.Color.White.copy(alpha = 0.35f)
    } else {
        PlayerColors.TrackInactive
    }
    val fillColor = if (onAccent) {
        androidx.compose.ui.graphics.Color.White
    } else {
        PlayerColors.Accent
    }

    Box(
        modifier
            // [chip] gives the volume slider the same rounded fill its neighbours
            // in the transport row have, lit the same way on focus. Without it
            // the slider was the one focus stop in the overlay whose focused
            // state was a 2dp ring on a 14dp thumb — walking onto it with a
            // D-pad read as "the focus disappeared", which is exactly how the
            // "Go to live" stranding was first described. Opt-in so the VOD
            // scrubber, which spans the bar, stays a bare track.
            .then(
                if (chip) {
                    Modifier
                        .height(PlayerDimens.ButtonSize)
                        .clip(RoundedCornerShape(PlayerDimens.ButtonCorner))
                        .background(
                            if (focused || editing) {
                                PlayerColors.ButtonBgFocused
                            } else {
                                PlayerColors.ButtonBg
                            },
                        )
                        .padding(horizontal = 12.dp)
                } else {
                    // Comfortable touch / focus target around the thin track.
                    Modifier.height(28.dp)
                },
            )
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
                .background(trackColor),
        ) {
            Box(
                Modifier
                    .fillMaxWidth(f)
                    .height(4.dp)
                    .clip(RoundedCornerShape(2.dp))
                    .background(fillColor),
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
                    .background(fillColor)
                    .then(
                        // On an accent chip the thumb is already white; a white
                        // ring around it would only blur its edge.
                        if ((editing || focused) && !onAccent) {
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
 * The zap banner: what a channel change says while the chrome is hidden.
 *
 * It sits exactly where the bottom bar's live block does and carries the same
 * two pieces — the channel identity run and the live EPG strip — rather than
 * a layout of its own, so a channel seen through the banner and the same
 * channel seen with the controls up read identically. That reuse is the whole
 * design: this is the fifth surface that has to agree about the live strip
 * (docs/player.md, "The live EPG strip"), and a bespoke one would be a fifth
 * thing to keep in step.
 */
@Composable
private fun ZapBanner(state: PlayerUiState, nowMillis: Long) {
    Box(Modifier.fillMaxSize().safeDrawingPadding()) {
        Column(
            Modifier
                .align(Alignment.BottomStart)
                .fillMaxWidth()
                .padding(
                    start = PlayerDimens.edgePadding(state.isTv),
                    end = PlayerDimens.edgePadding(state.isTv),
                    bottom = 18.dp + PlayerDimens.edgeExtraVertical(state.isTv),
                )
                .clip(RoundedCornerShape(PlayerDimens.BarCorner))
                .background(PlayerColors.Panel)
                .padding(horizontal = 16.dp, vertical = 12.dp),
        ) {
            ChannelIdentityRow(state)
            state.epgNow?.let { now ->
                Spacer(Modifier.height(10.dp))
                LiveEpgStrip(now, state.epgNext, nowMillis)
            }
        }
    }
}

/**
 * `12 · BBC One`, with the half-typed channel number leading it and any
 * transient note trailing it.
 *
 * Shared by the banner and the bottom bar so the two cannot drift. The typed
 * digits are the headline while they exist: mid-entry, the number the user is
 * building is the thing they are looking at, and the channel beside it is
 * still the one playing.
 */
@Composable
private fun ChannelIdentityRow(state: PlayerUiState) {
    val identity = state.channelIdentityLabel()
    val digits = state.digitBuffer
    val message = state.zapMessage
    if (identity == null && digits.isEmpty() && message == null) return
    Row(
        Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (digits.isNotEmpty()) {
            Text(
                text = digits,
                color = PlayerColors.Accent,
                fontFamily = InterFontFamily,
                fontWeight = FontWeight.Bold,
                fontSize = 24.sp,
                maxLines = 1,
            )
            Spacer(Modifier.width(12.dp))
        }
        if (identity != null) {
            Text(
                text = identity,
                color = PlayerColors.TextHi,
                fontFamily = InterFontFamily,
                fontWeight = FontWeight.SemiBold,
                fontSize = 16.sp,
                maxLines = 1,
                modifier = Modifier.weight(1f),
            )
        } else {
            Spacer(Modifier.weight(1f))
        }
        if (message != null) {
            Spacer(Modifier.width(8.dp))
            Text(
                text = message,
                color = PlayerColors.Live,
                fontFamily = InterFontFamily,
                fontSize = 12.sp,
                maxLines = 1,
            )
        } else if (state.zapTotal > 0 && state.zapPosition > 0) {
            Spacer(Modifier.width(8.dp))
            Text(
                text = "${state.zapPosition}/${state.zapTotal}",
                color = PlayerColors.TextLo,
                fontFamily = InterFontFamily,
                fontSize = 12.sp,
                maxLines = 1,
            )
        }
    }
}

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
                text = "Next · ${clockHm(it.startMs)} – ${clockHm(it.stopMs)} · ${it.title}",
                color = PlayerColors.TextLo,
                fontFamily = InterFontFamily,
                fontSize = 12.sp,
                maxLines = 1,
            )
        }
    }
}
