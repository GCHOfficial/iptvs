/// The one-at-a-time slot every background EPG refresh runs in.
library;

import 'dart:async';

import 'diagnostics_log.dart';
import 'load_token.dart';

/// Serialises background EPG refreshes across the whole app.
///
/// `LibraryRepository` is built per source and thrown away when the source
/// changes, so a refresh it started outlives it. Once the refresh stopped being
/// awaited by `load()` there was nothing left holding it, and two of them could
/// overlap: the outgoing source's guide still downloading while the incoming
/// source's channel list was being written. Both want the same single sqflite
/// connection, and the outgoing one is pure waste — its result is for a source
/// the user has already left.
///
/// So there is exactly one slot. Starting a refresh cancels whatever occupies
/// it and **waits for that to actually finish** before the new one begins:
/// cancellation is cooperative (`LoadToken`, checked between batches), so
/// "cancelled" and "no longer touching the database" are different moments and
/// only the second one is safe to build on.
class EpgIngestCoordinator {
  LoadToken? _token;

  /// The tail of the chain. Every [start] links onto it and replaces it, so the
  /// bookkeeping is done **synchronously** — two [start] calls in the same turn
  /// cannot both believe the slot is free, which an `await` before the
  /// assignment would have allowed.
  Future<void>? _inFlight;

  /// Whether a refresh is running or queued. Tests and diagnostics only.
  bool get isBusy => _inFlight != null;

  /// Cancels the running refresh, if any, and returns once it has stopped
  /// touching the database.
  ///
  /// Call this before foreground work that must not queue behind an ingest —
  /// chiefly the channel-list write of a newly activated source.
  Future<void> cancelAndWait() async {
    _token?.cancel();
    // Never completes with an error (see [start]), so this cannot throw into an
    // unrelated caller.
    await _inFlight;
  }

  /// Runs [body] as the single background refresh, superseding any other.
  ///
  /// [body] receives the token to honour; it is already cancelled if a newer
  /// refresh arrives. The returned future is the one a caller that *does* want
  /// to wait (a test, or a path that needs the guide before it continues) can
  /// await, while the normal caller drops it.
  ///
  /// Never completes with an error: an EPG refresh is best-effort and this
  /// future is routinely unawaited, where a rejection would surface as an
  /// unhandled asynchronous error and — in a test — fail an unrelated case.
  Future<void> start(
    String label,
    Future<void> Function(LoadToken token) body,
  ) {
    final previous = _inFlight;
    _token?.cancel();
    if (_closed) return Future<void>.value();
    final token = LoadToken();
    _token = token;

    Future<void> run() async {
      // Wait the predecessor out rather than racing it: it may still be inside
      // `replaceEpgStream`'s transaction, and starting a second guide's ingest
      // against the same connection is exactly the contention this class
      // exists to prevent.
      await previous;
      try {
        // Superseded before it ever ran — a third `start` while two were
        // already queued. Doing the work would be writing a guide the caller
        // has already replaced.
        if (token.isCancelled) return;
        await body(token);
      } catch (error) {
        DiagnosticsLog.instance.add(
          'epg',
          'background EPG refresh for $label failed: ${error.runtimeType}',
        );
      } finally {
        // Only clear the slot if it is still ours: a superseded refresh must
        // not erase its successor's bookkeeping — the same monotonic-owner rule
        // `ChannelHandlerOwner` uses for native channel handlers.
        if (identical(_token, token)) {
          _token = null;
          _inFlight = null;
        }
      }
    }

    final future = run();
    _inFlight = future;
    return future;
  }

  /// Cancels the running refresh, refuses any further ones, and returns once
  /// the running one has stopped.
  ///
  /// **`AppDatabase.close` must await this**, and the reason is worth stating
  /// because the shortcut looks safe and is not. A refresh that is mid-ingest
  /// holds an open sqflite transaction; closing the connection under it does
  /// not cancel that transaction, it just moves the wait somewhere with no
  /// cancellation and no diagnostics — `_db.close()` blocks instead, and a
  /// widget test that ends while a guide is still being written hangs there for
  /// its full ten-minute timeout with nothing but sqflite's
  /// `database has been locked` warning to go on. Waiting here costs
  /// milliseconds (the transaction is local, and the token has already stopped
  /// it from feeding more batches) and the wait is attributable.
  Future<void> shutdown() async {
    _closed = true;
    await cancelAndWait();
  }

  bool _closed = false;
}
