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

  /// Whether a guide refresh is still running behind the loaded channel list.
  ///
  /// `LibraryRepository.load` returns as soon as the channels are ready and
  /// refreshes the guide afterwards, so "loaded" and "up to date" are now two
  /// different moments. Without something saying so, pressing Reload on a
  /// source with a large guide looks instantaneous and then, some seconds
  /// later, the programme titles change on their own.
  bool epgRefreshing = false;

  /// Whether the guide refresh failed and left nothing to show.
  ///
  /// Deliberately **both** conditions. A failed refresh that still has a cached
  /// guide behind it is not worth alarming anyone about — that is exactly the
  /// retain-the-last-good-guide policy working. It is only worth saying when
  /// the screen would otherwise be indistinguishable from a source that simply
  /// has no EPG, which is the one case the user can act on (a wrong or dead
  /// guide URL).
  bool epgUnavailable = false;

  /// Whether a guide is *coming*, before one has arrived.
  ///
  /// Row height depends on whether a channel row draws an EPG line — 72 px
  /// without, 112 with — and on a source's very first load the guide now lands
  /// after the list is already built, so the rows would be laid out short and
  /// then jump. The source's own declared capability answers the question
  /// ahead of the data: Stalker and Xtream always carry a guide, M3U does when
  /// it has an EPG URL, and anything reporting `unknown` keeps the old
  /// behaviour of waiting to see.
  bool get expectsEpg =>
      epgRefreshing &&
      capabilitiesOf(repo.source).epg == CapabilityAvailability.supported;

  Timer? _epgTimer;
  StreamSubscription<String>? _epgLanded;
  bool _disposed = false;
  int _loadGeneration = 0;
  LoadToken? _loadToken;

  void _set(VoidCallback fn) {
    if (_disposed) return;
    fn();
    notifyListeners();
  }

  /// Start the periodic now/next refresh (call once, after the first load).
  ///
  /// Two clocks, not one. The timer keeps "now playing" honest as programmes
  /// roll over; the subscription catches the guide being *replaced*, which
  /// `LibraryRepository.load` now does behind the snapshot it returns rather
  /// than in front of it. Without the second one, a refresh the user explicitly
  /// asked for would leave the old guide on screen for up to a minute after the
  /// new one had already landed in the database.
  void startEpgRefresh() {
    _epgTimer ??= Timer.periodic(
      const Duration(minutes: 1),
      (_) => refreshNowNext(),
    );
    _epgLanded ??= repo.db.epgChanged.listen((sourceId) {
      // Guides for other sources reach this stream too — a background refresh
      // for the source the user just left can land here. Re-reading for one of
      // those would replace this source's now/next with an empty map, because
      // the query is scoped to `repo.source.id` and would find nothing.
      if (sourceId == repo.source.id) refreshNowNext();
    });
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
      final refresh = repo.pendingEpgRefresh;
      _set(() {
        categories = snap.categories;
        channels = snap.channels;
        syncedAt = snap.syncedAt;
        fromCache = snap.fromCache;
        loading = false;
        epgRefreshing = refresh != null;
        epgUnavailable = false;
      });
      if (refresh != null) {
        // Deliberately not awaited: the point of the background refresh is that
        // nothing waits on it. This runs however it ends — including cancelled
        // by a newer load — which is why it hangs off `whenComplete` rather
        // than the success path.
        unawaited(refresh.whenComplete(() => _settleEpgRefresh(gen)));
      }
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

  /// Records how the background guide refresh ended.
  ///
  /// Re-reads now/next **before** clearing [epgRefreshing], rather than after,
  /// because [expectsEpg] is what holds the rows at their tall extent while the
  /// guide is in flight. Clearing the flag first would drop them to 72 px for
  /// however many frames it takes the new guide to be read back, then raise
  /// them again — a flicker on exactly the load this was meant to smooth.
  Future<void> _settleEpgRefresh(int gen) async {
    if (_disposed || gen != _loadGeneration) return;
    await refreshNowNext();
    if (_disposed || gen != _loadGeneration) return;
    _set(() {
      epgRefreshing = false;
      epgUnavailable =
          repo.lastEpgRefreshFailed && now.isEmpty && next.isEmpty;
    });
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
    unawaited(_epgLanded?.cancel());
    _loadToken?.cancel();
    super.dispose();
  }
}
