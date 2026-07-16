import 'dart:async';

import 'package:flutter/foundation.dart' hide Category;

import '../data/diagnostics_log.dart';
import '../data/library_repository.dart';
import '../data/load_token.dart';
import '../data/net.dart';
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
  int _loadGeneration = 0;
  LoadToken? _loadToken;

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
    final gen = ++_loadGeneration;
    // A newer load supersedes any still-running one — cancel its token so it
    // stops writing to the cache once this one has started.
    _loadToken?.cancel();
    final token = LoadToken();
    _loadToken = token;
    _set(() {
      loading = true;
      error = null;
    });
    try {
      repo.loadToken = token;
      final snap = await retryTransientNetworkOperation(
        () => repo.load(forceRefresh: forceRefresh),
        onRetry: (error, nextAttempt) {
          DiagnosticsLog.instance.add(
            'library',
            'retrying live source load attempt=$nextAttempt '
                'reason=${error.runtimeType}',
          );
        },
      );
      if (_disposed || gen != _loadGeneration) return;
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
      if (_disposed || gen != _loadGeneration) return;
      final message = sourceLoadErrorMessage(e);
      DiagnosticsLog.instance.add(
        'library',
        'live source load failed reason=${e.runtimeType} message=$message',
      );
      _set(() {
        error = message;
        loading = false;
      });
    }
  }

  Future<void> refreshNowNext() async {
    final gen = _loadGeneration;
    try {
      final nn = await repo.nowNext();
      if (_disposed || gen != _loadGeneration) return;
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
    _loadToken?.cancel();
    super.dispose();
  }
}
