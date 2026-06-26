package com.gchofficial.iptvs.player

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
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
            .padding(end = PlayerDimens.EdgePadding, bottom = 96.dp),
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
