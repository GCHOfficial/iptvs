import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show KeyDownEvent, KeyEvent, KeyRepeatEvent, KeyUpEvent, LogicalKeyboardKey;

import '../sources/source.dart';

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
/// Routing is keyed off [FocusNode.debugLabel] prefixes (the constants
/// below). They are **load-bearing routing keys**, not debug decoration —
/// every focusable the live tab creates must use them.
class LiveFocusCoordinator extends ChangeNotifier {
  /// Prefix for per-channel focus nodes: `live.channel.<channelId>`.
  static const channelLabelPrefix = 'live.channel.';

  /// Prefix for category-pane nodes: `live.category.<categoryId|all>`.
  static const categoryLabelPrefix = 'live.category.';

  /// The search box's "OK to edit" cell.
  static const searchCellLabel = 'live.search.cell';

  /// The stable node for the first visible channel row (gets `autofocus`).
  static const firstChannelLabel = '${channelLabelPrefix}first';

  /// What an unlabeled FocusNode reports — routed via [lastFocusArea].
  static const unlabeledLabel = 'Focus';

  /// Estimated height of one channel row, for jump-scrolling an off-screen
  /// target into build range before focusing it.
  static const _estimatedChannelRowExtent = 104.0;

  LiveFocusCoordinator({
    required this.scrollController,
    required this.visibleChannels,
    required this.categoryId,
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

  /// Current filtered channel list (the screen's memoized `_visible`).
  final List<Channel> Function() visibleChannels;

  /// Currently selected live category id (null = All).
  final String? Function() categoryId;

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

  final FocusNode firstChannelFocusNode = FocusNode(
    debugLabel: firstChannelLabel,
  );
  final FocusNode searchCellFocusNode = FocusNode(debugLabel: searchCellLabel);

  final Map<String, FocusNode> _channelNodes = {};
  final Map<String, FocusNode> _categoryNodes = {};
  bool _pruneScheduled = false;
  bool _disposed = false;

  /// Last channel that held focus in the list (drives the TV info panel).
  String? get lastFocusedChannelId => _lastFocusedChannelId;
  String? _lastFocusedChannelId;

  LiveFocusArea lastFocusArea = LiveFocusArea.unknown;

  /// Down-hold lock: once a Down hold starts in the channel list, subsequent
  /// Down events stay locked to channel navigation until key-up, so a held
  /// key can't leak into the category pane.
  bool _downHoldFromChannels = false;

  /// Per-category memory of the channel the user was on, so re-entering the
  /// channel pane resumes there instead of at the top.
  final Map<String, String> _lastBrowsedByCategory = {};

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
      final node = FocusNode(debugLabel: '$channelLabelPrefix$channelId');
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
    return _categoryNodes.putIfAbsent(
      key,
      () => FocusNode(debugLabel: '$categoryLabelPrefix$key'),
    );
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

  /// Move focus from the channel pane back to the selected category.
  void focusCategoryFromChannels() {
    _downHoldFromChannels = false;
    final categoryNode = focusNodeForCategory(categoryId());
    categoryNode.requestFocus();
    _reassertFocus(
      categoryNode,
      shouldRetry: (label) =>
          label.startsWith(channelLabelPrefix) || label == unlabeledLabel,
      attempts: 4,
    );
    lastFocusArea = LiveFocusArea.category;
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
      return;
    }
    noteFocusedChannel(visible[nextIndex].id);
    _focusChannelByIndex(visible, nextIndex);
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
      final label = FocusManager.instance.primaryFocus?.debugLabel ?? '';
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
    if (key == LogicalKeyboardKey.arrowDown && event is KeyUpEvent) {
      _downHoldFromChannels = false;
      return false;
    }
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;

    if (key != LogicalKeyboardKey.arrowDown) {
      _downHoldFromChannels = false;
    }

    final label = FocusManager.instance.primaryFocus?.debugLabel ?? '';
    if (key == LogicalKeyboardKey.arrowRight &&
        label.startsWith(categoryLabelPrefix)) {
      focusChannelsFromCategory();
      return true;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      final channelId = channelIdFromFocusLabel(label);
      if (channelId != null) {
        _downHoldFromChannels = true;
        noteFocusedChannel(channelId);
        moveDownInChannels(channelId);
        return true;
      }
      // Once a Down hold started in channels, keep all subsequent Down events
      // locked to channel navigation until key-up to avoid pane leakage.
      if (_downHoldFromChannels) {
        final visible = visibleChannels();
        if (visible.isEmpty) return true;
        final fallbackId = _lastFocusedChannelId ?? visible.first.id;
        moveDownInChannels(fallbackId);
        return true;
      }
      return false;
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

    final label = FocusManager.instance.primaryFocus?.debugLabel ?? '';
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
        _downHoldFromChannels) {
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
    searchCellFocusNode.dispose();
    firstChannelFocusNode.dispose();
    for (final node in _channelNodes.values) {
      node.dispose();
    }
    for (final node in _categoryNodes.values) {
      node.dispose();
    }
    super.dispose();
  }
}
