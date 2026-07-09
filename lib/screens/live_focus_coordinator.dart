import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show KeyDownEvent, KeyEvent, KeyRepeatEvent, KeyUpEvent, LogicalKeyboardKey;

import '../sources/source.dart';
import '../widgets/routed_focus_node.dart';

/// Which live pane last held focus — used to route arrow keys when focus
/// transiently lands on an unlabeled node.
enum LiveFocusArea { category, channels, search, unknown }

/// Owns the live tab's D-pad focus machinery: the channel/category focus
/// nodes (created lazily, pruned to the visible set), the category↔channel
/// pane routing, the down-hold lock, and the per-category "resume on the
/// channel you left" bookkeeping. Extracted from `ChannelListScreen`'s State
/// so the routing logic has one home and its label-based dispatch is
/// unit-testable.
///
/// A [ChangeNotifier]: notifies when [lastFocusedChannelId] changes, so the
/// preview/info panel that follows focus can rebuild through the screen's
/// body listenable instead of a whole-screen setState.
///
/// Routing is keyed off [RoutedFocusNode.routeKey] prefixes (the constants
/// below), read via [focusRouteKey]. They are **load-bearing routing keys**,
/// not debug decoration — every focusable the live tab creates must use a
/// [RoutedFocusNode] carrying one. (They were once read from
/// [FocusNode.debugLabel], but that is `null` in release builds, which broke
/// the whole ladder on real hardware.)
class LiveFocusCoordinator extends ChangeNotifier {
  /// Prefix for per-channel focus nodes: `live.channel.<channelId>`.
  static const channelLabelPrefix = 'live.channel.';

  /// Prefix for category-pane nodes: `live.category.<categoryId|all>`.
  static const categoryLabelPrefix = 'live.category.';

  /// The search box's "OK to edit" cell.
  static const searchCellLabel = 'live.search.cell';

  /// The stable node for the first visible channel row (gets `autofocus`).
  static const firstChannelLabel = '${channelLabelPrefix}first';

  /// The preview panel's Favorite control (top of the channel column).
  static const previewFavoriteLabel = 'live.preview.favorite';

  /// The preview panel's Catch-up control (shown only for archive channels).
  static const previewCatchupLabel = 'live.preview.catchup';

  /// The route key of an unrouted node (plain `Focus`/`FocusScope`) — the empty
  /// string, since [focusRouteKey] returns `''` for anything but a
  /// [RoutedFocusNode]. Such focus is routed via [lastFocusArea].
  static const unlabeledLabel = '';

  /// Estimated height of one channel row, for jump-scrolling an off-screen
  /// target into build range before focusing it.
  static const _estimatedChannelRowExtent = 104.0;

  /// Estimated height of one category row in the sidebar, for the same
  /// jump-scroll-into-build-range trick as channels.
  static const _estimatedCategoryRowExtent = 48.0;

  LiveFocusCoordinator({
    required this.scrollController,
    required this.categoryScrollController,
    required this.visibleChannels,
    required this.categoryId,
    required this.orderedCategoryIds,
    required this.channelById,
    required this.isLiveTab,
    required this.isRouteCurrent,
    required this.isMounted,
    required this.onChannelFocusChanged,
  }) {
    firstChannelFocusNode.addListener(() {
      final visible = visibleChannels();
      if (visible.isEmpty) return;
      if (firstChannelFocusNode.hasFocus) noteFocusedChannel(visible.first.id);
      onChannelFocusChanged(visible.first, firstChannelFocusNode.hasFocus);
    });
  }

  /// The live list's scroll controller (owned by the screen).
  final ScrollController scrollController;

  /// The category sidebar's scroll controller (owned by the screen), so an
  /// off-screen category can be jump-scrolled into build range before it's
  /// focused — otherwise `requestFocus` on an unbuilt node silently no-ops.
  final ScrollController categoryScrollController;

  /// Current filtered channel list (the screen's memoized `_visible`).
  final List<Channel> Function() visibleChannels;

  /// Currently selected live category id (null = All).
  final String? Function() categoryId;

  /// The category sidebar in display order (null = "All channels"), for
  /// index-based Up/Down navigation with wrap.
  final List<String?> Function() orderedCategoryIds;

  /// Channel lookup across the *full* (unfiltered) channel list.
  final Channel? Function(String id) channelById;

  /// Whether the live tab is the active content tab.
  final bool Function() isLiveTab;

  /// Whether the screen's route is on top. [handleGlobalKeyEvent] is
  /// registered on [HardwareKeyboard] for the screen's whole lifetime, so
  /// without this guard it would keep intercepting arrow keys behind any
  /// pushed route (player, sources, diagnostics) whose focus nodes happen to
  /// be unlabeled.
  final bool Function() isRouteCurrent;

  /// Whether the owning State is still mounted (guards post-frame work).
  final bool Function() isMounted;

  /// Focus-follow hook: the screen starts/stops previews and updates the info
  /// panel from this. Called with the channel and whether it gained focus.
  final void Function(Channel channel, bool hasFocus) onChannelFocusChanged;

  final FocusNode firstChannelFocusNode = RoutedFocusNode(firstChannelLabel);
  final FocusNode searchCellFocusNode = RoutedFocusNode(searchCellLabel);

  /// The preview panel's Favorite / Catch-up controls — the top of the channel
  /// column, reached by ArrowUp from the first channel (wide layout only).
  final FocusNode previewFavoriteFocusNode = RoutedFocusNode(
    previewFavoriteLabel,
  );
  final FocusNode previewCatchupFocusNode = RoutedFocusNode(
    previewCatchupLabel,
  );

  final Map<String, FocusNode> _channelNodes = {};
  final Map<String, FocusNode> _categoryNodes = {};
  bool _pruneScheduled = false;
  bool _disposed = false;

  /// Last channel that held focus in the list (drives the TV info panel).
  String? get lastFocusedChannelId => _lastFocusedChannelId;
  String? _lastFocusedChannelId;

  /// Last category that held focus in the sidebar, so returning from the
  /// channel pane lands where the user was — not always the selected one.
  String? get lastFocusedCategoryId => _lastFocusedCategoryId;
  String? _lastFocusedCategoryId;

  LiveFocusArea lastFocusArea = LiveFocusArea.unknown;

  /// Vertical-hold lock: once a Up/Down hold starts in a pane, a *held* key
  /// whose repeats land mid-scroll (focus transiently detached during a wrap
  /// jump-scroll) keeps walking the *same* pane in the *same* direction until
  /// key-up, so it can't leak into the neighbouring pane. [_heldArea] is the
  /// locked pane (channels/category), [_heldForward] its direction (Down/next).
  LiveFocusArea? _heldArea;
  bool _heldForward = false;

  /// Per-category memory of the channel the user was on, so re-entering the
  /// channel pane resumes there instead of at the top.
  final Map<String, String> _lastBrowsedByCategory = {};

  /// Digits typed on the remote while browsing live — committed to a
  /// channel-number jump after [_digitCommitDelay] (or OK). Non-empty means
  /// the screen shows the entry chip. Notifies on every change.
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

  static int? _digitFor(LogicalKeyboardKey key) => _digitKeys[key];

  /// Digit-entry channel jump. Returns true when the event was consumed.
  /// Only active while focus sits in one of the live panes ([area] known) —
  /// never while a text field is editing (that focus is `TvTextField.field`,
  /// which classifies as unknown, so typed digits reach the editor).
  bool _handleDigitKey(KeyEvent event, LiveFocusArea area) {
    if (event is! KeyDownEvent) {
      // Swallow digit-key repeats so a held digit doesn't leak into nav.
      return event is KeyRepeatEvent &&
          area != LiveFocusArea.unknown &&
          _digitFor(event.logicalKey) != null;
    }
    final key = event.logicalKey;
    final digit = _digitFor(key);
    if (digit != null) {
      if (area == LiveFocusArea.unknown) return false;
      appendDigit(digit);
      return true;
    }
    if (_digitBuffer.isEmpty) return false;
    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      commitDigitBuffer();
      return true;
    }
    if (key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.goBack) {
      clearDigitBuffer();
      return true;
    }
    return false;
  }

  /// Append a typed digit and (re)arm the auto-commit timer.
  void appendDigit(int digit) {
    if (_digitBuffer.length >= _maxDigits) return;
    _digitBuffer += '$digit';
    _digitTimer?.cancel();
    _digitTimer = Timer(_digitCommitDelay, commitDigitBuffer);
    if (!_disposed) notifyListeners();
  }

  /// Jump to the visible channel whose [Channel.number] matches the buffer.
  void commitDigitBuffer() {
    final number = int.tryParse(_digitBuffer);
    clearDigitBuffer();
    if (number == null) return;
    final visible = visibleChannels();
    final index = visible.indexWhere((channel) => channel.number == number);
    if (index < 0) return;
    noteFocusedChannel(visible[index].id);
    _focusChannelByIndex(visible, index);
    lastFocusArea = LiveFocusArea.channels;
  }

  void clearDigitBuffer() {
    _digitTimer?.cancel();
    _digitTimer = null;
    if (_digitBuffer.isEmpty) return;
    _digitBuffer = '';
    if (!_disposed) notifyListeners();
  }

  void noteFocusedChannel(String id) {
    if (_lastFocusedChannelId == id) return;
    _lastFocusedChannelId = id;
    if (!_disposed) notifyListeners();
  }

  /// Record [area] as the last known pane (used by the screen's Back-peel).
  void noteFocusArea(LiveFocusArea area) => lastFocusArea = area;

  String _categoryKey(String? id) => id ?? '__live.channels__';

  /// Remember [channelId] as where the user left the current category.
  void rememberBrowsedChannel(String channelId) {
    _lastBrowsedByCategory[_categoryKey(categoryId())] = channelId;
  }

  FocusNode focusNodeForChannel(String channelId) {
    return _channelNodes.putIfAbsent(channelId, () {
      final node = RoutedFocusNode('$channelLabelPrefix$channelId');
      node.addListener(() {
        final channel = channelById(channelId);
        if (channel == null) return;
        if (node.hasFocus) noteFocusedChannel(channelId);
        onChannelFocusChanged(channel, node.hasFocus);
      });
      return node;
    });
  }

  FocusNode focusNodeForCategory(String? categoryId) {
    final key = categoryId ?? 'all';
    return _categoryNodes.putIfAbsent(key, () {
      final node = RoutedFocusNode('$categoryLabelPrefix$key');
      node.addListener(() {
        if (node.hasFocus) _lastFocusedCategoryId = categoryId;
      });
      return node;
    });
  }

  /// The category id encoded in a `live.category.<key>` label (null for
  /// `all`), or null for a non-category label.
  String? categoryIdFromFocusLabel(String label) {
    if (!label.startsWith(categoryLabelPrefix)) return null;
    final key = label.substring(categoryLabelPrefix.length);
    return key == 'all' ? null : key;
  }

  /// Per-channel [FocusNode]s are created lazily as rows scroll into view.
  /// Left unbounded they'd accumulate the union of every channel browsed this
  /// session (thousands, on a large playlist). Prune back to the current
  /// working set — the filtered visible list — whenever that set changes.
  /// Runs post-frame so we never dispose a node still attached to a live
  /// widget, and never disposes the focused node.
  void scheduleFocusNodePrune() {
    if (_pruneScheduled) return;
    _pruneScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pruneScheduled = false;
      if (_disposed || !isMounted()) return;
      final keep = visibleChannels().map((c) => c.id).toSet();
      _channelNodes.removeWhere((id, node) {
        if (keep.contains(id) || node.hasFocus) return false;
        node.dispose();
        return true;
      });
    });
  }

  /// Move focus into the channel pane, resuming on the channel the user last
  /// browsed in this category (jump-scrolled into range if needed).
  void focusChannelsFromCategory() {
    final visible = visibleChannels();
    if (visible.isEmpty) return;
    final resumeId = _lastBrowsedByCategory[_categoryKey(categoryId())];
    final hasResume =
        resumeId != null && visible.any((channel) => channel.id == resumeId);
    final resumeIndex = hasResume
        ? visible.indexWhere((channel) => channel.id == resumeId)
        : -1;
    if (hasResume && resumeIndex > 0 && scrollController.hasClients) {
      final targetOffset = resumeIndex * _estimatedChannelRowExtent;
      final maxOffset = scrollController.position.maxScrollExtent;
      scrollController.jumpTo(targetOffset.clamp(0, maxOffset));
    }
    final FocusNode targetNode = hasResume && visible.first.id != resumeId
        ? focusNodeForChannel(resumeId)
        : firstChannelFocusNode;
    targetNode.requestFocus();
    _reassertFocus(
      targetNode,
      shouldRetry: (label) =>
          label.startsWith(categoryLabelPrefix) || label == unlabeledLabel,
      attempts: 4,
    );
    _reassertFocus(
      firstChannelFocusNode,
      shouldRetry: (label) =>
          label.startsWith(categoryLabelPrefix) || label == unlabeledLabel,
      attempts: 6,
    );
    lastFocusArea = LiveFocusArea.channels;
  }

  /// Land focus on [categoryId]'s pane node, scrolled into build range first
  /// (an off-screen sidebar node has a null context, so a bare `requestFocus`
  /// would no-op), then retrying across a few frames so a fresh-selection
  /// rebuild/autofocus race (the channel list's first-row autofocus + the
  /// scroll-to-top) can't strand focus on the channel list or an unlabeled
  /// node — which would leave the root Back ladder unable to tell where it is.
  void focusCategory(String? categoryId) {
    final ids = orderedCategoryIds();
    final index = ids.indexOf(categoryId);
    if (index >= 0) {
      _focusCategoryByIndex(ids, index);
    } else {
      focusNodeForCategory(categoryId).requestFocus();
      lastFocusArea = LiveFocusArea.category;
    }
    _reassertFocus(
      focusNodeForCategory(categoryId),
      shouldRetry: (label) =>
          label.startsWith(channelLabelPrefix) || label == unlabeledLabel,
      attempts: 6,
    );
    _lastFocusedCategoryId = categoryId;
  }

  /// Move focus from the channel pane back to the category the user last had
  /// (falling back to the selected one) — scrolled into range so it always
  /// lands, even from a long, scrolled sidebar.
  void focusCategoryFromChannels() {
    _heldArea = null;
    final targetId = _lastFocusedCategoryId ?? categoryId();
    final ids = orderedCategoryIds();
    final index = ids.indexOf(targetId);
    if (index >= 0) {
      _focusCategoryByIndex(ids, index);
    } else {
      focusNodeForCategory(targetId).requestFocus();
      lastFocusArea = LiveFocusArea.category;
    }
    _reassertFocus(
      focusNodeForCategory(targetId),
      shouldRetry: (label) =>
          label.startsWith(channelLabelPrefix) || label == unlabeledLabel,
      attempts: 4,
    );
  }

  /// Focus the category at [index] in [ids], jump-scrolling the sidebar to
  /// build the row first when it's off-screen (mirrors [_focusChannelByIndex]).
  void _focusCategoryByIndex(List<String?> ids, int index) {
    if (ids.isEmpty) return;
    final clamped = index.clamp(0, ids.length - 1);
    final targetId = ids[clamped];
    final node = focusNodeForCategory(targetId);
    _lastFocusedCategoryId = targetId;
    lastFocusArea = LiveFocusArea.category;
    final targetLabel = '$categoryLabelPrefix${targetId ?? 'all'}';

    // Is the target row painted within the viewport (not merely built in the
    // cache extent)? A built-but-cached (off-screen) node can't take focus via a
    // bare requestFocus — it must be scrolled into the visible range first. A
    // non-scrolling sidebar (everything fits) is always on-screen.
    bool onScreen() {
      if (node.context == null || !categoryScrollController.hasClients) {
        return false;
      }
      final pos = categoryScrollController.position;
      if (pos.maxScrollExtent <= 0) return true;
      final top = clamped * _estimatedCategoryRowExtent;
      return top >= pos.pixels &&
          top + _estimatedCategoryRowExtent <= pos.pixels + pos.viewportDimension;
    }

    if (!onScreen() && categoryScrollController.hasClients) {
      // Jump the target roughly to the viewport centre (so the card's own
      // scroll-on-focus doesn't then re-animate it), then focus post-frame —
      // re-requesting the next frame, plus the reassert, so it lands once the
      // jumped-to row has actually built.
      final pos = categoryScrollController.position;
      final centered =
          (clamped * _estimatedCategoryRowExtent -
                  (pos.viewportDimension - _estimatedCategoryRowExtent) / 2)
              .clamp(0.0, pos.maxScrollExtent);
      categoryScrollController.jumpTo(centered);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_disposed || !isMounted()) return;
        node.requestFocus();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_disposed || !isMounted()) return;
          node.requestFocus();
        });
      });
      _reassertFocus(
        node,
        shouldRetry: (label) => label != targetLabel,
        attempts: 4,
      );
      return;
    }
    node.requestFocus();
    _reassertFocus(
      node,
      shouldRetry: (label) => label != targetLabel,
      attempts: 4,
    );
  }

  /// Move focus one category down, wrapping past the last back to the first.
  void moveDownInCategories(String? currentId) {
    final ids = orderedCategoryIds();
    if (ids.isEmpty) return;
    final i = ids.indexOf(currentId);
    if (i < 0) return;
    _focusCategoryByIndex(ids, (i + 1) % ids.length);
  }

  /// Move focus one category up, wrapping past the first back to the last.
  void moveUpInCategories(String? currentId) {
    final ids = orderedCategoryIds();
    if (ids.isEmpty) return;
    final i = ids.indexOf(currentId);
    if (i < 0) return;
    _focusCategoryByIndex(ids, (i - 1 + ids.length) % ids.length);
  }

  /// Key handler for a category sidebar card. Right → channels; Up/Down cycle
  /// within the category list (wrapping) and are consumed so directional
  /// traversal can't spill focus into the channel pane. Returns [KeyEventResult]
  /// for the card's `onKeyEvent`.
  KeyEventResult handleCategoryCardKey(String? categoryId, KeyEvent event) {
    final key = event.logicalKey;
    final isVertical =
        key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown;
    if (key != LogicalKeyboardKey.arrowRight && !isVertical) {
      return KeyEventResult.ignored;
    }
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      focusChannelsFromCategory();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      moveDownInCategories(categoryId);
    } else {
      moveUpInCategories(categoryId);
    }
    return KeyEventResult.handled;
  }

  /// Move focus to the preview panel controls (the top of the channel column).
  /// When they aren't attached (narrow/phone layout, or a wide frame before the
  /// preview panel builds), wrap to the last channel instead.
  void focusPreviewControls() {
    if (previewFavoriteFocusNode.context != null) {
      previewFavoriteFocusNode.requestFocus();
      lastFocusArea = LiveFocusArea.unknown;
      return;
    }
    _focusLastChannel();
  }

  /// Focus the last visible channel (used by the Up-wrap from the preview
  /// controls), jump-scrolling it into range if needed.
  void _focusLastChannel() {
    final visible = visibleChannels();
    if (visible.isEmpty) return;
    noteFocusedChannel(visible.last.id);
    _focusChannelByIndex(visible, visible.length - 1);
    lastFocusArea = LiveFocusArea.channels;
  }

  /// Key handler for a preview control (Favorite / Catch-up). Down → first
  /// channel; Up → wrap to the last channel; Left → the sibling control or the
  /// category pane; Right → the sibling control. [fromCatchup] tells which
  /// control fired. Contained so focus can't leak out of the live column.
  KeyEventResult handlePreviewControlKey(bool fromCatchup, KeyEvent event) {
    final key = event.logicalKey;
    final isNav =
        key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight;
    if (!isNav) return KeyEventResult.ignored;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      focusFirstChannel();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _focusLastChannel();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      if (!fromCatchup && previewCatchupFocusNode.context != null) {
        previewCatchupFocusNode.requestFocus();
      } else {
        focusCategoryFromChannels();
      }
      return KeyEventResult.handled;
    }
    // arrowRight
    if (fromCatchup && previewFavoriteFocusNode.context != null) {
      previewFavoriteFocusNode.requestFocus();
    }
    return KeyEventResult.handled;
  }

  void _focusChannelByIndex(List<Channel> visible, int index) {
    if (visible.isEmpty) return;
    final clamped = index.clamp(0, visible.length - 1);
    if (clamped == 0) {
      firstChannelFocusNode.requestFocus();
      return;
    }
    final node = focusNodeForChannel(visible[clamped].id);
    if (node.context == null && scrollController.hasClients) {
      // The target row isn't built — jump-scroll it into range, then focus
      // post-frame (with one nudge retry if the estimate fell short).
      final maxOffset = scrollController.position.maxScrollExtent;
      final targetOffset = (clamped * _estimatedChannelRowExtent)
          .clamp(0, maxOffset)
          .toDouble();
      scrollController.jumpTo(targetOffset);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_disposed || !isMounted()) return;
        if (node.context != null) {
          node.requestFocus();
          return;
        }
        if (scrollController.hasClients) {
          final nudged =
              (scrollController.position.pixels + _estimatedChannelRowExtent)
                  .clamp(0, scrollController.position.maxScrollExtent)
                  .toDouble();
          scrollController.jumpTo(nudged);
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_disposed || !isMounted()) return;
          node.requestFocus();
        });
      });
      return;
    }
    node.requestFocus();
  }

  /// True when the channel list is scrolled more than one viewport deep —
  /// the threshold for the "first Back returns to the top of the list" rung.
  bool get channelListIsDeep =>
      scrollController.hasClients &&
      scrollController.position.pixels >
          scrollController.position.viewportDimension;

  /// Jump the list to the top and focus the first visible channel (used by
  /// the down-wrap and the Back-to-top rung). The first row may not be built
  /// yet right after the jump, hence the post-frame focus with one retry.
  void focusFirstChannel() {
    final visible = visibleChannels();
    if (visible.isEmpty) return;
    noteFocusedChannel(visible.first.id);
    if (scrollController.hasClients) {
      scrollController.jumpTo(0);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed || !isMounted()) return;
      if (firstChannelFocusNode.context != null) {
        firstChannelFocusNode.requestFocus();
        return;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_disposed || !isMounted()) return;
        firstChannelFocusNode.requestFocus();
      });
    });
    lastFocusArea = LiveFocusArea.channels;
  }

  /// Move focus one row down from [channelId], wrapping to the top.
  void moveDownInChannels(String channelId) {
    final visible = visibleChannels();
    if (visible.isEmpty) return;
    final currentIndex = visible.indexWhere(
      (channel) => channel.id == channelId,
    );
    if (currentIndex < 0) return;
    final nextIndex = (currentIndex + 1) % visible.length;
    if (nextIndex == 0) {
      focusFirstChannel();
      return;
    }
    noteFocusedChannel(visible[nextIndex].id);
    _focusChannelByIndex(visible, nextIndex);
  }

  /// Move focus one row up from [channelId]. From the first row it goes to the
  /// preview panel controls (the top of the channel column) — or, when those
  /// aren't present (narrow layout), wraps to the last row.
  void moveUpInChannels(String channelId) {
    final visible = visibleChannels();
    if (visible.isEmpty) return;
    final currentIndex = visible.indexWhere(
      (channel) => channel.id == channelId,
    );
    if (currentIndex < 0) return;
    if (currentIndex == 0) {
      focusPreviewControls();
      return;
    }
    final prevIndex = currentIndex - 1;
    noteFocusedChannel(visible[prevIndex].id);
    _focusChannelByIndex(visible, prevIndex);
  }

  /// Restore focus to [targetId] (e.g. the last-played channel) if visible,
  /// else the first row. No-op when the list is empty.
  void restoreFocusToChannel(String? targetId) {
    final visible = visibleChannels();
    if (visible.isEmpty) return;
    final hasTarget =
        targetId != null && visible.any((channel) => channel.id == targetId);
    if (hasTarget && visible.first.id != targetId) {
      focusNodeForChannel(targetId).requestFocus();
    } else {
      firstChannelFocusNode.requestFocus();
    }
  }

  /// The channel id encoded in a focus [label], or null for non-channel
  /// labels. `live.channel.first` maps to the first visible channel.
  String? channelIdFromFocusLabel(String label) {
    if (label == firstChannelLabel) {
      final visible = visibleChannels();
      return visible.isEmpty ? null : visible.first.id;
    }
    if (!label.startsWith(channelLabelPrefix)) return null;
    final id = label.substring(channelLabelPrefix.length);
    if (id.isEmpty || id == 'first') return null;
    return id;
  }

  /// Which pane a focus [label] belongs to.
  LiveFocusArea focusAreaFromLabel(String label) {
    if (label.startsWith(categoryLabelPrefix)) return LiveFocusArea.category;
    if (label.startsWith(channelLabelPrefix)) return LiveFocusArea.channels;
    if (label == searchCellLabel) return LiveFocusArea.search;
    return LiveFocusArea.unknown;
  }

  /// A focus request racing a rebuild can be stolen by the old pane's node —
  /// re-request for a few frames while focus still reads as the wrong side.
  void _reassertFocus(
    FocusNode targetNode, {
    required bool Function(String label) shouldRetry,
    int attempts = 3,
  }) {
    if (attempts <= 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed || !isMounted()) return;
      final label = focusRouteKey(FocusManager.instance.primaryFocus);
      if (!shouldRetry(label)) return;
      targetNode.requestFocus();
      _reassertFocus(
        targetNode,
        shouldRetry: shouldRetry,
        attempts: attempts - 1,
      );
    });
  }

  /// Global (HardwareKeyboard) handler: category→channels on Right, and the
  /// down-hold lock that keeps a held Down key walking the channel list.
  /// Registered by the screen for its lifetime.
  bool handleGlobalKeyEvent(KeyEvent event) {
    if (!isLiveTab() || !isRouteCurrent()) return false;
    final key = event.logicalKey;
    final isVertical =
        key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown;
    if (isVertical && event is KeyUpEvent) {
      _heldArea = null;
      return false;
    }
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
    if (!isVertical) _heldArea = null;

    final label = focusRouteKey(FocusManager.instance.primaryFocus);
    if (_handleDigitKey(event, focusAreaFromLabel(label))) return true;
    if (key == LogicalKeyboardKey.arrowRight &&
        label.startsWith(categoryLabelPrefix)) {
      focusChannelsFromCategory();
      return true;
    }
    if (!isVertical) return false;
    // Preview controls run their own contained Up/Down handler — don't let the
    // held-continuation logic below fight it.
    if (label == previewFavoriteLabel || label == previewCatchupLabel) {
      _heldArea = null;
      return false;
    }

    final forward = key == LogicalKeyboardKey.arrowDown;
    // Attached on a channel row.
    final channelId = channelIdFromFocusLabel(label);
    if (channelId != null) {
      _heldArea = LiveFocusArea.channels;
      _heldForward = forward;
      noteFocusedChannel(channelId);
      forward ? moveDownInChannels(channelId) : moveUpInChannels(channelId);
      return true;
    }
    // Attached on a category row.
    if (label.startsWith(categoryLabelPrefix)) {
      final catId = categoryIdFromFocusLabel(label);
      _heldArea = LiveFocusArea.category;
      _heldForward = forward;
      forward ? moveDownInCategories(catId) : moveUpInCategories(catId);
      return true;
    }
    // Detached mid-scroll but a hold is in progress: keep walking the same pane
    // in the same direction so a held key can't leak into the neighbour pane.
    if (_heldArea == LiveFocusArea.channels) {
      final visible = visibleChannels();
      if (visible.isEmpty) return true;
      final fallbackId = _lastFocusedChannelId ?? visible.first.id;
      _heldForward
          ? moveDownInChannels(fallbackId)
          : moveUpInChannels(fallbackId);
      return true;
    }
    if (_heldArea == LiveFocusArea.category) {
      _heldForward
          ? moveDownInCategories(_lastFocusedCategoryId)
          : moveUpInCategories(_lastFocusedCategoryId);
      return true;
    }
    return false;
  }

  /// Search cell: Down leaves the search box into the channel pane.
  KeyEventResult handleSearchCellKey(FocusNode node, KeyEvent event) {
    if (!isLiveTab()) return KeyEventResult.ignored;
    if (!searchCellFocusNode.hasFocus) return KeyEventResult.ignored;
    if (event.logicalKey != LogicalKeyboardKey.arrowDown) {
      return KeyEventResult.ignored;
    }
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.handled;
    }
    focusChannelsFromCategory();
    return KeyEventResult.handled;
  }

  /// Pane-level fallback (attached to the live body's Focus widget): tracks
  /// the last known pane, handles category↔channel arrows, and routes arrows
  /// deterministically when focus lands on an unlabeled node.
  KeyEventResult handlePaneFallbackKey(FocusNode node, KeyEvent event) {
    if (!isLiveTab()) return KeyEventResult.ignored;
    if (event is! KeyDownEvent &&
        event is! KeyRepeatEvent &&
        event is! KeyUpEvent) {
      return KeyEventResult.ignored;
    }

    final label = focusRouteKey(FocusManager.instance.primaryFocus);
    final area = focusAreaFromLabel(label);
    if (area != LiveFocusArea.unknown) {
      lastFocusArea = area;
      if (area == LiveFocusArea.channels) {
        final focusedChannelId = channelIdFromFocusLabel(label);
        if (focusedChannelId != null) {
          noteFocusedChannel(focusedChannelId);
        }
      }
    }

    final key = event.logicalKey;

    if (label.startsWith(categoryLabelPrefix) &&
        key == LogicalKeyboardKey.arrowRight) {
      focusChannelsFromCategory();
      return KeyEventResult.handled;
    }
    if (label.startsWith(channelLabelPrefix) &&
        key == LogicalKeyboardKey.arrowLeft) {
      focusCategoryFromChannels();
      return KeyEventResult.handled;
    }

    if (label.startsWith(categoryLabelPrefix) &&
        key == LogicalKeyboardKey.arrowDown &&
        (event is KeyDownEvent || event is KeyRepeatEvent) &&
        _heldArea == LiveFocusArea.channels &&
        _heldForward) {
      final visible = visibleChannels();
      if (visible.isNotEmpty) {
        moveDownInChannels(_lastFocusedChannelId ?? visible.first.id);
      }
      return KeyEventResult.handled;
    }

    // If focus transiently lands on an unlabeled node, route based on the last
    // known pane so navigation stays deterministic.
    if (label == unlabeledLabel) {
      if (key == LogicalKeyboardKey.arrowRight &&
          lastFocusArea == LiveFocusArea.category) {
        focusChannelsFromCategory();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowLeft &&
          lastFocusArea == LiveFocusArea.channels) {
        focusCategoryFromChannels();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowDown &&
          lastFocusArea == LiveFocusArea.search) {
        focusChannelsFromCategory();
        return KeyEventResult.handled;
      }
    }

    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    _disposed = true;
    _digitTimer?.cancel();
    searchCellFocusNode.dispose();
    firstChannelFocusNode.dispose();
    previewFavoriteFocusNode.dispose();
    previewCatchupFocusNode.dispose();
    for (final node in _channelNodes.values) {
      node.dispose();
    }
    for (final node in _categoryNodes.values) {
      node.dispose();
    }
    super.dispose();
  }
}
