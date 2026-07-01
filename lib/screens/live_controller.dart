import 'dart:async';

import 'package:flutter/foundation.dart' hide Category;

import '../data/diagnostics_log.dart';
import '../data/library_repository.dart';
import '../sources/source.dart';

/// Owns the live-TV data: the channel/category lists, the now/next EPG, and the
/// load + periodic EPG-refresh lifecycle. A [ChangeNotifier] so the screen
/// rebuilds via a listener instead of a `setState` per phase.
///
/// Deliberately *not* the live tab's focus/D-pad state or its preview player —
/// those stay in the screen (they're focus-node and platform-view heavy). The
/// selected category also stays in the screen, tied to the focus panes; this
/// controller is the data source those read from.
class LiveController extends ChangeNotifier {
  final LibraryRepository repo;

  LiveController({required this.repo});

  List<Category> categories = const [];
  List<Channel> channels = const [];
  Map<String, Programme> now = const {};
  Map<String, Programme> next = const {};
  DateTime? syncedAt;
  bool fromCache = false;
  bool loading = true;
  String? error;

  Timer? _epgTimer;
  bool _disposed = false;

  void _set(VoidCallback fn) {
    if (_disposed) return;
    fn();
    notifyListeners();
  }

  /// Start the periodic now/next refresh (call once, after the first load).
  void startEpgRefresh() {
    _epgTimer ??= Timer.periodic(
      const Duration(minutes: 1),
      (_) => refreshNowNext(),
    );
  }

  Future<void> load({bool forceRefresh = false}) async {
    _set(() {
      loading = true;
      error = null;
    });
    try {
      final snap = await repo.load(forceRefresh: forceRefresh);
      if (_disposed) return;
      DiagnosticsLog.instance.add(
        'library',
        'loaded live source=${repo.source.name} channels=${snap.channels.length} force=$forceRefresh cache=${snap.fromCache}',
      );
      _set(() {
        categories = snap.categories;
        channels = snap.channels;
        syncedAt = snap.syncedAt;
        fromCache = snap.fromCache;
        loading = false;
      });
      await refreshNowNext();
    } catch (e) {
      _set(() {
        error = '$e';
        loading = false;
      });
    }
  }

  Future<void> refreshNowNext() async {
    try {
      final nn = await repo.nowNext();
      if (_disposed) return;
      _set(() {
        now = nn.now;
        next = nn.next;
      });
    } catch (_) {}
  }

  @override
  void dispose() {
    _disposed = true;
    _epgTimer?.cancel();
    super.dispose();
  }
}
