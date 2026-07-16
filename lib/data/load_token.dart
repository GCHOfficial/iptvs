/// Cooperative cancellation for a repository load.
///
/// Additive to the controllers' generation guards (`LiveController`,
/// `MediaTabController`): the generation guard stops a stale result from
/// being *published* to the UI; this token stops a stale in-flight call from
/// *writing* to the cache or feeding more EPG batches once a newer call has
/// superseded it. Deliberately dumb — no streams, no listeners, just a flag a
/// newer call can flip on the exact instance an older call is holding.
class LoadToken {
  bool _cancelled = false;

  /// True until [cancel] is called.
  bool get isLive => !_cancelled;

  /// True once [cancel] has been called.
  bool get isCancelled => _cancelled;

  /// Marks this token cancelled. Idempotent.
  void cancel() => _cancelled = true;
}

/// Thrown by a cancellable batch stream (see `parseXmltvBatched`) when its
/// [LoadToken] is cancelled mid-stream, so an `await for` consumer — notably
/// `AppDatabase.replaceEpgStream` — sees an error and rolls back its
/// transaction, rather than silently ending the stream as if it had
/// completed the full guide. Not a real failure: callers should log this at
/// info level ("superseded"), never as a scary error.
class LoadCancelledException implements Exception {
  const LoadCancelledException();

  @override
  String toString() => 'LoadCancelledException: load superseded';
}
