package com.gchofficial.iptvs.player

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** Renders whichever list-menu is open, anchored above the bottom bar's right cluster. */
@Composable
fun BoxScope.PlayerMenusLayer(
    state: PlayerUiState,
    callbacks: PlayerCallbacks,
    onInteract: () -> Unit,
) {
    val menu = state.openMenu
    if (menu == PlayerMenu.None) return

    val header: String
    val options: List<TrackOption>
    val selectedId: String?
    val onSelect: (String) -> Unit

    when (menu) {
        PlayerMenu.Audio -> {
            header = "Audio"
            options = state.audioTracks
            selectedId = state.selectedAudioId
            onSelect = { callbacks.onSelectAudio(it) }
        }
        PlayerMenu.Subtitles -> {
            header = "Subtitles"
            options = state.subtitleTracks
            selectedId = state.selectedSubtitleId
            onSelect = { callbacks.onSelectSubtitle(it) }
        }
        PlayerMenu.Speed -> {
            header = "Playback speed"
            options = SPEED_OPTIONS.map { TrackOption(speedId(it), speedOptionLabel(it)) }
            selectedId = speedId(state.speed)
            onSelect = { id -> id.toFloatOrNull()?.let { callbacks.onSetSpeed(it) } }
        }
        PlayerMenu.None -> return
    }

    ListMenu(
        header = header,
        options = options,
        selectedId = selectedId,
        modifier = Modifier
            .align(Alignment.BottomEnd)
            // The 96dp clears the bottom bar; on TV that bar's outer inset grows
            // for overscan, so the menu has to rise with it (see
            // `PlayerDimens.TvEdgePadding`).
            .padding(
                end = PlayerDimens.edgePadding(state.isTv),
                bottom = 96.dp + PlayerDimens.edgeExtraVertical(state.isTv),
            ),
        onSelect = { id ->
            onInteract()
            onSelect(id)
            state.openMenu = PlayerMenu.None
        },
    )
}

/**
 * The one reusable vertical list-menu primitive (audio / subtitles / speed),
 * mirroring the Windows overlay's single-menu model. D-pad navigable: up/down
 * traverse the focusable rows, center selects, back closes (handled by the
 * screen-level BackHandler).
 */
@Composable
fun ListMenu(
    header: String,
    options: List<TrackOption>,
    selectedId: String?,
    modifier: Modifier = Modifier,
    onSelect: (String) -> Unit,
) {
    val firstFocus = remember { FocusRequester() }
    val selectedIndex = options.indexOfFirst { it.id == selectedId }.coerceAtLeast(0)

    LaunchedEffect(header) {
        runCatching { firstFocus.requestFocus() }
    }

    Column(
        modifier
            .width(PlayerDimens.MenuWidth)
            .clip(RoundedCornerShape(PlayerDimens.MenuCorner))
            .background(PlayerColors.Panel),
    ) {
        Text(
            text = header,
            color = PlayerColors.TextLo,
            fontFamily = InterFontFamily,
            fontWeight = FontWeight.SemiBold,
            fontSize = 12.sp,
            modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 14.dp, bottom = 6.dp),
        )
        LazyColumn(
            Modifier.heightIn(max = PlayerDimens.MenuMaxHeight),
        ) {
            itemsIndexed(options) { index, option ->
                MenuRow(
                    option = option,
                    selected = option.id == selectedId,
                    focusRequester = if (index == selectedIndex) firstFocus else null,
                    onClick = { onSelect(option.id) },
                )
            }
        }
        Spacer(Modifier.padding(bottom = 6.dp))
    }
}

@Composable
private fun MenuRow(
    option: TrackOption,
    selected: Boolean,
    focusRequester: FocusRequester?,
    onClick: () -> Unit,
) {
    var focused by remember { mutableStateOf(false) }
    val base = Modifier
        .fillMaxWidth()
        .let { if (focusRequester != null) it.focusRequester(focusRequester) else it }
        .onFocusChanged { focused = it.isFocused }
        .clickable(onClick = onClick)
        .background(if (focused) PlayerColors.PanelHi else Color.Transparent)
        .padding(horizontal = 16.dp, vertical = 11.dp)
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween,
        modifier = base,
    ) {
        Text(
            text = option.label,
            color = if (selected) PlayerColors.Accent else PlayerColors.TextHi,
            fontFamily = InterFontFamily,
            fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
            fontSize = 14.sp,
        )
        if (selected) {
            Spacer(Modifier.width(8.dp))
            Icon(
                imageVector = Icons.Filled.Check,
                contentDescription = null,
                tint = PlayerColors.Accent,
                modifier = Modifier.size(18.dp),
            )
        } else {
            Box(Modifier.size(18.dp))
        }
    }
}

private fun speedId(value: Float): String = value.toString()

private fun speedOptionLabel(value: Float): String =
    if (value == value.toLong().toFloat()) "${value.toLong()}×" else "${value}×"

/**
 * The in-player **quick list** — the same panel primitive as [ListMenu] above
 * (the same surface colour, corner radius, header type and row rhythm), in its
 * one other mode: a *selection model* rather than a focus ring.
 *
 * That is the whole difference, and it is not stylistic. [ListMenu]'s rows are
 * focus targets because a track menu has five of them; this list's rows are a
 * **window** of at most 40, cut by Dart from a range that is routinely the
 * whole 250k-channel catalog, so a row outside the window does not exist to
 * focus and the cursor cannot be a focused node. One integer arrives on the
 * wire ([QuickListState.selectedIndex], absolute), the highlight is drawn at
 * `selectedIndex - windowStart`, and the arrows that move it were claimed at
 * the Activity boundary by [ZapKeyPolicy] before Compose ever saw them
 * (docs/tv-navigation.md, "The in-player quick list").
 *
 * Everything drawn here is printed verbatim from the payload: labels, the
 * second line, the badges and every derived state are Dart's
 * (docs/player.md, "The quick list (Phase 6)"). The one thing computed is the
 * `n/total` position readout, which the contract sets aside `index` for.
 *
 * @param onActivateRow a pointer tap on a row — naming the row, since the
 *   cursor is Dart's to move.
 */
@Composable
fun QuickListPanel(
    state: PlayerUiState,
    onActivateRow: (QuickListRow) -> Unit,
) {
    val list = state.quickList
    val listState = rememberLazyListState()
    val cursor = list.selectedInWindow

    // Keep the cursor on screen. Only when it has actually left the visible
    // range: scrolling on every push would fight a user who is paging with a
    // held key, and the row height is fixed precisely so this is arithmetic
    // rather than a measurement of rows that may not be composed.
    LaunchedEffect(cursor, list.windowStart, list.revision) {
        if (cursor < 0) return@LaunchedEffect
        val visible = listState.layoutInfo.visibleItemsInfo
        val first = visible.firstOrNull()?.index
        val last = visible.lastOrNull()?.index
        if (first == null || last == null || cursor < first || cursor > last) {
            runCatching { listState.animateScrollToItem((cursor - 2).coerceAtLeast(0)) }
        }
    }

    Box(Modifier.fillMaxSize().safeDrawingPadding()) {
        Column(
            Modifier
                .align(Alignment.CenterStart)
                .padding(
                    start = PlayerDimens.edgePadding(state.isTv),
                    top = 18.dp + PlayerDimens.edgeExtraVertical(state.isTv),
                    bottom = 18.dp + PlayerDimens.edgeExtraVertical(state.isTv),
                )
                .width(PlayerDimens.QuickListWidth)
                .fillMaxHeight()
                .clip(RoundedCornerShape(PlayerDimens.MenuCorner))
                .background(PlayerColors.Panel),
        ) {
            QuickListHeader(list)
            when {
                list.rows.isEmpty() && list.loading -> Box(
                    Modifier.fillMaxWidth().weight(1f),
                    contentAlignment = Alignment.Center,
                ) {
                    CircularProgressIndicator(
                        color = PlayerColors.Accent,
                        strokeWidth = 2.dp,
                        modifier = Modifier.size(28.dp),
                    )
                }
                list.rows.isEmpty() -> Box(
                    Modifier.fillMaxWidth().weight(1f).padding(horizontal = 16.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    // Printed, never invented: with no `emptyLabel` there is
                    // nothing this side is entitled to say.
                    list.emptyLabel?.let {
                        Text(
                            text = it,
                            color = PlayerColors.TextLo,
                            fontFamily = InterFontFamily,
                            fontSize = 13.sp,
                        )
                    }
                }
                else -> LazyColumn(
                    state = listState,
                    modifier = Modifier.fillMaxWidth().weight(1f),
                ) {
                    itemsIndexed(list.rows) { offset, row ->
                        QuickListRowView(
                            row = row,
                            selected = offset == cursor,
                            onClick = { onActivateRow(row) },
                        )
                    }
                }
            }
            Spacer(Modifier.height(6.dp))
        }
    }
}

@Composable
private fun QuickListHeader(list: QuickListState) {
    Row(
        Modifier
            .fillMaxWidth()
            .padding(start = 16.dp, end = 16.dp, top = 14.dp, bottom = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = list.heading,
            color = PlayerColors.TextLo,
            fontFamily = InterFontFamily,
            fontWeight = FontWeight.SemiBold,
            fontSize = 12.sp,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        // A fetch behind an already-drawn list (paging in a category's
        // channels): the rows stay, the spinner says more is coming.
        if (list.loading && list.rows.isNotEmpty()) {
            Spacer(Modifier.width(8.dp))
            CircularProgressIndicator(
                color = PlayerColors.Accent,
                strokeWidth = 2.dp,
                modifier = Modifier.size(12.dp),
            )
        }
        if (list.total > 0) {
            Spacer(Modifier.width(8.dp))
            Text(
                text = "${list.selectedIndex + 1}/${list.total}",
                color = PlayerColors.TextLo,
                fontFamily = InterFontFamily,
                fontSize = 12.sp,
                maxLines = 1,
            )
        }
    }
}

@Composable
private fun QuickListRowView(
    row: QuickListRow,
    selected: Boolean,
    onClick: () -> Unit,
) {
    // A past programme is dimmed rather than hidden: it is still activatable
    // when the channel has an archive, and the schedule reads as a day.
    val primary = if (row.past && !selected) PlayerColors.TextLo else PlayerColors.TextHi
    Row(
        Modifier
            .fillMaxWidth()
            .height(PlayerDimens.QuickListRowHeight)
            .padding(horizontal = 8.dp, vertical = 2.dp)
            // Clips the two text lines as well as the highlight, so a large
            // system font scale trims rather than spilling out of the fixed
            // extent the cursor arithmetic depends on.
            .clip(RoundedCornerShape(PlayerDimens.ButtonCorner))
            .background(if (selected) PlayerColors.PanelHi else Color.Transparent)
            .clickable(onClick = onClick)
            .padding(horizontal = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (row.playing) {
            Icon(
                imageVector = Icons.Filled.PlayArrow,
                contentDescription = null,
                tint = PlayerColors.Accent,
                modifier = Modifier.size(16.dp),
            )
            Spacer(Modifier.width(6.dp))
        }
        Column(Modifier.weight(1f)) {
            Text(
                text = row.label,
                color = primary,
                fontFamily = InterFontFamily,
                fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
                fontSize = 14.sp,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            row.secondary?.let {
                Text(
                    text = it,
                    color = PlayerColors.TextLo,
                    fontFamily = InterFontFamily,
                    fontSize = 11.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        if (row.archive) {
            Spacer(Modifier.width(8.dp))
            Icon(
                imageVector = Icons.Filled.History,
                contentDescription = null,
                tint = PlayerColors.TextLo,
                modifier = Modifier.size(14.dp),
            )
        }
        row.badge?.let {
            Spacer(Modifier.width(8.dp))
            QuickListBadge(label = it, live = row.live)
        }
    }
}

/** `ON NOW` / `CATCH-UP` — the label is the payload's, never built here. */
@Composable
private fun QuickListBadge(label: String, live: Boolean) {
    Box(
        Modifier
            .clip(RoundedCornerShape(6.dp))
            .background(if (live) PlayerColors.Live else PlayerColors.PanelHi)
            .padding(horizontal = 6.dp, vertical = 2.dp),
    ) {
        Text(
            text = label,
            color = PlayerColors.TextHi,
            fontFamily = InterFontFamily,
            fontWeight = FontWeight.SemiBold,
            fontSize = 10.sp,
            maxLines = 1,
        )
    }
}
