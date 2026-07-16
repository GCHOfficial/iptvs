import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show KeyDownEvent, KeyEvent, KeyRepeatEvent, LogicalKeyboardKey;

import '../sources/source.dart';
import '../widgets/routed_focus_node.dart';

/// Which live region currently owns the D-pad.
enum LiveFocusRegion { none, channels, categories, previewControls, search }

/// Which column of the selected channel row the D-pad cursor occupies: the
/// row **body** (OK plays) or the trailing **favorite** star (OK toggles).
/// Right enters the favorite column; Left, every vertical move, and every
/// (re)entry into the channel pane peel it back to the body, so the star
/// column is never sticky across rows.
enum ChannelRowColumn { body, favorite }

/// The live tab's D-pad navigation, as a **selection model** — the same pattern
/// the TV guide ([EpgGridScreen]) uses, and for the same reason.
///
/// The channel list and the category sidebar each have exactly **one** focus
/// node and a **selected index**. Rows are not focus targets: they are plain
/// widgets highlighted at `i == selectedIndex`, and this class drives the scroll
/// itself with exact `itemExtent` math. That kills an entire class of bug the
/// previous per-row-focus design kept producing: an off-screen row in a lazy
/// `ListView` has no context, so `requestFocus` silently no-ops, which forced a
/// *jump-scroll → post-frame requestFocus → re-assert retry* pipeline that key
/// auto-repeat outran, that Flutter's geometry traversal leaked out of, and that
/// stale re-asserts fought. None of that exists any more: selecting row N is a
/// synchronous integer assignment that cannot fail or race.
///
/// **Movement rules** (the contract, deliberately asymmetric):
/// - **Down wraps** at the end of the channel list and of the category list —
///   this is the *only* infinite motion in the tab.
/// - **Up never wraps.** At the first row it *escapes upward*: categories → the
///   search box; channels → the preview controls (wide) or the search box
///   (phone). This is what makes the sidebar escapable — the old design wrapped
///   Up too, so the only ways out were Right or Back ("stuck in the categories").
/// - **Right** first enters the selected channel row's favorite star (the
///   intra-row [ChannelRowColumn]); **Left** peels the star column back to the
///   row body before crossing to the sidebar. Beyond that, Left/Right cross
///   between the panes; every arrow is consumed, so Flutter's geometry
///   traversal never runs inside the live body.
///
/// Route keys ([RoutedFocusNode.routeKey], read via [focusRouteKey]) still name
/// the regions for the Back ladder — they are release-safe, unlike `debugLabel`.
class LiveFocusCoordinator extends ChangeNotifier {
  /// The channel list's single D-pad node.
  static const channelsLabel = 'live.channels';

  /// The category sidebar's single D-pad node (wide layout only).
  static const categoriesLabel = 'live.categories';

  /// The search box's "OK to edit" cell.
  static const searchCellLabel = 'live.search.cell';

  /// The preview panel's Favorite / Catch-up controls.
  static const previewFavoriteLabel = 'live.preview.favorite';
  static const previewCatchupLabel = 'live.preview.catchup';

  LiveFocusCoordinator({
    required this.scrollController,
    required this.categoryScrollController,
    required this.visibleChannels,
    required this.orderedCategoryIds,
    required this.channelRowExtent,
    required this.categoryRowExtent,
    required this.isWide,
    required this.isMounted,
    required this.onChannelSelectionChanged,
    required this.onCategoryActivated,
    required this.onPlayChannel,
    required this.onToggleFavorite,
    required this.onFocusTabs,
  }) {
    // The cursor highlight is drawn from each list's `hasFocus`, and a focus
    // change rebuilds nothing on its own — so without this the highlight stayed
    // painted in the channel list after Left/Back moved the D-pad to the
    // categories, and the user couldn't see where they were. Notifying on focus
    // change re-renders the body so the cursor visibly hands over between panes.
    for (final node in [
      channelsFocusNode,
      categoriesFocusNode,
      previewFavoriteFocusNode,
      previewCatchupFocusNode,
      searchCellFocusNode,
    ]) {
      node.addListener(_notify);
    }
  }

  /// The channel list's scroll controller (owned by the screen).
  final ScrollController scrollController;

  /// The category sidebar's scroll controller (owned by the screen).
  final ScrollController categoryScrollController;

  /// The current filtered channel list (the screen's memoized `_visible`).
  final List<Channel> Function() visibleChannels;

  /// The sidebar in display order; index 0 is always `null` = "All channels".
  final List<String?> Function() orderedCategoryIds;

  /// Uniform row heights — the whole point of the model: index → offset is exact.
  final double Function() channelRowExtent;
  final double Function() categoryRowExtent;

  /// Wide (TV/desktop two-column) vs narrow (phone). Decides whether the
  /// category sidebar and preview controls exist at all.
  final bool Function() isWide;

  /// Whether the owning State is still mounted (guards post-frame work).
  final bool Function() isMounted;

  /// Selection-follow hook: the screen starts/stops previews and updates the
  /// info panel from this. `focused` is whether the channel region holds the
  /// D-pad (so a desktop auto-preview can be cancelled when it doesn't).
  final void Function(Channel channel, bool focused) onChannelSelectionChanged;

  /// OK on a category row — applies that filter synchronously. The coordinator
  /// then enters the newly filtered channel list when it is non-empty.
  final void Function(String? categoryId) onCategoryActivated;

  /// OK on a channel row's body column.
  final void Function(Channel channel) onPlayChannel;

  /// OK on the selected row's favorite column ([ChannelRowColumn.favorite]) —
  /// toggles that channel's favorite state in place.
  final void Function(Channel channel) onToggleFavorite;

  /// Escape hatch upward out of the live body (search → the content tabs).
  final VoidCallback onFocusTabs;

  final FocusNode channelsFocusNode = RoutedFocusNode(channelsLabel);
  final FocusNode categoriesFocusNode = RoutedFocusNode(categoriesLabel);
  final FocusNode searchCellFocusNode = RoutedFocusNode(searchCellLabel);
  final FocusNode previewFavoriteFocusNode = RoutedFocusNode(
    previewFavoriteLabel,
  );
  final FocusNode previewCatchupFocusNode = RoutedFocusNode(
    previewCatchupLabel,
  );

  /// The D-pad cursor into [visibleChannels].
  int get selectedChannelIndex => _selectedChannelIndex;
  int _selectedChannelIndex = 0;
  String? _selectedChannelId;

  /// The D-pad cursor into [orderedCategoryIds] (0 = "All channels").
  int get selectedCategoryIndex => _selectedCategoryIndex;
  int _selectedCategoryIndex = 0;

  /// The intra-row column the channel cursor sits on (body vs favorite star).
  ChannelRowColumn get channelColumn => _channelColumn;
  ChannelRowColumn _channelColumn = ChannelRowColumn.body;

  bool _disposed = false;

  /// Per-category memory of the row the user was on, so re-entering the channel
  /// pane resumes where they left instead of jumping to the top.
  final Map<String, String> _lastBrowsedByCategory = {};

  // ── Selection ──────────────────────────────────────────────────────────────

  /// The channel under the cursor, or null when the list is empty.
  Channel? get selectedChannel {
    final visible = visibleChannels();
    if (visible.isEmpty) return null;
    final index = _selectedChannelIndex.clamp(0, visible.length - 1);
    return visible[index];
  }

  String? get selectedChannelId => selectedChannel?.id;

  /// The category id under the cursor (null = "All channels").
  String? get selectedCategoryId {
    final ids = orderedCategoryIds();
    if (ids.isEmpty) return null;
    return ids[_selectedCategoryIndex.clamp(0, ids.length - 1)];
  }

  bool get onFirstChannel => _selectedChannelIndex == 0;
  bool get onFirstCategory => _selectedCategoryIndex == 0;

  /// Which region owns the D-pad right now (drives the Back ladder).
  LiveFocusRegion get region {
    if (channelsFocusNode.hasFocus) return LiveFocusRegion.channels;
    if (categoriesFocusNode.hasFocus) return LiveFocusRegion.categories;
    if (previewFavoriteFocusNode.hasFocus || previewCatchupFocusNode.hasFocus) {
      return LiveFocusRegion.previewControls;
    }
    if (searchCellFocusNode.hasFocus) return LiveFocusRegion.search;
    return LiveFocusRegion.none;
  }

  /// Reconcile the cursor after the visible list changes.
  ///
  /// Async refreshes can insert, remove, or reorder rows. Preserve the logical
  /// channel by id when it still exists rather than leaving the same numeric
  /// index pointed at an unrelated row. Explicit search/category changes call
  /// [resetChannelSelection] first, so those still intentionally start at the
  /// top of their new result set.
  void clampSelection() {
    final visible = visibleChannels();
    final rememberedIndex = _selectedChannelId == null
        ? -1
        : visible.indexWhere((channel) => channel.id == _selectedChannelId);
    final maxIndex = visible.isEmpty ? 0 : visible.length - 1;
    final channel = rememberedIndex >= 0
        ? rememberedIndex
        : _selectedChannelIndex.clamp(0, maxIndex);
    final ids = orderedCategoryIds();
    final maxCategory = ids.isEmpty ? 0 : ids.length - 1;
    final category = _selectedCategoryIndex.clamp(0, maxCategory);
    final channelId = visible.isEmpty ? null : visible[channel].id;
    if (channel == _selectedChannelIndex &&
        category == _selectedCategoryIndex &&
        channelId == _selectedChannelId) {
      return;
    }
    _selectedChannelIndex = channel;
    _selectedChannelId = channelId;
    _selectedCategoryIndex = category;
    _notify();
  }

  /// Put the channel cursor back at the top (a new filter/search starts fresh).
  void resetChannelSelection() {
    final visible = visibleChannels();
    final firstId = visible.isEmpty ? null : visible.first.id;
    if (_selectedChannelIndex == 0 && _selectedChannelId == firstId) return;
    _selectedChannelIndex = 0;
    _selectedChannelId = firstId;
    _notify();
  }

  /// Park the intra-row cursor back on the row body. No-op when already there.
  void resetChannelColumn() {
    if (_channelColumn == ChannelRowColumn.body) return;
    _channelColumn = ChannelRowColumn.body;
    _notify();
  }

  /// Move the channel cursor to [index] (clamped), reveal it, and tell the
  /// screen (preview-follow). Vertical motion always lands on the row *body* —
  /// the favorite column never travels with the cursor.
  void selectChannel(int index, {bool reveal = true}) {
    final visible = visibleChannels();
    if (visible.isEmpty) return;
    final next = index.clamp(0, visible.length - 1);
    final changed =
        next != _selectedChannelIndex ||
        visible[next].id != _selectedChannelId ||
        _channelColumn != ChannelRowColumn.body;
    _selectedChannelIndex = next;
    _selectedChannelId = visible[next].id;
    _channelColumn = ChannelRowColumn.body;
    _rememberBrowsed(visible[next].id);
    if (reveal) _revealChannel(next);
    if (changed) _notify();
    onChannelSelectionChanged(visible[next], channelsFocusNode.hasFocus);
  }

  /// Move the category cursor to [index] (clamped) and reveal it. This only
  /// moves the *highlight* — the filter changes on OK ([onCategoryActivated]).
  void selectCategory(int index, {bool reveal = true}) {
    final ids = orderedCategoryIds();
    if (ids.isEmpty) return;
    final next = index.clamp(0, ids.length - 1);
    if (next != _selectedCategoryIndex) {
      _selectedCategoryIndex = next;
      _notify();
    }
    if (reveal) _revealCategory(next);
  }

  /// Park the cursor on [channelId] (e.g. the channel we just came back from
  /// playing), else the first row.
  void restoreSelectionToChannel(String? channelId) {
    final visible = visibleChannels();
    if (visible.isEmpty) return;
    final index = channelId == null
        ? 0
        : visible.indexWhere((channel) => channel.id == channelId);
    selectChannel(index < 0 ? 0 : index);
    focusChannels();
  }

  /// Sync the category cursor to the *active* filter (e.g. after it's changed
  /// from the phone dropdown), without moving focus.
  void syncCategorySelection(String? categoryId) {
    final index = orderedCategoryIds().indexOf(categoryId);
    if (index < 0) return;
    selectCategory(index, reveal: false);
  }

  String _categoryKey(String? id) => id ?? '__all__';

  void _rememberBrowsed(String channelId) {
    _lastBrowsedByCategory[_categoryKey(selectedCategoryId)] = channelId;
  }

  // ── Scroll (exact, because rows are a uniform extent) ──────────────────────

  void _revealChannel(int index) =>
      _reveal(scrollController, index, channelRowExtent());

  void _revealCategory(int index) =>
      _reveal(categoryScrollController, index, categoryRowExtent());

  /// Scroll [controller] the minimum amount to bring row [index] fully into
  /// view. No focus involved, nothing to build first — pure arithmetic.
  void _reveal(ScrollController controller, int index, double extent) {
    if (!controller.hasClients || extent <= 0) return;
    final position = controller.position;
    final top = index * extent;
    final bottom = top + extent;
    final viewport = position.viewportDimension;
    double? target;
    if (top < position.pixels) {
      target = top;
    } else if (bottom > position.pixels + viewport) {
      target = bottom - viewport;
    }
    if (target == null) return;
    controller.animateTo(
      target.clamp(0.0, position.maxScrollExtent),
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOutCubic,
    );
  }

  // ── Region focus moves ─────────────────────────────────────────────────────

  void focusChannels() {
    final visible = visibleChannels();
    if (visible.isEmpty) return;
    // (Re)entering the pane always lands on the row body, never the star.
    resetChannelColumn();
    channelsFocusNode.requestFocus();
    _revealChannel(_selectedChannelIndex.clamp(0, visible.length - 1));
    onChannelSelectionChanged(
      visible[_selectedChannelIndex.clamp(0, visible.length - 1)],
      true,
    );
  }

  /// Enter the channel pane from the sidebar, resuming on the row the user last
  /// browsed in this category.
  void focusChannelsFromCategory() {
    final visible = visibleChannels();
    if (visible.isEmpty) return;
    final resumeId = _lastBrowsedByCategory[_categoryKey(selectedCategoryId)];
    final index = resumeId == null
        ? -1
        : visible.indexWhere((channel) => channel.id == resumeId);
    if (index >= 0) _selectedChannelIndex = index;
    _notify();
    focusChannels();
  }

  void focusCategories() {
    if (!isWide()) return;
    categoriesFocusNode.requestFocus();
    _revealCategory(_selectedCategoryIndex);
  }

  void focusSearch() => searchCellFocusNode.requestFocus();

  /// The preview panel's controls, when they exist (wide layout).
  bool focusPreviewControls() {
    if (previewFavoriteFocusNode.context == null) return false;
    previewFavoriteFocusNode.requestFocus();
    return true;
  }

  /// Up out of the top of the channel list: the preview controls if they're
  /// there (wide), else straight to the search box (phone). Never wraps.
  void escapeUpFromChannels() {
    if (focusPreviewControls()) return;
    focusSearch();
  }

  // ── Key handling ───────────────────────────────────────────────────────────

  static bool _isActivate(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.select ||
      key == LogicalKeyboardKey.enter ||
      key == LogicalKeyboardKey.numpadEnter ||
      key == LogicalKeyboardKey.gameButtonA ||
      key == LogicalKeyboardKey.space;

  static bool _isPress(KeyEvent event) =>
      event is KeyDownEvent || event is KeyRepeatEvent;

  /// The channel list owns the D-pad while it has focus.
  KeyEventResult handleChannelsKey(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    final visible = visibleChannels();
    if (visible.isEmpty) return KeyEventResult.ignored;

    if (_handleDigit(event)) return KeyEventResult.handled;

    if (key == LogicalKeyboardKey.arrowDown) {
      if (!_isPress(event)) return KeyEventResult.handled;
      // The one infinite motion: Down wraps past the last row to the first.
      selectChannel((_selectedChannelIndex + 1) % visible.length);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      if (!_isPress(event)) return KeyEventResult.handled;
      if (_selectedChannelIndex == 0) {
        // Never wrap upward — climb out of the list instead. Leaving the pane
        // parks the intra-row cursor back on the body.
        resetChannelColumn();
        escapeUpFromChannels();
      } else {
        selectChannel(_selectedChannelIndex - 1);
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      if (!_isPress(event)) return KeyEventResult.handled;
      // Left peels the intra-row cursor off the favorite star first; only a
      // second Left crosses into the sidebar.
      if (_channelColumn == ChannelRowColumn.favorite) {
        resetChannelColumn();
        return KeyEventResult.handled;
      }
      if (isWide()) focusCategories();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      if (!_isPress(event)) return KeyEventResult.handled;
      // Right enters the row's favorite star; always consumed (already on the
      // star, or an empty list) so geometry traversal never runs.
      if (_channelColumn == ChannelRowColumn.body && selectedChannel != null) {
        _channelColumn = ChannelRowColumn.favorite;
        _notify();
      }
      return KeyEventResult.handled;
    }

    if (_isActivate(key)) return _handleChannelActivate(event);
    return KeyEventResult.ignored;
  }

  /// OK on the selected channel row: the body column plays, the favorite
  /// column toggles. Acts on key-down only — repeats and key-up are swallowed
  /// so a held OK can't re-trigger.
  KeyEventResult _handleChannelActivate(KeyEvent event) {
    final channel = selectedChannel;
    if (channel == null) return KeyEventResult.ignored;
    if (event is KeyDownEvent) {
      if (_channelColumn == ChannelRowColumn.favorite) {
        onToggleFavorite(channel);
      } else {
        onPlayChannel(channel);
      }
    }
    return KeyEventResult.handled;
  }

  /// The category sidebar owns the D-pad while it has focus.
  KeyEventResult handleCategoriesKey(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    final ids = orderedCategoryIds();
    if (ids.isEmpty) return KeyEventResult.ignored;

    if (key == LogicalKeyboardKey.arrowDown) {
      if (!_isPress(event)) return KeyEventResult.handled;
      selectCategory((_selectedCategoryIndex + 1) % ids.length); // wraps
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      if (!_isPress(event)) return KeyEventResult.handled;
      if (_selectedCategoryIndex == 0) {
        // The fix for "stuck in the categories": Up at the top escapes to the
        // search box rather than wrapping back to the bottom.
        focusSearch();
      } else {
        selectCategory(_selectedCategoryIndex - 1);
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      if (!_isPress(event)) return KeyEventResult.handled;
      focusChannelsFromCategory();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      return KeyEventResult.handled; // consumed: nothing to the left
    }
    if (_isActivate(key)) {
      if (event is KeyDownEvent) {
        onCategoryActivated(selectedCategoryId);
        // Category activation updates the screen's filter synchronously, so
        // visibleChannels() now represents the selected category. Enter that
        // result immediately instead of leaving the user in the sidebar and
        // requiring a separate Right press. Empty categories deliberately keep
        // focus here so the D-pad is not moved onto a list with no target.
        focusChannelsFromCategory();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// The preview panel's Favorite / Catch-up controls sit between the search box
  /// and the channel list.
  KeyEventResult handlePreviewControlKey(bool fromCatchup, KeyEvent event) {
    final key = event.logicalKey;
    final isArrow =
        key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight;
    if (!isArrow) return KeyEventResult.ignored;
    if (!_isPress(event)) return KeyEventResult.handled;

    if (key == LogicalKeyboardKey.arrowDown) {
      focusChannels();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      focusSearch();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      if (!fromCatchup && previewCatchupFocusNode.context != null) {
        previewCatchupFocusNode.requestFocus();
      } else {
        focusCategories();
      }
      return KeyEventResult.handled;
    }
    // arrowRight
    if (fromCatchup && previewFavoriteFocusNode.context != null) {
      previewFavoriteFocusNode.requestFocus();
    }
    return KeyEventResult.handled;
  }

  /// Search box: Down drops into the channel list, Up climbs to the content tabs.
  KeyEventResult handleSearchCellKey(FocusNode node, KeyEvent event) {
    if (!searchCellFocusNode.hasFocus) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown) {
      if (!_isPress(event)) return KeyEventResult.handled;
      focusChannels();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      if (!_isPress(event)) return KeyEventResult.handled;
      onFocusTabs();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // ── Digit-entry channel jump ───────────────────────────────────────────────

  String get digitBuffer => _digitBuffer;
  String _digitBuffer = '';
  Timer? _digitTimer;
  static const _digitCommitDelay = Duration(milliseconds: 1500);
  static const _maxDigits = 4;

  // LogicalKeyboardKey overrides == and can't key a const map.
  static final Map<LogicalKeyboardKey, int> _digitKeys = {
    LogicalKeyboardKey.digit0: 0,
    LogicalKeyboardKey.digit1: 1,
    LogicalKeyboardKey.digit2: 2,
    LogicalKeyboardKey.digit3: 3,
    LogicalKeyboardKey.digit4: 4,
    LogicalKeyboardKey.digit5: 5,
    LogicalKeyboardKey.digit6: 6,
    LogicalKeyboardKey.digit7: 7,
    LogicalKeyboardKey.digit8: 8,
    LogicalKeyboardKey.digit9: 9,
    LogicalKeyboardKey.numpad0: 0,
    LogicalKeyboardKey.numpad1: 1,
    LogicalKeyboardKey.numpad2: 2,
    LogicalKeyboardKey.numpad3: 3,
    LogicalKeyboardKey.numpad4: 4,
    LogicalKeyboardKey.numpad5: 5,
    LogicalKeyboardKey.numpad6: 6,
    LogicalKeyboardKey.numpad7: 7,
    LogicalKeyboardKey.numpad8: 8,
    LogicalKeyboardKey.numpad9: 9,
  };

  /// Digits typed on the remote jump to a channel number. Only live while the
  /// channel list holds the D-pad, so a search field never loses its digits.
  bool _handleDigit(KeyEvent event) {
    final digit = _digitKeys[event.logicalKey];
    if (digit == null) return false;
    if (event is KeyDownEvent) appendDigit(digit);
    return true; // swallow repeats/ups too, so a held digit can't leak into nav
  }

  void appendDigit(int digit) {
    if (_digitBuffer.length >= _maxDigits) return;
    _digitBuffer += '$digit';
    _digitTimer?.cancel();
    _digitTimer = Timer(_digitCommitDelay, commitDigitBuffer);
    _notify();
  }

  /// Jump the cursor to the visible channel whose [Channel.number] matches.
  void commitDigitBuffer() {
    final number = int.tryParse(_digitBuffer);
    clearDigitBuffer();
    if (number == null) return;
    final index = visibleChannels().indexWhere(
      (channel) => channel.number == number,
    );
    if (index < 0) return;
    selectChannel(index);
    focusChannels();
  }

  void clearDigitBuffer() {
    _digitTimer?.cancel();
    _digitTimer = null;
    if (_digitBuffer.isEmpty) return;
    _digitBuffer = '';
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _digitTimer?.cancel();
    channelsFocusNode.dispose();
    categoriesFocusNode.dispose();
    searchCellFocusNode.dispose();
    previewFavoriteFocusNode.dispose();
    previewCatchupFocusNode.dispose();
    super.dispose();
  }
}
